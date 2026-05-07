// tb_act_lut.sv
//
// Self-checking Verilator testbench for rtl/act_lut.sv. Default FUNC
// is FUNC_EXP_NEG (0); the TB hard-codes the expected 16 entries it
// computes the same way as the DUT does at elaboration.

`timescale 1ns/1ps
`default_nettype none

module tb_act_lut;

    localparam int IN_W      = 8;
    localparam int OUT_W     = 8;
    localparam int N_ENTRIES = 16;
    localparam int FUNC      = 0;       // 0 = FUNC_EXP_NEG
    localparam int IDX_W     = $clog2(N_ENTRIES);

    logic                       clk;
    logic                       rst_n;
    logic                       enable_i;
    logic                       valid_i;
    logic                       ready_o;
    logic signed [IN_W-1:0]     data_i;
    logic                       valid_o;
    logic                       ready_i;
    logic signed [OUT_W-1:0]    data_o;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    act_lut #(
        .IN_W      (IN_W),
        .OUT_W     (OUT_W),
        .N_ENTRIES (N_ENTRIES),
        .FUNC      (FUNC)
    ) dut (
        .clk      (clk),
        .rst_n    (rst_n),
        .enable_i (enable_i),
        .valid_i  (valid_i),
        .ready_o  (ready_o),
        .data_i   (data_i),
        .valid_o  (valid_o),
        .ready_i  (ready_i),
        .data_o   (data_o)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    // Reference LUT: same math as the DUT's lut_value().
    logic signed [OUT_W-1:0] ref_lut [N_ENTRIES];
    initial begin
        real x, y;
        int signed_bin;
        for (int k = 0; k < N_ENTRIES; k++) begin
            signed_bin = k - (N_ENTRIES/2);
            x = real'(signed_bin) / 2.0;
            y = 127.0 * $exp(-x);
            if (y >  127.0) y =  127.0;
            if (y < -128.0) y = -128.0;
            ref_lut[k] = OUT_W'(int'(y));
        end
    end

    function automatic logic [IDX_W-1:0] ref_idx (input logic signed [IN_W-1:0] d);
        return {~d[IN_W-1], d[IN_W-2 -: IDX_W-1]};
    endfunction

    task automatic apply_reset(input int n_cycles = 4);
        rst_n    = 1'b0;
        enable_i = 1'b1;
        valid_i  = 1'b0;
        data_i   = '0;
        ready_i  = 1'b1;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic do_op (
        input  logic                    en,
        input  logic signed [IN_W-1:0]  d,
        output logic signed [OUT_W-1:0] got
    );
        enable_i = en;
        valid_i  = 1'b1;
        data_i   = d;
        ready_i  = 1'b1;
        @(posedge clk);
        valid_i = 1'b0;
        @(posedge clk);
        got = data_o;
    endtask

    task automatic check_op (
        input logic                    en,
        input logic signed [IN_W-1:0]  d,
        input logic signed [OUT_W-1:0] exp_data,
        input string                   msg
    );
        logic signed [OUT_W-1:0] got;
        do_op(en, d, got);
        check_count++;
        if (got !== exp_data) begin
            err_count++;
            $error("[%0t] %s: en=%0b d=%0d expected %0d got %0d",
                   $time, msg, en, d, exp_data, got);
        end else if (verbose) begin
            $display("[%0t] %s: en=%0b d=%0d OK (=%0d)", $time, msg, en, d, got);
        end
    endtask

    initial begin : main
        int seed_val;
        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_act_lut] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);
        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_act_lut);
            $display("[tb_act_lut] tracing to waves.fst");
        end

        $display("[tb_act_lut] starting");
        apply_reset();

        // Bypass mode covers the full INT8 range; output equals input.
        check_op(1'b0,  8'sd0,    8'sd0,    "bypass 0");
        check_op(1'b0,  8'sd42,   8'sd42,   "bypass +42");
        check_op(1'b0, -8'sd42,  -8'sd42,   "bypass -42");
        check_op(1'b0,  8'sd127,  8'sd127,  "bypass +127");
        check_op(1'b0, -8'sd128, -8'sd128,  "bypass -128");

        // LUT mode: spot-check every index by feeding bin*16 (so
        // upper 4 bits == bin), reference table holds the expected.
        for (int k = 0; k < N_ENTRIES; k++) begin
            automatic int bin       = k - (N_ENTRIES/2);
            automatic logic signed [IN_W-1:0] d = IN_W'(bin << 4);
            check_op(1'b1, d, ref_lut[k],
                     $sformatf("lut bin=%0d (k=%0d)", bin, k));
        end

        // exp_neg should be monotonically decreasing across bins, with
        // bin=-8 saturating near +127 and bin=+7 near 0.
        check_count++;
        if (ref_lut[0] < ref_lut[N_ENTRIES-1]) begin
            err_count++;
            $error("exp_neg LUT not monotonic decreasing: lut[0]=%0d lut[15]=%0d",
                   ref_lut[0], ref_lut[N_ENTRIES-1]);
        end

        // Random soak: random INT8 inputs, random enable_i. Reference
        // mirrors the DUT's signed->unsigned-bin conversion.
        for (int iter = 0; iter < 200; iter++) begin : rand_loop
            automatic logic signed [IN_W-1:0] d;
            automatic logic                   en;
            automatic logic signed [OUT_W-1:0] expv;
            d  = IN_W'($urandom());
            en = ($urandom() & 32'h1) != 0;
            if (en) begin
                expv = ref_lut[ref_idx(d)];
            end else begin
                expv = d;
            end
            check_op(en, d, expv, $sformatf("rand iter %0d", iter));
        end

        $display("[tb_act_lut] checks=%0d errors=%0d", check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_act_lut FAILED");
        $finish;
    end

    initial begin : watchdog
        #2_000_000;
        $error("[tb_act_lut] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
