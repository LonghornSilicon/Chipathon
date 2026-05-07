// ctrl_io.sv
//
// Streaming-I/O front end and control FSM for int4_mac_accel.
// Decodes the opcode-tagged packetized protocol on ui_in / uio_in,
// drives the data-plane blocks (mac_array_4x4, accum_bank,
// weight_rom, act_streamer, requant_sat, act_lut), and emits
// responses on uo_out / uio_out.
//
// Pin convention (consumed by the top wrapper):
//   ui_in[7:0]    host -> chip data byte
//   uio_in[2]     host_tx_valid (next ui_in byte is valid)
//   uio_in[3]     host_rx_ready (host has consumed last uo_out)
//   uo_out[7:0]   chip -> host data byte
//   uio_out[0]    chip_rx_ready (chip will consume ui_in this cycle)
//   uio_out[1]    chip_tx_valid (uo_out byte is valid this cycle)
//   uio_out[7:4]  debug: top FSM state
//
// Opcode set (4-bit op in [7:4], 4-bit field in [3:0]):
//   0x0 NOP            no payload, no response.
//   0x1 RD_STATUS      no payload, response 1B = STATUS.
//   0x2 WR_CTRL        field = new CTRL value; updates CTRL atomically.
//                      bit[3] of field = clear sticky (err + ovfl).
//   0x3 WR_MODE        payload 1B = new MODE; no response.
//   0x4 LOAD_W_ROM     field = rom_page (0..15). Walks ROM addresses
//                      {page,0..15} and fills the weight buffer, then
//                      pulses mac_load_weight for one cycle.
//   0x5 LOAD_W_DIRECT  payload 8B (low nibble first per byte = even
//                      slot, high nibble = odd slot), then pulses
//                      mac_load_weight for one cycle.
//   0x6 STREAM_ACT     field = {wr_mode, bank_row[1:0], bank_sel}.
//                      Payload 2B (4 INT4 activations packed). Pushes
//                      one row of acts through act_streamer, lets the
//                      array MAC them into the PE accs, then writes
//                      col_flat_o into accum_bank at the encoded
//                      target with the encoded write mode.
//   0x7 DRAIN_ACC      field = {2'h0, lut_en, bank_sel}. Walks 16
//                      bank entries through requant_sat (and act_lut
//                      if lut_en) and emits 16 response bytes.
//   0x8 RUN_TILE       field = {3'h0, bank_sel}. Pulses bank clear.
//                      (Composite alias of CLEAR_BANK to keep the
//                      opcode table aligned with the spec wording.)
//   0x9 CLEAR_BANK     field = {3'h0, bank_sel}. Pulses bank clear.
//   0xA RD_ACC         field = high 4 bits of bank addr; payload 1B
//                      whose low 4 bits supply the rest. Response 3 B
//                      (sign-extended INT20 -> 24 bits, little-endian).
//   0xB - 0xF reserved sets STATUS.err.
//
// CSRs:
//   STATUS [7] err_sticky  [6] busy  [5] ovfl_sticky  [4] reserved
//          [3:0] state[3:0]
//   CTRL   [3] clear_sticky on next WR_CTRL pulse (also clears ovfl)
//          [2:0] reserved
//   MODE   [4:0] requant_shift   [5] requant_int8
//          [6]   requant_round   [7] lut_enable_default

`timescale 1ns/1ps
`default_nettype none

