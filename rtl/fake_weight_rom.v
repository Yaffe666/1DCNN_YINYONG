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

genvar p;
generate
    for (p = 0; p < PORTS; p = p + 1) begin : g_port
        (* rom_style = "block" *) reg signed [7:0] mem [0:DEPTH-1];

        initial begin
            $readmemh(MEM_FILE, mem);
        end

        always @(posedge clk) begin
            data_flat[p*8 +: 8] <= mem[addr_flat[p*ADDR_WIDTH +: ADDR_WIDTH]];
        end
    end
endgenerate

endmodule

`default_nettype wire
