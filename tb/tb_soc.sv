`timescale 1ns / 1ps

module tb_soc;

localparam int CLK_PERIOD_NS = 10;
localparam int INPUT_LEN = 2048;
localparam int NUM_CLASSES = 10;
localparam int MAX_CYCLES = 5000000;
localparam logic [31:0] SOC_PASS_VALUE = 32'hA5A5_0001;

logic clk;
logic rst_n_async;

logic        s_axis_tvalid;
wire         s_axis_tready;
logic [7:0]  s_axis_tdata;
logic        s_axis_tlast;

wire         m_axis_tvalid;
logic        m_axis_tready;
wire [7:0]   m_axis_tdata;
wire         m_axis_tlast;

wire         test_done;
wire [31:0]  test_value;
wire         cpu_halted;
wire [31:0]  dbg_pc;
wire         dbg_cnn_busy;
wire         dbg_cnn_done;
wire         dbg_cnn_error;

logic [7:0] input_mem [0:INPUT_LEN-1];
logic [7:0] golden_logits [0:NUM_CLASSES-1];
logic [7:0] collected_logits [0:NUM_CLASSES-1];

int cycle_count;
int fail_count;

soc_top dut (
    .clk(clk),
    .rst_n_async(rst_n_async),
    .s_axis_tvalid(s_axis_tvalid),
    .s_axis_tready(s_axis_tready),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tlast(s_axis_tlast),
    .m_axis_tvalid(m_axis_tvalid),
    .m_axis_tready(m_axis_tready),
    .m_axis_tdata(m_axis_tdata),
    .m_axis_tlast(m_axis_tlast),
    .test_done(test_done),
    .test_value(test_value),
    .cpu_halted(cpu_halted),
    .dbg_pc(dbg_pc),
    .dbg_cnn_busy(dbg_cnn_busy),
    .dbg_cnn_done(dbg_cnn_done),
    .dbg_cnn_error(dbg_cnn_error)
);

initial begin
    clk = 1'b0;
    forever #(CLK_PERIOD_NS/2) clk = ~clk;
end

always @(posedge clk) begin
    if (!rst_n_async) begin
        cycle_count <= 0;
    end else begin
        cycle_count <= cycle_count + 1;
        if (cycle_count > MAX_CYCLES) begin
            $display("SOC TIMEOUT pc=%08x halted=%0b test=%0b/%08x cnn_busy=%0b cnn_done=%0b cnn_error=%0b in_ready=%0b out_valid=%0b",
                     dbg_pc, cpu_halted, test_done, test_value, dbg_cnn_busy, dbg_cnn_done, dbg_cnn_error,
                     s_axis_tready, m_axis_tvalid);
            $fatal(1, "Full SoC TB timeout");
        end
    end
end

task automatic init_signals;
    begin
        s_axis_tvalid = 1'b0;
        s_axis_tdata = 8'd0;
        s_axis_tlast = 1'b0;
        m_axis_tready = 1'b0;
    end
endtask

task automatic apply_reset;
    begin
        rst_n_async = 1'b0;
        repeat (12) @(posedge clk);
        rst_n_async = 1'b1;
        repeat (8) @(posedge clk);
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

task automatic wait_for_cnn_ready;
    begin
        while (s_axis_tready !== 1'b1) begin
            @(posedge clk);
            if (dbg_cnn_error) begin
                $display("CNN reported error before input stream pc=%08x", dbg_pc);
                fail_count++;
                return;
            end
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

task automatic collect_logits(input int n);
    int i;
    begin
        i = 0;
        @(negedge clk);
        m_axis_tready = 1'b1;
        while (i < n) begin
            @(posedge clk);
            if (m_axis_tvalid && m_axis_tready) begin
                collected_logits[i] = m_axis_tdata;
                if (m_axis_tlast !== (i == (n - 1))) begin
                    $display("TLAST mismatch at logit %0d: got %0b", i, m_axis_tlast);
                    fail_count++;
                    if (m_axis_tlast) begin
                        i = n;
                    end else begin
                        i++;
                    end
                end else begin
                    i++;
                end
            end
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

task automatic wait_for_test_done;
    begin
        while (test_done !== 1'b1) begin
            @(posedge clk);
            if (dbg_cnn_error) begin
                $display("CNN reported error while waiting for test_done pc=%08x", dbg_pc);
                fail_count++;
                return;
            end
        end
        repeat (4) @(posedge clk);
    end
endtask

initial begin
    cycle_count = 0;
    fail_count = 0;
    init_signals();
    clear_collected();
    $readmemh("D:/RICS_V_CNN/1DCNN_ACC/mem/fake_input_2048.mem", input_mem);
    $readmemh("D:/RICS_V_CNN/1DCNN_ACC/mem/golden_logits.mem", golden_logits);

    apply_reset();
    wait_for_cnn_ready();
    send_stream_samples(INPUT_LEN);
    collect_logits(NUM_CLASSES);
    check_logits(NUM_CLASSES);
    wait_for_test_done();

    if (test_value !== SOC_PASS_VALUE) begin
        $display("test_value mismatch got=%08x expected=%08x", test_value, SOC_PASS_VALUE);
        fail_count++;
    end
    if (dbg_cnn_error !== 1'b0) begin
        $display("CNN error asserted at end");
        fail_count++;
    end
    if (dbg_cnn_done !== 1'b1) begin
        $display("CNN done not asserted at end");
        fail_count++;
    end

    if (fail_count == 0) begin
        $display("FULL SOC TB PASS pc=%08x cycles=%0d test_value=%08x", dbg_pc, cycle_count, test_value);
    end else begin
        $fatal(1, "FULL SOC TB FAIL fail_count=%0d", fail_count);
    end
    $finish;
end

endmodule
