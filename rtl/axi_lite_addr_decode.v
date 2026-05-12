`timescale 1ns / 1ps
`default_nettype none

module axi_lite_addr_decode (
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

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
    output reg         m_axi_rready,

    output reg         test_done,
    output reg  [31:0] test_value
);

localparam [2:0] S_IDLE       = 3'd0;
localparam [2:0] S_CNN_WRITE  = 3'd1;
localparam [2:0] S_CNN_BRESP  = 3'd2;
localparam [2:0] S_CPU_BRESP  = 3'd3;
localparam [2:0] S_CNN_AR     = 3'd4;
localparam [2:0] S_CNN_RDATA  = 3'd5;
localparam [2:0] S_CPU_RDATA  = 3'd6;

localparam [1:0] RESP_OKAY  = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;

reg [2:0] state;
reg aw_done;
reg w_done;

wire write_fire;
wire read_fire;
wire write_to_cnn;
wire write_to_test;
wire read_from_cnn;
wire read_from_test;
wire cnn_aw_fire;
wire cnn_w_fire;

assign write_fire = s_axi_awvalid && s_axi_wvalid && (state == S_IDLE) && !s_axi_bvalid && !s_axi_rvalid;
assign read_fire = s_axi_arvalid && (state == S_IDLE) && !s_axi_bvalid && !s_axi_rvalid && !write_fire;
assign write_to_cnn = (s_axi_awaddr[31:16] == 16'h1000) && (s_axi_awaddr[7:0] <= 8'h1F);
assign write_to_test = (s_axi_awaddr == 32'h1000_0020);
assign read_from_cnn = (s_axi_araddr[31:16] == 16'h1000) && (s_axi_araddr[7:0] <= 8'h1F);
assign read_from_test = (s_axi_araddr == 32'h1000_0020);
assign cnn_aw_fire = m_axi_awvalid && m_axi_awready;
assign cnn_w_fire = m_axi_wvalid && m_axi_wready;

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        aw_done <= 1'b0;
        w_done <= 1'b0;
        s_axi_awready <= 1'b0;
        s_axi_wready <= 1'b0;
        s_axi_bresp <= RESP_OKAY;
        s_axi_bvalid <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rdata <= 32'd0;
        s_axi_rresp <= RESP_OKAY;
        s_axi_rvalid <= 1'b0;
        m_axi_awaddr <= 32'd0;
        m_axi_awvalid <= 1'b0;
        m_axi_wdata <= 32'd0;
        m_axi_wstrb <= 4'd0;
        m_axi_wvalid <= 1'b0;
        m_axi_bready <= 1'b0;
        m_axi_araddr <= 32'd0;
        m_axi_arvalid <= 1'b0;
        m_axi_rready <= 1'b0;
        test_done <= 1'b0;
        test_value <= 32'd0;
    end else begin
        s_axi_awready <= 1'b0;
        s_axi_wready <= 1'b0;
        s_axi_arready <= 1'b0;

        case (state)
            S_IDLE: begin
                aw_done <= 1'b0;
                w_done <= 1'b0;
                m_axi_bready <= 1'b0;
                m_axi_rready <= 1'b0;

                if (write_fire) begin
                    s_axi_awready <= 1'b1;
                    s_axi_wready <= 1'b1;
                    if (write_to_cnn) begin
                        m_axi_awaddr <= {24'd0, s_axi_awaddr[7:0]};
                        m_axi_awvalid <= 1'b1;
                        m_axi_wdata <= s_axi_wdata;
                        m_axi_wstrb <= s_axi_wstrb;
                        m_axi_wvalid <= 1'b1;
                        state <= S_CNN_WRITE;
                    end else begin
                        if (write_to_test) begin
                            test_done <= 1'b1;
                            test_value <= s_axi_wdata;
                            s_axi_bresp <= RESP_OKAY;
                        end else begin
                            s_axi_bresp <= RESP_SLVERR;
                        end
                        s_axi_bvalid <= 1'b1;
                        state <= S_CPU_BRESP;
                    end
                end else if (read_fire) begin
                    s_axi_arready <= 1'b1;
                    if (read_from_cnn) begin
                        m_axi_araddr <= {24'd0, s_axi_araddr[7:0]};
                        m_axi_arvalid <= 1'b1;
                        state <= S_CNN_AR;
                    end else begin
                        s_axi_rdata <= read_from_test ? test_value : 32'd0;
                        s_axi_rresp <= read_from_test ? RESP_OKAY : RESP_SLVERR;
                        s_axi_rvalid <= 1'b1;
                        state <= S_CPU_RDATA;
                    end
                end
            end

            S_CNN_WRITE: begin
                if (cnn_aw_fire) begin
                    m_axi_awvalid <= 1'b0;
                    aw_done <= 1'b1;
                end
                if (cnn_w_fire) begin
                    m_axi_wvalid <= 1'b0;
                    w_done <= 1'b1;
                end
                if ((aw_done || cnn_aw_fire) && (w_done || cnn_w_fire)) begin
                    m_axi_bready <= 1'b1;
                    state <= S_CNN_BRESP;
                end
            end

            S_CNN_BRESP: begin
                if (m_axi_bvalid) begin
                    m_axi_bready <= 1'b0;
                    s_axi_bresp <= m_axi_bresp;
                    s_axi_bvalid <= 1'b1;
                    state <= S_CPU_BRESP;
                end
            end

            S_CPU_BRESP: begin
                if (s_axi_bvalid && s_axi_bready) begin
                    s_axi_bvalid <= 1'b0;
                    s_axi_bresp <= RESP_OKAY;
                    state <= S_IDLE;
                end
            end

            S_CNN_AR: begin
                if (m_axi_arvalid && m_axi_arready) begin
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready <= 1'b1;
                    state <= S_CNN_RDATA;
                end
            end

            S_CNN_RDATA: begin
                if (m_axi_rvalid) begin
                    m_axi_rready <= 1'b0;
                    s_axi_rdata <= m_axi_rdata;
                    s_axi_rresp <= m_axi_rresp;
                    s_axi_rvalid <= 1'b1;
                    state <= S_CPU_RDATA;
                end
            end

            S_CPU_RDATA: begin
                if (s_axi_rvalid && s_axi_rready) begin
                    s_axi_rvalid <= 1'b0;
                    s_axi_rresp <= RESP_OKAY;
                    state <= S_IDLE;
                end
            end

            default: begin
                state <= S_IDLE;
                m_axi_awvalid <= 1'b0;
                m_axi_wvalid <= 1'b0;
                m_axi_bready <= 1'b0;
                m_axi_arvalid <= 1'b0;
                m_axi_rready <= 1'b0;
                s_axi_bvalid <= 1'b0;
                s_axi_rvalid <= 1'b0;
            end
        endcase
    end
end

endmodule

`default_nettype wire
