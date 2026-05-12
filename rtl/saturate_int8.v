`timescale 1ns / 1ps
`default_nettype none

module saturate_int8 (
    input  wire signed [31:0] in_data,
    output reg  signed [7:0]  out_data
);

always @(*) begin
    if (in_data > 32'sd127) begin
        out_data = 8'sd127;
    end else if (in_data < -32'sd128) begin
        out_data = -8'sd128;
    end else begin
        out_data = in_data[7:0];
    end
end

endmodule

`default_nettype wire