module ctrl_io #(
    parameter int ACC_W   = 20,
    parameter int OUT_W   = 8,
    parameter int SHIFT_W = $clog2(ACC_W) + 1,
    parameter int ROWS    = 4,
    parameter int COLS    = 4,
    parameter int BANKS   = 2,
    parameter int DATA_W  = 4,
    parameter int ROM_AW  = 8,
    parameter int BNK_AW  = $clog2(ROWS*COLS*BANKS)
) (
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  logic                                  ena,

    input  logic [7:0]                            ui_in,
    output logic [7:0]                            uo_out,
    input  logic [7:0]                            uio_in,
    output logic [7:0]                            uio_out,

    output logic                                  mac_en_o,
    output logic                                  mac_load_weight_o,
    output logic                                  mac_clear_acc_o,
    output logic signed [ROWS*COLS*DATA_W-1:0]    mac_weight_flat_o,

    output logic                                  bnk_wr_en_o,
    output logic                                  bnk_wr_mode_o,
    output logic [$clog2(BANKS)-1:0]              bnk_wr_bank_o,
    output logic [$clog2(ROWS)-1:0]               bnk_wr_row_o,
    output logic                                  bnk_clear_bank_en_o,
    output logic [$clog2(BANKS)-1:0]              bnk_clear_bank_o,
    output logic                                  bnk_rd_en_o,
    output logic [BNK_AW-1:0]                     bnk_rd_addr_o,
    input  logic signed [ACC_W-1:0]               bnk_rd_data_i,

    output logic                                  rom_rd_en_o,
    output logic [ROM_AW-1:0]                     rom_rd_addr_o,
    input  logic signed [DATA_W-1:0]              rom_rd_data_i,

    output logic                                  as_in_valid_o,
    input  logic                                  as_in_ready_i,
    output logic signed [DATA_W-1:0]              as_in_data_o,
    output logic                                  as_flush_o,
    input  logic                                  as_out_valid_i,
    output logic                                  as_out_ready_o,

    output logic                                  rq_valid_o,
    input  logic                                  rq_ready_i,
    output logic [SHIFT_W-1:0]                    rq_shift_o,
    output logic                                  rq_mode_o,
    output logic                                  rq_round_o,
    input  logic                                  rq_overflow_i,

    input  logic                                  lut_valid_i,
    output logic                                  lut_ready_o,
    output logic                                  lut_enable_o,
    input  logic signed [OUT_W-1:0]               lut_data_i
);

    localparam logic [3:0] OP_NOP           = 4'h0;
    localparam logic [3:0] OP_RD_STATUS     = 4'h1;
    localparam logic [3:0] OP_WR_CTRL       = 4'h2;
    localparam logic [3:0] OP_WR_MODE       = 4'h3;
    localparam logic [3:0] OP_LOAD_W_ROM    = 4'h4;
    localparam logic [3:0] OP_LOAD_W_DIRECT = 4'h5;
    localparam logic [3:0] OP_STREAM_ACT    = 4'h6;
    localparam logic [3:0] OP_DRAIN_ACC     = 4'h7;
    localparam logic [3:0] OP_RUN_TILE      = 4'h8;
    localparam logic [3:0] OP_CLEAR_BANK    = 4'h9;
    localparam logic [3:0] OP_RD_ACC        = 4'hA;
    localparam logic [3:0] OP_RESERVED_B    = 4'hB;

    typedef enum logic [4:0] {
        S_IDLE        = 5'd0,
        S_TX_STATUS   = 5'd1,
        S_RX_MODE     = 5'd2,
        S_LWR         = 5'd3,
        S_LWD_RX      = 5'd4,
        S_LATCH_W     = 5'd5,
        S_SA_RX_LO    = 5'd6,
        S_SA_PUSH_HI  = 5'd7,
        S_SA_DRAIN1   = 5'd8,
        S_SA_DRAIN2   = 5'd9,
        S_SA_BANK_WR  = 5'd10,
        S_DA_RD       = 5'd11,
        S_DA_RQ       = 5'd12,
        S_DA_TX       = 5'd13,
        S_RA_RX       = 5'd14,
        S_RA_RD       = 5'd15,
        S_RA_TX       = 5'd16
    } state_t;

    state_t                  state_q, state_d;
    logic [3:0]              op_q;
    logic [3:0]              field_q;
    logic [7:0]              mode_q;
    logic                    err_sticky_q;
    logic                    ovfl_sticky_q;

    // Per-opcode counters (reused across opcodes since only one is
    // active at a time).
    logic [4:0]              cnt_q;          // generic step counter
    logic [BNK_AW-1:0]       ra_addr_q;      // RD_ACC captured address
    logic [ACC_W-1:0]        ra_data_q;      // RD_ACC captured value
    logic [DATA_W-1:0]       hi_buf_q;       // STREAM_ACT high nibble pending push

    logic signed [DATA_W-1:0] wbuf_q [ROWS*COLS];

    // Combinational helper for the S_LWR ROM walk. cnt_q ranges
    // 0..16; we want to write wbuf_q[cnt_q-1] when cnt_q != 0, so
    // pre-compute the 4-bit index here. Module-scope so yosys
    // (which doesn't accept 'automatic' inside procedural blocks)
    // can parse the always_ff cleanly.
    logic [4:0] lwr_sub;
    logic [3:0] lwr_widx;
    assign lwr_sub  = cnt_q - 5'd1;
    assign lwr_widx = lwr_sub[3:0];

    // ---- Host handshake plumbing ----
    logic host_tx_valid;
    logic host_rx_ready;
    assign host_tx_valid = uio_in[2] & ena;
    assign host_rx_ready = uio_in[3];

    logic       chip_rx_ready;
    logic       chip_tx_valid;
    logic [7:0] tx_byte;

    // ---- Main combinational FSM (next-state + outputs) ----
    always_comb begin
        chip_rx_ready       = 1'b0;
        chip_tx_valid       = 1'b0;
        tx_byte             = 8'h00;

        mac_en_o            = 1'b0;
        mac_load_weight_o   = 1'b0;
        mac_clear_acc_o     = 1'b0;

        bnk_wr_en_o         = 1'b0;
        bnk_wr_mode_o       = field_q[3];          // STREAM_ACT field[3]
        bnk_wr_bank_o       = field_q[0];
        bnk_wr_row_o        = field_q[2:1];
        bnk_clear_bank_en_o = 1'b0;
        bnk_clear_bank_o    = field_q[0];
        bnk_rd_en_o         = 1'b0;
        bnk_rd_addr_o       = (op_q == OP_RD_ACC) ? ra_addr_q
                                                 : {field_q[0], cnt_q[3:0]};

        rom_rd_en_o         = (state_q == S_LWR);
        rom_rd_addr_o       = {field_q, cnt_q[3:0]};

        as_in_valid_o       = 1'b0;
        as_in_data_o        = '0;
        as_flush_o          = 1'b0;
        as_out_ready_o      = 1'b1;

        rq_valid_o          = 1'b0;
        rq_shift_o          = SHIFT_W'(mode_q[4:0]);
        rq_mode_o           = mode_q[5];
        rq_round_o          = mode_q[6];

        // lut_ready_o == 1 lets the lut capture from requant. We
        // must let it accept input (otherwise the pipeline never
        // fills), but we hold its output stable on backpressure by
        // only saying ready-to-consume once host_rx_ready is high.
        // When lut.valid_o is 0, lut_ready_o has no observable effect
        // (no consume happens), so default to 1 in that case.
        lut_ready_o         = (~lut_valid_i) | host_rx_ready;
        lut_enable_o        = (op_q == OP_DRAIN_ACC) ? field_q[1] : mode_q[7];

        state_d             = state_q;

        case (state_q)
            S_IDLE: begin
                chip_rx_ready = 1'b1;
                if (host_tx_valid) begin
                    case (ui_in[7:4])
                        OP_NOP:           state_d = S_IDLE;
                        OP_RD_STATUS:     state_d = S_TX_STATUS;
                        OP_WR_CTRL:       state_d = S_IDLE;
                        OP_WR_MODE:       state_d = S_RX_MODE;
                        OP_LOAD_W_ROM:    state_d = S_LWR;
                        OP_LOAD_W_DIRECT: state_d = S_LWD_RX;
                        OP_STREAM_ACT:    state_d = S_SA_RX_LO;
                        OP_DRAIN_ACC:     state_d = S_DA_RD;
                        OP_RUN_TILE: begin
                            // RUN_TILE = "start a fresh tile": clear
                            // both the named bank and the PE accs so
                            // the next LOAD_W + STREAM_ACT begins
                            // accumulation from zero.
                            bnk_clear_bank_en_o = 1'b1;
                            bnk_clear_bank_o    = ui_in[0];
                            mac_clear_acc_o     = 1'b1;
                            state_d             = S_IDLE;
                        end
                        OP_CLEAR_BANK: begin
                            bnk_clear_bank_en_o = 1'b1;
                            bnk_clear_bank_o    = ui_in[0];
                            state_d             = S_IDLE;
                        end
                        OP_RD_ACC:        state_d = S_RA_RX;
                        default:          state_d = S_IDLE;  // err_sticky in FF
                    endcase
                end
            end

            S_TX_STATUS: begin
                chip_tx_valid = 1'b1;
                tx_byte       = {err_sticky_q,
                                 (state_q != S_IDLE),
                                 ovfl_sticky_q,
                                 1'b0,
                                 state_q[3:0]};
                if (host_rx_ready) state_d = S_IDLE;
            end

            S_RX_MODE: begin
                chip_rx_ready = 1'b1;
                if (host_tx_valid) state_d = S_IDLE;
            end

            // -------- LOAD_W_ROM: walk 16 addresses with 1-cycle latency
            // cnt_q sequences:
            //   0..15: drive rom_rd_addr = {page, cnt}, rom_rd_en=1
            //   In FF: latch rom_rd_data_i into wbuf_q[cnt_q-1] when
            //   cnt_q in 1..15. After cnt_q reaches 15, we need one
            //   more cycle (cnt_q=16) to latch the last value.
            S_LWR: begin
                if (cnt_q == 5'd16) state_d = S_LATCH_W;
            end

            // -------- LOAD_W_DIRECT: receive 8 payload bytes
            S_LWD_RX: begin
                chip_rx_ready = 1'b1;
                if (host_tx_valid && (cnt_q == 5'd7)) state_d = S_LATCH_W;
            end

            S_LATCH_W: begin
                mac_load_weight_o = 1'b1;
                state_d           = S_IDLE;
            end

            // -------- STREAM_ACT: 2 payload bytes -> 4 acts. cnt_q
            // counts BYTES received (0,1). Each S_SA_RX_LO accepts a
            // byte, pushes its low nibble to the streamer, latches
            // the high nibble; S_SA_PUSH_HI pushes the high nibble
            // and either loops (byte 0) or moves on to drain (byte 1).
            S_SA_RX_LO: begin
                chip_rx_ready = as_in_ready_i;
                as_in_valid_o = host_tx_valid;
                as_in_data_o  = ui_in[3:0];
                if (host_tx_valid && as_in_ready_i) state_d = S_SA_PUSH_HI;
            end

            S_SA_PUSH_HI: begin
                chip_rx_ready = 1'b0;
                as_in_valid_o = 1'b1;
                as_in_data_o  = hi_buf_q;
                if (as_in_ready_i) begin
                    state_d = (cnt_q == 5'd1) ? S_SA_DRAIN1 : S_SA_RX_LO;
                end
            end

            // Activate mac_en exactly once per row burst. After 4 acts,
            // act_streamer presents the row; mac_en=1 for one cycle.
            S_SA_DRAIN1: begin
                mac_en_o = as_out_valid_i;
                state_d  = S_SA_DRAIN2;
            end

            S_SA_DRAIN2: begin
                // PE accs updated last cycle; col_q catches up this
                // cycle so col_flat_o is valid for the bank write next.
                state_d = S_SA_BANK_WR;
            end

            S_SA_BANK_WR: begin
                bnk_wr_en_o = 1'b1;
                state_d     = S_IDLE;
            end

            // -------- DRAIN_ACC: walk 16 entries through requant -> lut
            // S_DA_RD asserts bnk_rd_en for one cycle. The bank's
            // rd_data lands NEXT cycle, so we kick off requant in
            // S_DA_RQ. Then S_DA_TX waits for lut.valid_o (1-2 cycles
            // after rq.valid_i depending on the lut pipeline) and
            // emits one byte per host_rx_ready ack.
            S_DA_RD: begin
                bnk_rd_en_o = 1'b1;
                state_d     = S_DA_RQ;
            end

            S_DA_RQ: begin
                rq_valid_o = 1'b1;
                state_d    = S_DA_TX;
            end

            S_DA_TX: begin
                chip_tx_valid = lut_valid_i;
                tx_byte       = lut_data_i;
                if (lut_valid_i && host_rx_ready) begin
                    if (cnt_q == 5'd15) state_d = S_IDLE;
                    else                state_d = S_DA_RD;
                end
            end

            // -------- RD_ACC: 1B payload (low nibble = low addr bits),
            //                  3B response (sign-extended INT20)
            S_RA_RX: begin
                chip_rx_ready = 1'b1;
                if (host_tx_valid) state_d = S_RA_RD;
            end

            S_RA_RD: begin
                bnk_rd_en_o = 1'b1;
                state_d     = S_RA_TX;
            end

            S_RA_TX: begin
                chip_tx_valid = 1'b1;
                // For cnt_q == 0, bnk_rd_data_i is the freshly-read
                // value (registered last cycle in S_RA_RD); use it
                // directly. Subsequent cycles read from the latched
                // ra_data_q because by then we're driving bnk_rd_en=0
                // and the bank may move on to a different read.
                case (cnt_q[1:0])
                    2'd0:    tx_byte = bnk_rd_data_i[7:0];
                    2'd1:    tx_byte = ra_data_q[15:8];
                    default: tx_byte = {{(8 - (ACC_W-16)){ra_data_q[ACC_W-1]}},
                                        ra_data_q[ACC_W-1:16]};
                endcase
                if (host_rx_ready && (cnt_q[1:0] == 2'd2)) state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    // ---- Drive mac_weight_flat_o continuously from wbuf_q ----
    always_comb begin
        for (int r = 0; r < ROWS; r++) begin
            for (int c = 0; c < COLS; c++) begin
                mac_weight_flat_o[(r*COLS + c)*DATA_W +: DATA_W] =
                    wbuf_q[r*COLS + c];
            end
        end
    end

    // ---- Sequential ----
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state_q       <= S_IDLE;
            op_q          <= '0;
            field_q       <= '0;
            mode_q        <= 8'h00;
            err_sticky_q  <= 1'b0;
            ovfl_sticky_q <= 1'b0;
            cnt_q         <= '0;
            ra_addr_q     <= '0;
            ra_data_q     <= '0;
            hi_buf_q      <= '0;
            for (int i = 0; i < ROWS*COLS; i++) wbuf_q[i] <= '0;
        end else begin
            state_q       <= state_d;
            ovfl_sticky_q <= ovfl_sticky_q | rq_overflow_i;

            case (state_q)
                S_IDLE: begin
                    if (host_tx_valid) begin
                        op_q    <= ui_in[7:4];
                        field_q <= ui_in[3:0];
                        cnt_q   <= '0;
                        if (ui_in[7:4] == OP_WR_CTRL) begin
                            if (ui_in[3]) begin
                                err_sticky_q  <= 1'b0;
                                ovfl_sticky_q <= 1'b0;
                            end
                        end
                        if (ui_in[7:4] >= OP_RESERVED_B) begin
                            err_sticky_q <= 1'b1;
                        end
                    end
                end

                S_RX_MODE: begin
                    if (host_tx_valid) mode_q <= ui_in;
                end

                // ROM walk: cnt_q steps 0,1,2,...,16. We latch
                // rom_rd_data_i into wbuf_q[cnt_q-1] when cnt_q in
                // 1..16 (the data lags address by 1 cycle). The
                // pre-decrement and 4-bit slice are computed
                // combinationally outside this block (lwr_widx) to
                // keep the procedural block free of yosys-incompatible
                // 'automatic' declarations.
                S_LWR: begin
                    cnt_q <= cnt_q + 5'd1;
                    if (cnt_q != 5'd0) begin
                        wbuf_q[lwr_widx] <= rom_rd_data_i;
                    end
                end

                S_LWD_RX: begin
                    if (host_tx_valid) begin
                        wbuf_q[{cnt_q[2:0], 1'b0}] <= ui_in[3:0];
                        wbuf_q[{cnt_q[2:0], 1'b1}] <= ui_in[7:4];
                        cnt_q <= cnt_q + 5'd1;
                    end
                end

                S_SA_RX_LO: begin
                    if (host_tx_valid && as_in_ready_i) begin
                        hi_buf_q <= ui_in[7:4];
                    end
                end

                S_SA_PUSH_HI: begin
                    if (as_in_ready_i) begin
                        cnt_q <= cnt_q + 5'd1;
                    end
                end

                S_DA_TX: begin
                    if (lut_valid_i && host_rx_ready) begin
                        cnt_q <= cnt_q + 5'd1;
                    end
                end

                S_RA_RX: begin
                    if (host_tx_valid) begin
                        ra_addr_q <= {field_q[BNK_AW-5:0], ui_in[3:0]};
                    end
                end

                S_RA_RD: begin
                    // bnk_rd_data_i is registered, becomes valid as we
                    // enter S_RA_TX; capture there.
                end

                S_RA_TX: begin
                    if (cnt_q[1:0] == 2'd0) begin
                        ra_data_q <= bnk_rd_data_i;
                    end
                    if (host_rx_ready) cnt_q <= cnt_q + 5'd1;
                    // Sign-extend on capture so the upper byte case
                    // can simply read ra_data_q[ACC_W-1:16].
                end

                default: ;
            endcase
        end
    end

    assign uo_out      = tx_byte;
    assign uio_out[0]  = chip_rx_ready;
    assign uio_out[1]  = chip_tx_valid;
    assign uio_out[2]  = err_sticky_q;
    assign uio_out[3]  = (state_q != S_IDLE);   // busy
    assign uio_out[7:4]= state_q[3:0];          // low nibble of state for debug

endmodule

`default_nettype wire
