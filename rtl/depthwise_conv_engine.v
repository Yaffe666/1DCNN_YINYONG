`timescale 1ns / 1ps
`default_nettype none

module depthwise_conv_engine #(
    parameter PAR_CH = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output reg                   busy,
    output reg                   done,
    output reg                   error,

    input  wire [2:0]            block_idx,
    input  wire [7:0]            channels,
    input  wire [15:0]           length,
    input  wire                  in_buf_sel,
    input  wire                  out_buf_sel,

    output reg  [PAR_CH-1:0]     feat_rd_en,
    output reg                   feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0]  feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]   feat_rd_data_flat,

    output reg  [PAR_CH-1:0]     feat_wr_en,
    output reg                   feat_wr_buf_sel,
    output reg  [PAR_CH*18-1:0]  feat_wr_addr_flat,
    output reg  [PAR_CH*8-1:0]   feat_wr_data_flat,

    output reg  [PAR_CH*16-1:0]  weight_addr_flat,
    input  wire [PAR_CH*8-1:0]   weight_data_flat,
    output reg  [PAR_CH*12-1:0]  bn_addr_flat,
    input  wire [PAR_CH*16-1:0]  bn_scale_q8_8_flat,
    input  wire [PAR_CH*32-1:0]  bn_bias_flat,
    input  wire [PAR_CH*8-1:0]   input_zp_flat,
    input  wire [PAR_CH*8-1:0]   weight_zp_flat,
    input  wire [PAR_CH*8-1:0]   output_zp_flat
);

localparam MAX_FEATURE_LEN = 2048;
localparam KERNEL_SIZE = 7;
localparam PADDING = 3;
localparam TOTAL_BLOCKS = 5;
localparam WB_PIPE = 6;

localparam [3:0] S_IDLE      = 4'd0;
localparam [3:0] S_LOAD_BN    = 4'd1;
localparam [3:0] S_WAIT_BN    = 4'd2;
localparam [3:0] S_CAPTURE_BN = 4'd3;
localparam [3:0] S_TAP_REQ     = 4'd4;
localparam [3:0] S_TAP_WAIT    = 4'd5;
localparam [3:0] S_TAP_WAIT2   = 4'd8;
localparam [3:0] S_TAP_PREPROC = 4'd9;
localparam [3:0] S_TAP_ACC     = 4'd6;
localparam [3:0] S_WB_DRAIN    = 4'd7;

reg [3:0] state;
reg [15:0] curr_pos;
reg [6:0] curr_k;
reg [6:0] issue_k;
reg [7:0] curr_ch_base;

reg signed [31:0] acc_reg [0:PAR_CH-1];
reg signed [15:0] bn_scale_reg [0:PAR_CH-1];
reg signed [31:0] bn_bias_reg [0:PAR_CH-1];
reg signed [7:0]  input_zp_reg [0:PAR_CH-1];
reg signed [7:0]  weight_zp_reg [0:PAR_CH-1];
reg signed [7:0]  output_zp_reg [0:PAR_CH-1];
reg [PAR_CH-1:0] rq_in_valid;
reg [PAR_CH*8-1:0] weight_data_r;
reg signed [8:0] feat_preproc_r [0:PAR_CH-1];
reg signed [8:0] wt_preproc_r [0:PAR_CH-1];

wire [PAR_CH-1:0] rq_out_valid;
wire rq_out_valid_any;
wire signed [7:0] rq_out_data [0:PAR_CH-1];

reg [WB_PIPE-1:0]         wb_valid;
reg [15:0]                wb_pos      [0:WB_PIPE-1];
reg [7:0]                 wb_ch_base  [0:WB_PIPE-1];
reg [PAR_CH-1:0]          wb_lanes    [0:WB_PIPE-1];
reg [2:0]                 drain_cnt;

integer lane;
integer ch_abs;
integer tap_pos;
integer preproc_k;
integer feature_addr;
integer bn_base;
integer weight_base;
reg signed [7:0] sample_data;
integer i;

