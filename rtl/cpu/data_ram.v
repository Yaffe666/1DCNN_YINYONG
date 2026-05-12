`timescale 1ns / 1ps
`default_nettype none

module data_ram #(
    parameter ADDR_WIDTH = 12
) (
    input  wire        clk,
    input  wire        mem_we,
    input  wire [3:0]  mem_wstrb,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata
);

localparam DEPTH = (1 << ADDR_WIDTH);

reg [31:0] mem [0:DEPTH-1];
wire [ADDR_WIDTH-1:0] word_addr;
integer i;

assign word_addr = addr[ADDR_WIDTH+1:2];

initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        mem[i] = 32'd0;
    end
end

always @(posedge clk) begin
    if (mem_we) begin
        if (mem_wstrb[0]) begin
            mem[word_addr][7:0] <= wdata[7:0];
        end
        if (mem_wstrb[1]) begin
            mem[word_addr][15:8] <= wdata[15:8];
        end
        if (mem_wstrb[2]) begin
            mem[word_addr][23:16] <= wdata[23:16];
        end
        if (mem_wstrb[3]) begin
            mem[word_addr][31:24] <= wdata[31:24];
        end
    end
end

always @(*) begin
    rdata = mem[word_addr];
end

endmodule

`default_nettype wire
