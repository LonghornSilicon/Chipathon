// requant_sat.sv
//
// Stateless shift-and-saturate requantization for the int4_mac_accel
// post-accumulator path. Consumes signed INT20 values from
// accum_bank.rd_data and produces a signed INT4 (sign-extended into
// the low 8 bits) or INT8, depending on mode_i.
//
// Math (in order):
//   1) bias = round_i ? (1 <<< (shift_i-1)) : 0
//        Round-half-up bias when shift_i > 0; zero otherwise.
//   2) shifted = (data_i + bias) >>> shift_i        // arith right shift
//   3) lim_hi  = mode_i ? +127 : +7
//      lim_lo  = mode_i ? -128 : -8
//   4) data_o  = clamp(shifted, lim_lo, lim_hi)
//   5) overflow_o is sticky: any clamp event sets it; cleared only by
//      synchronous active-low reset.
//
// Pipeline: math is combinational into wr_next; outputs are registered
// so downstream sees a single clean cycle of latency.
//
// Handshake: ready/valid pass-through. ready_o = ready_i (no skid
// buffer; this block never blocks the upstream when downstream is
// ready, because the math is one cycle).

`timescale 1ns/1ps
`default_nettype none

module requant_sat #(
    parameter int ACC_W   = 20,
    parameter int OUT_W   = 8,
    parameter int SHIFT_W = $clog2(ACC_W) + 1
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          valid_i,
    output logic                          ready_o,
    input  logic signed [ACC_W-1:0]       data_i,
    input  logic [SHIFT_W-1:0]            shift_i,
    input  logic                          mode_i,
    input  logic                          round_i,

    output logic                          valid_o,
    input  logic                          ready_i,
    output logic signed [OUT_W-1:0]       data_o,
    output logic                          overflow_o
);

    // Saturation bounds widened to OUT_W+1 bits so the post-shift
    // signed compare never warns about width mismatch. Width-matched
    // literals to keep verilator quiet.
    localparam logic signed [OUT_W:0] LIM_HI_INT4 = 9'sd7;
    localparam logic signed [OUT_W:0] LIM_LO_INT4 = -9'sd8;
    localparam logic signed [OUT_W:0] LIM_HI_INT8 = 9'sd127;
    localparam logic signed [OUT_W:0] LIM_LO_INT8 = -9'sd128;

    // Worst-case bias is 1 << (ACC_W-1), so the rounded-input width
    // grows by one bit beyond ACC_W. Keep that one bit of headroom
    // through the shift and into the saturation comparator.
    localparam int EXT_W = ACC_W + 1;

    logic signed [EXT_W-1:0] bias;
    logic signed [EXT_W-1:0] rounded;
    logic signed [EXT_W-1:0] shifted;
    logic signed [EXT_W-1:0] lim_hi_ext;
    logic signed [EXT_W-1:0] lim_lo_ext;
    logic signed [OUT_W-1:0] sat_d;
    logic                    ovfl_d;

    always_comb begin
        if (round_i && (shift_i != 0)) begin
            bias = (signed'(EXT_W'(1))) <<< (shift_i - 1);
        end else begin
            bias = '0;
        end

        rounded = EXT_W'(data_i) + bias;
        shifted = rounded >>> shift_i;

        lim_hi_ext = mode_i ? EXT_W'(LIM_HI_INT8) : EXT_W'(LIM_HI_INT4);
        lim_lo_ext = mode_i ? EXT_W'(LIM_LO_INT8) : EXT_W'(LIM_LO_INT4);

        if (shifted > lim_hi_ext) begin
            sat_d  = lim_hi_ext[OUT_W-1:0];
            ovfl_d = 1'b1;
        end else if (shifted < lim_lo_ext) begin
            sat_d  = lim_lo_ext[OUT_W-1:0];
            ovfl_d = 1'b1;
        end else begin
            sat_d  = shifted[OUT_W-1:0];
            ovfl_d = 1'b0;
        end
    end

    // Single-cycle register stage. Handshake: when downstream is not
    // ready we hold valid_o and data_o. Upstream is throttled in lock-
    // step (ready_o = ready_i) so we never need a skid buffer.
    assign ready_o = ready_i;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_o    <= 1'b0;
            data_o     <= '0;
            overflow_o <= 1'b0;
        end else begin
            if (valid_i && ready_o) begin
                valid_o    <= 1'b1;
                data_o     <= sat_d;
                overflow_o <= overflow_o | ovfl_d;
            end else if (valid_o && ready_i) begin
                valid_o    <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
