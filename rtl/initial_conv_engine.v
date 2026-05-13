`timescale 1ns / 1ps
`default_nettype none

module initial_conv_engine #(
    parameter PAR_OC = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output reg                   busy,
    output reg                   done,
    output reg                   error,

    input  wire [15:0]           input_len,
    output reg  [15:0]           output_len,

    output reg                   input_rd_en,
    output reg  [13:0]           input_rd_addr,
    input  wire signed [7:0]     input_rd_data,

    output reg  [PAR_OC*16-1:0]  weight_addr_flat,
    input  wire [PAR_OC*8-1:0]   weight_data_flat,
    output reg  [PAR_OC*12-1:0]  bn_addr_flat,
    input  wire [PAR_OC*16-1:0]  bn_scale_q8_8_flat,
    input  wire [PAR_OC*32-1:0]  bn_bias_flat,
    input  wire [PAR_OC*8-1:0]   input_zp_flat,
    input  wire [PAR_OC*8-1:0]   weight_zp_flat,
    input  wire [PAR_OC*8-1:0]   output_zp_flat,

    output reg  [PAR_OC-1:0]     feat_wr_en,
    output reg                   feat_wr_buf_sel,
    output reg  [PAR_OC*18-1:0]  feat_wr_addr_flat,
    output reg  [PAR_OC*8-1:0]   feat_wr_data_flat,
    input  wire                  out_buf_sel
);

localparam TOTAL_OUT_CH = 12;
localparam KERNEL_SIZE = 64;
localparam STRIDE = 8;
localparam PADDING = 28;
localparam MAX_FEATURE_LEN = 2048;
localparam WB_PIPE = 6;

localparam [3:0] S_IDLE        = 4'd0;
localparam [3:0] S_LOAD_BN     = 4'd1;
localparam [3:0] S_WAIT_BN     = 4'd2;
localparam [3:0] S_CAPTURE_BN  = 4'd3;
localparam [3:0] S_TAP_REQ     = 4'd4;
localparam [3:0] S_TAP_WAIT    = 4'd5;
localparam [3:0] S_TAP_ACC     = 4'd6;
localparam [3:0] S_WB_DRAIN    = 4'd7;

reg [3:0] state;
reg [15:0] curr_pos;
reg [6:0] curr_k;
reg [6:0] issue_k;
reg [4:0] curr_oc_base;

