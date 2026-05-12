`timescale 1ns / 1ps
`default_nettype none

module hazard_unit (
    input  wire [4:0] id_rs1,
    input  wire [4:0] id_rs2,
    input  wire [4:0] ex_rs1,
    input  wire [4:0] ex_rs2,
    input  wire [4:0] ex_rd,
    input  wire       ex_mem_read,
    input  wire [4:0] mem_rd,
    input  wire       mem_reg_write,
    input  wire [4:0] wb_rd,
    input  wire       wb_reg_write,
    input  wire       branch_taken,
    input  wire       axi_stall,
    output reg        stall_f,
    output reg        stall_d,
    output reg        flush_d,
    output reg        flush_e,
    output reg  [1:0] fwd_a_sel,
    output reg  [1:0] fwd_b_sel
);

wire load_use_hazard;

assign load_use_hazard = ex_mem_read && (ex_rd != 5'd0) && ((ex_rd == id_rs1) || (ex_rd == id_rs2));

always @(*) begin
    stall_f = axi_stall || load_use_hazard;
    stall_d = axi_stall || load_use_hazard;
    flush_d = branch_taken;
    flush_e = branch_taken || load_use_hazard;

    fwd_a_sel = 2'd0;
    if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs1)) begin
        fwd_a_sel = 2'd1;
    end else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs1)) begin
        fwd_a_sel = 2'd2;
    end

    fwd_b_sel = 2'd0;
    if (mem_reg_write && (mem_rd != 5'd0) && (mem_rd == ex_rs2)) begin
        fwd_b_sel = 2'd1;
    end else if (wb_reg_write && (wb_rd != 5'd0) && (wb_rd == ex_rs2)) begin
        fwd_b_sel = 2'd2;
    end
end

endmodule

`default_nettype wire
