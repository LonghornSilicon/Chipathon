// rsqrt_unit.sv
//
// Reciprocal square root: given the unsigned 32-bit ``Σ y_i²``,
// produces ``inv_norm = round_floor((1 << OUT_FRAC) / sqrt(norm2))``
// in UQ<OUT_INT>.<OUT_FRAC> (default UQ2.13, 15 bits unsigned).
// Saturates to the UQ max for ``norm2 == 0`` or quotients above the
// max.
//
// Two-phase sequential implementation:
//
//   Phase A — non-restoring binary sqrt, 16 iterations for 32-bit input:
//     rem = 0; res = 0
//     for i = 15 downto 0:
//       rem  = (rem << 2) | (norm2 >> 2i) & 3
//       test = (res << 2) | 1
//       if rem >= test: rem -= test; res = (res << 1) | 1
//       else:                       res =  res << 1
//
//   Phase B — restoring binary division, 14 iterations for the 14-bit
//   numerator ``(1 << OUT_FRAC)``:
//     dr = 0; q = 0
//     for i = OUT_FRAC downto 0:
//       num_bit = (i == OUT_FRAC)         // numerator has only that bit set
//       dr = (dr << 1) | num_bit
//       if dr >= sqrt_val: dr -= sqrt_val; q = (q << 1) | 1
//       else:                              q =  q << 1
//
// Total: 16 + (OUT_FRAC + 1) = 30 cycles between ``in_valid`` and
// ``out_valid``. The Python golden in ``tb/golden/rsqrt.py`` mirrors
// this algorithm bit-for-bit so the testbench can compare exactly.

`timescale 1ns/1ps
`default_nettype none

module rsqrt_unit #(
    parameter int N2_W     = 32,
    parameter int OUT_INT  = 2,
    parameter int OUT_FRAC = 13,
    parameter int NORM_W   = 14
) (
    input  logic                                clk,
    input  logic                                rst_n,
    input  logic                                in_valid,
    input  logic [N2_W-1:0]                     norm2,
    output logic                                out_valid,
    output logic [OUT_INT+OUT_FRAC-1:0]         inv_norm,
    output logic [NORM_W-1:0]                   norm_int  // floor(sqrt(norm2)), saturated
);

    localparam int OUT_W      = OUT_INT + OUT_FRAC;            // 15
    localparam int OUT_MAX    = (1 << OUT_W) - 1;              // 32767
    localparam int SQRT_W     = (N2_W + 1) / 2;                // 16
    localparam int N_SQRT     = SQRT_W;                        // 16
    localparam int N_DIV      = OUT_FRAC + 1;                  // 14
    localparam int REM_W      = N2_W + 2;                      // sqrt running rem
    localparam int DIV_REM_W  = SQRT_W + 2;                    // division running rem

    typedef enum logic [1:0] {
        S_IDLE = 2'd0,
        S_SQRT = 2'd1,
        S_DIV  = 2'd2,
        S_OUT  = 2'd3
    } state_e;

    state_e state, next_state;

    logic [4:0]              iter;          // 0..15 for sqrt, 0..13 for div
    logic [N2_W-1:0]         n_save;
    logic [REM_W-1:0]        rem;
    logic [SQRT_W-1:0]       res;

    logic [DIV_REM_W-1:0]    div_rem;
    logic [SQRT_W-1:0]       div_den;
    logic [N_DIV-1:0]        quot;

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    always_comb begin
        next_state = state;
        case (state)
            S_IDLE: if (in_valid)               next_state = S_SQRT;
            S_SQRT: if (iter == 5'(N_SQRT - 1)) next_state = S_DIV;
            S_DIV:  if (iter == 5'(N_DIV  - 1)) next_state = S_OUT;
            S_OUT:                              next_state = S_IDLE;
            default:                            next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Sqrt step (combinational)
    // ------------------------------------------------------------------
    logic [REM_W-1:0]   rem_shift;
    logic [REM_W-1:0]   test_val;
    logic [1:0]         pair;
    logic               sqrt_take;
    logic [REM_W-1:0]   rem_next;
    logic [SQRT_W-1:0]  res_next;
    logic [4:0]         pair_pos;

    always_comb begin
        // Position to read: from MSB pair (i=15) down to LSB (i=0).
        pair_pos  = 5'(N_SQRT - 1) - iter;
        pair      = (n_save >> (pair_pos << 1)) & 2'b11;
        rem_shift = (rem << 2) | REM_W'(pair);
        test_val  = ({{(REM_W - SQRT_W - 2){1'b0}}, res, 2'b00}) | REM_W'(1);
        sqrt_take = (rem_shift >= test_val);
        rem_next  = sqrt_take ? (rem_shift - test_val) : rem_shift;
        res_next  = sqrt_take ? ((res << 1) | 1'b1)    : (res << 1);
    end

    // ------------------------------------------------------------------
    // Division step (combinational)
    // ------------------------------------------------------------------
    logic                      num_bit;
    logic [DIV_REM_W-1:0]      div_rem_shift;
    logic                      div_take;
    logic [DIV_REM_W-1:0]      div_rem_next;
    logic [N_DIV-1:0]          quot_next;

    always_comb begin
        // Numerator is (1 << OUT_FRAC); MSB-first walk over OUT_FRAC+1 bits.
        // bit at position OUT_FRAC is 1; the rest are 0. We walk position
        // OUT_FRAC down to 0, so num_bit is high only on the first iteration.
        num_bit       = (iter == 5'd0);
        div_rem_shift = (div_rem << 1) | DIV_REM_W'(num_bit);
        div_take      = (div_rem_shift >= DIV_REM_W'(div_den));
        div_rem_next  = div_take ? (div_rem_shift - DIV_REM_W'(div_den)) : div_rem_shift;
        quot_next     = div_take ? ((quot << 1) | 1'b1) : (quot << 1);
    end

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            iter      <= '0;
            n_save    <= '0;
            rem       <= '0;
            res       <= '0;
            div_rem   <= '0;
            div_den   <= '0;
            quot      <= '0;
            inv_norm  <= '0;
            norm_int  <= '0;
            out_valid <= 1'b0;
        end else begin
            state     <= next_state;
            out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (in_valid) begin
                        n_save <= norm2;
                        rem    <= '0;
                        res    <= '0;
                        iter   <= '0;
                    end
                end
                S_SQRT: begin
                    rem <= rem_next;
                    res <= res_next;
                    if (next_state == S_DIV) begin
                        // Latch sqrt result; reset div counters.
                        div_den <= res_next;
                        div_rem <= '0;
                        quot    <= '0;
                        iter    <= '0;
                    end else begin
                        iter <= iter + 1'b1;
                    end
                end
                S_DIV: begin
                    div_rem <= div_rem_next;
                    quot    <= quot_next;
                    iter    <= iter + 1'b1;
                end
                S_OUT: begin
                    // div_den (= sqrt(norm2)) saturates to OUT_MAX only when
                    // norm2 == 0; otherwise quot is at most N_DIV=14 bits wide
                    // (max 16383) which always fits in OUT_W=15 bits unsigned,
                    // so just zero-extend.
                    inv_norm  <= (div_den == 0) ? OUT_W'(OUT_MAX) : OUT_W'(quot);
                    norm_int  <= (div_den >= NORM_W'(({NORM_W{1'b1}}))) ? {NORM_W{1'b1}}
                                : NORM_W'(div_den);
                    out_valid <= 1'b1;
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
