`timescale 1ns / 1ps
`default_nettype none

module cnn_accelerator_top (
    input  wire        clk,
    input  wire        rst_n_async,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tlast,

    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast,

    output wire        dbg_busy,
    output wire        dbg_done,
    output wire        dbg_error
);

localparam PAR_CH = 8;
localparam PAR_OC = 8;
localparam PAR_IC = 8;
localparam PAR_CLASS = 8;
localparam MAX_INPUT_LEN = 16384;
localparam MAX_FEATURE_LEN = 2048;
localparam MAX_CHANNELS = 72;
localparam MAX_CLASSES = 16;
localparam WEIGHT_PORTS = PAR_OC * PAR_IC;
localparam BN_PORTS = 8;

localparam [4:0] S_IDLE            = 5'd0;
localparam [4:0] S_WAIT_INPUT      = 5'd1;
localparam [4:0] S_INIT_CONV_START = 5'd2;
localparam [4:0] S_INIT_CONV_WAIT  = 5'd3;
localparam [4:0] S_DW_START        = 5'd4;
localparam [4:0] S_DW_WAIT         = 5'd5;
localparam [4:0] S_PW_START        = 5'd6;
localparam [4:0] S_PW_WAIT         = 5'd7;
localparam [4:0] S_MP_START        = 5'd8;
localparam [4:0] S_MP_WAIT         = 5'd9;
localparam [4:0] S_GAP_START       = 5'd10;
localparam [4:0] S_GAP_WAIT        = 5'd11;
localparam [4:0] S_FC_START        = 5'd12;
localparam [4:0] S_FC_WAIT         = 5'd13;
localparam [4:0] S_OUTPUT          = 5'd14;
localparam [4:0] S_DONE            = 5'd15;
localparam [4:0] S_ERROR           = 5'd16;

wire rst_n;
wire engine_rst_n;

wire reg_start_pulse;
wire reg_soft_reset_pulse;
wire reg_clear_pulse;
wire [15:0] cfg_input_len;
wire [3:0] cfg_num_blocks;
wire [4:0] cfg_num_classes;

reg status_busy;
reg status_done;
reg status_error;
reg [31:0] cycle_cnt;

reg [4:0] state;
reg [15:0] run_input_len;
reg [3:0] run_num_blocks;
reg [4:0] run_num_classes;
reg [13:0] input_count;
reg [2:0] current_block;
reg [7:0] current_channels;
reg [15:0] current_len;
reg current_buf_sel;
reg [4:0] output_index;

reg stream_wr_en;
reg [13:0] stream_wr_addr;
reg signed [7:0] stream_wr_data;

wire init_start_signal;
wire dw_start_signal;
wire pw_start_signal;
wire mp_start_signal;
wire gap_start_signal;
wire fc_start_signal;
reg init_start;
reg dw_start;
reg pw_start;
reg mp_start;
reg gap_start;
reg fc_start;

wire init_busy;
wire init_done;
wire init_error;
wire [15:0] init_output_len;
wire init_input_rd_en;
wire [13:0] init_input_rd_addr;
wire signed [7:0] input_rd_data;
wire [PAR_OC*16-1:0] init_weight_addr_flat;
wire [PAR_OC*12-1:0] init_bn_addr_flat;
wire [PAR_OC-1:0] init_feat_wr_en;
wire init_feat_wr_buf_sel;
wire [PAR_OC*18-1:0] init_feat_wr_addr_flat;
wire [PAR_OC*8-1:0] init_feat_wr_data_flat;

wire dw_busy;
wire dw_done;
wire dw_error;
wire [PAR_CH-1:0] dw_feat_rd_en;
wire dw_feat_rd_buf_sel;
wire [PAR_CH*18-1:0] dw_feat_rd_addr_flat;
wire [PAR_CH-1:0] dw_feat_wr_en;
wire dw_feat_wr_buf_sel;
wire [PAR_CH*18-1:0] dw_feat_wr_addr_flat;
wire [PAR_CH*8-1:0] dw_feat_wr_data_flat;
wire [PAR_CH*16-1:0] dw_weight_addr_flat;
wire [PAR_CH*12-1:0] dw_bn_addr_flat;

