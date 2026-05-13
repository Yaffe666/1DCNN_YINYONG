`timescale 1ns / 1ps
`default_nettype none

module final_conv_engine #(
    parameter PAR_CLASS = 8,
    parameter PAR_IC = 4,
    parameter MAX_CHANNELS = 72,
    parameter MAX_CLASSES = 16
) (
    input  wire                            clk,
    input  wire                            rst_n,
    input  wire                            start,
    output reg                             busy,
    output reg                             done,
    output reg                             error,

    input  wire [7:0]                      channels,
    input  wire [4:0]                      num_classes,

    output reg  [PAR_IC*7-1:0]             gap_rd_addr_flat,
    input  wire [PAR_IC*8-1:0]             gap_rd_data_flat,

    output reg  [PAR_CLASS*PAR_IC*16-1:0]  weight_addr_flat,
    input  wire [PAR_CLASS*PAR_IC*8-1:0]   weight_data_flat,
    output reg  [PAR_CLASS*12-1:0]         bn_addr_flat,
    input  wire [PAR_CLASS*16-1:0]         bn_scale_q8_8_flat,
    input  wire [PAR_CLASS*32-1:0]         bn_bias_flat,
    input  wire [PAR_CLASS*8-1:0]          input_zp_flat,
    input  wire [PAR_CLASS*8-1:0]          weight_zp_flat,
    input  wire [PAR_CLASS*8-1:0]          output_zp_flat,

    output reg                             logit_wr_en,
    output reg  [4:0]                      logit_wr_addr,
    output reg  signed [7:0]               logit_wr_data
);

localparam FC_WEIGHT_BASE = 16104;
localparam FC_BN_BASE = 504;

localparam [3:0] S_IDLE      = 4'd0;
localparam [3:0] S_LOAD_BN    = 4'd1;
localparam [3:0] S_WAIT_BN    = 4'd2;
localparam [3:0] S_CAPTURE_BN = 4'd3;
localparam [3:0] S_IC_REQ     = 4'd4;
localparam [3:0] S_IC_WAIT    = 4'd5;
localparam [3:0] S_IC_ACC     = 4'd6;
localparam [3:0] S_RQ_START   = 4'd7;
localparam [3:0] S_RQ_WAIT    = 4'd8;
localparam [3:0] S_WRITE      = 4'd9;

reg [3:0] state;
reg [4:0] curr_class_base;
reg [7:0] curr_ic_base;
reg [3:0] write_lane;

(* DONT_TOUCH = "true" *) reg signed [31:0] acc_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [15:0] bn_scale_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [31:0] bn_bias_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  input_zp_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  weight_zp_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  output_zp_reg [0:PAR_CLASS-1];
reg signed [7:0]  logit_reg [0:PAR_CLASS-1];
(* DONT_TOUCH = "true" *) reg signed [7:0]  gap_data_reg [0:PAR_IC-1];
(* DONT_TOUCH = "true" *) reg [PAR_CLASS*PAR_IC*8-1:0] weight_data_r;
(* DONT_TOUCH = "true" *) reg signed [8:0] gap_preproc_r [0:PAR_CLASS*PAR_IC-1];
(* DONT_TOUCH = "true" *) reg signed [8:0] wt_preproc_r   [0:PAR_CLASS*PAR_IC-1];
reg [PAR_CLASS-1:0] rq_in_valid;

wire [PAR_CLASS-1:0] rq_out_valid;
wire rq_out_valid_any;
wire signed [7:0] rq_out_data [0:PAR_CLASS-1];

integer class_lane;
integer ic_lane;
integer class_abs;
integer ic_abs;
integer weight_slot;
integer weight_addr_value;
reg signed [7:0] gap_sample;
reg signed [7:0] wt_sample;
reg signed [31:0] sum_next;

assign rq_out_valid_any = |rq_out_valid;

