`timescale 1ns / 1ps
`default_nettype none

// Per-bank ping-pong storage backed by two XPM simple dual-port BRAMs.
// Write port A (wr_en/wr_buf_sel selects A or B half).
// Read port B, 1-cycle read latency. doutb holds last value when enb=0;
// the outer feature_buffer masks invalid lanes with rd_bank_valid_r.
module feature_buffer_bank_ram #(
    parameter ADDR_WIDTH = 15,
    parameter DEPTH = 18432
) (
    input  wire                  clk,
    input  wire                  wr_en,
    input  wire                  wr_buf_sel,
    input  wire [ADDR_WIDTH-1:0] wr_addr,
    input  wire signed [7:0]     wr_data,
    input  wire                  rd_en,
    input  wire                  rd_buf_sel,
    input  wire [ADDR_WIDTH-1:0] rd_addr,
    output reg  signed [7:0]     rd_data
);

localparam integer MEMORY_SIZE_BITS = DEPTH * 8;

wire wr_en_a = wr_en && (wr_buf_sel == 1'b0);
wire wr_en_b = wr_en && (wr_buf_sel == 1'b1);
wire rd_en_a = rd_en && (rd_buf_sel == 1'b0);
wire rd_en_b = rd_en && (rd_buf_sel == 1'b1);

wire [7:0] doutb_a;
wire [7:0] doutb_b;

reg rd_buf_sel_r;
always @(posedge clk) begin
    rd_buf_sel_r <= rd_buf_sel;
end

xpm_memory_sdpram #(
    .ADDR_WIDTH_A(ADDR_WIDTH),
    .ADDR_WIDTH_B(ADDR_WIDTH),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(MEMORY_SIZE_BITS),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(8),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(1),
    .USE_MEM_INIT_MMI(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(8),
    .WRITE_MODE_B("no_change"),
    .WRITE_PROTECT(1)
) u_bram_a (
    .dbiterrb(),
    .doutb(doutb_a),
    .sbiterrb(),
    .addra(wr_addr),
    .addrb(rd_addr),
    .clka(clk),
    .clkb(clk),
    .dina(wr_data),
    .ena(wr_en_a),
    .enb(rd_en_a),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb(1'b1),
    .rstb(1'b0),
    .sleep(1'b0),
    .wea(wr_en_a)
);

xpm_memory_sdpram #(
    .ADDR_WIDTH_A(ADDR_WIDTH),
    .ADDR_WIDTH_B(ADDR_WIDTH),
    .AUTO_SLEEP_TIME(0),
    .BYTE_WRITE_WIDTH_A(8),
    .CASCADE_HEIGHT(0),
    .CLOCKING_MODE("common_clock"),
    .ECC_MODE("no_ecc"),
    .MEMORY_INIT_FILE("none"),
    .MEMORY_INIT_PARAM("0"),
    .MEMORY_OPTIMIZATION("true"),
    .MEMORY_PRIMITIVE("block"),
    .MEMORY_SIZE(MEMORY_SIZE_BITS),
    .MESSAGE_CONTROL(0),
    .READ_DATA_WIDTH_B(8),
    .READ_LATENCY_B(1),
    .READ_RESET_VALUE_B("0"),
    .RST_MODE_A("SYNC"),
    .RST_MODE_B("SYNC"),
    .SIM_ASSERT_CHK(0),
    .USE_EMBEDDED_CONSTRAINT(0),
    .USE_MEM_INIT(1),
    .USE_MEM_INIT_MMI(0),
    .WAKEUP_TIME("disable_sleep"),
    .WRITE_DATA_WIDTH_A(8),
    .WRITE_MODE_B("no_change"),
    .WRITE_PROTECT(1)
) u_bram_b (
    .dbiterrb(),
    .doutb(doutb_b),
    .sbiterrb(),
    .addra(wr_addr),
    .addrb(rd_addr),
    .clka(clk),
    .clkb(clk),
    .dina(wr_data),
    .ena(wr_en_b),
    .enb(rd_en_b),
    .injectdbiterra(1'b0),
    .injectsbiterra(1'b0),
    .regceb(1'b1),
    .rstb(1'b0),
    .sleep(1'b0),
    .wea(wr_en_b)
);

always @(*) begin
    if (rd_buf_sel_r)
        rd_data = doutb_b;
    else
        rd_data = doutb_a;
end

endmodule

module feature_buffer #(
    parameter ADDR_WIDTH = 18,
    parameter LANES = 8,
    parameter BANKS = 8,
    parameter MAX_FEATURE_LEN = 2048,
    parameter MAX_CHANNELS = 72
) (
    input  wire                        clk,
    input  wire [LANES-1:0]            wr_en,
    input  wire                        wr_buf_sel,
    input  wire [LANES*ADDR_WIDTH-1:0] wr_addr_flat,
    input  wire [LANES*8-1:0]          wr_data_flat,
    input  wire [LANES-1:0]            rd_en,
    input  wire                        rd_buf_sel,
    input  wire [LANES*ADDR_WIDTH-1:0] rd_addr_flat,
    output reg  [LANES*8-1:0]          rd_data_flat
);

function integer clog2;
    input integer value;
    integer tmp;
    begin
        tmp = value - 1;
        clog2 = 0;
        while (tmp > 0) begin
            tmp = tmp >> 1;
            clog2 = clog2 + 1;
        end
    end
endfunction

localparam BANK_DEPTH = ((MAX_CHANNELS + BANKS - 1) / BANKS) * MAX_FEATURE_LEN;
localparam BANK_ADDR_WIDTH = clog2(BANK_DEPTH);
localparam LANE_IDX_WIDTH = (LANES > 1) ? clog2(LANES) : 1;

wire [BANKS*8-1:0] rd_bank_data_flat;

reg [LANES-1:0] wr_en_r;
reg             wr_buf_sel_r;
reg [LANES*ADDR_WIDTH-1:0] wr_addr_flat_r;
reg [LANES*8-1:0] wr_data_flat_r;

reg [BANKS-1:0] wr_bank_en;
reg [BANKS*BANK_ADDR_WIDTH-1:0] wr_bank_addr_flat;
reg [BANKS*8-1:0] wr_bank_data_flat;
reg [BANKS-1:0] rd_bank_en;
reg [BANKS*BANK_ADDR_WIDTH-1:0] rd_bank_addr_flat;
reg [BANKS*LANE_IDX_WIDTH-1:0] rd_bank_lane_flat;
reg [BANKS-1:0] rd_bank_valid_r;
reg [BANKS*LANE_IDX_WIDTH-1:0] rd_bank_lane_flat_r;
reg [LANES*8-1:0] rd_data_flat_comb;

integer lane;
integer bank;
integer logical_addr;
integer channel;
integer position;
integer bank_id;
integer bank_addr;
integer selected_lane;
reg [7:0] rd_lane_word;

genvar bank_gen;
generate
    for (bank_gen = 0; bank_gen < BANKS; bank_gen = bank_gen + 1) begin : g_bank
        feature_buffer_bank_ram #(
            .ADDR_WIDTH(BANK_ADDR_WIDTH),
            .DEPTH(BANK_DEPTH)
        ) u_bank_ram (
            .clk(clk),
            .wr_en(wr_bank_en[bank_gen]),
            .wr_buf_sel(wr_buf_sel_r),
            .wr_addr(wr_bank_addr_flat[bank_gen*BANK_ADDR_WIDTH +: BANK_ADDR_WIDTH]),
            .wr_data(wr_bank_data_flat[bank_gen*8 +: 8]),
            .rd_en(rd_bank_en[bank_gen]),
            .rd_buf_sel(rd_buf_sel),
            .rd_addr(rd_bank_addr_flat[bank_gen*BANK_ADDR_WIDTH +: BANK_ADDR_WIDTH]),
            .rd_data(rd_bank_data_flat[bank_gen*8 +: 8])
        );
    end
endgenerate

always @(*) begin
    wr_bank_en = {BANKS{1'b0}};
    wr_bank_addr_flat = {(BANKS*BANK_ADDR_WIDTH){1'b0}};
    wr_bank_data_flat = {(BANKS*8){1'b0}};
    rd_bank_en = {BANKS{1'b0}};
    rd_bank_addr_flat = {(BANKS*BANK_ADDR_WIDTH){1'b0}};
    rd_bank_lane_flat = {(BANKS*LANE_IDX_WIDTH){1'b0}};

    for (lane = 0; lane < LANES; lane = lane + 1) begin
        if (wr_en_r[lane]) begin
            logical_addr = wr_addr_flat_r[lane*ADDR_WIDTH +: ADDR_WIDTH];
            channel = logical_addr >> 11;
            position = logical_addr[10:0];
            bank_id = logical_addr[13:11];
            bank_addr = ((logical_addr >> 14) << 11) + position;

            if (bank_addr < BANK_DEPTH) begin
                wr_bank_en[bank_id] = 1'b1;
                wr_bank_addr_flat[bank_id*BANK_ADDR_WIDTH +: BANK_ADDR_WIDTH] = bank_addr[BANK_ADDR_WIDTH-1:0];
                wr_bank_data_flat[bank_id*8 +: 8] = wr_data_flat_r[lane*8 +: 8];
            end
        end

        if (rd_en[lane]) begin
            logical_addr = rd_addr_flat[lane*ADDR_WIDTH +: ADDR_WIDTH];
            channel = logical_addr >> 11;
            position = logical_addr[10:0];
            bank_id = logical_addr[13:11];
            bank_addr = ((logical_addr >> 14) << 11) + position;

            if (bank_addr < BANK_DEPTH) begin
                rd_bank_en[bank_id] = 1'b1;
                rd_bank_addr_flat[bank_id*BANK_ADDR_WIDTH +: BANK_ADDR_WIDTH] = bank_addr[BANK_ADDR_WIDTH-1:0];
                rd_bank_lane_flat[bank_id*LANE_IDX_WIDTH +: LANE_IDX_WIDTH] = lane[LANE_IDX_WIDTH-1:0];
            end
        end
    end
end

always @(posedge clk) begin
    wr_en_r <= wr_en;
    wr_buf_sel_r <= wr_buf_sel;
    wr_addr_flat_r <= wr_addr_flat;
    wr_data_flat_r <= wr_data_flat;
    rd_bank_valid_r <= rd_bank_en;
    rd_bank_lane_flat_r <= rd_bank_lane_flat;
    rd_data_flat <= rd_data_flat_comb;
end

always @(*) begin
    rd_data_flat_comb = {(LANES*8){1'b0}};

    for (lane = 0; lane < LANES; lane = lane + 1) begin
        rd_lane_word = 8'h00;
        for (bank = 0; bank < BANKS; bank = bank + 1) begin
            selected_lane = rd_bank_lane_flat_r[bank*LANE_IDX_WIDTH +: LANE_IDX_WIDTH];
            if (rd_bank_valid_r[bank] && (selected_lane == lane)) begin
                rd_lane_word = rd_bank_data_flat[bank*8 +: 8];
            end
        end
        rd_data_flat_comb[lane*8 +: 8] = rd_lane_word;
    end
end

endmodule

`default_nettype wire
