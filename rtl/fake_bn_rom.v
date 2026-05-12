`timescale 1ns / 1ps
`default_nettype none

module fake_bn_rom #(
    parameter ADDR_WIDTH = 12,
    parameter PORTS = 1,
    parameter DEPTH = (1 << ADDR_WIDTH),
    parameter MEM_FILE = "mem/fake_bn_params.mem"
) (
    input  wire                        clk,
    input  wire [PORTS*ADDR_WIDTH-1:0] addr_flat,
    output reg  [PORTS*16-1:0]         scale_q8_8_flat,
    output reg  [PORTS*32-1:0]         bias_flat,
    output reg  [PORTS*8-1:0]          input_zp_flat,
    output reg  [PORTS*8-1:0]          weight_zp_flat,
    output reg  [PORTS*8-1:0]          output_zp_flat
);

localparam [71:0] DEFAULT_ENTRY = {16'h0100, 32'h00000000, 8'h00, 8'h00, 8'h00};

(* rom_style = "block" *) reg [71:0] mem [0:DEPTH-1];

integer i;
integer p;
reg [ADDR_WIDTH-1:0] addr_word;
reg [71:0] entry_word;

initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        mem[i] = DEFAULT_ENTRY;
    end
    $readmemh(MEM_FILE, mem);
end

always @(posedge clk) begin
    for (p = 0; p < PORTS; p = p + 1) begin
        addr_word = addr_flat[p*ADDR_WIDTH +: ADDR_WIDTH];
        entry_word = mem[addr_word];
        scale_q8_8_flat[p*16 +: 16] <= entry_word[71:56];
        bias_flat[p*32 +: 32] <= entry_word[55:24];
        input_zp_flat[p*8 +: 8] <= entry_word[23:16];
        weight_zp_flat[p*8 +: 8] <= entry_word[15:8];
        output_zp_flat[p*8 +: 8] <= entry_word[7:0];
    end
end

endmodule

`default_nettype wire
