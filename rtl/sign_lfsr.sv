// sign_lfsr.sv
//
// 16-bit Galois LFSR. Generates a deterministic Rademacher (±1) sign
// sequence used to randomize the input vector before the WHT, giving
// `H @ Diag(s)` the SRHT property TurboQuant relies on.
//
// Polynomial: x^16 + x^14 + x^13 + x^11 + 1  (Galois mask 0xB400, period 65535).
// Default seed: 0xACE1 (any nonzero 16-bit value works).
//
// Bit-exact match to ``tb/golden/lfsr.py``: on each cycle while running,
// the output ``sign_bit`` is the LSB of the current state; on the next
// posedge, the state shifts right by one and conditionally XORs the
// mask. The first emitted bit is therefore ``SEED & 1``.
//
// Output mapping is left to the consumer: typically
//     y_byte = sign_bit ? +x_byte : -x_byte
// in two's complement.
//
// Interface:
//   start (1 cycle pulse) -> begin streaming D bits, one per cycle, with
//                            ``valid`` high. ``last`` pulses with the
//                            D-th valid bit.
//   The first ``valid``/``sign_bit`` appears the cycle AFTER ``start``.

`timescale 1ns/1ps
`default_nettype none

module sign_lfsr #(
    parameter int          D    = 64,
    parameter logic [15:0] SEED = 16'hACE1,
    parameter logic [15:0] MASK = 16'hB400
) (
    input  logic clk,
    input  logic rst_n,
    input  logic start,        // pulse to (re)seed and begin streaming
    output logic valid,        // high while sign_bit is meaningful
    output logic sign_bit,     // LSB of state; map to ±1 outside
    output logic last          // pulses with the D-th valid bit
);

    localparam int CW = $clog2(D + 1);

    logic [15:0]    state;
    logic [CW-1:0]  count;
    logic           running;

    assign sign_bit = state[0];
    assign valid    = running;
    assign last     = running && (count == CW'(D - 1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= SEED;
            count   <= '0;
            running <= 1'b0;
        end else if (start) begin
            state   <= SEED;
            count   <= '0;
            running <= 1'b1;
        end else if (running) begin
            state <= state[0] ? ((state >> 1) ^ MASK) : (state >> 1);
            if (count == CW'(D - 1)) begin
                running <= 1'b0;
                count   <= '0;
            end else begin
                count <= count + 1'b1;
            end
        end
    end

`ifdef ASSERT_ON
    // start should be a single-cycle pulse; ignore re-pulses while running.
    initial assert (D >= 1);
    initial assert (SEED != 16'h0000);
`endif

endmodule

`default_nettype wire
