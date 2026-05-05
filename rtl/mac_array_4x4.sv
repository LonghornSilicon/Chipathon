// mac_array_4x4.sv
//
// 4x4 weight-stationary INT4 MAC array for the int4_mac_accel block.
// Instantiates ROWS*COLS int4_pe cells, broadcasts a per-row INT4
// activation across each row, and parallel-loads a 2D INT4 weight
// matrix into the cells. Each column's PE accumulators are summed by
// a combinational adder tree and registered into col_q, giving the
// array its second pipeline stage.
//
// Ports use packed buses (weight_flat_i, act_flat_i, col_flat_o) so
// the module synthesizes through Yosys's default Verilog frontend
// without needing the SystemVerilog plugin. They are unpacked into
// 2D / 1D arrays internally so the PE generate loop and adder tree
// keep their natural row,col indexing. Bus packing convention:
//   weight_flat_i[(r*COLS + c)*DATA_W +: DATA_W] = weight[r][c]
//   act_flat_i   [r*DATA_W            +: DATA_W] = act[r]
//   col_flat_o   [c*OUT_W             +: OUT_W ] = col[c]
//
// Pipeline:
//   stage 1 (inside int4_pe): combinational mul, registered into acc_q
//   stage 2 (this block):     combinational column reduction,
//                             registered into col_q
//
// Output width: OUT_W = ACC_W + $clog2(ROWS). With ROWS=4 and
// ACC_W=20 this is 22 bits, leaving headroom for the column sum
// without saturation. Saturation happens later in requant_sat.

`timescale 1ns/1ps
`default_nettype none

module mac_array_4x4 #(
    parameter int ROWS   = 4,
    parameter int COLS   = 4,
    parameter int DATA_W = 4,
    parameter int ACC_W  = 20,
    parameter int OUT_W  = ACC_W + $clog2(ROWS)
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                en,
    input  logic                                load_weight,
    input  logic                                clear_acc,
    input  logic signed [ROWS*COLS*DATA_W-1:0]  weight_flat_i,
    input  logic signed [ROWS*DATA_W-1:0]       act_flat_i,
    output logic signed [COLS*OUT_W-1:0]        col_flat_o
);

    // Internal unpacked views of the flat ports so the PE generate
    // loop and adder tree stay readable.
    logic signed [DATA_W-1:0] weight_i  [ROWS][COLS];
    logic signed [DATA_W-1:0] act_i     [ROWS];
    logic signed [OUT_W-1:0]  col_o     [COLS];

    logic signed [ACC_W-1:0]  pe_acc    [ROWS][COLS];
    logic signed [OUT_W-1:0]  col_sum_d [COLS];
    logic signed [OUT_W-1:0]  col_q     [COLS];

    genvar gru, gcu, gcp;
    generate
        for (gru = 0; gru < ROWS; gru++) begin : g_act_unpack
            assign act_i[gru] = act_flat_i[gru*DATA_W +: DATA_W];
        end
        for (gru = 0; gru < ROWS; gru++) begin : g_w_unpack_row
            for (gcu = 0; gcu < COLS; gcu++) begin : g_w_unpack_col
                assign weight_i[gru][gcu] =
                    weight_flat_i[(gru*COLS + gcu)*DATA_W +: DATA_W];
            end
        end
        for (gcp = 0; gcp < COLS; gcp++) begin : g_col_pack
            assign col_flat_o[gcp*OUT_W +: OUT_W] = col_o[gcp];
        end
    endgenerate

    genvar gr, gc;
    generate
        for (gr = 0; gr < ROWS; gr++) begin : gen_row
            for (gc = 0; gc < COLS; gc++) begin : gen_col
                int4_pe #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W)
                ) u_pe (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .en          (en),
                    .load_weight (load_weight),
                    .clear_acc   (clear_acc),
                    .weight_i    (weight_i[gr][gc]),
                    .act_i       (act_i[gr]),
                    .acc_o       (pe_acc[gr][gc])
                );
            end
        end
    endgenerate

    always_comb begin
        for (int cc = 0; cc < COLS; cc++) begin
            col_sum_d[cc] = '0;
            for (int rr = 0; rr < ROWS; rr++) begin
                col_sum_d[cc] = col_sum_d[cc] + OUT_W'(pe_acc[rr][cc]);
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int cc = 0; cc < COLS; cc++) begin
                col_q[cc] <= '0;
            end
        end else begin
            for (int cc = 0; cc < COLS; cc++) begin
                col_q[cc] <= col_sum_d[cc];
            end
        end
    end

    genvar go;
    generate
        for (go = 0; go < COLS; go++) begin : gen_col_out
            assign col_o[go] = col_q[go];
        end
    endgenerate

endmodule

`default_nettype wire
