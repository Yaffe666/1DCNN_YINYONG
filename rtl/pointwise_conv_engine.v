`timescale 1ns / 1ps
`default_nettype none

module pointwise_conv_engine #(
    parameter PAR_OC = 8,
    parameter PAR_IC = 4
) (
    input  wire                      clk,
    input  wire                      rst_n,
    input  wire                      start,
    output reg                       busy,
    output reg                       done,
    output reg                       error,

    input  wire [2:0]                block_idx,
    input  wire [7:0]                in_channels,
    input  wire [7:0]                out_channels,
    input  wire [15:0]               length,
    input  wire                      in_buf_sel,
    input  wire                      out_buf_sel,

    output reg  [PAR_IC-1:0]         feat_rd_en,
    output reg                       feat_rd_buf_sel,
    output reg  [PAR_IC*18-1:0]      feat_rd_addr_flat,
    input  wire [PAR_IC*8-1:0]       feat_rd_data_flat,

    output reg  [PAR_OC-1:0]         feat_wr_en,
    output reg                       feat_wr_buf_sel,
    output reg  [PAR_OC*18-1:0]      feat_wr_addr_flat,
    output reg  [PAR_OC*8-1:0]       feat_wr_data_flat,

    output reg  [PAR_OC*PAR_IC*16-1:0] weight_addr_flat,
    input  wire [PAR_OC*PAR_IC*8-1:0]  weight_data_flat,
    output reg  [PAR_OC*12-1:0]        bn_addr_flat,
    input  wire [PAR_OC*16-1:0]        bn_scale_q8_8_flat,
    input  wire [PAR_OC*32-1:0]        bn_bias_flat,
    input  wire [PAR_OC*8-1:0]         input_zp_flat,
    input  wire [PAR_OC*8-1:0]         weight_zp_flat,
    input  wire [PAR_OC*8-1:0]         output_zp_flat
);

localparam MAX_FEATURE_LEN = 2048;
localparam TOTAL_BLOCKS = 5;

localparam [3:0] S_IDLE      = 4'd0;
localparam [3:0] S_LOAD_BN    = 4'd1;
localparam [3:0] S_WAIT_BN    = 4'd2;
localparam [3:0] S_CAPTURE_BN = 4'd3;
localparam [3:0] S_IC_REQ     = 4'd4;
localparam [3:0] S_IC_WAIT    = 4'd5;
localparam [3:0] S_IC_ACC     = 4'd6;
localparam [3:0] S_RQ_START   = 4'd7;
localparam [3:0] S_RQ_WAIT    = 4'd8;
localparam [3:0] S_WRITE_OUT  = 4'd9;

reg [3:0] state;
reg [15:0] curr_pos;
reg [7:0] curr_oc_base;
reg [7:0] curr_ic_base;

reg signed [31:0] acc_reg [0:PAR_OC-1];
reg signed [15:0] bn_scale_reg [0:PAR_OC-1];
reg signed [31:0] bn_bias_reg [0:PAR_OC-1];
reg signed [7:0]  input_zp_reg [0:PAR_OC-1];
reg signed [7:0]  weight_zp_reg [0:PAR_OC-1];
reg signed [7:0]  output_zp_reg [0:PAR_OC-1];
reg signed [7:0]  rq_data_reg [0:PAR_OC-1];
reg [PAR_OC-1:0] rq_in_valid;

wire [PAR_OC-1:0] rq_out_valid;
wire rq_out_valid_any;
wire signed [7:0] rq_out_data [0:PAR_OC-1];

integer oc_lane;
integer ic_lane;
integer oc_abs;
integer ic_abs;
integer feature_addr;
integer bn_base;
integer weight_base;
integer ic_groups;
integer oc_group_index;
integer ic_group_index;
integer weight_addr_value;
integer weight_slot;
reg signed [7:0] feat_sample;
reg signed [7:0] wt_sample;
reg signed [31:0] sum_next;

function integer ceil_div;
    input integer value;
    input integer divisor;
    begin
        ceil_div = (value + divisor - 1) / divisor;
    end
endfunction

function integer get_pw_weight_base;
    input [2:0] blk;
    begin
        case (blk)
            3'd0: get_pw_weight_base = 852;
            3'd1: get_pw_weight_base = 1308;
            3'd2: get_pw_weight_base = 2796;
            3'd3: get_pw_weight_base = 6096;
            default: get_pw_weight_base = 10920;
        endcase
    end
endfunction

