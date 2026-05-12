`timescale 1ns / 1ps
`default_nettype none

module gap_unit #(
    parameter PAR_CH = 8,
    parameter MAX_CHANNELS = 72
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire                  start,
    output reg                   busy,
    output reg                   done,
    output reg                   error,

    input  wire [7:0]            channels,
    input  wire [15:0]           length,
    input  wire                  in_buf_sel,

    output reg  [PAR_CH-1:0]     feat_rd_en,
    output reg                   feat_rd_buf_sel,
    output reg  [PAR_CH*18-1:0]  feat_rd_addr_flat,
    input  wire [PAR_CH*8-1:0]   feat_rd_data_flat,

    output reg                   gap_wr_en,
    output reg  [6:0]            gap_wr_addr,
    output reg  signed [7:0]     gap_wr_data
);

localparam MAX_FEATURE_LEN = 2048;

localparam [2:0] S_IDLE  = 3'd0;
localparam [2:0] S_RD    = 3'd1;
localparam [2:0] S_WAIT  = 3'd2;
localparam [2:0] S_ACC   = 3'd3;
localparam [2:0] S_WRITE = 3'd4;

reg [2:0] state;
reg [15:0] curr_pos;
reg [7:0] curr_ch_base;
reg [3:0] write_lane;
reg signed [31:0] sum_reg [0:PAR_CH-1];

integer lane;
integer ch_abs;
integer feature_addr;
integer avg_value;

function signed [7:0] sat_int8;
    input signed [31:0] value;
    begin
        if (value > 32'sd127) begin
            sat_int8 = 8'sd127;
        end else if (value < -32'sd128) begin
            sat_int8 = -8'sd128;
        end else begin
            sat_int8 = value[7:0];
        end
    end
endfunction

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        curr_pos <= 16'd0;
        curr_ch_base <= 8'd0;
        write_lane <= 4'd0;
        feat_rd_en <= {PAR_CH{1'b0}};
        feat_rd_buf_sel <= 1'b0;
        feat_rd_addr_flat <= {(PAR_CH*18){1'b0}};
        gap_wr_en <= 1'b0;
        gap_wr_addr <= 7'd0;
        gap_wr_data <= 8'sd0;
        for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
            sum_reg[lane] <= 32'sd0;
        end
    end else begin
        done <= 1'b0;
        error <= 1'b0;
        feat_rd_en <= {PAR_CH{1'b0}};
        feat_rd_buf_sel <= in_buf_sel;
        feat_rd_addr_flat <= {(PAR_CH*18){1'b0}};
        gap_wr_en <= 1'b0;
        gap_wr_addr <= 7'd0;
        gap_wr_data <= 8'sd0;

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    if ((channels == 8'd0) || (channels > MAX_CHANNELS) || (length == 16'd0)) begin
                        error <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        curr_pos <= 16'd0;
                        curr_ch_base <= 8'd0;
                        write_lane <= 4'd0;
                        for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                            sum_reg[lane] <= 32'sd0;
                        end
                        state <= S_RD;
                    end
                end
            end

            S_RD: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        feature_addr = (ch_abs * MAX_FEATURE_LEN) + curr_pos;
                        feat_rd_en[lane] <= 1'b1;
                        feat_rd_addr_flat[lane*18 +: 18] <= feature_addr;
                    end
                end
                state <= S_WAIT;
            end

            S_WAIT: begin
                busy <= 1'b1;
                state <= S_ACC;
            end

            S_ACC: begin
                busy <= 1'b1;
                for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                    ch_abs = curr_ch_base + lane;
                    if (ch_abs < channels) begin
                        sum_reg[lane] <= sum_reg[lane] + $signed(feat_rd_data_flat[lane*8 +: 8]);
                    end
                end

                if ((curr_pos + 1'b1) < length) begin
                    curr_pos <= curr_pos + 1'b1;
                    state <= S_RD;
                end else begin
                    write_lane <= 4'd0;
                    state <= S_WRITE;
                end
            end

            S_WRITE: begin
                busy <= 1'b1;
                ch_abs = curr_ch_base + write_lane;
                if (ch_abs < channels) begin
                    avg_value = sum_reg[write_lane] / length;
                    gap_wr_en <= 1'b1;
                    gap_wr_addr <= ch_abs[6:0];
                    gap_wr_data <= sat_int8(avg_value);
                end

                if ((write_lane + 1'b1) < PAR_CH) begin
                    write_lane <= write_lane + 1'b1;
                end else if ((curr_ch_base + PAR_CH) < channels) begin
                    curr_ch_base <= curr_ch_base + PAR_CH;
                    curr_pos <= 16'd0;
                    write_lane <= 4'd0;
                    for (lane = 0; lane < PAR_CH; lane = lane + 1) begin
                        sum_reg[lane] <= 32'sd0;
                    end
                    state <= S_RD;
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
