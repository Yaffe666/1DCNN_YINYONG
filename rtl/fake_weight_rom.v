`timescale 1ns / 1ps
`default_nettype none

module fake_weight_rom #(
    parameter ADDR_WIDTH = 16,
    parameter PORTS = 1,
    parameter DEPTH = (1 << ADDR_WIDTH),
    parameter MEM_FILE = "mem/fake_weights.mem"
) (
    input  wire                        clk,
    input  wire [PORTS*ADDR_WIDTH-1:0] addr_flat,
    output reg  [PORTS*8-1:0]          data_flat
);

(* rom_style = "block" *) reg signed [7:0] mem [0:DEPTH-1];

integer i;
integer p;
reg [ADDR_WIDTH-1:0] addr_word;

initial begin
    for (i = 0; i < DEPTH; i = i + 1) begin
        case (i % 5)
            0: mem[i] = -8'sd2;
            1: mem[i] = -8'sd1;
            2: mem[i] =  8'sd0;
            3: mem[i] =  8'sd1;
            default: mem[i] = 8'sd2;
        endcase
    end
    $readmemh(MEM_FILE, mem);
end

always @(posedge clk) begin
    for (p = 0; p < PORTS; p = p + 1) begin
        addr_word = addr_flat[p*ADDR_WIDTH +: ADDR_WIDTH];
        data_flat[p*8 +: 8] <= mem[addr_word];
    end
end

endmodule

`default_nettype wire
