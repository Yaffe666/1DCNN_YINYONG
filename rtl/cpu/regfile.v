`timescale 1ns / 1ps
`default_nettype none

module regfile (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [4:0]  rs1_addr,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs1_data,
    output wire [31:0] rs2_data,
    input  wire        rd_we,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data
);

reg [31:0] regs [0:31];
integer i;

assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

always @(posedge clk) begin
    if (!rst_n) begin
        for (i = 0; i < 32; i = i + 1) begin
            regs[i] <= 32'd0;
        end
    end else if (rd_we && (rd_addr != 5'd0)) begin
        regs[rd_addr] <= rd_data;
    end
end

endmodule

`default_nettype wire
