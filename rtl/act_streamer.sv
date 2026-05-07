// act_streamer.sv
//
// 4-deep INT4 fill buffer that stages activations arriving one at a
// time from ctrl_io and presents them ROWS-wide to mac_array_4x4.
// Out-side packing matches mac_array_4x4.act_flat_i exactly:
//   out_data_flat[r*DATA_W +: DATA_W] = buf[r]
//
// Handshake:
//   * in_valid / in_ready: 1-element ready/valid push port.
//   * out_valid / out_ready: ROWS-wide ready/valid pop port.
//
// Behaviour:
//   * Each accepted in_valid increments fill_cnt and stores in_data
//     at buf[fill_cnt].
//   * out_valid asserts when fill_cnt == ROWS (buffer full).
//   * On out_valid && out_ready, fill_cnt resets to 0 and the buffer
//     becomes available for the next 4 pushes.
//   * in_ready is high whenever we can accept the next byte: either
//     there's room (fill_cnt < ROWS) or the consumer is draining the
//     full buffer this same cycle (the new byte goes into slot 0).
//   * flush_i resets fill_cnt to 0 without producing an out_valid
//     pulse. ctrl_io drives this between transactions.
//
// Reset: synchronous, active-low, matching the rest of the chip.

`timescale 1ns/1ps
`default_nettype none

module act_streamer #(
    parameter int ROWS    = 4,
    parameter int DATA_W  = 4,
    parameter int CNT_W   = $clog2(ROWS+1)
) (
    input  logic                              clk,
    input  logic                              rst_n,
    input  logic                              flush_i,

    input  logic                              in_valid,
    output logic                              in_ready,
    input  logic signed [DATA_W-1:0]          in_data,

    output logic                              out_valid,
    input  logic                              out_ready,
    output logic signed [ROWS*DATA_W-1:0]     out_data_flat
);

    logic signed [DATA_W-1:0] buf_q [ROWS];
    logic [CNT_W-1:0]         fill_cnt;

    localparam int IDX_W = $clog2(ROWS);

    logic                  do_pop;
    logic                  do_push;
    logic [IDX_W-1:0]      write_idx;

    assign out_valid = (fill_cnt == CNT_W'(ROWS));
    assign in_ready  = (fill_cnt < CNT_W'(ROWS)) || (out_valid && out_ready);
    assign do_pop    = out_valid && out_ready;
    assign do_push   = in_valid  && in_ready;
    // When the consumer is draining this cycle, the freshly pushed byte
    // lands in slot 0 of the next-cycle buffer. Otherwise it lands at
    // the current fill_cnt position. fill_cnt only needs IDX_W bits
    // (0..ROWS-1) when it's a valid write slot; the ROWS value never
    // becomes a write index because do_push is gated by in_ready.
    assign write_idx = do_pop ? '0 : fill_cnt[IDX_W-1:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fill_cnt <= '0;
            for (int r = 0; r < ROWS; r++) buf_q[r] <= '0;
        end else if (flush_i) begin
            fill_cnt <= '0;
        end else begin
            if (do_push) begin
                buf_q[write_idx] <= in_data;
            end

            unique case ({do_push, do_pop})
                2'b10:   fill_cnt <= fill_cnt + CNT_W'(1);
                2'b01:   fill_cnt <= '0;
                2'b11:   fill_cnt <= CNT_W'(1);
                default: fill_cnt <= fill_cnt;
            endcase
        end
    end

    genvar gr;
    generate
        for (gr = 0; gr < ROWS; gr++) begin : g_pack
            assign out_data_flat[gr*DATA_W +: DATA_W] = buf_q[gr];
        end
    endgenerate

endmodule

`default_nettype wire
