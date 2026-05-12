`timescale 1ns / 1ps
`default_nettype none

module axi_lite_slave_regs (
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

    output reg         start_pulse,
    output reg         soft_reset_pulse,
    output reg         clear_pulse,
    output reg  [15:0] cfg_input_len,
    output reg  [3:0]  cfg_num_blocks,
    output reg  [4:0]  cfg_num_classes,

    input  wire        status_busy,
    input  wire        status_done,
    input  wire        status_error,
    input  wire [31:0] cycle_cnt
);

localparam [7:0] ADDR_CTRL        = 8'h00;
localparam [7:0] ADDR_STATUS      = 8'h04;
localparam [7:0] ADDR_INPUT_LEN   = 8'h08;
localparam [7:0] ADDR_LAYER_CFG   = 8'h0C;
localparam [7:0] ADDR_NUM_CLASSES = 8'h10;
localparam [7:0] ADDR_CLEAR       = 8'h14;
localparam [7:0] ADDR_CYCLE_CNT   = 8'h18;
localparam [7:0] ADDR_VERSION     = 8'h1C;

localparam [1:0] RESP_OKAY  = 2'b00;
localparam [1:0] RESP_SLVERR = 2'b10;
localparam [31:0] VERSION_VALUE = 32'h0000_0400;

reg        aw_hold_valid;
reg [31:0] aw_hold_addr;
reg        w_hold_valid;
reg [31:0] w_hold_data;
reg [3:0]  w_hold_strb;

reg [31:0] merged_wdata;
reg [31:0] read_data_next;
reg [1:0]  read_resp_next;
reg [7:0]  write_addr_lsb;
reg [7:0]  read_addr_lsb;

function [31:0] apply_wstrb;
    input [31:0] curr;
    input [31:0] wdata;
    input [3:0]  wstrb;
    begin
        apply_wstrb = curr;
        if (wstrb[0]) begin
            apply_wstrb[7:0] = wdata[7:0];
        end
        if (wstrb[1]) begin
            apply_wstrb[15:8] = wdata[15:8];
        end
        if (wstrb[2]) begin
            apply_wstrb[23:16] = wdata[23:16];
        end
        if (wstrb[3]) begin
            apply_wstrb[31:24] = wdata[31:24];
        end
    end
endfunction

