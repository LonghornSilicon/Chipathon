// int4_mac_accel.sv
//
// Top-level wrapper for the int4 MAC accelerator. Wires ctrl_io into
// the data plane (mac_array_4x4, accum_bank, weight_rom, act_streamer,
// requant_sat, act_lut) and exposes the Tiny Tapeout pinout per the
// microarchitecture spec, p.9:
//
//   clk            single core clock
//   rst_n          synchronous active-low reset
//   ena            global enable (gates host_tx_valid in ctrl_io so
//                  that ui_in/uio_in are ignored when ena=0)
//   ui_in[7:0]     host -> chip data byte
//   uo_out[7:0]    chip -> host data byte
//   uio_in[7:0]    bidirectional input  (uio_in[2]=host_tx_valid,
//                                        uio_in[3]=host_rx_ready,
//                                        others reserved)
//   uio_out[7:0]   bidirectional output (uio_out[0]=chip_rx_ready,
//                                        uio_out[1]=chip_tx_valid,
//                                        uio_out[2]=err_sticky,
//                                        uio_out[3]=busy,
//                                        uio_out[7:4]=state[3:0])
//   uio_oe[7:0]    bidirectional drive-enable. Statically:
//                    bits driven by chip = uio_oe = 8'b1111_0011
//                    (bits 0,1,4,5,6,7 are outputs, 2,3 are inputs).

`timescale 1ns/1ps
`default_nettype none

