// tq_ctrl.sv
//
// Top-level controller for the TurboQuant Algorithm 1 encoder.
//
// Per vector, the FSM walks five phases:
//
//   1. RX_X      collect 64 input bytes from the host
//                (uio_in[2]=host_tx_valid handshake; ui_in carries x byte)
//                while in parallel running ``sign_lfsr`` and feeding both
//                bytes + signs into ``wht64``
//
//   2. COMPUTE   wht64 runs its 192-cycle butterfly schedule; controller
//                stays here until ``wht_ready`` goes high
//
//   3. NORM2     pulse wht64.replay_start, stream y through norm2_acc
//                (64 cycles); when norm2_acc.done pulses, latch norm2 and
//                kick rsqrt_unit
//
//   4. RSQRT     wait ~30 cycles for rsqrt_unit.out_valid; latch inv_norm
//
//   5. QUANT     pulse wht64.replay_start again; stream y through
//                quant_unit using inv_norm; quant_unit's idx outputs feed
//                bit_packer; in parallel emit norm bytes (UQ14.0 -> 2
//                bytes) and the 24 packed idx bytes to the host over
//                uo_out (chip_tx_valid / host_rx_ready handshake on uio)
//
//   6. TX        emit the 26-byte output frame to the host
//
// The controller is pure FSM + counters — no datapath of its own. All
// arithmetic happens in the leaf blocks. See PLAN.md §7 for the host
// frame format and uio bit assignments.

`timescale 1ns/1ps
`default_nettype none