(* DONT_TOUCH = "true" *) reg signed [31:0] acc_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [15:0] bn_scale_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [31:0] bn_bias_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  input_zp_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  weight_zp_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  output_zp_reg [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg [PAR_OC*8-1:0] weight_data_r;
(* DONT_TOUCH = "true" *) reg signed [8:0] input_preproc_r [0:PAR_OC-1];
(* DONT_TOUCH = "true" *) reg signed [8:0] wt_preproc_r    [0:PAR_OC-1];
reg [PAR_OC-1:0] rq_in_valid;

wire [PAR_OC-1:0] rq_out_valid;
wire rq_out_valid_any;
wire signed [7:0] rq_out_data [0:PAR_OC-1];

// Writeback pipeline
reg [WB_PIPE-1:0]         wb_valid;
reg [15:0]                wb_pos      [0:WB_PIPE-1];
reg [4:0]                 wb_oc_base  [0:WB_PIPE-1];
reg [PAR_OC-1:0]          wb_lanes    [0:WB_PIPE-1];
reg [2:0]                 drain_cnt;

integer lane;
integer oc_abs;
integer tap_input_index;
integer feature_addr;
reg signed [7:0] sample_data;
integer i;

function [15:0] calc_output_len;
    input [15:0] in_len;
    reg [16:0] padded_len;
    begin
        padded_len = in_len + (PADDING * 2);
        if (padded_len < KERNEL_SIZE) begin
            calc_output_len = 16'd0;
        end else begin
            calc_output_len = ((padded_len - KERNEL_SIZE) / STRIDE) + 1;
        end
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
        output_len <= 16'd0;
        curr_pos <= 16'd0;
        curr_k <= 7'd0;
        issue_k <= 7'd0;
        curr_oc_base <= 5'd0;
        input_rd_en <= 1'b0;
        input_rd_addr <= 14'd0;
        weight_addr_flat <= {(PAR_OC*16){1'b0}};
        bn_addr_flat <= {(PAR_OC*12){1'b0}};
        feat_wr_en <= {PAR_OC{1'b0}};
        feat_wr_buf_sel <= 1'b0;
        feat_wr_addr_flat <= {(PAR_OC*18){1'b0}};
        feat_wr_data_flat <= {(PAR_OC*8){1'b0}};
        rq_in_valid <= {PAR_OC{1'b0}};
        weight_data_r <= {(PAR_OC*8){1'b0}};
        for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
            input_preproc_r[lane] <= 9'sd0;
            wt_preproc_r[lane] <= 9'sd0;
        end
        wb_valid <= {WB_PIPE{1'b0}};
        drain_cnt <= 3'd0;
        for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
            acc_reg[lane] <= 32'sd0;
            bn_scale_reg[lane] <= 16'sd0;
            bn_bias_reg[lane] <= 32'sd0;
            input_zp_reg[lane] <= 8'sd0;
            weight_zp_reg[lane] <= 8'sd0;
            output_zp_reg[lane] <= 8'sd0;
        end
        for (i = 0; i < WB_PIPE; i = i + 1) begin
            wb_pos[i] <= 16'd0;
            wb_oc_base[i] <= 5'd0;
            wb_lanes[i] <= {PAR_OC{1'b0}};
        end
    end else begin
        done <= 1'b0;
        error <= 1'b0;
        input_rd_en <= 1'b0;
        input_rd_addr <= 14'd0;
        weight_addr_flat <= {(PAR_OC*16){1'b0}};
        bn_addr_flat <= {(PAR_OC*12){1'b0}};
        feat_wr_en <= {PAR_OC{1'b0}};
        feat_wr_buf_sel <= out_buf_sel;
        feat_wr_addr_flat <= {(PAR_OC*18){1'b0}};
        feat_wr_data_flat <= {(PAR_OC*8){1'b0}};
        rq_in_valid <= {PAR_OC{1'b0}};

        weight_data_r <= weight_data_flat;

        // === Writeback pipeline: shift ===
        for (i = WB_PIPE-1; i > 0; i = i - 1) begin
            wb_valid[i]   <= wb_valid[i-1];
            wb_pos[i]     <= wb_pos[i-1];
            wb_oc_base[i] <= wb_oc_base[i-1];
            wb_lanes[i]   <= wb_lanes[i-1];
        end
        wb_valid[0] <= 1'b0;

        // === Writeback pipeline: consume (stage WB_PIPE-1) ===
        if (wb_valid[WB_PIPE-1] && rq_out_valid_any) begin
            feat_wr_buf_sel <= out_buf_sel;
            for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                if (wb_lanes[WB_PIPE-1][lane]) begin
                    oc_abs = wb_oc_base[WB_PIPE-1] + lane;
                    feature_addr = (oc_abs << 11) + wb_pos[WB_PIPE-1];
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
                    output_len <= calc_output_len(input_len);
                    if ((input_len == 16'd0) || (calc_output_len(input_len) == 16'd0) || (calc_output_len(input_len) > MAX_FEATURE_LEN)) begin
                        error <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        curr_pos <= 16'd0;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        curr_oc_base <= 5'd0;
                        for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                            acc_reg[lane] <= 32'sd0;
                        end
                        state <= S_LOAD_BN;
                    end
                end
            end

            S_LOAD_BN: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    oc_abs = curr_oc_base + lane;
                    if (oc_abs < TOTAL_OUT_CH) begin
                        bn_addr_flat[lane*12 +: 12] <= oc_abs[11:0];
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
                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    oc_abs = curr_oc_base + lane;
                    if (oc_abs < TOTAL_OUT_CH) begin
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
                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    acc_reg[lane] <= 32'sd0;
                end
                tap_input_index = (curr_pos * STRIDE) + curr_k - PADDING;

                if ((tap_input_index >= 0) && (tap_input_index < input_len)) begin
                    input_rd_en <= 1'b1;
                    input_rd_addr <= tap_input_index[13:0];
                end

                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    oc_abs = curr_oc_base + lane;
                    if (oc_abs < TOTAL_OUT_CH) begin
                        weight_addr_flat[lane*16 +: 16] <= (oc_abs * KERNEL_SIZE) + curr_k;
                    end
                end
                issue_k <= 7'd1;
                state <= S_TAP_WAIT;
            end

            S_TAP_WAIT: begin
                busy <= 1'b1;
                tap_input_index = (curr_pos * STRIDE) + issue_k - PADDING;

                if ((tap_input_index >= 0) && (tap_input_index < input_len)) begin
                    input_rd_en <= 1'b1;
                    input_rd_addr <= tap_input_index[13:0];
                end

                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    oc_abs = curr_oc_base + lane;
                    if (oc_abs < TOTAL_OUT_CH) begin
                        weight_addr_flat[lane*16 +: 16] <= (oc_abs * KERNEL_SIZE) + issue_k;
                        input_preproc_r[lane] <= $signed(input_rd_data) - $signed(input_zp_reg[lane]);
                        wt_preproc_r[lane]    <= $signed(weight_data_flat[lane*8 +: 8]) - $signed(weight_zp_reg[lane]);
                    end
                end
                issue_k <= issue_k + 1'b1;
                state <= S_TAP_ACC;
            end

            S_TAP_ACC: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                    oc_abs = curr_oc_base + lane;
                    if (oc_abs < TOTAL_OUT_CH) begin
                        acc_reg[lane] <= acc_reg[lane]
                            + $signed(input_preproc_r[lane])
                            * $signed(wt_preproc_r[lane]);
                    end
                end

                if (issue_k < KERNEL_SIZE) begin
                    tap_input_index = (curr_pos * STRIDE) + issue_k - PADDING;

                    if ((tap_input_index >= 0) && (tap_input_index < input_len)) begin
                        input_rd_en <= 1'b1;
                        input_rd_addr <= tap_input_index[13:0];
                    end

                    for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                        oc_abs = curr_oc_base + lane;
                        if (oc_abs < TOTAL_OUT_CH) begin
                            weight_addr_flat[lane*16 +: 16] <= (oc_abs * KERNEL_SIZE) + issue_k;
                        end
                    end
                    issue_k <= issue_k + 1'b1;
                end

                if (curr_k == (KERNEL_SIZE - 1)) begin
                    for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                        oc_abs = curr_oc_base + lane;
                        if (oc_abs < TOTAL_OUT_CH) begin
                            rq_in_valid[lane] <= 1'b1;
                        end
                    end
                    wb_valid[0] <= 1'b1;
                    wb_pos[0] <= curr_pos;
                    wb_oc_base[0] <= curr_oc_base;
                    for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                        wb_lanes[0][lane] <= (curr_oc_base + lane < TOTAL_OUT_CH);
                    end

                    if ((curr_pos + 1'b1) < output_len) begin
                        curr_pos <= curr_pos + 1'b1;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        state <= S_TAP_REQ;
                    end else if ((curr_oc_base + PAR_OC) < TOTAL_OUT_CH) begin
                        curr_oc_base <= curr_oc_base + PAR_OC;
                        curr_pos <= 16'd0;
                        curr_k <= 7'd0;
                        issue_k <= 7'd0;
                        state <= S_LOAD_BN;
                    end else begin
                        drain_cnt <= 3'd0;
                        state <= S_WB_DRAIN;
                    end
                end else begin
                    // Preprocess next tap data for next iteration
                    for (lane = 0; lane < PAR_OC; lane = lane + 1) begin
                        oc_abs = curr_oc_base + lane;
                        if (oc_abs < TOTAL_OUT_CH) begin
                            input_preproc_r[lane] <= $signed(input_rd_data) - $signed(input_zp_reg[lane]);
                            wt_preproc_r[lane]    <= $signed(weight_data_flat[lane*8 +: 8]) - $signed(weight_zp_reg[lane]);
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