always @(posedge clk) begin
    if (!rst_n) begin
        s_axi_awready <= 1'b0;
        s_axi_wready <= 1'b0;
        s_axi_bresp <= RESP_OKAY;
        s_axi_bvalid <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rdata <= 32'd0;
        s_axi_rresp <= RESP_OKAY;
        s_axi_rvalid <= 1'b0;
        start_pulse <= 1'b0;
        soft_reset_pulse <= 1'b0;
        clear_pulse <= 1'b0;
        cfg_input_len <= 16'd2048;
        cfg_num_blocks <= 4'd5;
        cfg_num_classes <= 5'd10;
        aw_hold_valid <= 1'b0;
        aw_hold_addr <= 32'd0;
        w_hold_valid <= 1'b0;
        w_hold_data <= 32'd0;
        w_hold_strb <= 4'd0;
        merged_wdata <= 32'd0;
        read_data_next <= 32'd0;
        read_resp_next <= RESP_OKAY;
        write_addr_lsb <= 8'd0;
        read_addr_lsb <= 8'd0;
    end else begin
        s_axi_awready <= 1'b0;
        s_axi_wready <= 1'b0;
        s_axi_arready <= 1'b0;
        start_pulse <= 1'b0;
        soft_reset_pulse <= 1'b0;
        clear_pulse <= 1'b0;

        if (!s_axi_bvalid && !aw_hold_valid && s_axi_awvalid) begin
            s_axi_awready <= 1'b1;
            aw_hold_valid <= 1'b1;
            aw_hold_addr <= s_axi_awaddr;
        end

        if (!s_axi_bvalid && !w_hold_valid && s_axi_wvalid) begin
            s_axi_wready <= 1'b1;
            w_hold_valid <= 1'b1;
            w_hold_data <= s_axi_wdata;
            w_hold_strb <= s_axi_wstrb;
        end

        if (aw_hold_valid && w_hold_valid && !s_axi_bvalid) begin
            s_axi_bvalid <= 1'b1;
            s_axi_bresp <= RESP_OKAY;

            write_addr_lsb <= aw_hold_addr[7:0];
            case (aw_hold_addr[7:0])
                ADDR_CTRL: begin
                    merged_wdata <= apply_wstrb(32'd0, w_hold_data, w_hold_strb);
                    start_pulse <= w_hold_strb[0] & w_hold_data[0];
                    soft_reset_pulse <= w_hold_strb[0] & w_hold_data[1];
                end
                ADDR_INPUT_LEN: begin
                    merged_wdata <= apply_wstrb({16'd0, cfg_input_len}, w_hold_data, w_hold_strb);
                    cfg_input_len <= apply_wstrb({16'd0, cfg_input_len}, w_hold_data, w_hold_strb);
                end
                ADDR_LAYER_CFG: begin
                    merged_wdata <= apply_wstrb({28'd0, cfg_num_blocks}, w_hold_data, w_hold_strb);
                    cfg_num_blocks <= apply_wstrb({28'd0, cfg_num_blocks}, w_hold_data, w_hold_strb);
                end
                ADDR_NUM_CLASSES: begin
                    merged_wdata <= apply_wstrb({27'd0, cfg_num_classes}, w_hold_data, w_hold_strb);
                    cfg_num_classes <= apply_wstrb({27'd0, cfg_num_classes}, w_hold_data, w_hold_strb);
                end
                ADDR_CLEAR: begin
                    merged_wdata <= apply_wstrb(32'd0, w_hold_data, w_hold_strb);
                    clear_pulse <= w_hold_strb[0] & w_hold_data[0];
                end
                default: begin
                    merged_wdata <= 32'd0;
                    s_axi_bresp <= RESP_SLVERR;
                end
            endcase

            aw_hold_valid <= 1'b0;
            w_hold_valid <= 1'b0;
        end

        if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
        end

        if (!s_axi_rvalid && s_axi_arvalid) begin
            s_axi_arready <= 1'b1;
            s_axi_rvalid <= 1'b1;
            s_axi_rresp <= RESP_OKAY;

            read_addr_lsb <= s_axi_araddr[7:0];
            case (s_axi_araddr[7:0])
                ADDR_CTRL: begin
                    read_data_next <= 32'd0;
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= 32'd0;
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_STATUS: begin
                    read_data_next <= {29'd0, status_error, status_done, status_busy};
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= {29'd0, status_error, status_done, status_busy};
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_INPUT_LEN: begin
                    read_data_next <= {16'd0, cfg_input_len};
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= {16'd0, cfg_input_len};
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_LAYER_CFG: begin
                    read_data_next <= {28'd0, cfg_num_blocks};
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= {28'd0, cfg_num_blocks};
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_NUM_CLASSES: begin
                    read_data_next <= {27'd0, cfg_num_classes};
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= {27'd0, cfg_num_classes};
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_CLEAR: begin
                    read_data_next <= 32'd0;
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= 32'd0;
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_CYCLE_CNT: begin
                    read_data_next <= cycle_cnt;
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= cycle_cnt;
                    s_axi_rresp <= RESP_OKAY;
                end
                ADDR_VERSION: begin
                    read_data_next <= VERSION_VALUE;
                    read_resp_next <= RESP_OKAY;
                    s_axi_rdata <= VERSION_VALUE;
                    s_axi_rresp <= RESP_OKAY;
                end
                default: begin
                    read_data_next <= 32'd0;
                    read_resp_next <= RESP_SLVERR;
                    s_axi_rdata <= 32'd0;
                    s_axi_rresp <= RESP_SLVERR;
                end
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end
end

endmodule

`default_nettype wire
