`timescale 1ns / 1ps

module tb_riscv_core #(
    parameter string FIRMWARE = "firmware/cpu_test.hex",
    parameter int    AW_DELAY = 0,
    parameter int    W_DELAY  = 0,
    parameter int    B_DELAY  = 0,
    parameter int    AR_DELAY = 0,
    parameter int    R_DELAY  = 0,
    parameter int    GOLDEN_COUNT = 0,
    parameter logic [47:0] GOLDEN_WRITES [0:15] = '{default: 48'd0}
);

localparam int CLK_PERIOD_NS = 10;
localparam int MAX_CYCLES = 5000;
localparam logic [31:0] TEST_OUTPUT_ADDR = 32'h1000_0020;
localparam logic [31:0] PASS_VALUE = 32'hCAFE_BABE;

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

// AXI write recording
localparam int MAX_RECORDED = 16;
logic [31:0] recorded_awaddr [0:MAX_RECORDED-1];
logic [31:0] recorded_wdata  [0:MAX_RECORDED-1];
int          recorded_count;
logic        observed_test_write;
logic [31:0] observed_test_value;
int          cycle_count;
int          fail_count;

// AXI slave delay counters
int aw_delay_cnt, w_delay_cnt, b_delay_cnt, ar_delay_cnt, r_delay_cnt;

// Track when write/read handshake completes and BVALID/RVALID should be armed
logic m_axi_bvalid_armed;
logic m_axi_rvalid_armed;

riscv_top #(
    .INST_MEM_FILE(FIRMWARE)
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
    if (!rst_n) begin
        cycle_count <= 0;
    end else begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > MAX_CYCLES) begin
            $display("RISC-V TIMEOUT pc=%08x halted=%0b test_done=%0b test_value=%08x observed=%0b/%08x",
                     dbg_pc, halted, test_done, test_value, observed_test_write, observed_test_value);
            $display("Recorded writes: %0d", recorded_count);
            for (int i = 0; i < recorded_count; i++)
                $display("  [%0d] awaddr=%08x wdata=%08x", i, recorded_awaddr[i], recorded_wdata[i]);
            $fatal(1, "RISC-V TB timeout");
        end
    end
end

// AXI-Lite dummy slave with configurable delays
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
        ar_delay_cnt  <= 0;
        r_delay_cnt   <= 0;
        observed_test_write <= 1'b0;
        observed_test_value <= 32'd0;
        recorded_count <= 0;
        for (int i = 0; i < MAX_RECORDED; i++) begin
            recorded_awaddr[i] <= 32'd0;
            recorded_wdata[i]  <= 32'd0;
        end
    end else begin
        // AW channel with programmable delay
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

        // W channel with programmable delay
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

        // AR channel with programmable delay
        if (m_axi_arvalid && ar_delay_cnt < AR_DELAY) begin
            ar_delay_cnt <= ar_delay_cnt + 1;
            m_axi_arready <= 1'b0;
        end else if (m_axi_arvalid) begin
            m_axi_arready <= 1'b1;
            ar_delay_cnt <= 0;
        end else begin
            m_axi_arready <= 1'b0;
            ar_delay_cnt <= 0;
        end

        // Write response with programmable BVALID delay
        if (!m_axi_bvalid && m_axi_awready && m_axi_awvalid && m_axi_wready && m_axi_wvalid) begin
            // Capture the write transaction
            if (m_axi_awaddr == TEST_OUTPUT_ADDR) begin
                observed_test_write <= 1'b1;
                observed_test_value <= m_axi_wdata;
            end
            // Record all writes for golden comparison
            if (recorded_count < MAX_RECORDED) begin
                recorded_awaddr[recorded_count] <= m_axi_awaddr;
                recorded_wdata[recorded_count]  <= m_axi_wdata;
                recorded_count <= recorded_count + 1;
            end
            b_delay_cnt <= 0;
            m_axi_bvalid <= 1'b0;
        end

        if (m_axi_bvalid) begin
            if (m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                b_delay_cnt <= 0;
            end
        end else if (m_axi_bvalid_armed && !m_axi_bvalid) begin
            // Wait for B_DELAY before asserting BVALID
            if (b_delay_cnt < B_DELAY) begin
                b_delay_cnt <= b_delay_cnt + 1;
            end else begin
                m_axi_bvalid <= 1'b1;
                m_axi_bresp <= 2'b00;
                b_delay_cnt <= 0;
            end
        end

        // Read response with programmable RVALID delay
        if (!m_axi_rvalid && m_axi_arready && m_axi_arvalid) begin
            m_axi_rdata <= 32'd0;
            m_axi_rresp <= 2'b00;
            r_delay_cnt <= 0;
            m_axi_rvalid <= 1'b0;
        end

        if (m_axi_rvalid) begin
            if (m_axi_rready) begin
                m_axi_rvalid <= 1'b0;
                r_delay_cnt <= 0;
            end
        end else if (m_axi_rvalid_armed && !m_axi_rvalid) begin
            if (r_delay_cnt < R_DELAY) begin
                r_delay_cnt <= r_delay_cnt + 1;
            end else begin
                m_axi_rvalid <= 1'b1;
                r_delay_cnt <= 0;
            end
        end
    end
end

always @(posedge clk) begin
    if (!rst_n) begin
        m_axi_bvalid_armed <= 1'b0;
        m_axi_rvalid_armed <= 1'b0;
    end else begin
        if (m_axi_awready && m_axi_awvalid && m_axi_wready && m_axi_wvalid && !m_axi_bvalid)
            m_axi_bvalid_armed <= 1'b1;
        else if (m_axi_bvalid && m_axi_bready)
            m_axi_bvalid_armed <= 1'b0;

        if (m_axi_arready && m_axi_arvalid && !m_axi_rvalid)
            m_axi_rvalid_armed <= 1'b1;
        else if (m_axi_rvalid && m_axi_rready)
            m_axi_rvalid_armed <= 1'b0;
    end
end

// Check golden write list
task automatic check_golden_writes;
    int errors;
    begin
        errors = 0;
        if (GOLDEN_COUNT > 0) begin
            if (recorded_count != GOLDEN_COUNT) begin
                $display("Write count mismatch: recorded=%0d golden=%0d", recorded_count, GOLDEN_COUNT);
                errors++;
            end
            for (int i = 0; i < GOLDEN_COUNT && i < recorded_count; i++) begin
                if (recorded_awaddr[i][15:0] != GOLDEN_WRITES[i][47:32]) begin
                    $display("Write[%0d] awaddr mismatch: got=%08x expected=%04x",
                             i, recorded_awaddr[i], GOLDEN_WRITES[i][47:32]);
                    errors++;
                end
                if (recorded_wdata[i] != GOLDEN_WRITES[i][31:0]) begin
                    $display("Write[%0d] wdata mismatch: got=%08x expected=%08x",
                             i, recorded_wdata[i], GOLDEN_WRITES[i][31:0]);
                    errors++;
                end
            end
            if (errors == 0)
                $display("GOLDEN WRITE CHECK PASS %0d writes match", recorded_count);
            else begin
                $display("GOLDEN WRITE CHECK FAIL errors=%0d", errors);
                fail_count += errors;
            end
        end
    end
endtask

initial begin
    fail_count = 0;
    cycle_count = 0;
    rst_n = 1'b0;
    repeat (12) @(posedge clk);
    rst_n = 1'b1;

    wait (halted === 1'b1 || test_done === 1'b1);
    repeat (8) @(posedge clk);

    // Print recorded writes
    $display("Recorded AXI writes: %0d", recorded_count);
    for (int i = 0; i < recorded_count; i++)
        $display("  [%0d] awaddr=%08x wdata=%08x", i, recorded_awaddr[i], recorded_wdata[i]);

    check_golden_writes();

    if (test_done !== 1'b1) begin
        $display("test_done was not asserted");
        fail_count++;
    end
    if (test_value !== PASS_VALUE) begin
        $display("test_value mismatch got=%08x expected=%08x pc=%08x x13=%08x x14=%08x x15=%08x x24=%08x x25=%08x x26=%08x", test_value, PASS_VALUE, dbg_pc, dut.u_regfile.regs[13], dut.u_regfile.regs[14], dut.u_regfile.regs[15], dut.u_regfile.regs[24], dut.u_regfile.regs[25], dut.u_regfile.regs[26]);
        fail_count++;
    end
    if (halted !== 1'b1) begin
        $display("halted was not asserted");
        fail_count++;
    end
    if (observed_test_write !== 1'b1 || observed_test_value !== PASS_VALUE) begin
        $display("AXI test write mismatch observed=%0b value=%08x", observed_test_write, observed_test_value);
        fail_count++;
    end

    if (fail_count == 0) begin
        $display("RISC-V CORE TB PASS pc=%08x cycles=%0d", dbg_pc, cycle_count);
    end else begin
        $fatal(1, "RISC-V CORE TB FAIL fail_count=%0d", fail_count);
    end
    $finish;
end

endmodule
