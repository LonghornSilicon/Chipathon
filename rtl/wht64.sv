// wht64.sv
//
// Walsh-Hadamard transform engine. Loads d=64 signed input bytes one
// per cycle, applies an in-place radix-2 WHT (6 stages of 32 butterflies
// each = 192 butterfly cycles), then streams out d=64 transformed
// values one per cycle. Supports multi-pass output via ``replay_start``
// so the controller can read y twice — once into norm2_acc and once,
// after rsqrt produces inv_norm, into quant_unit.
//
// Algorithm matches ``tb/golden/wht.py``:
//
//   for stage in 0..log2(d)-1:
//     h = 1 << stage
//     for pair in 0..d/2-1:
//       i_lo = pair % h
//       i_hi = (pair / h) * 2h
//       a_idx = i_hi | i_lo
//       b_idx = a_idx | h
//       a = mem[a_idx]; b = mem[b_idx]
//       mem[a_idx] = a + b
//       mem[b_idx] = a - b
//
// Storage is a 64-entry register file with two read ports and two
// write ports. At d=64, b=14 this is 64 * 14 = 896 flops, comfortably
// within a 1 TT-tile budget.
//
// FSM phases:
//   IDLE        -> waiting for ``start`` or ``replay_start``
//   LOAD        -> 64 cycles, write x_in into mem[0..63]; the LFSR
//                  flips signs on the way in
//   COMPUTE     -> 192 butterfly cycles
//   READY       -> compute done; mem holds y; waiting for stream req
//   STREAM      -> 64 cycles, read mem[0..63] out as ``y_out``; ``last``
//                  pulses with the 64th
// After STREAM, returns to READY (not IDLE), so a subsequent
// ``replay_start`` pulse triggers another stream pass over the same y.

`timescale 1ns/1ps
`default_nettype none

