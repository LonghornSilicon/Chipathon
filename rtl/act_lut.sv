// act_lut.sv
//
// 16-entry piecewise lookup table for activation / softmax helpers in
// the int4_mac_accel post-requant path. Consumes signed INT8 from
// requant_sat.data_o and produces INT8.
//
// Indexing: top $clog2(N_ENTRIES) bits of data_i select the entry.
// For IN_W=8, N_ENTRIES=16 this is data_i[7:4] interpreted as a
// signed nibble: -8..+7 maps to entries 0..15 in two's-complement
// order, i.e. {data_i[7], data_i[6:4]} after the top-bit invert that
// converts signed to unsigned bin index. We therefore add 8 to the
// signed nibble to get an unsigned 0..15 index.
//
// Bypass: enable_i=0 routes data_i straight to data_o (still
// registered, so latency is identical between LUT and bypass paths;
// downstream timing doesn't change at runtime).
//
// FUNC selects the synth-time table contents (integer-encoded so the
// parameter is portable to Yosys's Verilog-2005 frontend, which does
// not accept `parameter string`). Use the FUNC_* localparams below or
// pass the raw integer:
//   0 FUNC_EXP_NEG  : LUT[k] approx round( 127 * exp(-(k-8)/2) ) clipped INT8.
//   1 FUNC_IDENTITY : LUT[k] = (k - 8) << 4   (pass-through, scaled to INT8 range)
//   2 FUNC_GELU     : reserved, falls back to identity until specialised
//   3 FUNC_SILU     : reserved, falls back to identity until specialised
//
// Pipeline: combinational LUT lookup (or bypass), one register stage
// at the output. Handshake matches requant_sat (ready/valid passthrough).

`timescale 1ns/1ps
`default_nettype none

module act_lut #(
    parameter int IN_W      = 8,
    parameter int OUT_W     = 8,
    parameter int N_ENTRIES = 16,
    parameter int FUNC      = 0,
    parameter int IDX_W     = $clog2(N_ENTRIES)
) (
    input  logic                       clk,
    input  logic                       rst_n,
    input  logic                       enable_i,

    input  logic                       valid_i,
    output logic                       ready_o,
    input  logic signed [IN_W-1:0]     data_i,

    output logic                       valid_o,
    input  logic                       ready_i,
    output logic signed [OUT_W-1:0]    data_o
);

    // FUNC encoding (mirrors header doc). Kept as localparams so users
    // can write `.FUNC(act_lut::FUNC_EXP_NEG)` once a package is added,
    // or just pass the integer literal today. The non-selected entries
    // look unused to Verilator after constant-folding; suppress the
    // UNUSEDPARAM noise rather than #ifdef'ing them out.
    /* verilator lint_off UNUSEDPARAM */
    localparam int FUNC_EXP_NEG  = 0;
    localparam int FUNC_IDENTITY = 1;
    localparam int FUNC_GELU     = 2;
    localparam int FUNC_SILU     = 3;
    /* verilator lint_on UNUSEDPARAM */

    // Build the LUT contents at elaboration. The values are integer
    // constants only (no `real`, no `$exp`) so Yosys's Verilog-2005
    // frontend can constant-fold the table the same way the simulator
    // does. The EXP_NEG table is the round-to-nearest of
    //   y_k = 127 * exp(-(k - N_ENTRIES/2) / 2)
    // saturated to INT8 [-128, 127]. tb_act_lut.sv recomputes that
    // same table from real arithmetic at sim time using OUT_W'(int'(y)),
    // which per SV LRM rounds real-to-int to nearest; the two agree.
    function automatic logic signed [OUT_W-1:0] lut_value (input int k);
        int signed_bin;
        signed_bin = k - (N_ENTRIES/2);
        if (FUNC == FUNC_EXP_NEG) begin
            // Hard-coded for N_ENTRIES=16, OUT_W=8 (the only legal
            // EXP_NEG configuration; enforced by the assertion below).
            case (k)
                 0: lut_value = 8'sd127; // bin=-8 (saturated)
                 1: lut_value = 8'sd127; // bin=-7 (saturated)
                 2: lut_value = 8'sd127; // bin=-6 (saturated)
                 3: lut_value = 8'sd127; // bin=-5 (saturated)
                 4: lut_value = 8'sd127; // bin=-4 (saturated)
                 5: lut_value = 8'sd127; // bin=-3 (saturated)
                 6: lut_value = 8'sd127; // bin=-2 (saturated)
                 7: lut_value = 8'sd127; // bin=-1 (saturated)
                 8: lut_value = 8'sd127; // bin= 0  (127*1.0000)
                 9: lut_value = 8'sd77;  // bin=+1  (127*0.6065)
                10: lut_value = 8'sd47;  // bin=+2  (127*0.3679)
                11: lut_value = 8'sd28;  // bin=+3  (127*0.2231)
                12: lut_value = 8'sd17;  // bin=+4  (127*0.1353)
                13: lut_value = 8'sd10;  // bin=+5  (127*0.0821)
                14: lut_value = 8'sd6;   // bin=+6  (127*0.0498)
                15: lut_value = 8'sd4;   // bin=+7  (127*0.0302)
                default: lut_value = '0;
            endcase
        end else begin
            // identity / gelu / silu fallback: scaled bin so that
            // bypass and LUT agree at the bin centroid.
            lut_value = OUT_W'(signed_bin <<< 4);
        end
    endfunction

    // Elaboration-time guard for the hard-coded EXP_NEG table.
    // pragma translate_off
    initial begin
        if (FUNC == FUNC_EXP_NEG && (N_ENTRIES != 16 || OUT_W != 8)) begin
            $fatal(1, "act_lut: FUNC_EXP_NEG requires N_ENTRIES=16, OUT_W=8 (got %0d, %0d)",
                   N_ENTRIES, OUT_W);
        end
    end
    // pragma translate_on

    logic signed [OUT_W-1:0] lut [N_ENTRIES];
    initial begin
        for (int k = 0; k < N_ENTRIES; k++) begin
            lut[k] = lut_value(k);
        end
    end

    logic [IDX_W-1:0]        idx;
    logic signed [OUT_W-1:0] lut_q;
    logic signed [OUT_W-1:0] mux_d;

    // Convert signed top-IDX_W bits to unsigned 0..N-1 index by
    // inverting the sign bit (two's complement -> offset binary).
    assign idx = {~data_i[IN_W-1], data_i[IN_W-2 -: IDX_W-1]};

    always_comb begin
        lut_q = lut[idx];
        mux_d = enable_i ? lut_q : OUT_W'(data_i);
    end

    assign ready_o = ready_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_o <= 1'b0;
            data_o  <= '0;
        end else begin
            if (valid_i && ready_o) begin
                valid_o <= 1'b1;
                data_o  <= mux_d;
            end else if (valid_o && ready_i) begin
                valid_o <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
