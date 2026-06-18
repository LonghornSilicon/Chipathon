// tb_norm2_acc.sv
//
// Self-checking testbench for norm2_acc.sv. Streams the 64 post-WHT
// integers from ``vec_<id>_y.hex`` in over 64 cycles, then compares the
// final accumulator against ``vec_<id>_norm2.hex``.

`timescale 1ns/1ps
`default_nettype none

module tb_norm2_acc;
    localparam int D    = 64;
    localparam int Y_W  = 14;
    localparam int N2_W = 32;

    logic clk = 0;
    logic rst_n = 0;
    logic clear = 0;
    logic in_valid = 0;
    logic signed [Y_W-1:0] y_in = '0;
    logic               done;
    logic [N2_W-1:0]    norm2_q;

    norm2_acc #(.D(D), .Y_W(Y_W), .N2_W(N2_W)) dut (
        .clk(clk), .rst_n(rst_n), .clear(clear),
        .in_valid(in_valid), .y_in(y_in),
        .done(done), .norm2_q(norm2_q)
    );

    always #5 clk = ~clk;

    int    vec_id = 0;
    string yfile, nfile;
    logic [Y_W-1:0]   y     [D];
    logic [N2_W-1:0]  ref_n [1];
    int errors = 0;
    int done_count = 0;

    initial begin
        if (!$value$plusargs("vec=%d", vec_id)) vec_id = 0;
        $sformat(yfile, "../../tb/golden/out/vec_%03d_y.hex", vec_id);
        $sformat(nfile, "../../tb/golden/out/vec_%03d_norm2.hex", vec_id);
        $readmemh(yfile, y);
        $readmemh(nfile, ref_n);

        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;

        clear <= 1; @(posedge clk); clear <= 0;

        for (int i = 0; i < D; i++) begin
            y_in <= $signed(y[i]);
            in_valid <= 1'b1;
            @(posedge clk);
        end
        in_valid <= 1'b0;

        // Wait several cycles for done to register and TB always_ff to count it.
        repeat (4) @(posedge clk);

        if (done_count != 1) begin
            $display("[FAIL] done pulsed %0d times (expected 1)", done_count);
            errors = errors + 1;
        end
        if (norm2_q !== ref_n[0]) begin
            $display("[FAIL] norm2 rtl=0x%08h ref=0x%08h", norm2_q, ref_n[0]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[PASS] norm2_acc vec=%0d  norm2=0x%08h", vec_id, norm2_q);
        else
            $display("[FAIL] norm2_acc vec=%0d  %0d errors", vec_id, errors);
        $finish(errors == 0 ? 0 : 1);
    end

    always_ff @(posedge clk) begin
        if (rst_n && done) done_count = done_count + 1;
    end

    initial begin #10000 $display("[FAIL] norm2_acc timeout"); $finish(1); end

endmodule

`default_nettype wire
