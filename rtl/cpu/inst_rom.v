`timescale 1ns / 1ps
`default_nettype none

module inst_rom #(
    parameter ADDR_WIDTH = 12,
    parameter MEM_FILE = "firmware/cpu_test.hex"
) (
    input  wire        clk,
    input  wire        ce,
    input  wire [31:0] addr,
    output reg  [31:0] instr
);

localparam DEPTH = (1 << ADDR_WIDTH);

reg [31:0] mem [0:DEPTH-1];
wire [ADDR_WIDTH-1:0] word_addr;
integer i;

assign word_addr = addr[ADDR_WIDTH+1:2];

initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        mem[i] = 32'h0000_0013;
    end
    $readmemh(MEM_FILE, mem);
end

always @(posedge clk) begin
    if (ce) begin
        instr <= mem[word_addr];
    end
end

endmodule

`default_nettype wire
