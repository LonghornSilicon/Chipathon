// bit_packer.sv
//
// Streams 64 × 3-bit indices in (one per cycle when ``idx_valid`` is
// high) and emits 24 × 8-bit bytes back-to-back as the bit budget
// fills. 64 * 3 = 192 = 24 * 8, so there is no padding — the last byte
// always lands exactly on a byte boundary.
//
// MSB-first bit packing: the first index occupies the top 3 bits of the
// first emitted byte, the second index the next 3 bits, etc.
//
// Pattern over 8 input cycles (counted by ``count_q``, the bits-still-
// in-the-buffer counter that runs 0->3->6->1(emit)->4->7->2(emit)->5->0(emit)):
//
//   in #1  count 0  -> 3   no emit
//   in #2  count 3  -> 6   no emit
//   in #3  count 6  -> 9   emit byte (top 8 of 9), keep 1 bit
//   in #4  count 1  -> 4   no emit
//   in #5  count 4  -> 7   no emit
//   in #6  count 7  -> 10  emit byte (top 8 of 10), keep 2 bits
//   in #7  count 2  -> 5   no emit
//   in #8  count 5  -> 8   emit byte (8 of 8), keep 0 bits
//
// 8 inputs -> 3 bytes; 64 inputs -> 24 bytes; ``last_byte`` pulses with
// the 24th byte. Assert ``clear`` for one cycle at the start of each
// vector to reset the internal state.

`timescale 1ns/1ps
`default_nettype none

module bit_packer #(
    parameter int IDX_BITS  = 3,
    parameter int N_INDICES = 64
) (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  clear,         // sync clear at vector start
    input  logic                  idx_valid,
    input  logic [IDX_BITS-1:0]   idx,
    output logic                  byte_valid,
    output logic [7:0]            out_byte,
    output logic                  last_byte
);

    localparam int TOTAL_BITS  = N_INDICES * IDX_BITS;       // 192
    localparam int TOTAL_BYTES = (TOTAL_BITS + 7) / 8;       // 24
    // Buffer holds up to (8 + IDX_BITS - 1) bits at any time.
    localparam int BUF_W       = 8 + IDX_BITS - 1;           // 10
    localparam int CAT_W       = BUF_W + IDX_BITS;           // 13
    localparam int CNT_W       = $clog2(BUF_W + 1);          // 4
    localparam int BC_W        = $clog2(TOTAL_BYTES + 1);    // 5

    logic [BUF_W-1:0]   buf_q;     // valid bits live in [count_q-1 : 0]
    logic [CNT_W-1:0]   count_q;
    logic [BC_W-1:0]    bytes_q;

    logic [CAT_W-1:0]   cat;
    logic [CNT_W:0]     new_count;

    always_comb begin
        cat       = (CAT_W'(buf_q) << IDX_BITS) | CAT_W'(idx);
        new_count = count_q + IDX_BITS[CNT_W:0];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            buf_q      <= '0;
            count_q    <= '0;
            bytes_q    <= '0;
            byte_valid <= 1'b0;
            out_byte   <= '0;
            last_byte  <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            last_byte  <= 1'b0;

            if (clear) begin
                buf_q   <= '0;
                count_q <= '0;
                bytes_q <= '0;
            end else if (idx_valid) begin
                if (new_count >= 8) begin
                    // Emit top 8 bits of cat (positions [new_count-1 : new_count-8]).
                    out_byte   <= 8'((cat >> (new_count - 5'd8)) & {8{1'b1}});
                    byte_valid <= 1'b1;
                    last_byte  <= (bytes_q + 1'b1 == BC_W'(TOTAL_BYTES));
                    bytes_q    <= bytes_q + 1'b1;
                    // Keep the residual low (new_count - 8) bits.
                    buf_q   <= BUF_W'(cat & ((CAT_W'(1) << (new_count - 5'd8)) - 1));
                    count_q <= CNT_W'(new_count - 5'd8);
                end else begin
                    buf_q   <= BUF_W'(cat);
                    count_q <= CNT_W'(new_count);
                end
            end
        end
    end

endmodule

`default_nettype wire
