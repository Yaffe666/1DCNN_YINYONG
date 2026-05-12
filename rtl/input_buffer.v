`timescale 1ns / 1ps
`default_nettype none

module input_buffer #(
    parameter ADDR_WIDTH = 14,
    parameter DEPTH = 16384
) (
    input  wire                   clk,
    input  wire                   wr_en,
    input  wire [ADDR_WIDTH-1:0]  wr_addr,
    input  wire signed [7:0]      wr_data,
    input  wire                   rd_en,
    input  wire [ADDR_WIDTH-1:0]  rd_addr,
    output reg  signed [7:0]      rd_data
);

(* ram_style = "block" *) reg signed [7:0] mem [0:DEPTH-1];

always @(posedge clk) begin
    if (wr_en) begin
        mem[wr_addr] <= wr_data;
    end

    if (rd_en) begin
        rd_data <= mem[rd_addr];
    end else begin
        rd_data <= 8'sd0;
    end
end

endmodule

`default_nettype wire
