`timescale 1ns / 1ps
`default_nettype none

module reset_sync (
    input  wire clk,
    input  wire rst_n_async,
    output wire rst_n
);

(* ASYNC_REG = "TRUE" *) reg rst_ff1;
(* ASYNC_REG = "TRUE" *) reg rst_ff2;

always @(posedge clk or negedge rst_n_async) begin
    if (!rst_n_async) begin
        rst_ff1 <= 1'b0;
        rst_ff2 <= 1'b0;
    end else begin
        rst_ff1 <= 1'b1;
        rst_ff2 <= rst_ff1;
    end
end

assign rst_n = rst_ff2;

endmodule

`default_nettype wire
