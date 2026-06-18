// tq_top.sv
//
// TurboQuant Algorithm 1 encoder — top level. Tiny Tapeout pinout per
// PLAN.md §7. Wires sign_lfsr / wht64 / norm2_acc / rsqrt_unit /
// quant_unit / bit_packer / codebook_rom together via tq_ctrl.
//
//   ui_in[7:0]     host -> chip data byte (input vector x and host frame)
//   uo_out[7:0]    chip -> host data byte (output frame: norm + idx)
//   uio_in[2]      host_tx_valid
//   uio_in[3]      host_rx_ready
//   uio_out[0]     chip_rx_ready
//   uio_out[1]     chip_tx_valid
//   uio_out[2]     err_sticky
//   uio_out[3]     busy
//   uio_out[7:4]   FSM state (debug)
//   uio_oe[7:0]    static 8'b1111_0011  (bits 0,1,4,5,6,7 driven by chip)
//   ena            global enable; gates host_tx_valid in ctrl_io
//
// Reset is synchronous active-low. A single core clock.

`timescale 1ns/1ps
`default_nettype none

module tq_top #(
    parameter int    D              = 64,
    parameter int    X_W            = 8,
    parameter int    Y_W            = 14,
    parameter int    N2_W           = 32,
    parameter int    NORM_W         = 14,
    parameter int    INV_W          = 15,    // UQ2.13
    parameter int    RSQRT_INT      = 2,
    parameter int    RSQRT_FRAC     = 13,
    parameter int    U_FRAC         = 9,
    parameter int    CB_FRAC        = 9,
    parameter int    N_BOUNDS       = 7,
    parameter int    N_CENTROIDS    = 8,
    parameter int    CB_W           = CB_FRAC + 2,
    parameter int    IDX_W          = 3,
    parameter logic [15:0] LFSR_SEED = 16'hACE1,
    parameter logic [15:0] LFSR_MASK = 16'hB400,
    parameter        BOUNDS_FILE    = "codebook_bounds.mem",
    parameter        CENTROIDS_FILE = "codebook_centroids.mem"
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         ena,

    input  logic [7:0]   ui_in,
    output logic [7:0]   uo_out,
    input  logic [7:0]   uio_in,
    output logic [7:0]   uio_out,
    output logic [7:0]   uio_oe
);

    // Static drive-enable: chip drives bits {0,1,4,5,6,7}, listens on {2,3}.
    assign uio_oe = 8'b1111_0011;

    // ------------------------------------------------------------------
    // Internal signals
    // ------------------------------------------------------------------
    logic                            host_tx_valid;
    logic                            host_rx_ready;
    logic                            chip_rx_ready;
    logic                            chip_tx_valid;
    logic                            busy;
    logic                            err_sticky;
    logic [3:0]                      state_dbg;

    logic                            lfsr_start;
    logic                            lfsr_valid;
    logic                            lfsr_sign_bit;

    logic                            wht_start;
    logic                            wht_replay_start;
    logic                            wht_busy;
    logic                            wht_ready;
    logic                            wht_in_valid;
    logic                            wht_in_ready;
    logic signed [X_W-1:0]           wht_x_in;
    logic                            wht_x_sign;
    logic                            wht_out_valid;
    logic signed [Y_W-1:0]           wht_y_out;
    logic                            wht_out_last;

    logic                            n2_clear;
    logic                            n2_in_valid;
    logic signed [Y_W-1:0]           n2_y_in;
    logic                            n2_done;
    logic [N2_W-1:0]                 n2_norm2;

    logic                            rs_in_valid;
    logic [N2_W-1:0]                 rs_norm2;
    logic                            rs_out_valid;
    logic [INV_W-1:0]                rs_inv_norm;
    logic [NORM_W-1:0]               rs_norm_int;

    logic                            q_in_valid;
    logic signed [Y_W-1:0]           q_y_i;
    logic [INV_W-1:0]                q_inv_norm;
    logic                            q_out_valid;
    logic [IDX_W-1:0]                q_idx_out;

    logic                            bp_clear;
    logic                            bp_idx_valid;
    logic [IDX_W-1:0]                bp_idx;
    logic                            bp_byte_valid;
    logic [7:0]                      bp_out_byte;
    logic                            bp_last_byte;

    logic signed [CB_W-1:0]          bounds_all    [N_BOUNDS];
    logic signed [CB_W-1:0]          centroids_all [N_CENTROIDS];

    // Host handshake decoded from / encoded onto uio.
    assign host_tx_valid = uio_in[2] & ena;
    assign host_rx_ready = uio_in[3];
    assign uio_out[0]    = chip_rx_ready;
    assign uio_out[1]    = chip_tx_valid;
    assign uio_out[2]    = err_sticky;
    assign uio_out[3]    = busy;
    assign uio_out[7:4]  = state_dbg;

    // ------------------------------------------------------------------
    // Submodules
    // ------------------------------------------------------------------
    sign_lfsr #(.D(D), .SEED(LFSR_SEED), .MASK(LFSR_MASK)) u_lfsr (
        .clk(clk), .rst_n(rst_n),
        .start(lfsr_start),
        .valid(lfsr_valid),
        .sign_bit(lfsr_sign_bit),
        .last()
    );

    wht64 #(.D(D), .X_W(X_W), .Y_W(Y_W)) u_wht (
        .clk(clk), .rst_n(rst_n),
        .start(wht_start), .replay_start(wht_replay_start),
        .busy(wht_busy), .ready(wht_ready),
        .in_ready(wht_in_ready), .in_valid(wht_in_valid),
        .x_in(wht_x_in), .x_sign(wht_x_sign),
        .out_valid(wht_out_valid), .y_out(wht_y_out), .out_last(wht_out_last)
    );

    norm2_acc #(.D(D), .Y_W(Y_W), .N2_W(N2_W)) u_n2 (
        .clk(clk), .rst_n(rst_n),
        .clear(n2_clear), .in_valid(n2_in_valid), .y_in(n2_y_in),
        .done(n2_done), .norm2_q(n2_norm2)
    );

    rsqrt_unit #(
        .N2_W(N2_W), .OUT_INT(RSQRT_INT), .OUT_FRAC(RSQRT_FRAC), .NORM_W(NORM_W)
    ) u_rsqrt (
        .clk(clk), .rst_n(rst_n),
        .in_valid(rs_in_valid), .norm2(rs_norm2),
        .out_valid(rs_out_valid), .inv_norm(rs_inv_norm), .norm_int(rs_norm_int)
    );

    codebook_rom #(
        .N_BOUNDS(N_BOUNDS), .N_CENTROIDS(N_CENTROIDS), .W(CB_W),
        .BOUNDS_FILE(BOUNDS_FILE), .CENTROIDS_FILE(CENTROIDS_FILE)
    ) u_cb (
        .bounds_all(bounds_all),
        .centroids_all(centroids_all)
    );

    quant_unit #(
        .Y_W(Y_W), .INV_W(INV_W),
        .RSQRT_FRAC(RSQRT_FRAC), .U_FRAC(U_FRAC), .CB_FRAC(CB_FRAC),
        .N_BOUNDS(N_BOUNDS), .CB_W(CB_W)
    ) u_q (
        .clk(clk), .rst_n(rst_n),
        .in_valid(1'b0), .y_i('0), .inv_norm(q_inv_norm),
        .bounds_in(bounds_all),
        .out_valid(q_out_valid), .idx_out(q_idx_out)
    );
    // TEMP: tie quant inputs off to bisect a t=0 hang

    bit_packer #(.IDX_BITS(IDX_W), .N_INDICES(D)) u_bp (
        .clk(clk), .rst_n(rst_n),
        .clear(bp_clear), .idx_valid(bp_idx_valid), .idx(bp_idx),
        .byte_valid(bp_byte_valid), .out_byte(bp_out_byte), .last_byte(bp_last_byte)
    );

    tq_ctrl #(
        .D(D), .X_W(X_W), .Y_W(Y_W), .N2_W(N2_W),
        .NORM_W(NORM_W), .INV_W(INV_W), .IDX_W(IDX_W),
        .N_BOUNDS(N_BOUNDS), .CB_W(CB_W)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .ui_in(ui_in), .uo_out(uo_out),
        .host_tx_valid(host_tx_valid), .host_rx_ready(host_rx_ready),
        .chip_rx_ready(chip_rx_ready), .chip_tx_valid(chip_tx_valid),
        .busy(busy), .err_sticky(err_sticky), .state_dbg(state_dbg),
        .lfsr_start(lfsr_start), .lfsr_valid(lfsr_valid), .lfsr_sign_bit(lfsr_sign_bit),
        .wht_start(wht_start), .wht_replay_start(wht_replay_start),
        .wht_busy(wht_busy), .wht_ready(wht_ready),
        .wht_in_valid(wht_in_valid), .wht_in_ready(wht_in_ready),
        .wht_x_in(wht_x_in), .wht_x_sign(wht_x_sign),
        .wht_out_valid(wht_out_valid), .wht_y_out(wht_y_out), .wht_out_last(wht_out_last),
        .n2_clear(n2_clear), .n2_in_valid(n2_in_valid), .n2_y_in(n2_y_in),
        .n2_done(n2_done), .n2_norm2(n2_norm2),
        .rs_in_valid(rs_in_valid), .rs_norm2(rs_norm2),
        .rs_out_valid(rs_out_valid), .rs_inv_norm(rs_inv_norm), .rs_norm_int(rs_norm_int),
        .q_in_valid(q_in_valid), .q_y_i(q_y_i), .q_inv_norm(q_inv_norm),
        .q_out_valid(q_out_valid), .q_idx_out(q_idx_out),
        .bp_clear(bp_clear), .bp_idx_valid(bp_idx_valid), .bp_idx(bp_idx),
        .bp_byte_valid(bp_byte_valid), .bp_out_byte(bp_out_byte), .bp_last_byte(bp_last_byte)
    );

endmodule

`default_nettype wire