wire pw_busy;
wire pw_done;
wire pw_error;
wire [PAR_IC-1:0] pw_feat_rd_en;
wire pw_feat_rd_buf_sel;
wire [PAR_IC*18-1:0] pw_feat_rd_addr_flat;
wire [PAR_OC-1:0] pw_feat_wr_en;
wire pw_feat_wr_buf_sel;
wire [PAR_OC*18-1:0] pw_feat_wr_addr_flat;
wire [PAR_OC*8-1:0] pw_feat_wr_data_flat;
wire [PAR_OC*PAR_IC*16-1:0] pw_weight_addr_flat;
wire [PAR_OC*12-1:0] pw_bn_addr_flat;

wire mp_busy;
wire mp_done;
wire mp_error;
wire [15:0] mp_output_len;
wire [PAR_CH-1:0] mp_feat_rd_en;
wire mp_feat_rd_buf_sel;
wire [PAR_CH*18-1:0] mp_feat_rd_addr_flat;
wire [PAR_CH-1:0] mp_feat_wr_en;
wire mp_feat_wr_buf_sel;
wire [PAR_CH*18-1:0] mp_feat_wr_addr_flat;
wire [PAR_CH*8-1:0] mp_feat_wr_data_flat;

wire gap_busy;
wire gap_done;
wire gap_error;
wire [PAR_CH-1:0] gap_feat_rd_en;
wire gap_feat_rd_buf_sel;
wire [PAR_CH*18-1:0] gap_feat_rd_addr_flat;
wire gap_wr_en;
wire [6:0] gap_wr_addr;
wire signed [7:0] gap_wr_data;

wire fc_busy;
wire fc_done;
wire fc_error;
wire [PAR_IC*7-1:0] fc_gap_rd_addr_flat;
reg [PAR_IC*8-1:0] fc_gap_rd_data_flat;
wire [PAR_CLASS*PAR_IC*16-1:0] fc_weight_addr_flat;
wire [PAR_CLASS*12-1:0] fc_bn_addr_flat;
wire fc_logit_wr_en;
wire [4:0] fc_logit_wr_addr;
wire signed [7:0] fc_logit_wr_data;

reg [PAR_CH-1:0] feat_wr_en_mux;
reg feat_wr_buf_sel_mux;
reg [PAR_CH*18-1:0] feat_wr_addr_flat_mux;
reg [PAR_CH*8-1:0] feat_wr_data_flat_mux;
reg [PAR_CH-1:0] feat_rd_en_mux;
reg feat_rd_buf_sel_mux;
reg [PAR_CH*18-1:0] feat_rd_addr_flat_mux;
wire [PAR_CH*8-1:0] feat_rd_data_flat;

reg [WEIGHT_PORTS*16-1:0] weight_addr_flat_mux;
wire [WEIGHT_PORTS*8-1:0] weight_data_flat;
reg [BN_PORTS*12-1:0] bn_addr_flat_mux;
wire [BN_PORTS*16-1:0] bn_scale_q8_8_flat;
wire [BN_PORTS*32-1:0] bn_bias_flat;
wire [BN_PORTS*8-1:0] bn_input_zp_flat;
wire [BN_PORTS*8-1:0] bn_weight_zp_flat;
wire [BN_PORTS*8-1:0] bn_output_zp_flat;

reg signed [7:0] gap_vec [0:MAX_CHANNELS-1];
reg signed [7:0] logit_buf [0:MAX_CLASSES-1];

reg m_axis_tvalid_r;
reg [7:0] m_axis_tdata_r;
reg m_axis_tlast_r;

integer i;
integer ic_lane;
integer gap_addr;

function [7:0] get_pw_out_channels;
    input [2:0] blk;
    begin
        case (blk)
            3'd0: get_pw_out_channels = 8'd24;
            3'd1: get_pw_out_channels = 8'd48;
            3'd2: get_pw_out_channels = 8'd60;
            3'd3: get_pw_out_channels = 8'd72;
            default: get_pw_out_channels = 8'd72;
        endcase
    end
endfunction

