// quant_unit.sv
//
// One-cycle-per-coordinate quantizer for TurboQuant Algorithm 1.
//
// Per coordinate (running for D cycles):
//
//   1. mul     u_raw = y_i * inv_norm                      // signed * unsigned
//                = (Y_W + INV_W)-bit signed
//   2. shift   u_q   = round_half_up(u_raw, RSQRT_FRAC - U_FRAC)
//                = saturated to (U_FRAC + 2)-bit signed Q1.U_FRAC
//   3. shift   u_cmp = round_half_up(u_q, U_FRAC - CB_FRAC)
//                = signed Q1.CB_FRAC for compare against bounds
//   4. compare u_cmp against the 7 codebook bounds in parallel,
//      popcount of "u_cmp > bound[k]" gives the 3-bit idx ∈ [0, 7]
//
// The shifts are constant (RSQRT_FRAC and CB_FRAC are parameters, U_FRAC
// is wired by the integration), so they synthesize to plain wire fan-in.
// The 7 comparators are independent and resolve in parallel; the popcount
// is a small fan-in adder. Result latency: 1 cycle from valid-in to
// valid-out (registered).
//
// The N_BOUNDS bounds are passed in flat as ``bounds_in`` (one cycle
// constant) — the integration-level wires this from ``codebook_rom``.

`timescale 1ns/1ps
`default_nettype none

module quant_unit #(
    parameter int Y_W        = 14,
    parameter int INV_W      = 15,    // UQ2.13
    parameter int RSQRT_FRAC = 13,
    parameter int U_FRAC     = 9,
    parameter int CB_FRAC    = 9,
    parameter int N_BOUNDS   = 7,
    parameter int CB_W       = CB_FRAC + 2,    // Q1.CB_FRAC bounds width
    parameter int IDX_W      = $clog2(N_BOUNDS + 1)
) (
    input  logic                          clk,
    input  logic                          rst_n,
    input  logic                          in_valid,
    input  logic signed [Y_W-1:0]         y_i,
    input  logic        [INV_W-1:0]       inv_norm,
    input  logic signed [CB_W-1:0]        bounds_in [N_BOUNDS],
    output logic                          out_valid,
    output logic        [IDX_W-1:0]       idx_out
);

    localparam int U_RAW_W = Y_W + INV_W;            // signed product width
    localparam int U_Q_W   = U_FRAC + 2;             // Q1.U_FRAC, signed
    localparam int SH_RU   = RSQRT_FRAC - U_FRAC;    // 4 with defaults
    localparam int SH_UC   = U_FRAC - CB_FRAC;       // 0 with defaults

    // Stage A (combinational): multiply, shift, narrow, saturate to U_Q_W.
    logic signed [U_RAW_W-1:0]  u_raw;
    logic signed [U_RAW_W-1:0]  u_round;
    logic signed [U_Q_W-1:0]    u_q;
    logic signed [U_RAW_W:0]    half_ru;

    always_comb begin
        u_raw   = $signed(y_i) * $signed({1'b0, inv_norm});  // inv_norm zero-extended
        if (SH_RU > 0) begin
            half_ru = (U_RAW_W+1)'(1) << (SH_RU - 1);
            u_round = (u_raw + U_RAW_W'(half_ru)) >>> SH_RU;
        end else if (SH_RU < 0) begin
            u_round = u_raw <<< (-SH_RU);
        end else begin
            u_round = u_raw;
        end
        // Saturate to Q1.U_FRAC.
        if (u_round > $signed({1'b0, {(U_Q_W-1){1'b1}}}))
            u_q = $signed({1'b0, {(U_Q_W-1){1'b1}}});
        else if (u_round < $signed({1'b1, {(U_Q_W-1){1'b0}}}))
            u_q = $signed({1'b1, {(U_Q_W-1){1'b0}}});
        else
            u_q = U_Q_W'(u_round);
    end

    // Stage B (combinational): bring u_q to CB_FRAC if needed, then compare.
    logic signed [CB_W-1:0]  u_cmp;
    always_comb begin
        if (SH_UC > 0)
            u_cmp = CB_W'((u_q + ((U_Q_W)'(1) <<< (SH_UC - 1))) >>> SH_UC);
        else if (SH_UC < 0)
            u_cmp = CB_W'(u_q <<< (-SH_UC));
        else
            u_cmp = CB_W'(u_q);
    end

    logic [N_BOUNDS-1:0] gt_mask;
    always_comb begin
        // Match np.searchsorted(bounds, u_cmp, side='right'), i.e.
        // idx = sum(bound[k] <= u_cmp). Equivalent to (u_cmp >= bound).
        // Strict > would give side='left', which mismatches the Python
        // golden on exact boundary values.
        for (int k = 0; k < N_BOUNDS; k++)
            gt_mask[k] = (u_cmp >= bounds_in[k]);
    end

    // Popcount of gt_mask gives idx ∈ [0, N_BOUNDS]. Equivalent to
    // np.searchsorted(bounds, u_cmp, side='right').
    logic [IDX_W-1:0] idx_comb;
    always_comb begin
        idx_comb = '0;
        for (int k = 0; k < N_BOUNDS; k++)
            idx_comb = idx_comb + IDX_W'(gt_mask[k]);
    end

    // Pipeline register at the output (1 cycle latency).
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx_out   <= '0;
            out_valid <= 1'b0;
        end else begin
            out_valid <= in_valid;
            idx_out   <= idx_comb;
        end
    end

endmodule

`default_nettype wire