module tq_ctrl #(
    parameter int D          = 64,
    parameter int X_W        = 8,
    parameter int Y_W        = 14,
    parameter int N2_W       = 32,
    parameter int NORM_W     = 14,
    parameter int INV_W      = 15,
    parameter int IDX_W      = 3,
    parameter int N_BOUNDS   = 7,
    parameter int CB_W       = 11
) (
    input  logic clk,
    input  logic rst_n,
    input  logic ena,

    // Host data path
    input  logic [X_W-1:0] ui_in,
    output logic [7:0]     uo_out,

    // Host handshake (subset of uio)
    input  logic           host_tx_valid,    // host has a byte on ui_in
    input  logic           host_rx_ready,    // host can accept a byte on uo_out
    output logic           chip_rx_ready,    // chip can take this cycle's byte
    output logic           chip_tx_valid,    // chip has a byte on uo_out
    output logic           busy,
    output logic           err_sticky,
    output logic [3:0]     state_dbg,

    // sign_lfsr port
    output logic           lfsr_start,
    input  logic           lfsr_valid,
    input  logic           lfsr_sign_bit,

    // wht64 port
    output logic           wht_start,
    output logic           wht_replay_start,
    input  logic           wht_busy,
    input  logic           wht_ready,
    output logic           wht_in_valid,
    input  logic           wht_in_ready,
    output logic signed [X_W-1:0] wht_x_in,
    output logic           wht_x_sign,
    input  logic           wht_out_valid,
    input  logic signed [Y_W-1:0] wht_y_out,
    input  logic           wht_out_last,

    // norm2_acc port
    output logic           n2_clear,
    output logic           n2_in_valid,
    output logic signed [Y_W-1:0] n2_y_in,
    input  logic           n2_done,
    input  logic [N2_W-1:0] n2_norm2,

    // rsqrt_unit port
    output logic           rs_in_valid,
    output logic [N2_W-1:0] rs_norm2,
    input  logic           rs_out_valid,
    input  logic [INV_W-1:0] rs_inv_norm,
    input  logic [NORM_W-1:0] rs_norm_int,

    // quant_unit port
    output logic           q_in_valid,
    output logic signed [Y_W-1:0] q_y_i,
    output logic [INV_W-1:0] q_inv_norm,
    input  logic           q_out_valid,
    input  logic [IDX_W-1:0] q_idx_out,

    // bit_packer port
    output logic           bp_clear,
    output logic           bp_idx_valid,
    output logic [IDX_W-1:0] bp_idx,
    input  logic           bp_byte_valid,
    input  logic [7:0]     bp_out_byte,
    input  logic           bp_last_byte
);

    typedef enum logic [3:0] {
        S_IDLE   = 4'd0,
        S_RX_X   = 4'd1,
        S_WAIT_C = 4'd2,
        S_NORM2  = 4'd3,
        S_RSQRT  = 4'd4,
        S_QUANT  = 4'd5,
        S_TX     = 4'd6,
        S_DONE   = 4'd7,
        S_ERR    = 4'hF
    } state_e;

    state_e          state, next_state;
    logic [$clog2(D + 1)-1:0]      rx_count;
    logic [$clog2(D + 1)-1:0]      stream_count;
    logic [INV_W-1:0]              inv_norm_q;
    logic [NORM_W-1:0]             norm_q;
    logic [4:0]                    tx_byte_count;       // 0..25
    logic [7:0]                    norm_buf [2];        // norm bytes for tx
    logic [7:0]                    idx_byte_buf [24];   // packed idx bytes
    logic [4:0]                    idx_byte_wptr;

    // Sticky pulse latches generated in always_ff (decoupled from
    // next_state to avoid iverilog cross-block delta hangs).
    logic                          lfsr_start_q;
    logic                          wht_start_q;
    logic                          wht_replay_start_q;
    logic                          rs_in_valid_q;
    logic [7:0]                    tx_uo_q;
    logic [4:0]                    tx_idx;

    assign busy      = (state != S_IDLE);
    assign state_dbg = state;

    // ------------------------------------------------------------------
    // Default outputs (each state overrides as needed)
    //
    // Pulse signals (lfsr_start, wht_start, wht_replay_start, n2_clear,
    // bp_clear, rs_in_valid) are level-asserted across an entire FSM
    // state instead of one-cycle-transition pulses, because iverilog has
    // trouble settling combinational chains that cross-reference
    // ``next_state`` from a different always @* block. The downstream
    // FSMs (wht64, norm2_acc, rsqrt_unit, bit_packer) handle multi-cycle
    // strobes correctly (they either latch on first valid or auto-clear).
    // ------------------------------------------------------------------
    // Explicit sensitivity list — iverilog's auto-sensitivity in @* /
    // always_comb deadlocks on this block (likely a settling-order issue
    // around the unpacked-array bp_out_byte / q_idx_out feed-in).
    always @(state or lfsr_start_q or wht_start_q or wht_replay_start_q or
             rs_in_valid_q or inv_norm_q or n2_norm2 or wht_in_ready or
             lfsr_valid or wht_out_valid or wht_y_out or q_out_valid or
             q_idx_out or ui_in or lfsr_sign_bit or host_tx_valid or
             tx_uo_q) begin
        lfsr_start = lfsr_start_q;
        // wht64
        wht_start         = wht_start_q;
        wht_replay_start  = wht_replay_start_q;
        wht_in_valid      = 1'b0;
        wht_x_in          = '0;
        wht_x_sign        = 1'b1;
        // norm2_acc
        n2_clear     = 1'b0;   // TODO bring back state-based clear
        n2_in_valid  = 1'b0;
        n2_y_in      = '0;
        // rsqrt
        rs_in_valid  = rs_in_valid_q;
        rs_norm2     = n2_norm2;
        // quant
        q_in_valid   = 1'b0;
        q_y_i        = '0;
        q_inv_norm   = inv_norm_q;
        // bit_packer
        bp_clear     = 1'b0;   // TODO bring back state-based clear
        bp_idx_valid = 1'b0;
        bp_idx       = '0;
        // host handshake
        chip_rx_ready = 1'b0;
        chip_tx_valid = 1'b0;
        uo_out        = '0;

        case (state)
            S_IDLE: begin
                // chip_rx_ready stays 0 in IDLE — wht/lfsr aren't ready yet,
                // so latching a byte here would drop it. Host should hold
                // valid=1 with the first byte until ready goes high in RX_X.
                chip_rx_ready = 1'b0;
            end

            S_RX_X: begin
                chip_rx_ready = wht_in_ready && lfsr_valid;
                if (host_tx_valid && chip_rx_ready) begin
                    wht_in_valid = 1'b1;
                    wht_x_in     = $signed(ui_in);
                    wht_x_sign   = lfsr_sign_bit;
                end
            end

            S_NORM2: begin
                if (wht_out_valid) begin
                    n2_in_valid = 1'b1;
                    n2_y_in     = wht_y_out;
                    // Also feed bit_packer's clear path here.
                end
            end

            S_RSQRT: begin
                // rsqrt has been kicked at the boundary; just wait.
            end

            S_QUANT: begin
                if (wht_out_valid) begin
                    q_in_valid = 1'b1;
                    q_y_i      = wht_y_out;
                end
                if (q_out_valid) begin
                    bp_idx_valid = 1'b1;
                    bp_idx       = q_idx_out;
                end
            end

            S_TX: begin
                chip_tx_valid = 1'b1;
                uo_out        = tx_uo_q;
            end

            default: ;
        endcase
    end

    // S_TX byte-stream output. The byte to emit is selected combinationally
    // (continuous assign) and registered into ``tx_uo_q`` in the seq block;
    // the main comb block then just drives ``uo_out = tx_uo_q`` in S_TX.
    // This avoids variable-index unpacked-array reads inside an always @*,
    // which deadlock iverilog's auto-sensitivity at t=0.
    assign tx_idx = (tx_byte_count >= 5'd2) ? (tx_byte_count - 5'd2) : 5'd0;

    // ------------------------------------------------------------------
    // FSM transitions
    // ------------------------------------------------------------------
    always @* begin
        next_state = state;
        case (state)
            S_IDLE: begin
                if (ena && host_tx_valid) next_state = S_RX_X;
            end
            S_RX_X: begin
                if (host_tx_valid && wht_in_ready && lfsr_valid &&
                    rx_count == ($clog2(D + 1))'(D - 1))
                    next_state = S_WAIT_C;
            end
            S_WAIT_C: if (wht_ready) next_state = S_NORM2;
            S_NORM2:  if (n2_done)   next_state = S_RSQRT;
            S_RSQRT:  if (rs_out_valid) next_state = S_QUANT;
            S_QUANT:  if (bp_last_byte) next_state = S_TX;
            S_TX:     if (tx_byte_count == 5'd25 && host_rx_ready)
                          next_state = S_DONE;
            S_DONE:   next_state = S_IDLE;
            default:  next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= S_IDLE;
            rx_count           <= '0;
            stream_count       <= '0;
            tx_byte_count      <= '0;
            inv_norm_q         <= '0;
            norm_q             <= '0;
            idx_byte_wptr      <= '0;
            err_sticky         <= 1'b0;
            lfsr_start_q       <= 1'b0;
            wht_start_q        <= 1'b0;
            wht_replay_start_q <= 1'b0;
            rs_in_valid_q      <= 1'b0;
            tx_uo_q            <= '0;
            for (int i = 0; i < 2;  i++) norm_buf[i]     <= '0;
            for (int i = 0; i < 24; i++) idx_byte_buf[i] <= '0;
        end else begin
            state <= next_state;

            // Edge-driven pulse latches: pulse for ONE cycle when the
            // FSM enters specific states. Decoupled from next_state via
            // the registered ``state`` to avoid the iverilog hang.
            lfsr_start_q       <= (state == S_IDLE && next_state == S_RX_X);
            wht_start_q        <= (state == S_IDLE && next_state == S_RX_X);
            wht_replay_start_q <= ((state == S_WAIT_C && next_state == S_NORM2)
                                || (state == S_RSQRT && next_state == S_QUANT));
            rs_in_valid_q      <= (state == S_NORM2 && next_state == S_RSQRT);

            // Registered tx byte: avoids variable-index reads in always @*.
            if (state == S_TX) begin
                if (tx_byte_count < 5'd2)
                    tx_uo_q <= norm_buf[tx_byte_count[0]];
                else
                    tx_uo_q <= idx_byte_buf[tx_idx];
            end else begin
                tx_uo_q <= '0;
            end

            // Edge-driven side effects per transition.
            case (state)
                S_IDLE: begin
                    rx_count      <= '0;
                    stream_count  <= '0;
                    tx_byte_count <= '0;
                    idx_byte_wptr <= '0;
                    if (next_state == S_RX_X) begin
                        // pulse lfsr_start at entry of RX_X
                    end
                end
                S_RX_X: begin
                    if (host_tx_valid && wht_in_ready && lfsr_valid)
                        rx_count <= rx_count + 1'b1;
                end
                S_NORM2: begin
                    if (wht_out_valid) stream_count <= stream_count + 1'b1;
                end
                S_QUANT: begin
                    if (bp_byte_valid && idx_byte_wptr < 5'd24) begin
                        idx_byte_buf[idx_byte_wptr] <= bp_out_byte;
                        idx_byte_wptr <= idx_byte_wptr + 1'b1;
                    end
                end
                S_TX: begin
                    if (host_rx_ready) tx_byte_count <= tx_byte_count + 1'b1;
                end
                default: ;
            endcase

            // Latch rsqrt result and reported norm.
            if (rs_out_valid) begin
                inv_norm_q <= rs_inv_norm;
                norm_q     <= rs_norm_int;
            end

            // After idx capture, format norm_buf for tx.
            if (state == S_QUANT && bp_last_byte) begin
                norm_buf[0] <= 8'(norm_q[NORM_W-1 -: 8]);
                norm_buf[1] <= 8'({{(8 - (NORM_W - 8)){1'b0}}, norm_q[NORM_W-9:0]});
            end
        end
    end

endmodule

`default_nettype wire