wire cycle_count_enable;
wire output_backpressure;
assign cycle_count_enable = (state >= S_INIT_CONV_START) && (state <= S_OUTPUT);
assign output_backpressure = (state == S_OUTPUT) && m_axis_tvalid_r && !m_axis_tready;

assign engine_rst_n = rst_n & ~reg_soft_reset_pulse;
assign s_axis_tready = (state == S_WAIT_INPUT) && !status_error;
assign m_axis_tvalid = m_axis_tvalid_r;
assign m_axis_tdata = m_axis_tdata_r;
assign m_axis_tlast = m_axis_tlast_r;
assign dbg_busy = status_busy;
assign dbg_done = status_done;
assign dbg_error = status_error;

assign init_start_signal = init_start;
assign dw_start_signal = dw_start;
assign pw_start_signal = pw_start;
assign mp_start_signal = mp_start;
assign gap_start_signal = gap_start;
assign fc_start_signal = fc_start;

reset_sync u_reset_sync (
    .clk(clk),
    .rst_n_async(rst_n_async),
    .rst_n(rst_n)
);

axi_lite_slave_regs u_axi_lite_slave_regs (
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .start_pulse(reg_start_pulse),
    .soft_reset_pulse(reg_soft_reset_pulse),
    .clear_pulse(reg_clear_pulse),
    .cfg_input_len(cfg_input_len),
    .cfg_num_blocks(cfg_num_blocks),
    .cfg_num_classes(cfg_num_classes),
    .status_busy(status_busy),
    .status_done(status_done),
    .status_error(status_error),
    .cycle_cnt(cycle_cnt)
);

input_buffer u_input_buffer (
    .clk(clk),
    .wr_en(stream_wr_en),
    .wr_addr(stream_wr_addr),
    .wr_data(stream_wr_data),
    .rd_en(init_input_rd_en),
    .rd_addr(init_input_rd_addr),
    .rd_data(input_rd_data)
);

feature_buffer u_feature_buffer (
    .clk(clk),
    .wr_en(feat_wr_en_mux),
    .wr_buf_sel(feat_wr_buf_sel_mux),
    .wr_addr_flat(feat_wr_addr_flat_mux),
    .wr_data_flat(feat_wr_data_flat_mux),
    .rd_en(feat_rd_en_mux),
    .rd_buf_sel(feat_rd_buf_sel_mux),
    .rd_addr_flat(feat_rd_addr_flat_mux),
    .rd_data_flat(feat_rd_data_flat)
);

fake_weight_rom #(
    .ADDR_WIDTH(16),
    .PORTS(WEIGHT_PORTS),
    .MEM_FILE("D:/RICS_V_CNN/1DCNN_ACC/mem/fake_weights.mem")
) u_fake_weight_rom (
    .clk(clk),
    .addr_flat(weight_addr_flat_mux),
    .data_flat(weight_data_flat)
);

fake_bn_rom #(
    .ADDR_WIDTH(12),
    .PORTS(BN_PORTS),
    .MEM_FILE("D:/RICS_V_CNN/1DCNN_ACC/mem/fake_bn_params.mem")
) u_fake_bn_rom (
    .clk(clk),
    .addr_flat(bn_addr_flat_mux),
    .scale_q8_8_flat(bn_scale_q8_8_flat),
    .bias_flat(bn_bias_flat),
    .input_zp_flat(bn_input_zp_flat),
    .weight_zp_flat(bn_weight_zp_flat),
    .output_zp_flat(bn_output_zp_flat)
);

