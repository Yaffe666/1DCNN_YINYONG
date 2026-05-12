`timescale 1ns / 1ps
`default_nettype none

module alu (
    input  wire [3:0]  alu_op,
    input  wire [31:0] src_a,
    input  wire [31:0] src_b,
    output reg  [31:0] result
);

localparam [3:0] ALU_ADD  = 4'd0;
localparam [3:0] ALU_SUB  = 4'd1;
localparam [3:0] ALU_SLL  = 4'd2;
localparam [3:0] ALU_SLT  = 4'd3;
localparam [3:0] ALU_SLTU = 4'd4;
localparam [3:0] ALU_XOR  = 4'd5;
localparam [3:0] ALU_SRL  = 4'd6;
localparam [3:0] ALU_SRA  = 4'd7;
localparam [3:0] ALU_OR   = 4'd8;
localparam [3:0] ALU_AND  = 4'd9;

always @(*) begin
    case (alu_op)
        ALU_ADD:  result = src_a + src_b;
        ALU_SUB:  result = src_a - src_b;
        ALU_SLL:  result = src_a << src_b[4:0];
        ALU_SLT:  result = ($signed(src_a) < $signed(src_b)) ? 32'd1 : 32'd0;
        ALU_SLTU: result = (src_a < src_b) ? 32'd1 : 32'd0;
        ALU_XOR:  result = src_a ^ src_b;
        ALU_SRL:  result = src_a >> src_b[4:0];
        ALU_SRA:  result = $signed(src_a) >>> src_b[4:0];
        ALU_OR:   result = src_a | src_b;
        ALU_AND:  result = src_a & src_b;
        default:  result = 32'd0;
    endcase
end

endmodule

`default_nettype wire