module wht64 #(
    parameter int D     = 64,
    parameter int X_W   = 8,        // signed input width
    parameter int Y_W   = 14,       // signed internal/output width
    parameter int LOG2D = 6
) (
    input  logic                clk,
    input  logic                rst_n,

    // Control
    input  logic                start,         // pulse to begin LOAD phase
    input  logic                replay_start,  // pulse to re-stream the existing y
    output logic                busy,          // high from start until READY/IDLE
    output logic                ready,         // high while in READY (mem holds y)

    // Input stream (LOAD phase). Caller drives ``x_in`` and ``x_sign``
    // for D consecutive cycles when ``in_ready`` is high. ``x_sign`` is
    // the LFSR bit (0 -> negate; 1 -> keep), produced by sign_lfsr.
    output logic                in_ready,
    input  logic                in_valid,
    input  logic signed [X_W-1:0] x_in,
    input  logic                x_sign,    // 1 keeps; 0 negates

    // Output stream (STREAM phase).
    output logic                out_valid,
    output logic signed [Y_W-1:0] y_out,
    output logic                out_last
);

    localparam int CW   = $clog2(D + 1);              // 7 for D=64
    localparam int SW   = $clog2(LOG2D + 1);          // 3 for 6 stages
    localparam int PW   = $clog2(D / 2);              // 5 for 32 pairs

    // ------------------------------------------------------------------
    // Storage: 64 × Y_W register file with two combinational read ports
    // and two write ports (one paired write per cycle in COMPUTE).
    // ------------------------------------------------------------------
    logic signed [Y_W-1:0] mem [D];

    // Two read addresses + two write addresses + write-enable.
    logic [CW-1:0]          rd_a, rd_b;
    logic [CW-1:0]          wr_a, wr_b;
    logic                   wr_a_en, wr_b_en;
    logic signed [Y_W-1:0]  wr_a_data, wr_b_data;

    logic signed [Y_W-1:0]  rd_a_data, rd_b_data;
    assign rd_a_data = mem[rd_a];
    assign rd_b_data = mem[rd_b];

    always_ff @(posedge clk) begin
        if (wr_a_en) mem[wr_a] <= wr_a_data;
        if (wr_b_en) mem[wr_b] <= wr_b_data;
    end

    // ------------------------------------------------------------------
    // Control FSM
    // ------------------------------------------------------------------
    typedef enum logic [2:0] {
        S_IDLE    = 3'd0,
        S_LOAD    = 3'd1,
        S_COMPUTE = 3'd2,
        S_READY   = 3'd3,
        S_STREAM  = 3'd4
    } state_e;

    state_e         state, next_state;
    logic [CW-1:0]  load_idx;
    logic [SW-1:0]  stage;
    logic [PW:0]    pair;          // 0..32; we exit when pair == D/2
    logic [CW-1:0]  stream_idx;

    assign busy  = (state != S_IDLE) && (state != S_READY);
    assign ready = (state == S_READY);

    // ------------------------------------------------------------------
    // Address generation for COMPUTE: at stage k, h = 1 << k.
    //   a_idx = ((pair >> k) << (k + 1)) | (pair & ((1 << k) - 1))
    //   b_idx = a_idx | (1 << k)
    // ------------------------------------------------------------------
    logic [CW-1:0]  a_idx, b_idx;
    logic [CW-1:0]  h_lo_mask;
    logic [CW-1:0]  h;

    always_comb begin
        h         = CW'(1) << stage;
        h_lo_mask = h - CW'(1);
        a_idx     = (CW'(pair) >> stage) << (stage + 1) | (CW'(pair) & h_lo_mask);
        b_idx     = a_idx | h;
    end

    // ------------------------------------------------------------------
    // FSM combinational
    // ------------------------------------------------------------------
    logic compute_last_pair;
    logic compute_last_stage;
    assign compute_last_pair  = (pair == PW'(D / 2 - 1));
    assign compute_last_stage = (stage == SW'(LOG2D - 1));

    always_comb begin
        next_state = state;
        case (state)
            S_IDLE:    if (start)    next_state = S_LOAD;
            S_LOAD:    if (in_valid && load_idx == CW'(D - 1)) next_state = S_COMPUTE;
            S_COMPUTE: if (compute_last_pair && compute_last_stage) next_state = S_READY;
            S_READY:   if (start)         next_state = S_LOAD;
                       else if (replay_start) next_state = S_STREAM;
            S_STREAM:  if (stream_idx == CW'(D - 1)) next_state = S_READY;
            default:   next_state = S_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Read/write ports as a function of state
    // ------------------------------------------------------------------
    logic signed [Y_W-1:0] load_data;
    logic signed [Y_W-1:0] x_in_ext;
    // Sign-extend x_in to Y_W then conditionally negate per x_sign.
    // Continuous assigns (not always_comb) sidestep iverilog's
    // "constant select sensitivity" warning on part-selects, which can
    // cause the comb settle to hang at t=0.
    assign x_in_ext = {{(Y_W - X_W){x_in[X_W-1]}}, x_in};
    assign load_data = x_sign ? x_in_ext : -x_in_ext;

    always_comb begin
        rd_a = '0; rd_b = '0;
        wr_a = '0; wr_b = '0;
        wr_a_data = '0; wr_b_data = '0;
        wr_a_en = 1'b0; wr_b_en = 1'b0;
        in_ready  = 1'b0;
        out_valid = 1'b0;
        out_last  = 1'b0;
        y_out     = '0;

        case (state)
            S_LOAD: begin
                in_ready = 1'b1;
                if (in_valid) begin
                    wr_a       = load_idx;
                    wr_a_data  = load_data;
                    wr_a_en    = 1'b1;
                end
            end

            S_COMPUTE: begin
                rd_a = a_idx;
                rd_b = b_idx;
                wr_a = a_idx;
                wr_b = b_idx;
                wr_a_data = rd_a_data + rd_b_data;
                wr_b_data = rd_a_data - rd_b_data;
                wr_a_en   = 1'b1;
                wr_b_en   = 1'b1;
            end

            S_STREAM: begin
                rd_a      = stream_idx;
                y_out     = rd_a_data;
                out_valid = 1'b1;
                out_last  = (stream_idx == CW'(D - 1));
            end

            default: ;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential state and counters
    // ------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            load_idx   <= '0;
            stage      <= '0;
            pair       <= '0;
            stream_idx <= '0;
        end else begin
            state <= next_state;

            // LOAD index advances on every accepted input.
            if (state == S_LOAD && in_valid) begin
                if (load_idx == CW'(D - 1))
                    load_idx <= '0;
                else
                    load_idx <= load_idx + 1'b1;
            end else if (state == S_IDLE && start) begin
                load_idx <= '0;
            end

            // COMPUTE counters.
            if (state == S_COMPUTE) begin
                if (compute_last_pair) begin
                    pair  <= '0;
                    stage <= compute_last_stage ? '0 : (stage + 1'b1);
                end else begin
                    pair <= pair + 1'b1;
                end
            end else if (next_state == S_COMPUTE && state == S_LOAD) begin
                stage <= '0;
                pair  <= '0;
            end

            // STREAM index.
            if (state == S_STREAM) begin
                if (stream_idx == CW'(D - 1))
                    stream_idx <= '0;
                else
                    stream_idx <= stream_idx + 1'b1;
            end else if (next_state == S_STREAM) begin
                stream_idx <= '0;
            end
        end
    end

endmodule

`default_nettype wire