initial_conv_engine #(
    .PAR_OC(PAR_OC)
) u_initial_conv_engine (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(init_start_signal),
    .busy(init_busy),
    .done(init_done),
    .error(init_error),
    .input_len(run_input_len),
    .output_len(init_output_len),
    .input_rd_en(init_input_rd_en),
    .input_rd_addr(init_input_rd_addr),
    .input_rd_data(input_rd_data),
    .weight_addr_flat(init_weight_addr_flat),
    .weight_data_flat(weight_data_flat[PAR_OC*8-1:0]),
    .bn_addr_flat(init_bn_addr_flat),
    .bn_scale_q8_8_flat(bn_scale_q8_8_flat[PAR_OC*16-1:0]),
    .bn_bias_flat(bn_bias_flat[PAR_OC*32-1:0]),
    .input_zp_flat(bn_input_zp_flat[PAR_OC*8-1:0]),
    .weight_zp_flat(bn_weight_zp_flat[PAR_OC*8-1:0]),
    .output_zp_flat(bn_output_zp_flat[PAR_OC*8-1:0]),
    .feat_wr_en(init_feat_wr_en),
    .feat_wr_buf_sel(init_feat_wr_buf_sel),
    .feat_wr_addr_flat(init_feat_wr_addr_flat),
    .feat_wr_data_flat(init_feat_wr_data_flat),
    .out_buf_sel(1'b0)
);

depthwise_conv_engine #(
    .PAR_CH(PAR_CH)
) u_depthwise_conv_engine (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(dw_start_signal),
    .busy(dw_busy),
    .done(dw_done),
    .error(dw_error),
    .block_idx(current_block),
    .channels(current_channels),
    .length(current_len),
    .in_buf_sel(current_buf_sel),
    .out_buf_sel(~current_buf_sel),
    .feat_rd_en(dw_feat_rd_en),
    .feat_rd_buf_sel(dw_feat_rd_buf_sel),
    .feat_rd_addr_flat(dw_feat_rd_addr_flat),
    .feat_rd_data_flat(feat_rd_data_flat),
    .feat_wr_en(dw_feat_wr_en),
    .feat_wr_buf_sel(dw_feat_wr_buf_sel),
    .feat_wr_addr_flat(dw_feat_wr_addr_flat),
    .feat_wr_data_flat(dw_feat_wr_data_flat),
    .weight_addr_flat(dw_weight_addr_flat),
    .weight_data_flat(weight_data_flat[PAR_CH*8-1:0]),
    .bn_addr_flat(dw_bn_addr_flat),
    .bn_scale_q8_8_flat(bn_scale_q8_8_flat[PAR_CH*16-1:0]),
    .bn_bias_flat(bn_bias_flat[PAR_CH*32-1:0]),
    .input_zp_flat(bn_input_zp_flat[PAR_CH*8-1:0]),
    .weight_zp_flat(bn_weight_zp_flat[PAR_CH*8-1:0]),
    .output_zp_flat(bn_output_zp_flat[PAR_CH*8-1:0])
);

pointwise_conv_engine #(
    .PAR_OC(PAR_OC),
    .PAR_IC(PAR_IC)
) u_pointwise_conv_engine (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(pw_start_signal),
    .busy(pw_busy),
    .done(pw_done),
    .error(pw_error),
    .block_idx(current_block),
    .in_channels(current_channels),
    .out_channels(get_pw_out_channels(current_block)),
    .length(current_len),
    .in_buf_sel(current_buf_sel),
    .out_buf_sel(~current_buf_sel),
    .feat_rd_en(pw_feat_rd_en),
    .feat_rd_buf_sel(pw_feat_rd_buf_sel),
    .feat_rd_addr_flat(pw_feat_rd_addr_flat),
    .feat_rd_data_flat(feat_rd_data_flat[PAR_IC*8-1:0]),
    .feat_wr_en(pw_feat_wr_en),
    .feat_wr_buf_sel(pw_feat_wr_buf_sel),
    .feat_wr_addr_flat(pw_feat_wr_addr_flat),
    .feat_wr_data_flat(pw_feat_wr_data_flat),
    .weight_addr_flat(pw_weight_addr_flat),
    .weight_data_flat(weight_data_flat),
    .bn_addr_flat(pw_bn_addr_flat),
    .bn_scale_q8_8_flat(bn_scale_q8_8_flat[PAR_OC*16-1:0]),
    .bn_bias_flat(bn_bias_flat[PAR_OC*32-1:0]),
    .input_zp_flat(bn_input_zp_flat[PAR_OC*8-1:0]),
    .weight_zp_flat(bn_weight_zp_flat[PAR_OC*8-1:0]),
    .output_zp_flat(bn_output_zp_flat[PAR_OC*8-1:0])
);

