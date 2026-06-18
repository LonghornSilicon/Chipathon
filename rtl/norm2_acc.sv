// norm2_acc.sv
//
// Streaming Σ y_i² accumulator. One signed Y_W-wide sample arrives per
// cycle when ``in_valid``; after D samples have been seen, ``done``
// pulses and ``norm2_q`` holds the final unsigned sum.
//
// Width budget. Per-sample square: max y_i² = (2^(Y_W-1))². Sum of D
// such squares fits in 2*Y_W + log2(D) bits worst case.  For Y_W=14,
// D=64 that is 28 + 6 = 34 bits; we use N2_W=32 since by Parseval
// ``Σ y² = d · ||x||²`` with int8 input is bounded by d^2 · 128² =
// 64·64·16384 ≈ 67M, well below 2^27. The 32-bit accumulator carries
// a comfortable margin.

`timescale 1ns/1ps
`default_nettype none

module norm2_acc #(
    parameter int D    = 64,
    parameter int Y_W  = 14,
    parameter int N2_W = 32
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  clear,        // sync clear at vector start
    input  logic                  in_valid,
    input  logic signed [Y_W-1:0] y_in,
    output logic                  done,         // pulses when D-th sample is consumed
    output logic [N2_W-1:0]       norm2_q       // valid from the cycle after done=1
);

    localparam int CW = $clog2(D + 1);

    logic [CW-1:0]      count;
    logic [N2_W-1:0]    acc;
    logic [2*Y_W-1:0]   sq;
    logic signed [2*Y_W-1:0] y_ext;

    always_comb begin
        // Sign-extend y_in from Y_W to 2*Y_W before squaring; otherwise
        // the implicit width of y_in*y_in is max(operand widths) = Y_W,
        // truncating the upper bits of the product.
        y_ext = y_in;
        sq    = $unsigned(y_ext * y_ext);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc      <= '0;
            count    <= '0;
            done     <= 1'b0;
            norm2_q  <= '0;
        end else begin
            done <= 1'b0;
            if (clear) begin
                acc   <= '0;
                count <= '0;
            end else if (in_valid) begin
                if (count == CW'(D - 1)) begin
                    norm2_q <= acc + N2_W'(sq);
                    done    <= 1'b1;
                    acc     <= '0;
                    count   <= '0;
                end else begin
                    acc   <= acc + N2_W'(sq);
                    count <= count + 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
