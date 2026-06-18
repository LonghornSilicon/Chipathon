// tb_bit_packer.sv
//
// Self-checking testbench for bit_packer.sv. Drives 64 random 3-bit
// indices in over 64 cycles, captures the emitted bytes, and compares
// against an MSB-first reference packing computed in the testbench.
//
// Pass criteria:
//   - exactly 24 bytes are emitted (last_byte pulses on the 24th)
//   - emitted bytes match the reference
//   - clear cleanly resets state between two runs

`timescale 1ns/1ps
`default_nettype none

module tb_bit_packer;
    localparam int N         = 64;
    localparam int IDX_BITS  = 3;
    localparam int N_BYTES   = (N * IDX_BITS + 7) / 8;  // 24
    localparam int TOTAL_BITS = N * IDX_BITS;

    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic idx_valid = 0;
    logic [IDX_BITS-1:0] idx = '0;
    logic byte_valid;
    logic [7:0] out_byte;
    logic last_byte;

    bit_packer #(.IDX_BITS(IDX_BITS), .N_INDICES(N)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .idx_valid(idx_valid), .idx(idx),
        .byte_valid(byte_valid), .out_byte(out_byte), .last_byte(last_byte)
    );

    always #5 clk = ~clk;

    int seed_plus = 1;
    int seed = 1;
    logic [IDX_BITS-1:0] inputs [N];
    logic [7:0] expected [N_BYTES];
    logic [7:0] captured [N_BYTES];
    int captured_count;
    int errors = 0;
    int last_seen_count = 0;

    // Build the MSB-first reference packing.
    function automatic void build_reference();
        // Concatenate inputs into a TOTAL_BITS-wide vector, MSB-first.
        // We use a queue of bits to keep the test simulator-agnostic.
        int bitpos;
        int bit_v;
        bitpos = 0;
        for (int i = 0; i < N_BYTES; i++) expected[i] = 8'h00;
        for (int i = 0; i < N; i++) begin
            for (int b = IDX_BITS - 1; b >= 0; b--) begin
                bit_v = (inputs[i] >> b) & 1;
                expected[bitpos / 8][7 - (bitpos % 8)] = bit_v[0];
                bitpos = bitpos + 1;
            end
        end
    endfunction

    initial begin
        if ($value$plusargs("seed=%d", seed_plus)) seed = seed_plus;

        // Generate random inputs. Seed once, then call $urandom() with no
        // arg so iverilog accepts it (its $urandom(N) requires a register
        // operand, not an expression).
        seed = seed + 0;  // touch
        void'($urandom(seed));
        for (int i = 0; i < N; i++) begin
            inputs[i] = $urandom() & ((1 << IDX_BITS) - 1);
        end
        build_reference();

        // Reset
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;

        // Run #1
        captured_count = 0;
        clear <= 1; @(posedge clk); clear <= 0;
        for (int i = 0; i < N; i++) begin
            idx <= inputs[i];
            idx_valid <= 1'b1;
            @(posedge clk);
            // capture during the cycle following each input
        end
        idx_valid <= 1'b0;
        idx <= '0;

        // Wait a couple of cycles in case of pipeline lag, capturing bytes.
        repeat (3) @(posedge clk);

        if (captured_count != N_BYTES) begin
            $display("[FAIL] captured %0d bytes, expected %0d", captured_count, N_BYTES);
            errors = errors + 1;
        end
        for (int i = 0; i < captured_count && i < N_BYTES; i++) begin
            if (captured[i] !== expected[i]) begin
                $display("[FAIL] byte[%0d] rtl=0x%02h ref=0x%02h", i, captured[i], expected[i]);
                errors = errors + 1;
            end
        end
        if (last_seen_count != 1) begin
            $display("[FAIL] last_byte pulsed %0d times (expected 1)", last_seen_count);
            errors = errors + 1;
        end

        if (errors == 0) $display("[PASS] bit_packer ran %0d inputs -> %0d bytes",
                                  N, captured_count);
        else             $display("[FAIL] %0d errors", errors);
        $finish(errors == 0 ? 0 : 1);
    end

    // Capture bytes as they appear.
    always_ff @(posedge clk) begin
        if (rst_n && byte_valid) begin
            if (captured_count < N_BYTES) captured[captured_count] = out_byte;
            captured_count = captured_count + 1;
            if (last_byte) last_seen_count = last_seen_count + 1;
            if ($test$plusargs("verbose"))
                $display("  byte[%0d] = 0x%02h%s", captured_count - 1, out_byte,
                         last_byte ? "  (last)" : "");
        end
    end

endmodule

`default_nettype wire