maxpool_unit #(
    .PAR_CH(PAR_CH)
) u_maxpool_unit (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(mp_start_signal),
    .busy(mp_busy),
    .done(mp_done),
    .error(mp_error),
    .channels(current_channels),
    .input_len(current_len),
    .output_len(mp_output_len),
    .in_buf_sel(current_buf_sel),
    .out_buf_sel(~current_buf_sel),
    .feat_rd_en(mp_feat_rd_en),
    .feat_rd_buf_sel(mp_feat_rd_buf_sel),
    .feat_rd_addr_flat(mp_feat_rd_addr_flat),
    .feat_rd_data_flat(feat_rd_data_flat),
    .feat_wr_en(mp_feat_wr_en),
    .feat_wr_buf_sel(mp_feat_wr_buf_sel),
    .feat_wr_addr_flat(mp_feat_wr_addr_flat),
    .feat_wr_data_flat(mp_feat_wr_data_flat)
);

gap_unit #(
    .PAR_CH(PAR_CH),
    .MAX_CHANNELS(MAX_CHANNELS)
) u_gap_unit (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(gap_start_signal),
    .busy(gap_busy),
    .done(gap_done),
    .error(gap_error),
    .channels(current_channels),
    .length(current_len),
    .in_buf_sel(current_buf_sel),
    .feat_rd_en(gap_feat_rd_en),
    .feat_rd_buf_sel(gap_feat_rd_buf_sel),
    .feat_rd_addr_flat(gap_feat_rd_addr_flat),
    .feat_rd_data_flat(feat_rd_data_flat),
    .gap_wr_en(gap_wr_en),
    .gap_wr_addr(gap_wr_addr),
    .gap_wr_data(gap_wr_data)
);

final_conv_engine #(
    .PAR_CLASS(PAR_CLASS),
    .PAR_IC(PAR_IC),
    .MAX_CHANNELS(MAX_CHANNELS),
    .MAX_CLASSES(MAX_CLASSES)
) u_final_conv_engine (
    .clk(clk),
    .rst_n(engine_rst_n),
    .start(fc_start_signal),
    .busy(fc_busy),
    .done(fc_done),
    .error(fc_error),
    .channels(current_channels),
    .num_classes(run_num_classes),
    .gap_rd_addr_flat(fc_gap_rd_addr_flat),
    .gap_rd_data_flat(fc_gap_rd_data_flat),
    .weight_addr_flat(fc_weight_addr_flat),
    .weight_data_flat(weight_data_flat[PAR_CLASS*PAR_IC*8-1:0]),
    .bn_addr_flat(fc_bn_addr_flat),
    .bn_scale_q8_8_flat(bn_scale_q8_8_flat[PAR_CLASS*16-1:0]),
    .bn_bias_flat(bn_bias_flat[PAR_CLASS*32-1:0]),
    .input_zp_flat(bn_input_zp_flat[PAR_CLASS*8-1:0]),
    .weight_zp_flat(bn_weight_zp_flat[PAR_CLASS*8-1:0]),
    .output_zp_flat(bn_output_zp_flat[PAR_CLASS*8-1:0]),
    .logit_wr_en(fc_logit_wr_en),
    .logit_wr_addr(fc_logit_wr_addr),
    .logit_wr_data(fc_logit_wr_data)
);