function integer get_dw_weight_base;
    input [2:0] blk;
    begin
        case (blk)
            3'd0: get_dw_weight_base = 768;
            3'd1: get_dw_weight_base = 1140;
            3'd2: get_dw_weight_base = 2460;
            3'd3: get_dw_weight_base = 5676;
            default: get_dw_weight_base = 10416;
        endcase
    end
endfunction

function integer get_dw_bn_base;
    input [2:0] blk;
    begin
        case (blk)
            3'd0: get_dw_bn_base = 12;
            3'd1: get_dw_bn_base = 48;
            3'd2: get_dw_bn_base = 120;
            3'd3: get_dw_bn_base = 228;
            default: get_dw_bn_base = 360;
        endcase
    end
endfunction

assign rq_out_valid_any = |rq_out_valid;

genvar gi;
generate
    for (gi = 0; gi < PAR_CH; gi = gi + 1) begin : g_requant
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
        curr_k <= 7'd0;
        issue_k <= 7'd0;
        curr_ch_base <= 8'd0;
        feat_rd_en <= {PAR_CH{1'b0}};
        feat_rd_buf_sel <= 1'b0;
        feat_rd_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_en <= {PAR_CH{1'b0}};
        feat_wr_buf_sel <= 1'b0;
        feat_wr_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_data_flat <= {(PAR_CH*8){1'b0}};
        weight_addr_flat <= {(PAR_CH*16){1'b0}};
        bn_addr_flat <= {(PAR_CH*12){1'b0}};
        rq_in_valid <= {PAR_CH{1'b0}};
        weight_data_r <= {(PAR_CH*8){1'b0}};
        wb_valid <= {WB_PIPE{1'b0}};
        drain_cnt <= 3'd0;
        for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
            acc_reg[lane] <= 32'sd0;
            bn_scale_reg[lane] <= 16'sd0;
            bn_bias_reg[lane] <= 32'sd0;
            input_zp_reg[lane] <= 8'sd0;
            weight_zp_reg[lane] <= 8'sd0;
            output_zp_reg[lane] <= 8'sd0;
            feat_preproc_r[lane] <= 9'sd0;
            wt_preproc_r[lane] <= 9'sd0;
        end
        for (i = 0; i < WB_PIPE; i = i + 1) begin
            wb_pos[i] <= 16'd0;
            wb_ch_base[i] <= 8'd0;
            wb_lanes[i] <= {PAR_CH{1'b0}};
        end
    end else begin
        done <= 1'b0;
        error <= 1'b0;
        feat_rd_en <= {PAR_CH{1'b0}};
        feat_rd_buf_sel <= in_buf_sel;
        feat_rd_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_en <= {PAR_CH{1'b0}};
        feat_wr_buf_sel <= out_buf_sel;
        feat_wr_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_data_flat <= {(PAR_CH*8){1'b0}};
        weight_addr_flat <= {(PAR_CH*16){1'b0}};
        bn_addr_flat <= {(PAR_CH*12){1'b0}};
        rq_in_valid <= {PAR_CH{1'b0}};
        weight_data_r <= weight_data_flat;

        // === Writeback pipeline: shift ===
        for (i = WB_PIPE-1; i > 0; i = i - 1) begin
            wb_valid[i]   <= wb_valid[i-1];
            wb_pos[i]     <= wb_pos[i-1];
            wb_ch_base[i] <= wb_ch_base[i-1];
            wb_lanes[i]   <= wb_lanes[i-1];
        end
        wb_valid[0] <= 1'b0;

        // === Writeback pipeline: consume ===
        if (wb_valid[WB_PIPE-1] && rq_out_valid_any) begin
            feat_wr_buf_sel <= out_buf_sel;
            for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                if (wb_lanes[WB_PIPE-1][lane]) begin
                    ch_abs = wb_ch_base[WB_PIPE-1] + lane;
                    feature_addr = (ch_abs << 11) + wb_pos[WB_PIPE-1];
                    feat_wr_en[lane] <= 1'b1;
                    feat_wr_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                    feat_wr_data_flat[lane*8 +: 8] <= rq_out_data[lane];
                end
            end
            wb_valid[WB_PIPE-1] <= 1'b0;
        end

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    if ((block_idx >= TOTAL_BLOCKS) || (channels == 8'd0) || (length == 16'd0)) begin
                        error <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        curr_pos <= 16'd0;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        curr_ch_base <= 8'd0;
                        for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                            acc_reg[lane] <= 32'sd0;
                        end
                        state <= S_LOAD_BN;
                    end
                end
            end

            S_LOAD_BN: begin
                busy <= 1'b1;
                bn_base = get_dw_bn_base(block_idx);
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        bn_addr_flat[lane*12 +: 12] <= bn_base + ch_abs;
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
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        bn_scale_reg[lane] <= bn_scale_q8_8_flat[lane*16 +: 16];
                        bn_bias_reg[lane] <= bn_bias_flat[lane*32 +: 32];
                        input_zp_reg[lane] <= input_zp_flat[lane*8 +: 8];
                        weight_zp_reg[lane] <= weight_zp_flat[lane*8 +: 8];
                        output_zp_reg[lane] <= output_zp_flat[lane*8 +: 8];
                    end else begin
                        bn_scale_reg[lane] <= 16'sd0;
                        bn_bias_reg[lane] <= 32'sd0;
                        input_zp_reg[lane] <= 8'sd0;
                        weight_zp_reg[lane] <= 8'sd0;
                        output_zp_reg[lane] <= 8'sd0;
                    end
                    acc_reg[lane] <= 32'sd0;
                end
                curr_k <= 7'd0;
                issue_k <= 7'd0;
                state <= S_TAP_REQ;
            end

            S_TAP_REQ: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    acc_reg[lane] <= 32'sd0;
                end
                tap_pos = curr_pos + curr_k - PADDING;
                weight_base = get_dw_weight_base(block_idx);
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        weight_addr_flat[lane*16 +: 16] <= weight_base + (ch_abs * KERNEL_SIZE) + curr_k;
                        if ((tap_pos >= 0) && (tap_pos < length)) begin
                            feature_addr = (ch_abs << 11) + tap_pos;
                            feat_rd_en[lane] <= 1'b1;
                            feat_rd_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                        end
                    end
                end
                issue_k <= 7'd1;
                state <= S_TAP_WAIT;
            end

            S_TAP_WAIT: begin
                busy <= 1'b1;
                if (issue_k < KERNEL_SIZE) begin
                    tap_pos = curr_pos + issue_k - PADDING;
                    weight_base = get_dw_weight_base(block_idx);
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            weight_addr_flat[lane*16 +: 16] <= weight_base + (ch_abs * KERNEL_SIZE) + issue_k;
                            if ((tap_pos >= 0) && (tap_pos < length)) begin
                                feature_addr = (ch_abs << 11) + tap_pos;
                                feat_rd_en[lane] <= 1'b1;
                                feat_rd_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                            end
                        end
                    end
                    issue_k <= issue_k + 1'b1;
                end
                state <= S_TAP_WAIT2;
            end

            S_TAP_WAIT2: begin
                busy <= 1'b1;
                if (issue_k < KERNEL_SIZE) begin
                    tap_pos = curr_pos + issue_k - PADDING;
                    weight_base = get_dw_weight_base(block_idx);
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            weight_addr_flat[lane*16 +: 16] <= weight_base + (ch_abs * KERNEL_SIZE) + issue_k;
                            if ((tap_pos >= 0) && (tap_pos < length)) begin
                                feature_addr = (ch_abs << 11) + tap_pos;
                                feat_rd_en[lane] <= 1'b1;
                                feat_rd_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                            end
                        end
                    end
                    issue_k <= issue_k + 1'b1;
                end
                state <= S_TAP_PREPROC;
            end

            S_TAP_PREPROC: begin
                busy <= 1'b1;
                preproc_k = curr_k;
                tap_pos = curr_pos + preproc_k - PADDING;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        if ((tap_pos >= 0) && (tap_pos < length)) begin
                            sample_data = feat_rd_data_flat[lane*8 +: 8];
                        end else begin
                            sample_data = 8'sd0;
                        end
                        feat_preproc_r[lane] <= $signed(sample_data) - input_zp_reg[lane];
                        wt_preproc_r[lane] <= $signed(weight_data_r[lane*8 +: 8]) - weight_zp_reg[lane];
                    end else begin
                        feat_preproc_r[lane] <= 9'sd0;
                        wt_preproc_r[lane] <= 9'sd0;
                    end
                end

                if (issue_k < KERNEL_SIZE) begin
                    tap_pos = curr_pos + issue_k - PADDING;
                    weight_base = get_dw_weight_base(block_idx);
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            weight_addr_flat[lane*16 +: 16] <= weight_base + (ch_abs * KERNEL_SIZE) + issue_k;
                            if ((tap_pos >= 0) && (tap_pos < length)) begin
                                feature_addr = (ch_abs << 11) + tap_pos;
                                feat_rd_en[lane] <= 1'b1;
                                feat_rd_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                            end
                        end
                    end
                    issue_k <= issue_k + 1'b1;
                end
                state <= S_TAP_ACC;
            end

            S_TAP_ACC: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        acc_reg[lane] <= acc_reg[lane]
                            + ($signed(feat_preproc_r[lane]) * $signed(wt_preproc_r[lane]));
                    end
                end

                if (issue_k < KERNEL_SIZE) begin
                    tap_pos = curr_pos + issue_k - PADDING;
                    weight_base = get_dw_weight_base(block_idx);
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            weight_addr_flat[lane*16 +: 16] <= weight_base + (ch_abs * KERNEL_SIZE) + issue_k;
                            if ((tap_pos >= 0) && (tap_pos < length)) begin
                                feature_addr = (ch_abs << 11) + tap_pos;
                                feat_rd_en[lane] <= 1'b1;
                                feat_rd_addr_flat[lane*18 +: 18] <= feature_addr[17:0];
                            end
                        end
                    end
                    issue_k <= issue_k + 1'b1;
                end

                if (curr_k == (KERNEL_SIZE - 1)) begin
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            rq_in_valid[lane] <= 1'b1;
                        end
                    end
                    wb_valid[0] <= 1'b1;
                    wb_pos[0] <= curr_pos;
                    wb_ch_base[0] <= curr_ch_base;
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        wb_lanes[0][lane] <= (curr_ch_base + lane < channels);
                    end

                    if ((curr_pos + 1'b1) < length) begin
                        curr_pos <= curr_pos + 1'b1;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        state <= S_TAP_REQ;
                    end else if ((curr_ch_base + PAR_CH) < channels) begin
                        curr_ch_base <= curr_ch_base + PAR_CH;
                        curr_pos <= 16'd0;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        state <= S_LOAD_BN;
                    end else begin
                        drain_cnt <= 3'd0;
                        state <= S_WB_DRAIN;
                    end
                end else begin
                    preproc_k = curr_k + 1'b1;
                    tap_pos = curr_pos + preproc_k - PADDING;
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        ch_abs = curr_ch_base + lane;
                        if (ch_abs < channels) begin
                            if ((tap_pos >= 0) && (tap_pos < length)) begin
                                sample_data = feat_rd_data_flat[lane*8 +: 8];
                            end else begin
                                sample_data = 8'sd0;
                            end
                            feat_preproc_r[lane] <= $signed(sample_data) - input_zp_reg[lane];
                            wt_preproc_r[lane] <= $signed(weight_data_r[lane*8 +: 8]) - weight_zp_reg[lane];
                        end else begin
                            feat_preproc_r[lane] <= 9'sd0;
                            wt_preproc_r[lane] <= 9'sd0;
                        end
                    end
                    curr_k <= curr_k + 1'b1;
                    state <= S_TAP_ACC;
                end
            end

            S_WB_DRAIN: begin
                busy <= 1'b1;
                drain_cnt <= drain_cnt + 1'b1;
                if (drain_cnt == (WB_PIPE - 1)) begin
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
