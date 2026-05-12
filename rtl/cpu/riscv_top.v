`timescale 1ns / 1ps
`default_nettype none

module riscv_top #(
    parameter INST_MEM_FILE = "firmware/cpu_test.hex"
) (
    input  wire        clk,
    input  wire        rst_n,

    output wire [31:0] m_axi_awaddr,
    output wire        m_axi_awvalid,
    input  wire        m_axi_awready,
    output wire [31:0] m_axi_wdata,
    output wire [3:0]  m_axi_wstrb,
    output wire        m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output wire        m_axi_bready,

    output wire [31:0] m_axi_araddr,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready,

    output reg         test_done,
    output reg  [31:0] test_value,
    output reg         halted,
    output wire [31:0] dbg_pc
);

localparam [31:0] NOP_INSTR = 32'h0000_0013;
localparam [31:0] TEST_OUTPUT_ADDR = 32'h1000_0020;

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
localparam [1:0] JMP_NONE = 2'd0;
localparam [1:0] JMP_JAL  = 2'd1;
localparam [1:0] JMP_JALR = 2'd2;

reg [31:0] pc;
reg [31:0] fetch_pc_r;
reg        fetch_valid_r;
reg [31:0] if_buf_pc;
reg [31:0] if_buf_instr;
reg        if_buf_valid;
wire [31:0] if_instr;

reg [31:0] if_id_pc;
reg [31:0] if_id_instr;
reg        if_id_valid;

wire [4:0] id_rs1;
wire [4:0] id_rs2;
wire [4:0] id_rd;
wire [31:0] id_rs1_data;
wire [31:0] id_rs2_data;
wire [31:0] id_rs1_data_bypass;
wire [31:0] id_rs2_data_bypass;
wire [31:0] id_imm_i;
wire [31:0] id_imm_s;
wire [31:0] id_imm_b;
wire [31:0] id_imm_u;
wire [31:0] id_imm_j;
wire [3:0] id_alu_op;
wire [1:0] id_alu_src_a_sel;
wire [2:0] id_alu_src_b_sel;
wire id_reg_write;
wire id_mem_read;
wire id_mem_write;
wire id_mem_to_reg;
wire [2:0] id_branch_type;
wire [1:0] id_jump_type;
wire [2:0] id_load_type;
wire [2:0] id_store_type;
wire id_is_ecall;
wire id_is_ebreak;
wire id_is_fence;
wire id_illegal_instr;

reg [31:0] id_ex_pc;
reg [31:0] id_ex_rs1_val;
reg [31:0] id_ex_rs2_val;
reg [31:0] id_ex_imm_i;
reg [31:0] id_ex_imm_s;
reg [31:0] id_ex_imm_b;
reg [31:0] id_ex_imm_u;
reg [31:0] id_ex_imm_j;
reg [4:0]  id_ex_rs1;
reg [4:0]  id_ex_rs2;
reg [4:0]  id_ex_rd;
reg [3:0]  id_ex_alu_op;
reg [1:0]  id_ex_alu_src_a_sel;
reg [2:0]  id_ex_alu_src_b_sel;
reg        id_ex_reg_write;
reg        id_ex_mem_read;
reg        id_ex_mem_write;
reg        id_ex_mem_to_reg;
reg [2:0]  id_ex_branch_type;
reg [1:0]  id_ex_jump_type;
reg        id_ex_is_ecall;
reg        id_ex_is_ebreak;
reg        id_ex_illegal_instr;
reg        id_ex_valid;

wire [1:0] fwd_a_sel;
wire [1:0] fwd_b_sel;
wire [31:0] ex_rs1_fwd;
wire [31:0] ex_rs2_fwd;
reg  [31:0] ex_src_a;
reg  [31:0] ex_src_b;
wire [31:0] ex_alu_result;
wire branch_condition_taken;
wire ex_branch_taken;
wire ex_jump_taken;
wire ex_control_taken;
reg  [31:0] ex_control_target;
wire ex_halt_instr;

reg [31:0] ex_mem_alu_result;
reg [31:0] ex_mem_store_data;
reg [4:0]  ex_mem_rd;
reg        ex_mem_reg_write;
reg        ex_mem_mem_read;
reg        ex_mem_mem_write;
reg        ex_mem_mem_to_reg;
reg        ex_mem_valid;

wire ex_mem_mem_access;
wire ex_mem_local_access;
wire ex_mem_external_access;
wire ex_mem_bad_access;
wire local_mem_we;
wire [31:0] local_ram_rdata;

