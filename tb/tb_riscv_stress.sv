`timescale 1ns / 1ps

// Back-to-back MMIO store regression testbench.
// Uses cpu_stress_mmio.hex firmware with configurable AXI delays.
// Golden: 4 back-to-back stores reusing x2, then TEST_OUTPUT write.
module tb_riscv_stress;

localparam int CLK_PERIOD_NS = 10;
localparam int MAX_CYCLES = 2000;
localparam logic [31:0] TEST_OUTPUT_ADDR = 32'h1000_0020;
localparam logic [31:0] PASS_VALUE = 32'hCAFE_BABE;

// Sweep these delay values to exercise different pipeline_hold durations
localparam int B_DELAY = 3;
localparam int AW_DELAY = 0;
localparam int W_DELAY  = 0;

// Golden: 4 MMIO stores + 1 test output write
localparam int GOLDEN_COUNT = 5;
localparam logic [47:0] GOLDEN_WRITES [0:4] = '{
    {16'h0000, 32'h00000123},  // [0] awaddr=0x10000000 wdata=0x00000123
    {16'h0004, 32'h00000456},  // [1] awaddr=0x10000004 wdata=0x00000456
    {16'h0008, 32'h00000789},  // [2] awaddr=0x10000008 wdata=0x00000789
    {16'h000C, 32'h00000321},  // [3] awaddr=0x1000000C wdata=0x00000321
    {16'h0020, 32'hCAFEBABE}   // [4] awaddr=0x10000020 wdata=0xCAFEBABE
};

logic clk;
logic rst_n;

wire [31:0] m_axi_awaddr;
wire        m_axi_awvalid;
logic       m_axi_awready;
wire [31:0] m_axi_wdata;
wire [3:0]  m_axi_wstrb;
wire        m_axi_wvalid;
logic       m_axi_wready;
logic [1:0] m_axi_bresp;
logic       m_axi_bvalid;
wire        m_axi_bready;

wire [31:0] m_axi_araddr;
wire        m_axi_arvalid;
logic       m_axi_arready;
logic [31:0] m_axi_rdata;
logic [1:0]  m_axi_rresp;
logic        m_axi_rvalid;
wire         m_axi_rready;

wire         test_done;
wire [31:0]  test_value;
wire         halted;
wire [31:0]  dbg_pc;

logic [31:0] recorded_awaddr [0:15];
logic [31:0] recorded_wdata  [0:15];
int          recorded_count;
int          cycle_count;
int          fail_count;

// AXI slave delay state
int aw_delay_cnt, w_delay_cnt, b_delay_cnt;
logic bvalid_armed;

riscv_top #(
    .INST_MEM_FILE("firmware/cpu_stress_mmio.hex")
) dut (
    .clk(clk),
    .rst_n(rst_n),
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
    .m_axi_rready(m_axi_rready),
    .test_done(test_done),
    .test_value(test_value),
    .halted(halted),
    .dbg_pc(dbg_pc)
);

initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD_NS/2) clk = ~clk;
end

always @(posedge clk) begin
    if (!rst_n)
        cycle_count <= 0;
    else begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > MAX_CYCLES) begin
            $display("STRESS TB TIMEOUT pc=%08x cycles=%0d recorded=%0d", dbg_pc, cycle_count, recorded_count);
            for (int i = 0; i < recorded_count; i++)
                $display("  [%0d] awaddr=%08x wdata=%08x", i, recorded_awaddr[i], recorded_wdata[i]);
            $fatal(1, "STRESS TB timeout");
        end
    end
end

// AXI-Lite dummy slave with configurable BVALID delay
always @(posedge clk) begin
    if (!rst_n) begin
        m_axi_awready <= 1'b0;
        m_axi_wready  <= 1'b0;
        m_axi_bresp   <= 2'b00;
        m_axi_bvalid  <= 1'b0;
        m_axi_arready <= 1'b0;
        m_axi_rdata   <= 32'd0;
        m_axi_rresp   <= 2'b00;
        m_axi_rvalid  <= 1'b0;
        aw_delay_cnt  <= 0;
        w_delay_cnt   <= 0;
        b_delay_cnt   <= 0;
        bvalid_armed  <= 1'b0;
        recorded_count <= 0;
        for (int i = 0; i < 16; i++) begin
            recorded_awaddr[i] <= 32'd0;
            recorded_wdata[i]  <= 32'd0;
        end
    end else begin
        // AW channel
        if (m_axi_awvalid && aw_delay_cnt < AW_DELAY) begin
            aw_delay_cnt <= aw_delay_cnt + 1;
            m_axi_awready <= 1'b0;
        end else if (m_axi_awvalid) begin
            m_axi_awready <= 1'b1;
            aw_delay_cnt <= 0;
        end else begin
            m_axi_awready <= 1'b0;
            aw_delay_cnt <= 0;
        end

        // W channel
        if (m_axi_wvalid && w_delay_cnt < W_DELAY) begin
            w_delay_cnt <= w_delay_cnt + 1;
            m_axi_wready <= 1'b0;
        end else if (m_axi_wvalid) begin
            m_axi_wready <= 1'b1;
            w_delay_cnt <= 0;
        end else begin
            m_axi_wready <= 1'b0;
            w_delay_cnt <= 0;
        end

        // AR channel - immediate response
        m_axi_arready <= m_axi_arvalid;
        if (m_axi_arvalid && m_axi_arready) begin
            m_axi_rvalid <= 1'b1;
            m_axi_rdata <= 32'd0;
            m_axi_rresp <= 2'b00;
        end else if (m_axi_rvalid && m_axi_rready) begin
            m_axi_rvalid <= 1'b0;
        end

        // Capture write transaction when AW+W handshake completes
        if (m_axi_awready && m_axi_awvalid && m_axi_wready && m_axi_wvalid && !bvalid_armed) begin
            bvalid_armed <= 1'b1;
            b_delay_cnt <= 0;
            // Record
            if (recorded_count < 16) begin
                recorded_awaddr[recorded_count] <= m_axi_awaddr;
                recorded_wdata[recorded_count]  <= m_axi_wdata;
                recorded_count <= recorded_count + 1;
            end
        end

        // BVALID with configurable delay
        if (m_axi_bvalid) begin
            if (m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                bvalid_armed <= 1'b0;
            end
        end else if (bvalid_armed) begin
            if (b_delay_cnt < B_DELAY) begin
                b_delay_cnt <= b_delay_cnt + 1;
            end else begin
                m_axi_bvalid <= 1'b1;
                m_axi_bresp <= 2'b00;
            end
        end
    end
end

initial begin
    fail_count = 0;
    cycle_count = 0;
    rst_n = 1'b0;
    repeat (12) @(posedge clk);
    rst_n = 1'b1;

    $display("STRESS TB: B_DELAY=%0d AW_DELAY=%0d W_DELAY=%0d", B_DELAY, AW_DELAY, W_DELAY);

    wait (halted === 1'b1 || test_done === 1'b1);
    repeat (8) @(posedge clk);

    $display("STRESS TB: recorded %0d writes", recorded_count);
    for (int i = 0; i < recorded_count; i++)
        $display("  [%0d] awaddr=%08x wdata=%08x", i, recorded_awaddr[i], recorded_wdata[i]);

    // Check golden
    if (recorded_count != GOLDEN_COUNT) begin
        $display("FAIL: write count got=%0d expected=%0d", recorded_count, GOLDEN_COUNT);
        fail_count++;
    end
    for (int i = 0; i < GOLDEN_COUNT && i < recorded_count; i++) begin
        if (recorded_awaddr[i][15:0] != GOLDEN_WRITES[i][47:32]) begin
            $display("FAIL[%0d]: awaddr got=%08x expected=%04x", i, recorded_awaddr[i], GOLDEN_WRITES[i][47:32]);
            fail_count++;
        end
        if (recorded_wdata[i] != GOLDEN_WRITES[i][31:0]) begin
            $display("FAIL[%0d]: wdata got=%08x expected=%08x", i, recorded_wdata[i], GOLDEN_WRITES[i][31:0]);
            fail_count++;
        end
    end
    if (fail_count == 0) begin
        $display("STRESS TB GOLDEN PASS: all %0d writes match", recorded_count);
    end

    // Standard checks
    if (test_done !== 1'b1) begin
        $display("FAIL: test_done not asserted");
        fail_count++;
    end
    if (test_value !== PASS_VALUE) begin
        $display("FAIL: test_value got=%08x expected=%08x", test_value, PASS_VALUE);
        fail_count++;
    end

    if (fail_count == 0) begin
        $display("RISC-V STRESS TB PASS pc=%08x cycles=%0d", dbg_pc, cycle_count);
    end else begin
        $fatal(1, "RISC-V STRESS TB FAIL fail_count=%0d", fail_count);
    end
    $finish;
end

endmodule
