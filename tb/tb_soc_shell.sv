`timescale 1ns / 1ps

module tb_soc_shell;

localparam int CLK_PERIOD_NS = 10;
localparam int INPUT_LEN = 2048;
localparam int NUM_CLASSES = 10;
localparam int MAX_CYCLES = 3000000;

localparam logic [31:0] ADDR_CTRL        = 32'h0000_0000;
localparam logic [31:0] ADDR_STATUS      = 32'h0000_0004;
localparam logic [31:0] ADDR_INPUT_LEN   = 32'h0000_0008;
localparam logic [31:0] ADDR_LAYER_CFG   = 32'h0000_000C;
localparam logic [31:0] ADDR_NUM_CLASSES = 32'h0000_0010;
localparam logic [31:0] ADDR_CLEAR       = 32'h0000_0014;
localparam logic [31:0] ADDR_CYCLE_CNT   = 32'h0000_0018;
localparam logic [31:0] ADDR_VERSION     = 32'h0000_001C;

logic clk;
logic rst_n_async;

logic [31:0] s_axi_awaddr;
logic        s_axi_awvalid;
wire         s_axi_awready;
logic [31:0] s_axi_wdata;
logic [3:0]  s_axi_wstrb;
logic        s_axi_wvalid;
wire         s_axi_wready;
wire [1:0]   s_axi_bresp;
wire         s_axi_bvalid;
logic        s_axi_bready;
logic [31:0] s_axi_araddr;
logic        s_axi_arvalid;
wire         s_axi_arready;
wire [31:0]  s_axi_rdata;
wire [1:0]   s_axi_rresp;
wire         s_axi_rvalid;
logic        s_axi_rready;

logic        s_axis_tvalid;
wire         s_axis_tready;
logic [7:0]  s_axis_tdata;
logic        s_axis_tlast;

wire         m_axis_tvalid;
logic        m_axis_tready;
wire [7:0]   m_axis_tdata;
wire         m_axis_tlast;

wire         dbg_busy;
wire         dbg_done;
wire         dbg_error;

logic [7:0] input_mem [0:INPUT_LEN-1];
logic [7:0] golden_logits [0:NUM_CLASSES-1];
logic [7:0] collected_logits [0:NUM_CLASSES-1];

int fail_count;
int cycle_count_tb;

soc_top dut (
    .clk(clk),
    .rst_n_async(rst_n_async),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tlast(s_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tlast(m_axis_tlast),
    .dbg_busy(dbg_busy),
    .dbg_done(dbg_done),
    .dbg_error(dbg_error)
);

initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD_NS/2) clk = ~clk;
end

always @(posedge clk) begin
    cycle_count_tb <= cycle_count_tb + 1;
    if (cycle_count_tb > MAX_CYCLES) begin
        $display("SOC TIMEOUT DBG busy=%0b done=%0b error=%0b in_ready=%0b out_valid=%0b out_ready=%0b",
                 dbg_busy, dbg_done, dbg_error, s_axis_tready, m_axis_tvalid, m_axis_tready);
        $fatal(1, "SOC shell TB timeout after %0d cycles", MAX_CYCLES);
    end
end

task automatic init_signals;
    begin
        s_axi_awaddr = 32'd0;
        s_axi_awvalid = 1'b0;
        s_axi_wdata = 32'd0;
        s_axi_wstrb = 4'd0;
        s_axi_wvalid = 1'b0;
        s_axi_bready = 1'b0;
        s_axi_araddr = 32'd0;
        s_axi_arvalid = 1'b0;
        s_axi_rready = 1'b0;
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 8'd0;
        s_axis_tlast = 1'b0;
        m_axis_tready = 1'b0;
    end
endtask

task automatic apply_reset;
    begin
        rst_n_async = 1'b0;
        repeat (10) @(posedge clk);
        rst_n_async = 1'b1;
        repeat (8) @(posedge clk);
    end
endtask

task automatic axi_write(input logic [31:0] addr, input logic [31:0] data);
    bit aw_done;
    bit w_done;
    begin
        aw_done = 1'b0;
        w_done = 1'b0;
        @(negedge clk);
        s_axi_awaddr = addr;
        s_axi_awvalid = 1'b1;
        s_axi_wdata = data;
        s_axi_wstrb = 4'hF;
        s_axi_wvalid = 1'b1;
        s_axi_bready = 1'b1;

        while (!aw_done || !w_done) begin
            @(posedge clk);
            #1;
            if (s_axi_awready) begin
                aw_done = 1'b1;
            end
            if (s_axi_wready) begin
                w_done = 1'b1;
            end
            @(negedge clk);
            if (aw_done) begin
                s_axi_awvalid = 1'b0;
            end
            if (w_done) begin
                s_axi_wvalid = 1'b0;
            end
        end

        do begin
            @(posedge clk);
            #1;
        end while (!s_axi_bvalid);

        if (s_axi_bresp !== 2'b00) begin
            $display("AXI write SLVERR addr=%08x data=%08x resp=%0b", addr, data, s_axi_bresp);
            fail_count++;
        end

        @(negedge clk);
        s_axi_bready = 1'b0;
    end
endtask

task automatic axi_read(input logic [31:0] addr, output logic [31:0] data);
    bit ar_done;
    bit r_done;
    begin
        ar_done = 1'b0;
        r_done = 1'b0;
        @(negedge clk);
        s_axi_araddr = addr;
        s_axi_arvalid = 1'b1;
        s_axi_rready = 1'b1;

        while (!ar_done || !r_done) begin
            @(posedge clk);
            #1;
            if (s_axi_arready) begin
                ar_done = 1'b1;
            end
            if (s_axi_rvalid) begin
                data = s_axi_rdata;
                if (s_axi_rresp !== 2'b00) begin
                    $display("AXI read SLVERR addr=%08x resp=%0b", addr, s_axi_rresp);
                    fail_count++;
                end
                r_done = 1'b1;
            end
            @(negedge clk);
            if (ar_done) begin
                s_axi_arvalid = 1'b0;
            end
            if (r_done) begin
                s_axi_rready = 1'b0;
            end
        end
    end
endtask

task automatic clear_collected;
    int i;
    begin
        for (i = 0; i < NUM_CLASSES; i++) begin
            collected_logits[i] = 8'd0;
        end
    end
endtask

task automatic send_stream_samples(input int n);
    int i;
    begin
        for (i = 0; i < n; i++) begin
            @(negedge clk);
            s_axis_tvalid = 1'b1;
            s_axis_tdata = input_mem[i];
            s_axis_tlast = (i == (n - 1));

            do begin
                @(posedge clk);
            end while (!s_axis_tready);
        end

        @(negedge clk);
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 8'd0;
        s_axis_tlast = 1'b0;
    end
endtask

task automatic collect_logits_with_backpressure(input int n, input int stall_period);
    int i;
    int wait_cycles;
    bit stall_now;
    begin
        i = 0;
        wait_cycles = 0;
        @(negedge clk);
        m_axis_tready = 1'b1;
        while (i < n) begin
            @(negedge clk);
            stall_now = (stall_period > 0) && (wait_cycles != 0) && ((wait_cycles % stall_period) == 0);
            m_axis_tready = !stall_now;
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                collected_logits[i] = m_axis_tdata;
                if (m_axis_tlast !== (i == (n - 1))) begin
                    $display("TLAST mismatch at logit %0d: got %0b", i, m_axis_tlast);
                    fail_count++;
                end
                i++;
            end
            wait_cycles++;
        end
        @(negedge clk);
        m_axis_tready = 1'b0;
    end
endtask

task automatic check_logits(input int n);
    int i;
    begin
        for (i = 0; i < n; i++) begin
            if (collected_logits[i] !== golden_logits[i]) begin
                $display("LOGIT mismatch idx=%0d got=%02x expected=%02x", i, collected_logits[i], golden_logits[i]);
                fail_count++;
            end
        end
    end
endtask

task automatic check_done_status(input string case_name);
    logic [31:0] status_value;
    begin
        axi_read(ADDR_STATUS, status_value);
        if (status_value[0] !== 1'b0 || status_value[1] !== 1'b1 || status_value[2] !== 1'b0) begin
            $display("%s STATUS mismatch after inference: %08x", case_name, status_value);
            fail_count++;
        end
        if (dbg_busy !== 1'b0 || dbg_done !== 1'b1 || dbg_error !== 1'b0) begin
            $display("%s debug mismatch after inference: busy=%0b done=%0b error=%0b", case_name, dbg_busy, dbg_done, dbg_error);
            fail_count++;
        end
    end
endtask

task automatic check_cycle_count(input string case_name);
    logic [31:0] cycle_value;
    begin
        axi_read(ADDR_CYCLE_CNT, cycle_value);
        if (cycle_value == 32'd0) begin
            $display("%s CYCLE_CNT is zero", case_name);
            fail_count++;
        end else begin
            $display("%s cycle_cnt=%0d", case_name, cycle_value);
        end
    end
endtask

task automatic clear_status_and_check(input string case_name);
    logic [31:0] status_value;
    begin
        axi_write(ADDR_CLEAR, 32'd1);
        repeat (2) @(posedge clk);
        axi_read(ADDR_STATUS, status_value);
        if (status_value[1] !== 1'b0 || status_value[2] !== 1'b0) begin
            $display("%s CLEAR did not clear done/error: %08x", case_name, status_value);
            fail_count++;
        end
        if (dbg_done !== 1'b0 || dbg_error !== 1'b0) begin
            $display("%s debug clear mismatch: busy=%0b done=%0b error=%0b", case_name, dbg_busy, dbg_done, dbg_error);
            fail_count++;
        end
    end
endtask

task automatic run_inference_case(input string case_name, input int output_stall_period);
    begin
        clear_collected();
        axi_write(ADDR_INPUT_LEN, INPUT_LEN);
        axi_write(ADDR_LAYER_CFG, 32'd5);
        axi_write(ADDR_NUM_CLASSES, NUM_CLASSES);
        axi_write(ADDR_CTRL, 32'd1);

        repeat (2) @(posedge clk);
        if (dbg_busy !== 1'b1 || dbg_done !== 1'b0 || dbg_error !== 1'b0) begin
            $display("%s debug mismatch after start: busy=%0b done=%0b error=%0b", case_name, dbg_busy, dbg_done, dbg_error);
            fail_count++;
        end

        send_stream_samples(INPUT_LEN);
        collect_logits_with_backpressure(NUM_CLASSES, output_stall_period);

        check_logits(NUM_CLASSES);
        check_done_status(case_name);
        check_cycle_count(case_name);
    end
endtask

initial begin
    logic [31:0] read_value;

    cycle_count_tb = 0;
    fail_count = 0;
    init_signals();
    $readmemh("D:/RICS_V_CNN/1DCNN_ACC/mem/fake_input_2048.mem", input_mem);
    $readmemh("D:/RICS_V_CNN/1DCNN_ACC/mem/golden_logits.mem", golden_logits);

    apply_reset();

    if (dbg_busy !== 1'b0 || dbg_done !== 1'b0 || dbg_error !== 1'b0) begin
        $display("debug mismatch after reset: busy=%0b done=%0b error=%0b", dbg_busy, dbg_done, dbg_error);
        fail_count++;
    end

    axi_read(ADDR_VERSION, read_value);
    if (read_value !== 32'h0000_0400) begin
        $display("VERSION mismatch: %08x", read_value);
        fail_count++;
    end

    run_inference_case("soc_shell_basic", 0);
    clear_status_and_check("soc_shell_basic");

    run_inference_case("soc_shell_backpressure", 3);

    if (fail_count == 0) begin
        $display("SOC SHELL TB PASS");
    end else begin
        $fatal(1, "SOC SHELL TB FAIL fail_count=%0d", fail_count);
    end
    $finish;
end

endmodule
