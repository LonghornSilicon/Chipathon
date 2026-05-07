// accum_bank.sv
//
// Ping-pong INT20 accumulator bank for the int4_mac_accel block. Sits
// downstream of mac_array_4x4 and stores partial-sum tiles across
// multiple weight-load passes, so that output regions larger than the
// 4x4 array can be built up by accumulating across passes.
//
// Storage is BANKS x ROWS x COLS = 2 x 4 x 4 = 32 entries of signed
// INT20 (ACC_W = 20), matching the spec's "32-entry INT20 bank".
// "Dual-banked" is realised as two ROWS x COLS sub-tiles selected by
// wr_bank / clear_bank / rd_addr[ADDR_W-1], so software can drain one
// sub-tile through the read port while the other is still being
// accumulated.
//
// Write port:
//   * COLS wide (one row of mac_array_4x4 col_flat_o per cycle).
//   * IN_W defaults to ACC_W + $clog2(ROWS) = 22, which matches the
//     array's OUT_W. Inputs are saturated to ACC_W on entry.
//   * wr_mode = 0 (OVERWRITE): mem[wr_bank][wr_row][c] <= sat(in[c])
//   * wr_mode = 1 (ACCUMULATE): mem[...] <= sat(mem[...] + in[c])
//     where the intermediate sum is widened by one bit before
//     saturating back to INT20, giving saturating-MAC semantics.
//
// Bank clear:
//   * clear_bank_en zeroes all ROWS*COLS entries of mem[clear_bank]
//     in a single cycle (16 entries; combinational fan-out is fine).
//
// Read port:
//   * Single INT20 entry per cycle, addressed by a flat 5-bit
//     {bank, row, col} index. Output is registered, so rd_data is
//     valid one cycle after rd_en. When rd_en is low, rd_data holds
//     its previous value.
//
// Control priority (highest to lowest, matching int4_pe.sv style):
//   rst_n > clear_bank_en > wr_en
//
// Reset is synchronous and active-low.

`timescale 1ns/1ps
`default_nettype none

module accum_bank #(
    parameter int ROWS    = 4,
    parameter int COLS    = 4,
    parameter int BANKS   = 2,
    parameter int ACC_W   = 20,
    parameter int IN_W    = ACC_W + $clog2(ROWS),
    parameter int ROW_AW  = $clog2(ROWS),
    parameter int COL_AW  = $clog2(COLS),
    parameter int BANK_AW = $clog2(BANKS),
    parameter int ADDR_W  = $clog2(ROWS*COLS*BANKS)
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          wr_en,
    input  logic                          wr_mode,
    input  logic [BANK_AW-1:0]            wr_bank,
    input  logic [ROW_AW-1:0]             wr_row,
    input  logic signed [COLS*IN_W-1:0]   wr_data_flat,

    input  logic                          clear_bank_en,
    input  logic [BANK_AW-1:0]            clear_bank,

    input  logic                          rd_en,
    input  logic [ADDR_W-1:0]             rd_addr,
    output logic signed [ACC_W-1:0]       rd_data
);

    // INT20 saturation bounds, sized to the widest signed compare we
    // do in sat_to_acc (its arg is IN_W+1 bits to hold the post-add
    // intermediate). Sized this way so the comparators don't generate
    // WIDTHEXPAND warnings.
    localparam logic signed [IN_W:0] ACC_MAX = (1 <<< (ACC_W-1)) - 1;
    localparam logic signed [IN_W:0] ACC_MIN = -(1 <<< (ACC_W-1));

    // Storage. Unpacked array is fine for a leaf block; Yosys
    // flattens it for synthesis.
    logic signed [ACC_W-1:0] mem [BANKS][ROWS][COLS];

    // Combinational view of the per-column write input as signed IN_W.
    logic signed [IN_W-1:0]  wr_in [COLS];

    genvar gcw;
    generate
        for (gcw = 0; gcw < COLS; gcw++) begin : g_wr_unpack
            assign wr_in[gcw] = wr_data_flat[gcw*IN_W +: IN_W];
        end
    endgenerate

    // Saturating clamp from a signed (ACC_W+1)-bit (or wider) value
    // down to ACC_W bits. The intermediate type for the function arg
    // is one bit wider than the widest caller (IN_W is at most a few
    // bits over ACC_W in realistic params), giving headroom for the
    // worst-case += sum.
    function automatic logic signed [ACC_W-1:0]
            sat_to_acc (input logic signed [IN_W:0] x);
        if (x > ACC_MAX) sat_to_acc = ACC_MAX[ACC_W-1:0];
        else if (x < ACC_MIN) sat_to_acc = ACC_MIN[ACC_W-1:0];
        else sat_to_acc = x[ACC_W-1:0];
    endfunction

    // Write next-state. Computed combinationally so the always_ff
    // below is just storage, which keeps the synthesis intent clear.
    logic signed [ACC_W-1:0] wr_next [COLS];
    logic signed [IN_W:0]    sum_ext [COLS];

    always_comb begin
        for (int c = 0; c < COLS; c++) begin
            // Sign-extend the stored INT20 to IN_W+1 bits so the add
            // matches the wr_in operand width and the result fits.
            logic signed [IN_W:0] mem_ext;
            logic signed [IN_W:0] in_ext;
            mem_ext    = (IN_W+1)'(mem[wr_bank][wr_row][c]);
            in_ext     = (IN_W+1)'(wr_in[c]);
            sum_ext[c] = mem_ext + in_ext;
            wr_next[c] = wr_mode
                       ? sat_to_acc(sum_ext[c])
                       : sat_to_acc(in_ext);
        end
    end

    // Decompose the flat read address into {bank, row, col}.
    logic [BANK_AW-1:0] rd_bank;
    logic [ROW_AW-1:0]  rd_row;
    logic [COL_AW-1:0]  rd_col;

    assign rd_bank = rd_addr[ADDR_W-1 -: BANK_AW];
    assign rd_row  = rd_addr[COL_AW +: ROW_AW];
    assign rd_col  = rd_addr[0 +: COL_AW];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (int b = 0; b < BANKS; b++)
                for (int r = 0; r < ROWS; r++)
                    for (int c = 0; c < COLS; c++)
                        mem[b][r][c] <= '0;
            rd_data <= '0;
        end else begin
            if (clear_bank_en) begin
                for (int r = 0; r < ROWS; r++)
                    for (int c = 0; c < COLS; c++)
                        mem[clear_bank][r][c] <= '0;
            end else if (wr_en) begin
                for (int c = 0; c < COLS; c++)
                    mem[wr_bank][wr_row][c] <= wr_next[c];
            end

            if (rd_en) begin
                rd_data <= mem[rd_bank][rd_row][rd_col];
            end
        end
    end

endmodule

`default_nettype wire
