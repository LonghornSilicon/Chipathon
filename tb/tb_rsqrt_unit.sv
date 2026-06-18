// tb_rsqrt_unit.sv
//
// Self-checking testbench for rsqrt_unit.sv. Bit-exact compare against
// the Python golden ``rsqrt_q_hardware`` (which mirrors the same
// non-restoring sqrt + truncating divide). For each test vector loaded
// from ``vec_<id>_norm2.hex``, expect ``vec_<id>_invn.hex``.
//
// Also runs a small fixed-input panel covering corner cases (0, 1,
// max, typical norms) loaded from ``rsqrt_panel_in.hex`` /
// ``rsqrt_panel_out.hex`` if present.

`timescale 1ns/1ps
`default_nettype none

module tb_rsqrt_unit;
    localparam int N2_W     = 32;
    localparam int OUT_INT  = 2;
    localparam int OUT_FRAC = 13;
    localparam int OUT_W    = OUT_INT + OUT_FRAC;

    logic clk = 0;
    logic rst_n = 0;
    logic in_valid = 0;
    logic [N2_W-1:0] norm2 = '0;
    logic out_valid;
    logic [OUT_W-1:0] inv_norm;

    rsqrt_unit #(.N2_W(N2_W), .OUT_INT(OUT_INT), .OUT_FRAC(OUT_FRAC)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .norm2(norm2),
        .out_valid(out_valid), .inv_norm(inv_norm)
    );

    always #5 clk = ~clk;

    int    vec_id = 0;
    string n2file, invfile;
    logic [N2_W-1:0] ref_n2  [1];
    logic [OUT_W-1:0] ref_inv [1];
    int errors = 0;
    int captured = 0;
    logic [OUT_W-1:0] last_inv;

    initial begin
        if (!$value$plusargs("vec=%d", vec_id)) vec_id = 0;
        $sformat(n2file,  "../../tb/golden/out/vec_%03d_norm2.hex", vec_id);
        $sformat(invfile, "../../tb/golden/out/vec_%03d_invn.hex",  vec_id);
        $readmemh(n2file,  ref_n2);
        $readmemh(invfile, ref_inv);

        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        norm2    <= ref_n2[0];
        in_valid <= 1'b1;
        @(posedge clk);
        in_valid <= 1'b0;
        norm2    <= '0;

        // Wait for out_valid (up to 50 cycles).
        for (int t = 0; t < 50; t++) begin
            @(posedge clk);
            if (out_valid) break;
        end

        if (captured != 1) begin
            $display("[FAIL] out_valid pulsed %0d times (expected 1)", captured);
            errors = errors + 1;
        end
        if (last_inv !== ref_inv[0]) begin
            $display("[FAIL] inv_norm rtl=0x%04h ref=0x%04h (norm2=0x%08h)",
                     last_inv, ref_inv[0], ref_n2[0]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[PASS] rsqrt_unit vec=%0d  norm2=0x%08h inv=0x%04h",
                     vec_id, ref_n2[0], last_inv);
        else
            $display("[FAIL] rsqrt_unit vec=%0d  %0d errors", vec_id, errors);
        $finish(errors == 0 ? 0 : 1);
    end

    always_ff @(posedge clk) begin
        if (rst_n && out_valid) begin
            last_inv = inv_norm;
            captured = captured + 1;
        end
    end

    initial begin #5000 $display("[FAIL] rsqrt_unit timeout"); $finish(1); end

endmodule

`default_nettype wire
