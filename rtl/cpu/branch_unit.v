`timescale 1ns / 1ps
`default_nettype none

module branch_unit (
    input  wire [2:0]  branch_type,
    input  wire [31:0] rs1_data,
    input  wire [31:0] rs2_data,
    output reg         branch_taken
);

localparam [2:0] BR_NONE = 3'd0;
localparam [2:0] BR_BEQ  = 3'd1;
localparam [2:0] BR_BNE  = 3'd2;
localparam [2:0] BR_BLT  = 3'd3;
localparam [2:0] BR_BGE  = 3'd4;
localparam [2:0] BR_BLTU = 3'd5;
localparam [2:0] BR_BGEU = 3'd6;

always @(*) begin
    case (branch_type)
        BR_BEQ:  branch_taken = (rs1_data == rs2_data);
        BR_BNE:  branch_taken = (rs1_data != rs2_data);
        BR_BLT:  branch_taken = ($signed(rs1_data) < $signed(rs2_data));
        BR_BGE:  branch_taken = ($signed(rs1_data) >= $signed(rs2_data));
        BR_BLTU: branch_taken = (rs1_data < rs2_data);
        BR_BGEU: branch_taken = (rs1_data >= rs2_data);
        BR_NONE: branch_taken = 1'b0;
        default: branch_taken = 1'b0;
    endcase
end

endmodule

`default_nettype wire