wire axi_req_valid;
wire axi_req_ready;
wire axi_req_write;
wire [31:0] axi_req_addr;
wire [31:0] axi_req_wdata;
wire [3:0] axi_req_wstrb;
wire axi_resp_valid;
wire axi_resp_ready;
wire [31:0] axi_resp_rdata;
wire axi_resp_error;
reg axi_req_issued;
wire mem_external_wait;
wire mem_access_error;
wire [31:0] mem_load_data;
wire [31:0] mem_wb_next_data;

reg [31:0] mem_wb_wb_data;
reg [4:0]  mem_wb_rd;
reg        mem_wb_reg_write;
reg        mem_wb_valid;

wire wb_reg_write;
wire stall_f;
wire stall_d;
wire flush_d;
wire flush_e;
wire pipeline_hold;

assign dbg_pc = pc;
assign id_rs1 = if_id_instr[19:15];
assign id_rs2 = if_id_instr[24:20];
assign id_rd = if_id_instr[11:7];
assign wb_reg_write = mem_wb_valid && mem_wb_reg_write && !halted;
assign id_rs1_data_bypass = (wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rs1)) ? mem_wb_wb_data : id_rs1_data;
assign id_rs2_data_bypass = (wb_reg_write && (mem_wb_rd != 5'd0) && (mem_wb_rd == id_rs2)) ? mem_wb_wb_data : id_rs2_data;

assign ex_rs1_fwd = (fwd_a_sel == 2'd1) ? ex_mem_alu_result :
                    (fwd_a_sel == 2'd2) ? mem_wb_wb_data :
                    id_ex_rs1_val;
assign ex_rs2_fwd = (fwd_b_sel == 2'd1) ? ex_mem_alu_result :
                    (fwd_b_sel == 2'd2) ? mem_wb_wb_data :
                    id_ex_rs2_val;

assign ex_branch_taken = id_ex_valid && (id_ex_branch_type != BR_NONE) && branch_condition_taken;
assign ex_jump_taken = id_ex_valid && (id_ex_jump_type != JMP_NONE);
assign ex_control_taken = ex_branch_taken || ex_jump_taken;
assign ex_halt_instr = id_ex_valid && (id_ex_is_ecall || id_ex_is_ebreak || id_ex_illegal_instr);

assign ex_mem_mem_access = ex_mem_valid && (ex_mem_mem_read || ex_mem_mem_write);
assign ex_mem_local_access = ex_mem_mem_access && (ex_mem_alu_result[31:28] == 4'h0);
assign ex_mem_external_access = ex_mem_mem_access && (ex_mem_alu_result[31:16] == 16'h1000);
assign ex_mem_bad_access = ex_mem_mem_access && !ex_mem_local_access && !ex_mem_external_access;
assign local_mem_we = ex_mem_valid && ex_mem_mem_write && ex_mem_local_access && !halted;
assign axi_req_valid = ex_mem_external_access && !axi_req_issued && !halted;
assign axi_req_write = ex_mem_mem_write;
assign axi_req_addr = ex_mem_alu_result;
assign axi_req_wdata = ex_mem_store_data;
assign axi_req_wstrb = ex_mem_mem_write ? 4'hF : 4'h0;
assign axi_resp_ready = ex_mem_external_access && axi_resp_valid;
assign mem_external_wait = ex_mem_external_access && !axi_resp_valid;
assign pipeline_hold = mem_external_wait;
assign mem_access_error = ex_mem_bad_access || (ex_mem_external_access && axi_resp_valid && axi_resp_error);
assign mem_load_data = ex_mem_external_access ? axi_resp_rdata : local_ram_rdata;
assign mem_wb_next_data = ex_mem_mem_to_reg ? mem_load_data : ex_mem_alu_result;

inst_rom #(
    .MEM_FILE(INST_MEM_FILE)
) u_inst_rom (
    .clk(clk),
    .ce(!stall_f),
    .addr(pc),
    .instr(if_instr)
);

regfile u_regfile (
    .clk(clk),
    .rst_n(rst_n),
    .rs1_addr(id_rs1),
    .rs2_addr(id_rs2),
    .rs1_data(id_rs1_data),
    .rs2_data(id_rs2_data),
    .rd_we(wb_reg_write),
    .rd_addr(mem_wb_rd),
    .rd_data(mem_wb_wb_data)
);

imm_gen u_imm_gen (
    .instr(if_id_instr),
    .imm_i(id_imm_i),
    .imm_s(id_imm_s),
    .imm_b(id_imm_b),
    .imm_u(id_imm_u),
    .imm_j(id_imm_j)
);

ctrl_unit u_ctrl_unit (
    .instr(if_id_instr),
    .alu_op(id_alu_op),
    .alu_src_a_sel(id_alu_src_a_sel),
    .alu_src_b_sel(id_alu_src_b_sel),
    .reg_write(id_reg_write),
    .mem_read(id_mem_read),
    .mem_write(id_mem_write),
    .mem_to_reg(id_mem_to_reg),
    .branch_type(id_branch_type),
    .jump_type(id_jump_type),
    .load_type(id_load_type),
    .store_type(id_store_type),
    .is_ecall(id_is_ecall),
    .is_ebreak(id_is_ebreak),
    .is_fence(id_is_fence),
    .illegal_instr(id_illegal_instr)
);

hazard_unit u_hazard_unit (
    .id_rs1(id_rs1),
    .id_rs2(id_rs2),
    .ex_rs1(id_ex_rs1),
    .ex_rs2(id_ex_rs2),
    .ex_rd(id_ex_rd),
    .ex_mem_read(id_ex_mem_read),
    .mem_rd(ex_mem_rd),
    .mem_reg_write(ex_mem_reg_write),
    .wb_rd(mem_wb_rd),
    .wb_reg_write(mem_wb_reg_write),
    .branch_taken(ex_control_taken),
    .axi_stall(pipeline_hold),
    .stall_f(stall_f),
    .stall_d(stall_d),
    .flush_d(flush_d),
    .flush_e(flush_e),
    .fwd_a_sel(fwd_a_sel),
    .fwd_b_sel(fwd_b_sel)
);

always @(*) begin
    case (id_ex_alu_src_a_sel)
        SRC_A_PC: ex_src_a = id_ex_pc;
        SRC_A_ZERO: ex_src_a = 32'd0;
        SRC_A_RS1: ex_src_a = ex_rs1_fwd;
        default: ex_src_a = ex_rs1_fwd;
    endcase

    case (id_ex_alu_src_b_sel)
        SRC_B_IMM_I: ex_src_b = id_ex_imm_i;
        SRC_B_IMM_S: ex_src_b = id_ex_imm_s;
        SRC_B_IMM_U: ex_src_b = id_ex_imm_u;
        SRC_B_FOUR: ex_src_b = 32'd4;
        SRC_B_RS2: ex_src_b = ex_rs2_fwd;
        default: ex_src_b = ex_rs2_fwd;
    endcase
end

alu u_alu (
    .alu_op(id_ex_alu_op),
    .src_a(ex_src_a),
    .src_b(ex_src_b),
    .result(ex_alu_result)
);

branch_unit u_branch_unit (
    .branch_type(id_ex_branch_type),
    .rs1_data(ex_rs1_fwd),
    .rs2_data(ex_rs2_fwd),
    .branch_taken(branch_condition_taken)
);

always @(*) begin
    case (id_ex_jump_type)
        JMP_JAL: ex_control_target = id_ex_pc + id_ex_imm_j;
        JMP_JALR: ex_control_target = (ex_rs1_fwd + id_ex_imm_i) & 32'hFFFF_FFFE;
        default: ex_control_target = id_ex_pc + id_ex_imm_b;
    endcase
end

data_ram u_data_ram (
    .clk(clk),
    .mem_we(local_mem_we),
    .mem_wstrb(4'hF),
    .addr(ex_mem_alu_result),
    .wdata(ex_mem_store_data),
    .rdata(local_ram_rdata)
);

axi_lite_master u_axi_lite_master (
    .clk(clk),
    .rst_n(rst_n),
    .req_valid(axi_req_valid),
    .req_ready(axi_req_ready),
    .req_write(axi_req_write),
    .req_addr(axi_req_addr),
    .req_wdata(axi_req_wdata),
    .req_wstrb(axi_req_wstrb),
    .resp_valid(axi_resp_valid),
    .resp_ready(axi_resp_ready),
    .resp_rdata(axi_resp_rdata),
    .resp_error(axi_resp_error),
    .m_axi_awaddr(m_axi_awaddr),
    .m_axi_awvalid(m_axi_awvalid),
    .m_axi_awready(m_axi_awready),
    .m_axi_wdata(m_axi_wdata),
    .m_axi_wstrb(m_axi_wstrb),
    .m_axi_wvalid(m_axi_wvalid),
    .m_axi_wready(m_axi_wready),
    .m_axi_bresp(m_axi_bresp),
    .m_axi_bvalid(m_axi_bvalid),
    .m_axi_bready(m_axi_bready),
    .m_axi_araddr(m_axi_araddr),
    .m_axi_arvalid(m_axi_arvalid),
    .m_axi_arready(m_axi_arready),
    .m_axi_rdata(m_axi_rdata),
    .m_axi_rresp(m_axi_rresp),
    .m_axi_rvalid(m_axi_rvalid),
    .m_axi_rready(m_axi_rready)
);

always @(posedge clk) begin
    if (!rst_n) begin
        pc <= 32'd0;
        fetch_pc_r <= 32'd0;
        fetch_valid_r <= 1'b0;
        if_buf_pc <= 32'd0;
        if_buf_instr <= NOP_INSTR;
        if_buf_valid <= 1'b0;
        if_id_pc <= 32'd0;
        if_id_instr <= NOP_INSTR;
        if_id_valid <= 1'b0;
        id_ex_pc <= 32'd0;
        id_ex_rs1_val <= 32'd0;
        id_ex_rs2_val <= 32'd0;
        id_ex_imm_i <= 32'd0;
        id_ex_imm_s <= 32'd0;
        id_ex_imm_b <= 32'd0;
        id_ex_imm_u <= 32'd0;
        id_ex_imm_j <= 32'd0;
        id_ex_rs1 <= 5'd0;
        id_ex_rs2 <= 5'd0;
        id_ex_rd <= 5'd0;
        id_ex_alu_op <= ALU_ADD;
        id_ex_alu_src_a_sel <= SRC_A_RS1;
        id_ex_alu_src_b_sel <= SRC_B_RS2;
        id_ex_reg_write <= 1'b0;
        id_ex_mem_read <= 1'b0;
        id_ex_mem_write <= 1'b0;
        id_ex_mem_to_reg <= 1'b0;
        id_ex_branch_type <= BR_NONE;
        id_ex_jump_type <= JMP_NONE;
        id_ex_is_ecall <= 1'b0;
        id_ex_is_ebreak <= 1'b0;
        id_ex_illegal_instr <= 1'b0;
        id_ex_valid <= 1'b0;
        ex_mem_alu_result <= 32'd0;
        ex_mem_store_data <= 32'd0;
        ex_mem_rd <= 5'd0;
        ex_mem_reg_write <= 1'b0;
        ex_mem_mem_read <= 1'b0;
        ex_mem_mem_write <= 1'b0;
        ex_mem_mem_to_reg <= 1'b0;
        ex_mem_valid <= 1'b0;
        mem_wb_wb_data <= 32'd0;
        mem_wb_rd <= 5'd0;
        mem_wb_reg_write <= 1'b0;
        mem_wb_valid <= 1'b0;
        axi_req_issued <= 1'b0;
        test_done <= 1'b0;
        test_value <= 32'd0;
        halted <= 1'b0;
    end else begin
        if (!ex_mem_external_access || (axi_resp_valid && axi_resp_ready)) begin
            axi_req_issued <= 1'b0;
        end else if (axi_req_valid && axi_req_ready) begin
            axi_req_issued <= 1'b1;
        end

        if (!halted) begin
            if (ex_mem_valid && ex_mem_mem_write && ex_mem_external_access && axi_resp_valid && !axi_resp_error && (ex_mem_alu_result == TEST_OUTPUT_ADDR)) begin
                test_done <= 1'b1;
                test_value <= ex_mem_store_data;
            end

            if (pipeline_hold) begin
                mem_wb_valid <= 1'b0;
                mem_wb_reg_write <= 1'b0;
            end else begin
                if (ex_halt_instr || mem_access_error) begin
                    halted <= 1'b1;
                end

                if (!stall_f) begin
                    pc <= ex_control_taken ? ex_control_target : (pc + 32'd4);
                    fetch_pc_r <= pc;
                    fetch_valid_r <= !ex_control_taken;
                end

                if (flush_d) begin
                    if_buf_valid <= 1'b0;
                end else if (stall_d && !if_buf_valid) begin
                    if_buf_pc <= fetch_pc_r;
                    if_buf_instr <= if_instr;
                    if_buf_valid <= fetch_valid_r;
                end

                if (flush_d) begin
                    if_id_pc <= 32'd0;
                    if_id_instr <= NOP_INSTR;
                    if_id_valid <= 1'b0;
                end else if (!stall_d) begin
                    if (if_buf_valid) begin
                        if_id_pc <= if_buf_pc;
                        if_id_instr <= if_buf_instr;
                        if_id_valid <= if_buf_valid;
                        if_buf_valid <= 1'b0;
                    end else begin
                        if_id_pc <= fetch_pc_r;
                        if_id_instr <= if_instr;
                        if_id_valid <= fetch_valid_r;
                    end
                end

                if (flush_e) begin
                    id_ex_pc <= 32'd0;
                    id_ex_rs1_val <= 32'd0;
                    id_ex_rs2_val <= 32'd0;
                    id_ex_imm_i <= 32'd0;
                    id_ex_imm_s <= 32'd0;
                    id_ex_imm_b <= 32'd0;
                    id_ex_imm_u <= 32'd0;
                    id_ex_imm_j <= 32'd0;
                    id_ex_rs1 <= 5'd0;
                    id_ex_rs2 <= 5'd0;
                    id_ex_rd <= 5'd0;
                    id_ex_alu_op <= ALU_ADD;
                    id_ex_alu_src_a_sel <= SRC_A_RS1;
                    id_ex_alu_src_b_sel <= SRC_B_RS2;
                    id_ex_reg_write <= 1'b0;
                    id_ex_mem_read <= 1'b0;
                    id_ex_mem_write <= 1'b0;
                    id_ex_mem_to_reg <= 1'b0;
                    id_ex_branch_type <= BR_NONE;
                    id_ex_jump_type <= JMP_NONE;
                    id_ex_is_ecall <= 1'b0;
                    id_ex_is_ebreak <= 1'b0;
                    id_ex_illegal_instr <= 1'b0;
                    id_ex_valid <= 1'b0;
                end else if (!stall_d) begin
                    id_ex_pc <= if_id_pc;
                    id_ex_rs1_val <= id_rs1_data_bypass;
                    id_ex_rs2_val <= id_rs2_data_bypass;
                    id_ex_imm_i <= id_imm_i;
                    id_ex_imm_s <= id_imm_s;
                    id_ex_imm_b <= id_imm_b;
                    id_ex_imm_u <= id_imm_u;
                    id_ex_imm_j <= id_imm_j;
                    id_ex_rs1 <= id_rs1;
                    id_ex_rs2 <= id_rs2;
                    id_ex_rd <= id_rd;
                    id_ex_alu_op <= id_alu_op;
                    id_ex_alu_src_a_sel <= id_alu_src_a_sel;
                    id_ex_alu_src_b_sel <= id_alu_src_b_sel;
                    id_ex_reg_write <= id_reg_write;
                    id_ex_mem_read <= id_mem_read;
                    id_ex_mem_write <= id_mem_write;
                    id_ex_mem_to_reg <= id_mem_to_reg;
                    id_ex_branch_type <= id_branch_type;
                    id_ex_jump_type <= id_jump_type;
                    id_ex_is_ecall <= id_is_ecall;
                    id_ex_is_ebreak <= id_is_ebreak;
                    id_ex_illegal_instr <= id_illegal_instr;
                    id_ex_valid <= if_id_valid;
                end

                ex_mem_alu_result <= ex_alu_result;
                ex_mem_store_data <= ex_rs2_fwd;
                ex_mem_rd <= id_ex_rd;
                ex_mem_reg_write <= id_ex_valid && !ex_halt_instr && id_ex_reg_write;
                ex_mem_mem_read <= id_ex_valid && !ex_halt_instr && id_ex_mem_read;
                ex_mem_mem_write <= id_ex_valid && !ex_halt_instr && id_ex_mem_write;
                ex_mem_mem_to_reg <= id_ex_mem_to_reg;
                ex_mem_valid <= id_ex_valid && !ex_halt_instr;

                if (mem_access_error) begin
                    mem_wb_wb_data <= 32'd0;
                    mem_wb_rd <= 5'd0;
                    mem_wb_reg_write <= 1'b0;
                    mem_wb_valid <= 1'b0;
                end else begin
                    mem_wb_wb_data <= mem_wb_next_data;
                    mem_wb_rd <= ex_mem_rd;
                    mem_wb_reg_write <= ex_mem_valid && ex_mem_reg_write;
                    mem_wb_valid <= ex_mem_valid;
                end
            end
        end else begin
            mem_wb_reg_write <= 1'b0;
            mem_wb_valid <= 1'b0;
        end
    end
end

endmodule

`default_nettype wire
