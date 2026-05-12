`timescale 1ns / 1ps
`default_nettype none

module requant_relu (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               in_valid,
    input  wire signed [31:0] acc_in,
    input  wire signed [15:0] scale_q8_8,
    input  wire signed [31:0] bias,
    input  wire signed [7:0]  output_zero_point,
    input  wire               relu_en,
    output reg                out_valid,
    output reg  signed [7:0]  out_data
);

parameter PIPE_STAGES = 4;

reg signed [47:0] s1_mult;
reg signed [47:0] s2_shift;
reg signed [47:0] s3_add_bias;
reg signed [47:0] s4_add_zp;
reg               s4_relu_en;

reg [PIPE_STAGES-1:0] vld_pipe;

function signed [7:0] sat_int8;
    input signed [47:0] x;
    begin
        if (x > 48'sd127) begin
            sat_int8 = 8'sd127;
        end else if (x < -48'sd128) begin
            sat_int8 = -8'sd128;
        end else begin
            sat_int8 = x[7:0];
        end
    end
endfunction

wire signed [7:0] sat_data_w;
wire signed [7:0] relu_data_w;

assign sat_data_w = sat_int8(s4_add_zp);
assign relu_data_w = (s4_relu_en && (sat_data_w < 0)) ? 8'sd0 : sat_data_w;

always @(posedge clk) begin
    if (!rst_n) begin
        s1_mult   <= 48'sd0;
        s2_shift  <= 48'sd0;
        s3_add_bias <= 48'sd0;
        s4_add_zp <= 48'sd0;
        s4_relu_en <= 1'b0;
        vld_pipe <= {PIPE_STAGES{1'b0}};
        out_valid <= 1'b0;
        out_data <= 8'sd0;
    end else begin
        s1_mult <= acc_in * scale_q8_8;
        s2_shift <= s1_mult >>> 8;
        s3_add_bias <= s2_shift + bias;
        s4_add_zp <= s3_add_bias + output_zero_point;
        s4_relu_en <= relu_en;

        vld_pipe[0] <= in_valid;
        vld_pipe[PIPE_STAGES-1:1] <= vld_pipe[PIPE_STAGES-2:0];

        out_valid <= vld_pipe[PIPE_STAGES-1];
        out_data <= relu_data_w;
    end
end

endmodule

`default_nettype wire
