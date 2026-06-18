// tb_wht64.sv
//
// Self-checking testbench for wht64.sv. Loads a stimulus vector
// ``vec_<id>_x.hex`` plus the LFSR sign sequence ``signs.mem`` from
// tb/golden/out/, drives them into the DUT, and compares the streamed
// output against the golden ``vec_<id>_y.hex`` (post-WHT integer y,
// saturated to Y_W).
//
// Pick the vector with +vec=N (default 0). +verbose prints all 64
// values; otherwise only mismatches are printed.

`timescale 1ns/1ps
`default_nettype none

module tb_wht64;
    localparam int D    = 64;
    localparam int X_W  = 8;
    localparam int Y_W  = 14;

    logic clk = 0;
    logic rst_n = 0;
    logic start = 0;
    logic replay_start = 0;
    logic in_valid = 0;
    logic [X_W-1:0] x_in = '0;
    logic           x_sign = 1'b1;
    logic in_ready;
    logic busy;
    logic ready;
    logic out_valid;
    logic signed [Y_W-1:0] y_out;
    logic out_last;

    wht64 #(.D(D), .X_W(X_W), .Y_W(Y_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .replay_start(replay_start), .busy(busy), .ready(ready),
        .in_ready(in_ready), .in_valid(in_valid),
        .x_in($signed(x_in)), .x_sign(x_sign),
        .out_valid(out_valid), .y_out(y_out), .out_last(out_last)
    );

    always #5 clk = ~clk;

    int    vec_id = 0;
    string xfile, yfile;

    logic [X_W-1:0]        x [D];
    logic [Y_W-1:0]        y_expected [D];
    logic [0:0]            signs [D];
    logic [Y_W-1:0]        y_captured [D];
    int    capture_idx = 0;
    int    last_seen = 0;
    int    errors = 0;

    initial begin
        if (!$value$plusargs("vec=%d", vec_id)) vec_id = 0;
        $sformat(xfile, "../../tb/golden/out/vec_%03d_x.hex", vec_id);
        $sformat(yfile, "../../tb/golden/out/vec_%03d_y.hex", vec_id);
        $readmemh(xfile, x);
        $readmemh(yfile, y_expected);
        $readmemh("../../tb/golden/out/signs.mem", signs);

        // Reset
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Pulse start, then drive 64 inputs.
        start <= 1; @(posedge clk); start <= 0;

        for (int i = 0; i < D; i++) begin
            // Wait for in_ready, then drive one byte + sign.
            while (!in_ready) @(posedge clk);
            x_in    <= x[i];
            x_sign  <= signs[i][0];
            in_valid <= 1'b1;
            @(posedge clk);
        end
        in_valid <= 1'b0;
        x_in     <= '0;

        // Wait for COMPUTE to finish (ready goes high in S_READY).
        while (!ready) @(posedge clk);
        // Trigger first stream pass.
        replay_start <= 1'b1;
        @(posedge clk);
        replay_start <= 1'b0;

        // Wait for the 64 outputs to stream out.
        while (capture_idx < D) @(posedge clk);

        // Compare
        for (int i = 0; i < D; i++) begin
            if (y_captured[i] !== y_expected[i]) begin
                $display("[FAIL] y[%0d] rtl=0x%0h ref=0x%0h",
                         i, y_captured[i], y_expected[i]);
                errors = errors + 1;
            end
            if ($test$plusargs("verbose")) begin
                $display("  y[%0d] rtl=0x%0h ref=0x%0h", i, y_captured[i], y_expected[i]);
            end
        end
        if (last_seen != 1) begin
            $display("[FAIL] out_last pulsed %0d times (expected 1)", last_seen);
            errors = errors + 1;
        end

        if (errors == 0) $display("[PASS] wht64 vec=%0d (%0d outputs match)", vec_id, D);
        else             $display("[FAIL] wht64 vec=%0d (%0d errors)", vec_id, errors);
        $finish(errors == 0 ? 0 : 1);
    end

    always_ff @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (capture_idx < D) y_captured[capture_idx] = y_out[Y_W-1:0];
            capture_idx = capture_idx + 1;
            if (out_last) last_seen = last_seen + 1;
        end
    end

    initial begin
        // Generous overall timeout: load(64) + compute(192) + stream(64) + slack.
        #10000 $display("[FAIL] wht64 timeout"); $finish(1);
    end

endmodule

`default_nettype wire
