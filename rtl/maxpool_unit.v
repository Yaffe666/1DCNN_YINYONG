`timescale 1ns / 1ps
`default_nettype none

module maxpool_unit #(
    parameter PAR_CH = 8
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output reg                   busy,
    output reg                   done,
    output reg                   error,

    input  wire [7:0]            channels,
    input  wire [15:0]           input_len,
    output reg  [15:0]           output_len,
    input  wire                  in_buf_sel,
    input  wire                  out_buf_sel,

    output reg  [PAR_CH-1:0]     feat_rd_en,
    output reg                   feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0]  feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]   feat_rd_data_flat,

    output reg  [PAR_CH-1:0]     feat_wr_en,
    output reg                   feat_wr_buf_sel,
    output reg  [PAR_CH*18-1:0]  feat_wr_addr_flat,
    output reg  [PAR_CH*8-1:0]   feat_wr_data_flat
);

localparam MAX_FEATURE_LEN = 2048;

localparam [2:0] S_IDLE  = 3'd0;
localparam [2:0] S_RD0   = 3'd1;
localparam [2:0] S_WAIT0 = 3'd2;
localparam [2:0] S_SAVE0 = 3'd3;
localparam [2:0] S_RD1   = 3'd4;
localparam [2:0] S_WAIT1 = 3'd5;
localparam [2:0] S_SAVE1 = 3'd6;
localparam [2:0] S_WRITE = 3'd7;

reg [2:0] state;
reg [15:0] curr_pos;
reg [7:0] curr_ch_base;
reg signed [7:0] val0 [0:PAR_CH-1];
reg signed [7:0] val1 [0:PAR_CH-1];

integer lane;
integer ch_abs;
integer rd_pos;
integer feature_addr;
reg signed [7:0] max_value;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        output_len <= 16'd0;
        curr_pos <= 16'd0;
        curr_ch_base <= 8'd0;
        feat_rd_en <= {PAR_CH{1'b0}};
        feat_rd_buf_sel <= 1'b0;
        feat_rd_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_en <= {PAR_CH{1'b0}};
        feat_wr_buf_sel <= 1'b0;
        feat_wr_addr_flat <= {(PAR_CH*18){1'b0}};
        feat_wr_data_flat <= {(PAR_CH*8){1'b0}};
        for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
            val0[lane] <= 8'sd0;
            val1[lane] <= 8'sd0;
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

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    if ((channels == 8'd0) || (input_len < 16'd2)) begin
                        error <= 1'b1;
                    end else begin
                        output_len <= input_len >> 1;
                        busy <= 1'b1;
                        curr_pos <= 16'd0;
                        curr_ch_base <= 8'd0;
                        state <= S_RD0;
                    end
                end
            end

            S_RD0: begin
                busy <= 1'b1;
                rd_pos = curr_pos << 1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + rd_pos;
                        feat_rd_en[lane] <= 1'b1;
                        feat_rd_addr_flat[lane*18 +: 18] <= feature_addr;
                    end
                end
                state <= S_WAIT0;
            end

            S_WAIT0: begin
                busy <= 1'b1;
                state <= S_SAVE0;
            end

            S_SAVE0: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    val0[lane] <= feat_rd_data_flat[lane*8 +: 8];
                end

                rd_pos = (curr_pos << 1) + 1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + rd_pos;
                        feat_rd_en[lane] <= 1'b1;
                        feat_rd_addr_flat[lane*18 +: 18] <= feature_addr;
                    end
                end
                state <= S_WAIT1;
            end

            S_RD1: begin
                busy <= 1'b1;
                rd_pos = (curr_pos << 1) + 1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + rd_pos;
                        feat_rd_en[lane] <= 1'b1;
                        feat_rd_addr_flat[lane*18 +: 18] <= feature_addr;
                    end
                end
                state <= S_WAIT1;
            end

            S_WAIT1: begin
                busy <= 1'b1;
                state <= S_SAVE1;
            end

            S_SAVE1: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    val1[lane] <= feat_rd_data_flat[lane*8 +: 8];
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + curr_pos;
                        max_value = (val0[lane] >= $signed(feat_rd_data_flat[lane*8 +: 8])) ? val0[lane] : $signed(feat_rd_data_flat[lane*8 +: 8]);
                        feat_wr_en[lane] <= 1'b1;
                        feat_wr_addr_flat[lane*18 +: 18] <= feature_addr;
                        feat_wr_data_flat[lane*8 +: 8] <= max_value;
                    end
                end

                if ((curr_pos + 1'b1) < output_len) begin
                    curr_pos <= curr_pos + 1'b1;
                    state <= S_RD0;
                end else if ((curr_ch_base + PAR_CH) < channels) begin
                    curr_ch_base <= curr_ch_base + PAR_CH;
                    curr_pos <= 16'd0;
                    state <= S_RD0;
                end else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            end

            S_WRITE: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + curr_pos;
                        max_value = (val0[lane] >= val1[lane]) ? val0[lane] : val1[lane];
                        feat_wr_en[lane] <= 1'b1;
                        feat_wr_addr_flat[lane*18 +: 18] <= feature_addr;
                        feat_wr_data_flat[lane*8 +: 8] <= max_value;
                    end
                end

                if ((curr_pos + 1'b1) < output_len) begin
                    curr_pos <= curr_pos + 1'b1;
                    state <= S_RD0;
                end else if ((curr_ch_base + PAR_CH) < channels) begin
                    curr_ch_base <= curr_ch_base + PAR_CH;
                    curr_pos <= 16'd0;
                    state <= S_RD0;
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
