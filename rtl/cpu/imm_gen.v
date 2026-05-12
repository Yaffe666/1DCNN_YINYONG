`timescale 1ns / 1ps
`default_nettype none

module imm_gen (
    input  wire [31:0] instr,
    output reg  [31:0] imm_i,
    output reg  [31:0] imm_s,
    output reg  [31:0] imm_b,
    output reg  [31:0] imm_u,
    output reg  [31:0] imm_j
);

always @(*) begin
    imm_i = {{20{instr[31]}}, instr[31:20]};
    imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    imm_u = {instr[31:12], 12'd0};
    imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
end

endmodule

`default_nettype wire