module int4_mac_accel #(
    parameter int ACC_W   = 20,
    parameter int OUT_W   = 8,
    parameter int SHIFT_W = $clog2(ACC_W) + 1,
    parameter int ROWS    = 4,
    parameter int COLS    = 4,
    parameter int BANKS   = 2,
    parameter int DATA_W  = 4,
    parameter int ROM_AW  = 8,
    parameter int BNK_AW  = $clog2(ROWS*COLS*BANKS),
    parameter int ARR_OUT = ACC_W + $clog2(ROWS)
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

    // Static drive-enable. Bits 0,1,4,5,6,7 = chip drives (1).
    // Bits 2,3 = host drives (0). 8'b11110011 = 8'hF3.
    assign uio_oe = 8'hF3;

    // ---- Internal block-to-block wires ----
    logic                                  mac_en;
    logic                                  mac_load_weight;
    logic                                  mac_clear_acc;
    logic signed [ROWS*COLS*DATA_W-1:0]    mac_weight_flat;
    logic signed [ROWS*DATA_W-1:0]         mac_act_flat;
    logic signed [COLS*ARR_OUT-1:0]        mac_col_flat;

    logic                        bnk_wr_en;
    logic                        bnk_wr_mode;
    logic [$clog2(BANKS)-1:0]    bnk_wr_bank;
    logic [$clog2(ROWS)-1:0]     bnk_wr_row;
    logic                        bnk_clear_bank_en;
    logic [$clog2(BANKS)-1:0]    bnk_clear_bank;
    logic                        bnk_rd_en;
    logic [BNK_AW-1:0]           bnk_rd_addr;
    logic signed [ACC_W-1:0]     bnk_rd_data;

    logic                        rom_rd_en;
    logic [ROM_AW-1:0]           rom_rd_addr;
    logic signed [DATA_W-1:0]    rom_rd_data;

    logic                        as_in_valid;
    logic                        as_in_ready;
    logic signed [DATA_W-1:0]    as_in_data;
    logic                        as_flush;
    logic                        as_out_valid;
    logic                        as_out_ready;

    logic                        rq_valid;
    logic                        rq_ready;
    logic [SHIFT_W-1:0]          rq_shift;
    logic                        rq_mode;
    logic                        rq_round;
    logic signed [OUT_W-1:0]     rq_data;
    logic                        rq_ovfl;
    logic                        rq_to_lut_valid;
    logic                        lut_to_rq_ready;

    logic                        lut_valid;
    logic                        lut_ready_from_ctrl;
    logic                        lut_enable;
    logic signed [OUT_W-1:0]     lut_data;

    // ---- Controller ----
    ctrl_io #(
        .ACC_W   (ACC_W),
        .OUT_W   (OUT_W),
        .SHIFT_W (SHIFT_W),
        .ROWS    (ROWS),
        .COLS    (COLS),
        .BANKS   (BANKS),
        .DATA_W  (DATA_W),
        .ROM_AW  (ROM_AW),
        .BNK_AW  (BNK_AW)
    ) u_ctrl (
        .clk                 (clk),
        .rst_n               (rst_n),
        .ena                 (ena),
        .ui_in               (ui_in),
        .uo_out              (uo_out),
        .uio_in              (uio_in),
        .uio_out             (uio_out),
        .mac_en_o            (mac_en),
        .mac_load_weight_o   (mac_load_weight),
        .mac_clear_acc_o     (mac_clear_acc),
        .mac_weight_flat_o   (mac_weight_flat),
        .bnk_wr_en_o         (bnk_wr_en),
        .bnk_wr_mode_o       (bnk_wr_mode),
        .bnk_wr_bank_o       (bnk_wr_bank),
        .bnk_wr_row_o        (bnk_wr_row),
        .bnk_clear_bank_en_o (bnk_clear_bank_en),
        .bnk_clear_bank_o    (bnk_clear_bank),
        .bnk_rd_en_o         (bnk_rd_en),
        .bnk_rd_addr_o       (bnk_rd_addr),
        .bnk_rd_data_i       (bnk_rd_data),
        .rom_rd_en_o         (rom_rd_en),
        .rom_rd_addr_o       (rom_rd_addr),
        .rom_rd_data_i       (rom_rd_data),
        .as_in_valid_o       (as_in_valid),
        .as_in_ready_i       (as_in_ready),
        .as_in_data_o        (as_in_data),
        .as_flush_o          (as_flush),
        .as_out_valid_i      (as_out_valid),
        .as_out_ready_o      (as_out_ready),
        .rq_valid_o          (rq_valid),
        .rq_ready_i          (rq_ready),
        .rq_shift_o          (rq_shift),
        .rq_mode_o           (rq_mode),
        .rq_round_o          (rq_round),
        .rq_overflow_i       (rq_ovfl),
        .lut_valid_i         (lut_valid),
        .lut_ready_o         (lut_ready_from_ctrl),
        .lut_enable_o        (lut_enable),
        .lut_data_i          (lut_data)
    );

    // ---- MAC array ----
    mac_array_4x4 #(
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W),
        .OUT_W  (ARR_OUT)
    ) u_mac (
        .clk           (clk),
        .rst_n         (rst_n),
        .en            (mac_en),
        .load_weight   (mac_load_weight),
        .clear_acc     (mac_clear_acc),
        .weight_flat_i (mac_weight_flat),
        .act_flat_i    (mac_act_flat),
        .col_flat_o    (mac_col_flat)
    );

    // ---- Accumulator bank ----
    accum_bank #(
        .ROWS  (ROWS),
        .COLS  (COLS),
        .BANKS (BANKS),
        .ACC_W (ACC_W)
    ) u_bank (
        .clk           (clk),
        .rst_n         (rst_n),
        .wr_en         (bnk_wr_en),
        .wr_mode       (bnk_wr_mode),
        .wr_bank       (bnk_wr_bank),
        .wr_row        (bnk_wr_row),
        .wr_data_flat  (mac_col_flat),
        .clear_bank_en (bnk_clear_bank_en),
        .clear_bank    (bnk_clear_bank),
        .rd_en         (bnk_rd_en),
        .rd_addr       (bnk_rd_addr),
        .rd_data       (bnk_rd_data)
    );

    // ---- Weight ROM ----
    weight_rom #(
        .ENTRIES (256),
        .DATA_W  (DATA_W)
    ) u_rom (
        .clk     (clk),
        .rst_n   (rst_n),
        .rd_en   (rom_rd_en),
        .rd_addr (rom_rd_addr),
        .rd_data (rom_rd_data)
    );

    // ---- Activation streamer ----
    act_streamer #(
        .ROWS   (ROWS),
        .DATA_W (DATA_W)
    ) u_as (
        .clk           (clk),
        .rst_n         (rst_n),
        .flush_i       (as_flush),
        .in_valid      (as_in_valid),
        .in_ready      (as_in_ready),
        .in_data       (as_in_data),
        .out_valid     (as_out_valid),
        .out_ready     (as_out_ready),
        .out_data_flat (mac_act_flat)
    );

    // ---- Requantize / saturate ----
    requant_sat #(
        .ACC_W   (ACC_W),
        .OUT_W   (OUT_W),
        .SHIFT_W (SHIFT_W)
    ) u_rq (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_i    (rq_valid),
        .ready_o    (rq_ready),
        .data_i     (bnk_rd_data),
        .shift_i    (rq_shift),
        .mode_i     (rq_mode),
        .round_i    (rq_round),
        .valid_o    (rq_to_lut_valid),
        .ready_i    (lut_to_rq_ready),
        .data_o     (rq_data),
        .overflow_o (rq_ovfl)
    );

    // ---- Activation LUT ----
    act_lut #(
        .IN_W      (OUT_W),
        .OUT_W     (OUT_W),
        .N_ENTRIES (16),
        .FUNC      (0)              // 0 = FUNC_EXP_NEG (see act_lut.sv)
    ) u_lut (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable_i (lut_enable),
        .valid_i  (rq_to_lut_valid),
        .ready_o  (lut_to_rq_ready),
        .data_i   (rq_data),
        .valid_o  (lut_valid),
        .ready_i  (lut_ready_from_ctrl),
        .data_o   (lut_data)
    );

endmodule

`default_nettype wire
