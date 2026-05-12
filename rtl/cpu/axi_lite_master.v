`timescale 1ns / 1ps
`default_nettype none

module axi_lite_master (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        req_valid,
    output wire        req_ready,
    input  wire        req_write,
    input  wire [31:0] req_addr,
    input  wire [31:0] req_wdata,
    input  wire [3:0]  req_wstrb,

    output reg         resp_valid,
    input  wire        resp_ready,
    output reg  [31:0] resp_rdata,
    output reg         resp_error,

    output reg  [31:0] m_axi_awaddr,
    output reg         m_axi_awvalid,
    input  wire        m_axi_awready,
    output reg  [31:0] m_axi_wdata,
    output reg  [3:0]  m_axi_wstrb,
    output reg         m_axi_wvalid,
    input  wire        m_axi_wready,
    input  wire [1:0]  m_axi_bresp,
    input  wire        m_axi_bvalid,
    output reg         m_axi_bready,

    output reg  [31:0] m_axi_araddr,
    output reg         m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [31:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rvalid,
    output reg         m_axi_rready
);

localparam [2:0] M_IDLE            = 3'd0;
localparam [2:0] M_WRITE_ADDR_DATA = 3'd1;
localparam [2:0] M_WRITE_RESP      = 3'd2;
localparam [2:0] M_READ_ADDR       = 3'd3;
localparam [2:0] M_READ_DATA       = 3'd4;
localparam [2:0] M_RESP            = 3'd5;

reg [2:0] state;
reg aw_done;
reg w_done;
wire aw_fire;
wire w_fire;

assign req_ready = (state == M_IDLE);
assign aw_fire = m_axi_awvalid && m_axi_awready;
assign w_fire = m_axi_wvalid && m_axi_wready;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= M_IDLE;
        aw_done <= 1'b0;
        w_done <= 1'b0;
        resp_valid <= 1'b0;
        resp_rdata <= 32'd0;
        resp_error <= 1'b0;
        m_axi_awaddr <= 32'd0;
        m_axi_awvalid <= 1'b0;
        m_axi_wdata <= 32'd0;
        m_axi_wstrb <= 4'd0;
        m_axi_wvalid <= 1'b0;
        m_axi_bready <= 1'b0;
        m_axi_araddr <= 32'd0;
        m_axi_arvalid <= 1'b0;
        m_axi_rready <= 1'b0;
    end else begin
        case (state)
            M_IDLE: begin
                aw_done <= 1'b0;
                w_done <= 1'b0;
                resp_valid <= 1'b0;
                resp_error <= 1'b0;
                m_axi_bready <= 1'b0;
                m_axi_rready <= 1'b0;
                if (req_valid) begin
                    if (req_write) begin
                        m_axi_awaddr <= req_addr;
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata <= req_wdata;
                        m_axi_wstrb <= req_wstrb;
                        m_axi_wvalid <= 1'b1;
                        state <= M_WRITE_ADDR_DATA;
                    end else begin
                        m_axi_araddr <= req_addr;
                        m_axi_arvalid <= 1'b1;
                        state <= M_READ_ADDR;
                    end
                end
            end

            M_WRITE_ADDR_DATA: begin
                if (aw_fire) begin
                    m_axi_awvalid <= 1'b0;
                    aw_done <= 1'b1;
                end
                if (w_fire) begin
                    m_axi_wvalid <= 1'b0;
                    w_done <= 1'b1;
                end
                if ((aw_done || aw_fire) && (w_done || w_fire)) begin
                    m_axi_bready <= 1'b1;
                    state <= M_WRITE_RESP;
                end
            end

            M_WRITE_RESP: begin
                if (m_axi_bvalid) begin
                    m_axi_bready <= 1'b0;
                    resp_valid <= 1'b1;
                    resp_rdata <= 32'd0;
                    resp_error <= (m_axi_bresp != 2'b00);
                    state <= M_RESP;
                end
            end

            M_READ_ADDR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b1;
                    state <= M_READ_DATA;
                end
            end

            M_READ_DATA: begin
                if (m_axi_rvalid) begin
                    m_axi_rready <= 1'b0;
                    resp_valid <= 1'b1;
                    resp_rdata <= m_axi_rdata;
                    resp_error <= (m_axi_rresp != 2'b00);
                    state <= M_RESP;
                end
            end

            M_RESP: begin
                if (resp_ready) begin
                    resp_valid <= 1'b0;
                    resp_error <= 1'b0;
                    state <= M_IDLE;
                end
            end

            default: begin
                state <= M_IDLE;
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid <= 1'b0;
                m_axi_bready <= 1'b0;
                m_axi_arvalid <= 1'b0;
                m_axi_rready <= 1'b0;
                resp_valid <= 1'b0;
            end
        endcase
    end
end

endmodule

`default_nettype wire
