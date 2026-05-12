`timescale 1ns / 1ps
`default_nettype none

module ctrl_unit (
    input  wire [31:0] instr,
    output reg  [3:0]  alu_op,
    output reg  [1:0]  alu_src_a_sel,
    output reg  [2:0]  alu_src_b_sel,
    output reg         reg_write,
    output reg         mem_read,
    output reg         mem_write,
    output reg         mem_to_reg,
    output reg  [2:0]  branch_type,
    output reg  [1:0]  jump_type,
    output reg  [2:0]  load_type,
    output reg  [2:0]  store_type,
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_fence,
    output reg         illegal_instr
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

localparam [1:0] SRC_A_RS1  = 2'd0;
localparam [1:0] SRC_A_PC   = 2'd1;
localparam [1:0] SRC_A_ZERO = 2'd2;

localparam [2:0] SRC_B_RS2   = 3'd0;
localparam [2:0] SRC_B_IMM_I = 3'd1;
localparam [2:0] SRC_B_IMM_S = 3'd2;
localparam [2:0] SRC_B_IMM_U = 3'd3;
localparam [2:0] SRC_B_FOUR  = 3'd4;

localparam [2:0] BR_NONE = 3'd0;
localparam [2:0] BR_BEQ  = 3'd1;
localparam [2:0] BR_BNE  = 3'd2;
localparam [2:0] BR_BLT  = 3'd3;
localparam [2:0] BR_BGE  = 3'd4;
localparam [2:0] BR_BLTU = 3'd5;
localparam [2:0] BR_BGEU = 3'd6;

localparam [1:0] JMP_NONE = 2'd0;
localparam [1:0] JMP_JAL  = 2'd1;
localparam [1:0] JMP_JALR = 2'd2;

localparam [2:0] LD_NONE = 3'd0;
localparam [2:0] LD_LW   = 3'd1;
localparam [2:0] ST_NONE = 3'd0;
localparam [2:0] ST_SW   = 3'd1;

wire [6:0] opcode = instr[6:0];
wire [2:0] funct3 = instr[14:12];
wire [6:0] funct7 = instr[31:25];

always @(*) begin
    alu_op = ALU_ADD;
    alu_src_a_sel = SRC_A_RS1;
    alu_src_b_sel = SRC_B_RS2;
    reg_write = 1'b0;
    mem_read = 1'b0;
    mem_write = 1'b0;
    mem_to_reg = 1'b0;
    branch_type = BR_NONE;
    jump_type = JMP_NONE;
    load_type = LD_NONE;
    store_type = ST_NONE;
    is_ecall = 1'b0;
    is_ebreak = 1'b0;
    is_fence = 1'b0;
    illegal_instr = 1'b0;

    case (opcode)
        7'b0110011: begin
            reg_write = 1'b1;
            case (funct3)
                3'b000: begin
                    if (funct7 == 7'b0000000) begin
                        alu_op = ALU_ADD;
                    end else if (funct7 == 7'b0100000) begin
                        alu_op = ALU_SUB;
                    end else begin
                        illegal_instr = 1'b1;
                    end
                end
                3'b001: begin
                    alu_op = ALU_SLL;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b010: begin
                    alu_op = ALU_SLT;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b011: begin
                    alu_op = ALU_SLTU;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b100: begin
                    alu_op = ALU_XOR;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b101: begin
                    if (funct7 == 7'b0000000) begin
                        alu_op = ALU_SRL;
                    end else if (funct7 == 7'b0100000) begin
                        alu_op = ALU_SRA;
                    end else begin
                        illegal_instr = 1'b1;
                    end
                end
                3'b110: begin
                    alu_op = ALU_OR;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b111: begin
                    alu_op = ALU_AND;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                default: illegal_instr = 1'b1;
            endcase
        end

        7'b0010011: begin
            reg_write = 1'b1;
            alu_src_b_sel = SRC_B_IMM_I;
            case (funct3)
                3'b000: alu_op = ALU_ADD;
                3'b010: alu_op = ALU_SLT;
                3'b011: alu_op = ALU_SLTU;
                3'b100: alu_op = ALU_XOR;
                3'b110: alu_op = ALU_OR;
                3'b111: alu_op = ALU_AND;
                3'b001: begin
                    alu_op = ALU_SLL;
                    illegal_instr = (funct7 != 7'b0000000);
                end
                3'b101: begin
                    if (funct7 == 7'b0000000) begin
                        alu_op = ALU_SRL;
                    end else if (funct7 == 7'b0100000) begin
                        alu_op = ALU_SRA;
                    end else begin
                        illegal_instr = 1'b1;
                    end
                end
                default: illegal_instr = 1'b1;
            endcase
        end

        7'b0000011: begin
            if (funct3 == 3'b010) begin
                alu_op = ALU_ADD;
                alu_src_b_sel = SRC_B_IMM_I;
                reg_write = 1'b1;
                mem_read = 1'b1;
                mem_to_reg = 1'b1;
                load_type = LD_LW;
            end else begin
                illegal_instr = 1'b1;
            end
        end

        7'b0100011: begin
            if (funct3 == 3'b010) begin
                alu_op = ALU_ADD;
                alu_src_b_sel = SRC_B_IMM_S;
                mem_write = 1'b1;
                store_type = ST_SW;
            end else begin
                illegal_instr = 1'b1;
            end
        end

        7'b1100011: begin
            case (funct3)
                3'b000: branch_type = BR_BEQ;
                3'b001: branch_type = BR_BNE;
                3'b100: branch_type = BR_BLT;
                3'b101: branch_type = BR_BGE;
                3'b110: branch_type = BR_BLTU;
                3'b111: branch_type = BR_BGEU;
                default: illegal_instr = 1'b1;
            endcase
        end

        7'b1101111: begin
            reg_write = 1'b1;
            alu_src_a_sel = SRC_A_PC;
            alu_src_b_sel = SRC_B_FOUR;
            jump_type = JMP_JAL;
        end

        7'b1100111: begin
            if (funct3 == 3'b000) begin
                reg_write = 1'b1;
                alu_src_a_sel = SRC_A_PC;
                alu_src_b_sel = SRC_B_FOUR;
                jump_type = JMP_JALR;
            end else begin
                illegal_instr = 1'b1;
            end
        end

        7'b0110111: begin
            reg_write = 1'b1;
            alu_src_a_sel = SRC_A_ZERO;
            alu_src_b_sel = SRC_B_IMM_U;
            alu_op = ALU_ADD;
        end

        7'b0010111: begin
            reg_write = 1'b1;
            alu_src_a_sel = SRC_A_PC;
            alu_src_b_sel = SRC_B_IMM_U;
            alu_op = ALU_ADD;
        end

        7'b1110011: begin
            if (instr == 32'h0000_0073) begin
                is_ecall = 1'b1;
            end else if (instr == 32'h0010_0073) begin
                is_ebreak = 1'b1;
            end else begin
                illegal_instr = 1'b1;
            end
        end

        7'b0001111: begin
            is_fence = 1'b1;
        end

        default: begin
            illegal_instr = 1'b1;
        end
    endcase

    if (illegal_instr) begin
        reg_write = 1'b0;
        mem_read = 1'b0;
        mem_write = 1'b0;
        mem_to_reg = 1'b0;
        branch_type = BR_NONE;
        jump_type = JMP_NONE;
        load_type = LD_NONE;
        store_type = ST_NONE;
    end
end

endmodule

`default_nettype wire
