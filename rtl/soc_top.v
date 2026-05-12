`timescale 1ns / 1ps
`default_nettype none

module soc_top (
    input  wire        clk,
    input  wire        rst_n_async,

    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tlast,

    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tlast,

    output wire        test_done,
    output wire [31:0] test_value,
    output wire        cpu_halted,
    output wire [31:0] dbg_pc,
    output wire        dbg_cnn_busy,
    output wire        dbg_cnn_done,
    output wire        dbg_cnn_error
);

wire rst_n;

wire [31:0] cpu_awaddr;
wire        cpu_awvalid;
wire        cpu_awready;
wire [31:0] cpu_wdata;
wire [3:0]  cpu_wstrb;
wire        cpu_wvalid;
wire        cpu_wready;
wire [1:0]  cpu_bresp;
wire        cpu_bvalid;
wire        cpu_bready;
wire [31:0] cpu_araddr;
wire        cpu_arvalid;
wire        cpu_arready;
wire [31:0] cpu_rdata;
wire [1:0]  cpu_rresp;
wire        cpu_rvalid;
wire        cpu_rready;

wire [31:0] cnn_awaddr;
wire        cnn_awvalid;
wire        cnn_awready;
wire [31:0] cnn_wdata;
wire [3:0]  cnn_wstrb;
wire        cnn_wvalid;
wire        cnn_wready;
wire [1:0]  cnn_bresp;
wire        cnn_bvalid;
wire        cnn_bready;
wire [31:0] cnn_araddr;
wire        cnn_arvalid;
wire        cnn_arready;
wire [31:0] cnn_rdata;
wire [1:0]  cnn_rresp;
wire        cnn_rvalid;
wire        cnn_rready;

wire cpu_test_done;
wire [31:0] cpu_test_value;

reset_sync u_reset_sync (
    .clk(clk),
    .rst_n_async(rst_n_async),
    .rst_n(rst_n)
);

riscv_top #(
    .INST_MEM_FILE("D:/RICS_V_CNN/1DCNN_ACC/firmware/soc_firmware.hex")
) u_riscv_top (
    .clk(clk),
    .rst_n(rst_n),
    .m_axi_awaddr(cpu_awaddr),
    .m_axi_awvalid(cpu_awvalid),
    .m_axi_awready(cpu_awready),
    .m_axi_wdata(cpu_wdata),
    .m_axi_wstrb(cpu_wstrb),
    .m_axi_wvalid(cpu_wvalid),
    .m_axi_wready(cpu_wready),
    .m_axi_bresp(cpu_bresp),
    .m_axi_bvalid(cpu_bvalid),
    .m_axi_bready(cpu_bready),
    .m_axi_araddr(cpu_araddr),
    .m_axi_arvalid(cpu_arvalid),
    .m_axi_arready(cpu_arready),
    .m_axi_rdata(cpu_rdata),
    .m_axi_rresp(cpu_rresp),
    .m_axi_rvalid(cpu_rvalid),
    .m_axi_rready(cpu_rready),
    .test_done(cpu_test_done),
    .test_value(cpu_test_value),
    .halted(cpu_halted),
    .dbg_pc(dbg_pc)
);

axi_lite_addr_decode u_axi_lite_addr_decode (
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(cpu_awaddr),
    .s_axi_awvalid(cpu_awvalid),
    .s_axi_awready(cpu_awready),
    .s_axi_wdata(cpu_wdata),
    .s_axi_wstrb(cpu_wstrb),
    .s_axi_wvalid(cpu_wvalid),
    .s_axi_wready(cpu_wready),
    .s_axi_bresp(cpu_bresp),
    .s_axi_bvalid(cpu_bvalid),
    .s_axi_bready(cpu_bready),
    .s_axi_araddr(cpu_araddr),
    .s_axi_arvalid(cpu_arvalid),
    .s_axi_arready(cpu_arready),
    .s_axi_rdata(cpu_rdata),
    .s_axi_rresp(cpu_rresp),
    .s_axi_rvalid(cpu_rvalid),
    .s_axi_rready(cpu_rready),
    .m_axi_awaddr(cnn_awaddr),
    .m_axi_awvalid(cnn_awvalid),
    .m_axi_awready(cnn_awready),
    .m_axi_wdata(cnn_wdata),
    .m_axi_wstrb(cnn_wstrb),
    .m_axi_wvalid(cnn_wvalid),
    .m_axi_wready(cnn_wready),
    .m_axi_bresp(cnn_bresp),
    .m_axi_bvalid(cnn_bvalid),
    .m_axi_bready(cnn_bready),
    .m_axi_araddr(cnn_araddr),
    .m_axi_arvalid(cnn_arvalid),
    .m_axi_arready(cnn_arready),
    .m_axi_rdata(cnn_rdata),
    .m_axi_rresp(cnn_rresp),
    .m_axi_rvalid(cnn_rvalid),
    .m_axi_rready(cnn_rready),
    .test_done(test_done),
    .test_value(test_value)
);

cnn_accelerator_top u_cnn_accelerator_top (
    .clk(clk),
    .rst_n_async(rst_n_async),
    .s_axi_awaddr(cnn_awaddr),
    .s_axi_awvalid(cnn_awvalid),
    .s_axi_awready(cnn_awready),
    .s_axi_wdata(cnn_wdata),
    .s_axi_wstrb(cnn_wstrb),
    .s_axi_wvalid(cnn_wvalid),
    .s_axi_wready(cnn_wready),
    .s_axi_bresp(cnn_bresp),
    .s_axi_bvalid(cnn_bvalid),
    .s_axi_bready(cnn_bready),
    .s_axi_araddr(cnn_araddr),
    .s_axi_arvalid(cnn_arvalid),
    .s_axi_arready(cnn_arready),
    .s_axi_rdata(cnn_rdata),
    .s_axi_rresp(cnn_rresp),
    .s_axi_rvalid(cnn_rvalid),
    .s_axi_rready(cnn_rready),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tlast(s_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tlast(m_axis_tlast),
    .dbg_busy(dbg_cnn_busy),
    .dbg_done(dbg_cnn_done),
    .dbg_error(dbg_cnn_error)
);

endmodule

`default_nettype wire