always @(*) begin
    feat_wr_en_mux = {PAR_CH{1'b0}};
    feat_wr_buf_sel_mux = 1'b0;
    feat_wr_addr_flat_mux = {(PAR_CH*18){1'b0}};
    feat_wr_data_flat_mux = {(PAR_CH*8){1'b0}};
    feat_rd_en_mux = {PAR_CH{1'b0}};
    feat_rd_buf_sel_mux = 1'b0;
    feat_rd_addr_flat_mux = {(PAR_CH*18){1'b0}};

    if (init_busy || (|init_feat_wr_en)) begin
        feat_wr_en_mux = init_feat_wr_en;
        feat_wr_buf_sel_mux = init_feat_wr_buf_sel;
        feat_wr_addr_flat_mux = init_feat_wr_addr_flat;
        feat_wr_data_flat_mux = init_feat_wr_data_flat;
    end else if (dw_busy || (|dw_feat_wr_en)) begin
        feat_rd_en_mux = dw_feat_rd_en;
        feat_rd_buf_sel_mux = dw_feat_rd_buf_sel;
        feat_rd_addr_flat_mux = dw_feat_rd_addr_flat;
        feat_wr_en_mux = dw_feat_wr_en;
        feat_wr_buf_sel_mux = dw_feat_wr_buf_sel;
        feat_wr_addr_flat_mux = dw_feat_wr_addr_flat;
        feat_wr_data_flat_mux = dw_feat_wr_data_flat;
    end else if (pw_busy || (|pw_feat_wr_en)) begin
        feat_rd_en_mux[PAR_IC-1:0] = pw_feat_rd_en;
        feat_rd_buf_sel_mux = pw_feat_rd_buf_sel;
        feat_rd_addr_flat_mux[PAR_IC*18-1:0] = pw_feat_rd_addr_flat;
        feat_wr_en_mux = pw_feat_wr_en;
        feat_wr_buf_sel_mux = pw_feat_wr_buf_sel;
        feat_wr_addr_flat_mux = pw_feat_wr_addr_flat;
        feat_wr_data_flat_mux = pw_feat_wr_data_flat;
    end else if (mp_busy || (|mp_feat_wr_en)) begin
        feat_rd_en_mux = mp_feat_rd_en;
        feat_rd_buf_sel_mux = mp_feat_rd_buf_sel;
        feat_rd_addr_flat_mux = mp_feat_rd_addr_flat;
        feat_wr_en_mux = mp_feat_wr_en;
        feat_wr_buf_sel_mux = mp_feat_wr_buf_sel;
        feat_wr_addr_flat_mux = mp_feat_wr_addr_flat;
        feat_wr_data_flat_mux = mp_feat_wr_data_flat;
    end else if (gap_busy) begin
        feat_rd_en_mux = gap_feat_rd_en;
        feat_rd_buf_sel_mux = gap_feat_rd_buf_sel;
        feat_rd_addr_flat_mux = gap_feat_rd_addr_flat;
    end
end

always @(*) begin
    weight_addr_flat_mux = {(WEIGHT_PORTS*16){1'b0}};
    bn_addr_flat_mux = {(BN_PORTS*12){1'b0}};

    if (init_busy) begin
        weight_addr_flat_mux[PAR_OC*16-1:0] = init_weight_addr_flat;
        bn_addr_flat_mux[PAR_OC*12-1:0] = init_bn_addr_flat;
    end else if (dw_busy) begin
        weight_addr_flat_mux[PAR_CH*16-1:0] = dw_weight_addr_flat;
        bn_addr_flat_mux[PAR_CH*12-1:0] = dw_bn_addr_flat;
    end else if (pw_busy) begin
        weight_addr_flat_mux = pw_weight_addr_flat;
        bn_addr_flat_mux[PAR_OC*12-1:0] = pw_bn_addr_flat;
    end else if (fc_busy) begin
        weight_addr_flat_mux = fc_weight_addr_flat;
        bn_addr_flat_mux[PAR_CLASS*12-1:0] = fc_bn_addr_flat;
    end
end

always @(*) begin
    fc_gap_rd_data_flat = {(PAR_IC*8){1'b0}};
    for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
        gap_addr = fc_gap_rd_addr_flat[ic_lane*7 +: 7];
        if (gap_addr < MAX_CHANNELS) begin
            fc_gap_rd_data_flat[ic_lane*8 +: 8] = gap_vec[gap_addr];
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        status_busy <= 1'b0;
        status_done <= 1'b0;
        status_error <= 1'b0;
        cycle_cnt <= 32'd0;
        run_input_len <= 16'd2048;
        run_num_blocks <= 4'd5;
        run_num_classes <= 5'd10;
        input_count <= 14'd0;
        current_block <= 3'd0;
        current_channels <= 8'd0;
        current_len <= 16'd0;
        current_buf_sel <= 1'b0;
        output_index <= 5'd0;
        stream_wr_en <= 1'b0;
        stream_wr_addr <= 14'd0;
        stream_wr_data <= 8'sd0;
        init_start <= 1'b0;
        dw_start <= 1'b0;
        pw_start <= 1'b0;
        mp_start <= 1'b0;
        gap_start <= 1'b0;
        fc_start <= 1'b0;
        m_axis_tvalid_r <= 1'b0;
        m_axis_tdata_r <= 8'd0;
        m_axis_tlast_r <= 1'b0;
        for (i = 0; i < MAX_CHANNELS; i = i + 1) begin
            gap_vec[i] <= 8'sd0;
        end
        for (i = 0; i < MAX_CLASSES; i = i + 1) begin
            logit_buf[i] <= 8'sd0;
        end
    end else if (reg_soft_reset_pulse) begin
        state <= S_IDLE;
        status_busy <= 1'b0;
        status_done <= 1'b0;
        status_error <= 1'b0;
        cycle_cnt <= 32'd0;
        input_count <= 14'd0;
        current_block <= 3'd0;
        current_channels <= 8'd0;
        current_len <= 16'd0;
        current_buf_sel <= 1'b0;
        output_index <= 5'd0;
        stream_wr_en <= 1'b0;
        stream_wr_addr <= 14'd0;
        stream_wr_data <= 8'sd0;
        init_start <= 1'b0;
        dw_start <= 1'b0;
        pw_start <= 1'b0;
        mp_start <= 1'b0;
        gap_start <= 1'b0;
        fc_start <= 1'b0;
        m_axis_tvalid_r <= 1'b0;
        m_axis_tdata_r <= 8'd0;
        m_axis_tlast_r <= 1'b0;
    end else begin
        stream_wr_en <= 1'b0;
        init_start <= 1'b0;
        dw_start <= 1'b0;
        pw_start <= 1'b0;
        mp_start <= 1'b0;
        gap_start <= 1'b0;
        fc_start <= 1'b0;

        if (cycle_count_enable && !output_backpressure) begin
            cycle_cnt <= cycle_cnt + 1'b1;
        end

        if (gap_wr_en) begin
            gap_vec[gap_wr_addr] <= gap_wr_data;
        end

        if (fc_logit_wr_en) begin
            logit_buf[fc_logit_wr_addr] <= fc_logit_wr_data;
        end

        if (reg_clear_pulse) begin
            status_done <= 1'b0;
            status_error <= 1'b0;
            if ((state == S_DONE) || (state == S_ERROR)) begin
                state <= S_IDLE;
            end
        end else begin
            case (state)
                S_IDLE: begin
                    status_busy <= 1'b0;
                    m_axis_tvalid_r <= 1'b0;
                    m_axis_tlast_r <= 1'b0;
                    if (reg_start_pulse) begin
                        status_done <= 1'b0;
                        status_error <= 1'b0;
                        cycle_cnt <= 32'd0;
                        if ((cfg_input_len == 16'd0) || (cfg_input_len > MAX_INPUT_LEN) ||
                            (cfg_num_blocks == 4'd0) || (cfg_num_blocks > 4'd5) ||
                            (cfg_num_classes == 5'd0) || (cfg_num_classes > MAX_CLASSES)) begin
                            status_error <= 1'b1;
                            state <= S_ERROR;
                        end else begin
                            run_input_len <= cfg_input_len;
                            run_num_blocks <= cfg_num_blocks;
                            run_num_classes <= cfg_num_classes;
                            input_count <= 14'd0;
                            status_busy <= 1'b1;
                            state <= S_WAIT_INPUT;
                        end
                    end
                end

                S_WAIT_INPUT: begin
                    status_busy <= 1'b1;
                    if (s_axis_tvalid && s_axis_tready) begin
                        stream_wr_en <= 1'b1;
                        stream_wr_addr <= input_count;
                        stream_wr_data <= s_axis_tdata;

                        if (input_count == (run_input_len - 1'b1)) begin
                            if (!s_axis_tlast) begin
                                status_error <= 1'b1;
                                status_busy <= 1'b0;
                                state <= S_ERROR;
                            end else begin
                                state <= S_INIT_CONV_START;
                            end
                        end else begin
                            if (s_axis_tlast) begin
                                status_error <= 1'b1;
                                status_busy <= 1'b0;
                                state <= S_ERROR;
                            end else begin
                                input_count <= input_count + 1'b1;
                            end
                        end
                    end
                end

                S_INIT_CONV_START: begin
                    status_busy <= 1'b1;
                    init_start <= 1'b1;
                    state <= S_INIT_CONV_WAIT;
                end

                S_INIT_CONV_WAIT: begin
                    status_busy <= 1'b1;
                    if (init_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (init_done) begin
                        current_len <= init_output_len;
                        current_channels <= 8'd12;
                        current_buf_sel <= 1'b0;
                        current_block <= 3'd0;
                        state <= S_DW_START;
                    end
                end

                S_DW_START: begin
                    status_busy <= 1'b1;
                    dw_start <= 1'b1;
                    state <= S_DW_WAIT;
                end

                S_DW_WAIT: begin
                    status_busy <= 1'b1;
                    if (dw_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (dw_done) begin
                        current_buf_sel <= ~current_buf_sel;
                        state <= S_PW_START;
                    end
                end

                S_PW_START: begin
                    status_busy <= 1'b1;
                    pw_start <= 1'b1;
                    state <= S_PW_WAIT;
                end

                S_PW_WAIT: begin
                    status_busy <= 1'b1;
                    if (pw_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (pw_done) begin
                        current_buf_sel <= ~current_buf_sel;
                        current_channels <= get_pw_out_channels(current_block);
                        state <= S_MP_START;
                    end
                end

                S_MP_START: begin
                    status_busy <= 1'b1;
                    mp_start <= 1'b1;
                    state <= S_MP_WAIT;
                end

                S_MP_WAIT: begin
                    status_busy <= 1'b1;
                    if (mp_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (mp_done) begin
                        current_buf_sel <= ~current_buf_sel;
                        current_len <= mp_output_len;
                        if ((current_block + 1'b1) < run_num_blocks) begin
                            current_block <= current_block + 1'b1;
                            state <= S_DW_START;
                        end else begin
                            state <= S_GAP_START;
                        end
                    end
                end

                S_GAP_START: begin
                    status_busy <= 1'b1;
                    gap_start <= 1'b1;
                    state <= S_GAP_WAIT;
                end

                S_GAP_WAIT: begin
                    status_busy <= 1'b1;
                    if (gap_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (gap_done) begin
                        state <= S_FC_START;
                    end
                end

                S_FC_START: begin
                    status_busy <= 1'b1;
                    fc_start <= 1'b1;
                    state <= S_FC_WAIT;
                end

                S_FC_WAIT: begin
                    status_busy <= 1'b1;
                    if (fc_error) begin
                        status_error <= 1'b1;
                        status_busy <= 1'b0;
                        state <= S_ERROR;
                    end else if (fc_done) begin
                        output_index <= 5'd0;
                        m_axis_tvalid_r <= 1'b0;
                        m_axis_tlast_r <= 1'b0;
                        state <= S_OUTPUT;
                    end
                end

                S_OUTPUT: begin
                    status_busy <= 1'b1;
                    if (!m_axis_tvalid_r) begin
                        m_axis_tvalid_r <= 1'b1;
                        m_axis_tdata_r <= logit_buf[output_index];
                        m_axis_tlast_r <= (output_index == (run_num_classes - 1'b1));
                    end else if (m_axis_tready) begin
                        if (output_index == (run_num_classes - 1'b1)) begin
                            m_axis_tvalid_r <= 1'b0;
                            m_axis_tlast_r <= 1'b0;
                            status_busy <= 1'b0;
                            status_done <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            output_index <= output_index + 1'b1;
                            m_axis_tdata_r <= logit_buf[output_index + 1'b1];
                            m_axis_tlast_r <= ((output_index + 1'b1) == (run_num_classes - 1'b1));
                        end
                    end
                end

                S_DONE: begin
                    status_busy <= 1'b0;
                    status_done <= 1'b1;
                end

                S_ERROR: begin
                    status_busy <= 1'b0;
                    status_error <= 1'b1;
                    m_axis_tvalid_r <= 1'b0;
                    m_axis_tlast_r <= 1'b0;
                end

                default: begin
                    status_busy <= 1'b0;
                    status_error <= 1'b1;
                    state <= S_ERROR;
                end
            endcase
        end
    end
end

endmodule

`default_nettype wire