genvar gi;
generate
    for (gi = 0; gi < PAR_CLASS; gi = gi + 1) begin : g_requant
        requant_relu u_requant_relu (
            .clk(clk),
            .rst_n(rst_n),
            .in_valid(rq_in_valid[gi]),
            .acc_in(acc_reg[gi]),
            .scale_q8_8(bn_scale_reg[gi]),
            .bias(bn_bias_reg[gi]),
            .output_zero_point(output_zp_reg[gi]),
            .relu_en(1'b0),
            .out_valid(rq_out_valid[gi]),
            .out_data(rq_out_data[gi])
        );
    end
endgenerate

always @(posedge clk) begin
    if (!rst_n) begin
        state <= S_IDLE;
        busy <= 1'b0;
        done <= 1'b0;
        error <= 1'b0;
        curr_class_base <= 5'd0;
        curr_ic_base <= 8'd0;
        write_lane <= 4'd0;
        gap_rd_addr_flat <= {(PAR_IC*7){1'b0}};
        weight_addr_flat <= {(PAR_CLASS*PAR_IC*16){1'b0}};
        bn_addr_flat <= {(PAR_CLASS*12){1'b0}};
        logit_wr_en <= 1'b0;
        logit_wr_addr <= 5'd0;
        logit_wr_data <= 8'sd0;
        rq_in_valid <= {PAR_CLASS{1'b0}};
        for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
            acc_reg[class_lane] <= 32'sd0;
            bn_scale_reg[class_lane] <= 16'sd0;
            bn_bias_reg[class_lane] <= 32'sd0;
            input_zp_reg[class_lane] <= 8'sd0;
            weight_zp_reg[class_lane] <= 8'sd0;
            output_zp_reg[class_lane] <= 8'sd0;
            logit_reg[class_lane] <= 8'sd0;
        end
        for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
            gap_data_reg[ic_lane] <= 8'sd0;
        end
        weight_data_r <= {(PAR_CLASS*PAR_IC*8){1'b0}};
        for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
            for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                weight_slot = (class_lane * PAR_IC) + ic_lane;
                gap_preproc_r[weight_slot] <= 9'sd0;
                wt_preproc_r[weight_slot] <= 9'sd0;
            end
        end
    end else begin
        done <= 1'b0;
        error <= 1'b0;
        gap_rd_addr_flat <= {(PAR_IC*7){1'b0}};
        weight_addr_flat <= {(PAR_CLASS*PAR_IC*16){1'b0}};
        bn_addr_flat <= {(PAR_CLASS*12){1'b0}};
        logit_wr_en <= 1'b0;
        logit_wr_addr <= 5'd0;
        logit_wr_data <= 8'sd0;
        rq_in_valid <= {PAR_CLASS{1'b0}};

        weight_data_r <= weight_data_flat;

        case (state)
            S_IDLE: begin
                busy <= 1'b0;
                if (start) begin
                    if ((channels == 8'd0) || (channels > MAX_CHANNELS) || (num_classes == 5'd0) || (num_classes > MAX_CLASSES)) begin
                        error <= 1'b1;
                    end else begin
                        busy <= 1'b1;
                        curr_class_base <= 5'd0;
                        curr_ic_base <= 8'd0;
                        write_lane <= 4'd0;
                        for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                            acc_reg[class_lane] <= 32'sd0;
                        end
                        state <= S_LOAD_BN;
                    end
                end
            end

            S_LOAD_BN: begin
                busy <= 1'b1;
                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    if (class_abs < num_classes) begin
                        bn_addr_flat[class_lane*12 +: 12] <= FC_BN_BASE + class_abs;
                    end
                end
                state <= S_WAIT_BN;
            end

            S_WAIT_BN: begin
                busy <= 1'b1;
                state <= S_CAPTURE_BN;
            end

            S_CAPTURE_BN: begin
                busy <= 1'b1;
                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    if (class_abs < num_classes) begin
                        bn_scale_reg[class_lane] <= bn_scale_q8_8_flat[class_lane*16 +: 16];
                        bn_bias_reg[class_lane] <= bn_bias_flat[class_lane*32 +: 32];
                        input_zp_reg[class_lane] <= input_zp_flat[class_lane*8 +: 8];
                        weight_zp_reg[class_lane] <= weight_zp_flat[class_lane*8 +: 8];
                        output_zp_reg[class_lane] <= output_zp_flat[class_lane*8 +: 8];
                    end else begin
                        bn_scale_reg[class_lane] <= 16'sd0;
                        bn_bias_reg[class_lane] <= 32'sd0;
                        input_zp_reg[class_lane] <= 8'sd0;
                        weight_zp_reg[class_lane] <= 8'sd0;
                        output_zp_reg[class_lane] <= 8'sd0;
                    end
                    acc_reg[class_lane] <= 32'sd0;
                end
                curr_ic_base <= 8'd0;
                state <= S_IC_REQ;
            end

            S_IC_REQ: begin
                busy <= 1'b1;
                for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                    ic_abs = curr_ic_base + ic_lane;
                    if (ic_abs < channels) begin
                        gap_rd_addr_flat[ic_lane*7 +: 7] <= ic_abs[6:0];
                    end
                end

                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                        ic_abs = curr_ic_base + ic_lane;
                        weight_slot = (class_lane * PAR_IC) + ic_lane;
                        if ((class_abs < num_classes) && (ic_abs < channels)) begin
                            weight_addr_value = FC_WEIGHT_BASE + (class_abs * MAX_CHANNELS) + ic_abs;
                            weight_addr_flat[weight_slot*16 +: 16] <= weight_addr_value;
                        end
                    end
                end
                state <= S_IC_WAIT;
            end

            S_IC_WAIT: begin
                busy <= 1'b1;
                for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                    gap_data_reg[ic_lane] <= gap_rd_data_flat[ic_lane*8 +: 8];
                end
                // Preprocess first IC group data (gap from S_IC_REQ, weight captured this cycle)
                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    if (class_abs < num_classes) begin
                        for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                            weight_slot = (class_lane * PAR_IC) + ic_lane;
                            ic_abs = curr_ic_base + ic_lane;
                            if (ic_abs < channels) begin
                                gap_preproc_r[weight_slot] <= $signed(gap_rd_data_flat[ic_lane*8 +: 8]) - $signed(input_zp_reg[class_lane]);
                                wt_preproc_r[weight_slot]   <= $signed(weight_data_flat[weight_slot*8 +: 8]) - $signed(weight_zp_reg[class_lane]);
                            end
                        end
                    end
                end
                state <= S_IC_ACC;
            end

            S_IC_ACC: begin
                busy <= 1'b1;
                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    if (class_abs < num_classes) begin
                        sum_next = acc_reg[class_lane];
                        for (ic_lane = 0; ic_lane < PAR_IC; ic_lane = ic_lane + 1) begin
                            ic_abs = curr_ic_base + ic_lane;
                            if (ic_abs < channels) begin
                                weight_slot = (class_lane * PAR_IC) + ic_lane;
                                sum_next = sum_next
                                    + $signed(gap_preproc_r[weight_slot])
                                    * $signed(wt_preproc_r[weight_slot]);
                            end
                        end
                        acc_reg[class_lane] <= sum_next;
                    end
                end

                if ((curr_ic_base + PAR_IC) < channels) begin
                    curr_ic_base <= curr_ic_base + PAR_IC;
                    state <= S_IC_REQ;
                end else begin
                    state <= S_RQ_START;
                end
            end

            S_RQ_START: begin
                busy <= 1'b1;
                for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                    class_abs = curr_class_base + class_lane;
                    if (class_abs < num_classes) begin
                        rq_in_valid[class_lane] <= 1'b1;
                    end
                end
                state <= S_RQ_WAIT;
            end

            S_RQ_WAIT: begin
                busy <= 1'b1;
                if (rq_out_valid_any) begin
                    for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                        logit_reg[class_lane] <= rq_out_data[class_lane];
                    end
                    write_lane <= 4'd0;
                    state <= S_WRITE;
                end
            end

            S_WRITE: begin
                busy <= 1'b1;
                class_abs = curr_class_base + write_lane;
                if (class_abs < num_classes) begin
                    logit_wr_en <= 1'b1;
                    logit_wr_addr <= class_abs[4:0];
                    logit_wr_data <= logit_reg[write_lane];
                end

                if ((write_lane + 1'b1) < PAR_CLASS) begin
                    write_lane <= write_lane + 1'b1;
                end else if ((curr_class_base + PAR_CLASS) < num_classes) begin
                    curr_class_base <= curr_class_base + PAR_CLASS;
                    curr_ic_base <= 8'd0;
                    write_lane <= 4'd0;
                    for (class_lane = 0; class_lane < PAR_CLASS; class_lane = class_lane + 1) begin
                        acc_reg[class_lane] <= 32'sd0;
                    end
                    state <= S_LOAD_BN;
                end else begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= S_IDLE;
                end
            end

            default: begin
                busy <= 1'b0;
                state <= S_IDLE;
            end
        endcase
    end
end

endmodule

`default_nettype wire
