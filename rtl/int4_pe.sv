// int4_pe.sv
//
// Single weight-stationary INT4 processing element for the int4_mac_accel
// 4x4 MAC array. Holds one signed INT4 weight, performs one signed
// INT4 x INT4 multiply per cycle, and accumulates the product into a
// signed INT20 partial sum.
//
// Control priority (highest to lowest):
//   rst_n > load_weight > clear_acc > en
//
// Reset is synchronous and active-low, matching the top-level spec.

`timescale 1ns/1ps
`default_nettype none

module int4_pe #(
    parameter int DATA_W = 4,
    parameter int ACC_W  = 20
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic                     en,
    input  logic                     load_weight,
    input  logic                     clear_acc,
    input  logic signed [DATA_W-1:0] weight_i,
    input  logic signed [DATA_W-1:0] act_i,
    output logic signed [ACC_W-1:0]  acc_o
);

    logic signed [DATA_W-1:0]   weight_q;
    logic signed [ACC_W-1:0]    acc_q;

    logic signed [2*DATA_W-1:0] product;
    logic signed [ACC_W-1:0]    product_ext;

    assign product     = act_i * weight_q;
    assign product_ext = ACC_W'(product);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            weight_q <= '0;
            acc_q    <= '0;
        end else if (load_weight) begin
            weight_q <= weight_i;
        end else if (clear_acc) begin
            acc_q    <= '0;
        end else if (en) begin
            acc_q    <= acc_q + product_ext;
        end
    end

    assign acc_o = acc_q;

endmodule

`default_nettype wire