function integer get_pw_bn_base;
    input [2:0] blk;
    begin
        case (blk)
            3'd0: get_pw_bn_base = 24;
            3'd1: get_pw_bn_base = 72;
            3'd2: get_pw_bn_base = 168;
            3'd3: get_pw_bn_base = 288;
            default: get_pw_bn_base = 432;
        endcase
    end
endfunction

assign rq_out_valid_any = |rq_out_valid;

genvar gi;
generate
    for (gi = 0; gi < PAR_OC; gi = gi + 1) begin : g_requant
        requant_relu u_requant_relu (
            .clk(clk),
            .rst_n(rst_n),
            .in_valid(rq_in_valid[gi]),
            .acc_in(acc_reg[gi]),
            .scale_q8_8(bn_scale_reg[gi]),
            .bias(bn_bias_reg[gi]),
            .output_zero_point(output_zp_reg[gi]),
            .relu_en(1'b1),
            .out_valid(rq_out_valid[gi]),
            .out_data(rq_out_data[gi])
        );
    end
endgenerate

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        curr_pos <= 16'd0;
        curr_oc_base <= 8'd0;
        curr_ic_base <= 8'd0;
        feat_rd_en <= {PAR_IC{1'b0}};
        feat_rd_buf_sel <= 1'b0;
        feat_rd_addr_flat <= {(PAR_IC*18){1'b0}};
        feat_wr_en <= {PAR_OC{1'b0}};
        feat_wr_buf_sel <= 1'b0;
        feat_wr_addr_flat <= {(PAR_OC*18){1'b0}};
        feat_wr_data_flat <= {(PAR_OC*8){1'b0}};
        weight_addr_flat <= {(PAR_OC*PAR_IC*16){1'b0}};
        bn_addr_flat <= {(PAR_OC*12){1'b0}};
        rq_in_valid <= {PAR_OC{1'b0}};
        for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
            acc_reg[oc_lane] <= 32'sd0;
            bn_scale_reg[oc_lane] <= 16'sd0;
            bn_bias_reg[oc_lane] <= 32'sd0;
            input_zp_reg[oc_lane] <= 8'sd0;
            weight_zp_reg[oc_lane] <= 8'sd0;
            output_zp_reg[oc_lane] <= 8'sd0;
            rq_data_reg[oc_lane] <= 8'sd0;
        end
    end else begin
        done <= 1'b0;
        error <= 1'b0;
        feat_rd_en <= {PAR_IC{1'b0}};
        feat_rd_buf_sel <= in_buf_sel;
        feat_rd_addr_flat <= {(PAR_IC*18){1'b0}};
        feat_wr_en <= {PAR_OC{1'b0}};
        feat_wr_buf_sel <= out_buf_sel;
        feat_wr_addr_flat <= {(PAR_OC*18){1'b0}};
        feat_wr_data_flat <= {(PAR_OC*8){1'b0}};
        weight_addr_flat <= {(PAR_OC*PAR_IC*16){1'b0}};
        bn_addr_flat <= {(PAR_OC*12){1'b0}};
        rq_in_valid <= {PAR_OC{1'b0}};

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    if ((block_idx >= TOTAL_BLOCKS) || (in_channels == 8'd0) || (out_channels == 8'd0) || (length == 16'd0)) begin
                        error <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        curr_pos <= 16'd0;
                        curr_oc_base <= 8'd0;
                        curr_ic_base <= 8'd0;
                        for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                            acc_reg[oc_lane] <= 32'sd0;
                        end
                        state <= S_LOAD_BN;
                    end
                end
            end

            S_LOAD_BN: begin
                busy <= 1'b1;
                bn_base = get_pw_bn_base(block_idx);
                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    if (oc_abs < out_channels) begin
                        bn_addr_flat[oc_lane*12 +: 12] <= bn_base + oc_abs;
                    end
                end
                state <= S_WAIT_BN;
            end

            S_WAIT_BN: begin
                busy <= 1'b1;
                state <= S_CAPTURE_BN;
            end

            S_CAPTURE_BN: begin
                busy <= 1'b1;
                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    if (oc_abs < out_channels) begin
                        bn_scale_reg[oc_lane] <= bn_scale_q8_8_flat[oc_lane*16 +: 16];
                        bn_bias_reg[oc_lane] <= bn_bias_flat[oc_lane*32 +: 32];
                        input_zp_reg[oc_lane] <= input_zp_flat[oc_lane*8 +: 8];
                        weight_zp_reg[oc_lane] <= weight_zp_flat[oc_lane*8 +: 8];
                        output_zp_reg[oc_lane] <= output_zp_flat[oc_lane*8 +: 8];
                    end else begin
                        bn_scale_reg[oc_lane] <= 16'sd0;
                        bn_bias_reg[oc_lane] <= 32'sd0;
                        input_zp_reg[oc_lane] <= 8'sd0;
                        weight_zp_reg[oc_lane] <= 8'sd0;
                        output_zp_reg[oc_lane] <= 8'sd0;
                    end
                    acc_reg[oc_lane] <= 32'sd0;
                end
                curr_ic_base <= 8'd0;
                state <= S_IC_REQ;
            end

            S_IC_REQ: begin
                busy <= 1'b1;
                weight_base = get_pw_weight_base(block_idx);
                ic_groups = ceil_div(in_channels, PAR_IC);
                oc_group_index = curr_oc_base / PAR_OC;
                ic_group_index = curr_ic_base / PAR_IC;

                for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                    ic_abs = curr_ic_base + ic_lane;
                    if (ic_abs < in_channels) begin
                        feature_addr = (ic_abs * MAX_FEATURE_LEN) + curr_pos;
                        feat_rd_en[ic_lane] <= 1'b1;
                        feat_rd_addr_flat[ic_lane*18 +: 18] <= feature_addr[17:0];
                    end
                end

                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                        weight_slot = (oc_lane * PAR_IC) + ic_lane;
                        if ((oc_abs < out_channels) && ((curr_ic_base + ic_lane) < in_channels)) begin
                            weight_addr_value = weight_base + (oc_abs * in_channels) + (curr_ic_base + ic_lane);
                            weight_addr_flat[weight_slot*16 +: 16] <= weight_addr_value;
                        end
                    end
                end
                state <= S_IC_WAIT;
            end

            S_IC_WAIT: begin
                busy <= 1'b1;
                state <= S_IC_ACC;
            end

            S_IC_ACC: begin
                busy <= 1'b1;
                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    if (oc_abs < out_channels) begin
                        sum_next = acc_reg[oc_lane];
                        for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                            ic_abs = curr_ic_base + ic_lane;
                            if (ic_abs < in_channels) begin
                                weight_slot = (oc_lane * PAR_IC) + ic_lane;
                                feat_sample = feat_rd_data_flat[ic_lane*8 +: 8];
                                wt_sample = weight_data_flat[weight_slot*8 +: 8];
                                sum_next = sum_next
                                    + (($signed(feat_sample) - input_zp_reg[oc_lane])
                                    * ($signed(wt_sample) - weight_zp_reg[oc_lane]));
                            end
                        end
                        acc_reg[oc_lane] <= sum_next;
                    end
                end

                if ((curr_ic_base + PAR_IC) < in_channels) begin
                    curr_ic_base <= curr_ic_base + PAR_IC;
                    state <= S_IC_REQ;
                end else begin
                    state <= S_RQ_START;
                end
            end

            S_RQ_START: begin
                busy <= 1'b1;
                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    if (oc_abs < out_channels) begin
                        rq_in_valid[oc_lane] <= 1'b1;
                    end
                end
                state <= S_RQ_WAIT;
            end

            S_RQ_WAIT: begin
                busy <= 1'b1;
                if (rq_out_valid_any) begin
                    for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                        rq_data_reg[oc_lane] <= rq_out_data[oc_lane];
                    end
                    state <= S_WRITE_OUT;
                end
            end

            S_WRITE_OUT: begin
                busy <= 1'b1;
                for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                    oc_abs = curr_oc_base + oc_lane;
                    if (oc_abs < out_channels) begin
                        feature_addr = (oc_abs * MAX_FEATURE_LEN) + curr_pos;
                        feat_wr_en[oc_lane] <= 1'b1;
                        feat_wr_addr_flat[oc_lane*18 +: 18] <= feature_addr[17:0];
                        feat_wr_data_flat[oc_lane*8 +: 8] <= rq_data_reg[oc_lane];
                    end
                end

                if ((curr_pos + 1'b1) < length) begin
                    curr_pos <= curr_pos + 1'b1;
                    curr_ic_base <= 8'd0;
                    for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                        acc_reg[oc_lane] <= 32'sd0;
                    end
                    state <= S_IC_REQ;
                end else if ((curr_oc_base + PAR_OC) < out_channels) begin
                    curr_oc_base <= curr_oc_base + PAR_OC;
                    curr_pos <= 16'd0;
                    curr_ic_base <= 8'd0;
                    for (oc_lane = 0; oc_lane < PAR_OC; oc_lane = oc_lane + 1) begin
                        acc_reg[oc_lane] <= 32'sd0;
                    end
                    state <= S_LOAD_BN;
                end else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            end

            default: begin
                busy <= 1'b0;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule

`default_nettype wire
