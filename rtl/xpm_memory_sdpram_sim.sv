// Minimal simulation-only stub for Xilinx XPM xpm_memory_sdpram.
// Used ONLY for ModelSim functional simulation.
// Vivado synthesis uses the real XPM primitive — do NOT add this file to Vivado projects.

`timescale 1ns / 1ps

module xpm_memory_sdpram #(
    parameter ADDR_WIDTH_A          = 10,
    parameter ADDR_WIDTH_B          = 10,
    parameter AUTO_SLEEP_TIME       = 0,
    parameter BYTE_WRITE_WIDTH_A    = 8,
    parameter CASCADE_HEIGHT        = 0,
    parameter CLOCKING_MODE         = "common_clock",
    parameter ECC_MODE              = "no_ecc",
    parameter MEMORY_INIT_FILE      = "none",
    parameter MEMORY_INIT_PARAM     = "0",
    parameter MEMORY_OPTIMIZATION   = "true",
    parameter MEMORY_PRIMITIVE      = "block",
    parameter MEMORY_SIZE           = 147456,
    parameter MESSAGE_CONTROL       = 0,
    parameter READ_DATA_WIDTH_B     = 8,
    parameter READ_LATENCY_B        = 1,
    parameter READ_RESET_VALUE_B    = "0",
    parameter RST_MODE_A            = "SYNC",
    parameter RST_MODE_B            = "SYNC",
    parameter SIM_ASSERT_CHK        = 0,
    parameter USE_EMBEDDED_CONSTRAINT= 0,
    parameter USE_MEM_INIT          = 1,
    parameter USE_MEM_INIT_MMI      = 0,
    parameter WAKEUP_TIME           = "disable_sleep",
    parameter WRITE_DATA_WIDTH_A    = 8,
    parameter WRITE_MODE_B          = "no_change",
    parameter WRITE_PROTECT         = 1
) (
    output wire                              dbiterrb,
    output wire [READ_DATA_WIDTH_B-1:0]      doutb,
    output wire                              sbiterrb,
    input  wire [ADDR_WIDTH_A-1:0]           addra,
    input  wire [ADDR_WIDTH_B-1:0]           addrb,
    input  wire                              clka,
    input  wire                              clkb,
    input  wire [WRITE_DATA_WIDTH_A-1:0]     dina,
    input  wire                              ena,
    input  wire                              enb,
    input  wire                              injectdbiterra,
    input  wire                              injectsbiterra,
    input  wire                              regceb,
    input  wire                              rstb,
    input  wire                              sleep,
    input  wire                              wea
);

    localparam DEPTH = MEMORY_SIZE / WRITE_DATA_WIDTH_A;
    reg [WRITE_DATA_WIDTH_A-1:0] mem [0:DEPTH-1];
    reg [READ_DATA_WIDTH_B-1:0]  doutb_reg;

    always @(posedge clka) begin
        if (ena && wea)
            mem[addra] <= dina;
    end

    always @(posedge clkb) begin
        if (enb && regceb)
            doutb_reg <= mem[addrb];
    end

    assign doutb    = doutb_reg;
    assign dbiterrb = 1'b0;
    assign sbiterrb = 1'b0;

endmodule
