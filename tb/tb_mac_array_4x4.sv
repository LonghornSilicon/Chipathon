// tb_mac_array_4x4.sv
//
// Self-checking Verilator testbench for rtl/mac_array_4x4.sv.
//
// Run:
//   $ verilator --binary -sv --trace-fst --top-module tb_mac_array_4x4 \
//       rtl/int4_pe.sv rtl/mac_array_4x4.sv tb/tb_mac_array_4x4.sv
//   $ ./obj_dir/Vtb_mac_array_4x4 [+seed=N] [+verbose] [+trace]
//
// With +trace, an FST waveform is written to ./waves.fst (relative to
// the binary's working directory). View with `gtkwave waves.fst` or
// `surfer waves.fst`.
//
// Pipeline timing:
//   - apply_acts() drives en=1 with new activations and waits one
//     posedge. After it returns, the PE accumulators have just
//     incorporated the new MAC, but col_o still reflects the
//     previous-cycle PE state (the column register lags by one
//     cycle).
//   - One do_idle() after the last apply_acts() lets col_q catch up
//     so the registered column sums match the latest PE state.

`timescale 1ns/1ps
`default_nettype none

module tb_mac_array_4x4;

    localparam int ROWS   = 4;
    localparam int COLS   = 4;
    localparam int DATA_W = 4;
    localparam int ACC_W  = 20;
    localparam int OUT_W  = ACC_W + $clog2(ROWS);

    logic                     clk;
    logic                     rst_n;
    logic                     en;
    logic                     load_weight;
    logic                     clear_acc;
    logic signed [DATA_W-1:0] weight_i [ROWS][COLS];
    logic signed [DATA_W-1:0] act_i    [ROWS];
    logic signed [OUT_W-1:0]  col_o    [COLS];

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    mac_array_4x4 #(
        .ROWS   (ROWS),
        .COLS   (COLS),
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W),
        .OUT_W  (OUT_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .load_weight (load_weight),
        .clear_acc   (clear_acc),
        .weight_i    (weight_i),
        .act_i       (act_i),
        .col_o       (col_o)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    task automatic apply_reset(input int n_cycles = 4);
        rst_n       = 1'b0;
        en          = 1'b0;
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        for (int r = 0; r < ROWS; r++) act_i[r] = '0;
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                weight_i[r][c] = '0;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic load_weights(input logic signed [DATA_W-1:0] w [ROWS][COLS]);
        load_weight = 1'b1;
        clear_acc   = 1'b0;
        en          = 1'b0;
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                weight_i[r][c] = w[r][c];
        @(posedge clk);
        load_weight = 1'b0;
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                weight_i[r][c] = '0;
    endtask

    task automatic clear_all();
        load_weight = 1'b0;
        clear_acc   = 1'b1;
        en          = 1'b0;
        for (int r = 0; r < ROWS; r++) act_i[r] = '0;
        @(posedge clk);
        clear_acc = 1'b0;
    endtask

    task automatic apply_acts(input logic signed [DATA_W-1:0] acts [ROWS]);
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        en          = 1'b1;
        for (int r = 0; r < ROWS; r++) act_i[r] = acts[r];
        @(posedge clk);
        en = 1'b0;
        for (int r = 0; r < ROWS; r++) act_i[r] = '0;
    endtask

    task automatic do_idle();
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        en          = 1'b0;
        for (int r = 0; r < ROWS; r++) act_i[r] = '0;
        @(posedge clk);
    endtask

    task automatic check_col(input logic signed [OUT_W-1:0] exp [COLS],
                             input string msg);
        for (int c = 0; c < COLS; c++) begin
            check_count++;
            if (col_o[c] !== exp[c]) begin
                err_count++;
                $error("[%0t] %s col[%0d]: expected %0d, got %0d",
                       $time, msg, c, exp[c], col_o[c]);
            end else if (verbose) begin
                $display("[%0t] %s col[%0d]: OK (=%0d)",
                         $time, msg, c, col_o[c]);
            end
        end
    endtask

    initial begin : main
        logic signed [DATA_W-1:0] w_zero [ROWS][COLS];
        logic signed [DATA_W-1:0] w_id   [ROWS][COLS];
        logic signed [DATA_W-1:0] w_one  [ROWS][COLS];
        logic signed [DATA_W-1:0] w_neg  [ROWS][COLS];
        logic signed [DATA_W-1:0] a_v    [ROWS];
        logic signed [OUT_W-1:0]  exp4   [COLS];
        int seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_mac_array_4x4] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);

        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_mac_array_4x4);
            $display("[tb_mac_array_4x4] tracing to waves.fst");
        end

        $display("[tb_mac_array_4x4] starting");

        apply_reset();
        for (int c = 0; c < COLS; c++) exp4[c] = '0;
        check_col(exp4, "post-reset");

        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                w_zero[r][c] = '0;
        for (int r = 0; r < ROWS; r++) a_v[r] = '0;
        clear_all();
        load_weights(w_zero);
        apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = '0;
        check_col(exp4, "all-zero w/a, one MAC");

        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                w_id[r][c] = (r == c) ? 4'sd1 : 4'sd0;
        a_v[0] = 4'sd1; a_v[1] = 4'sd2; a_v[2] = 4'sd3; a_v[3] = 4'sd4;
        clear_all();
        load_weights(w_id);
        apply_acts(a_v);
        do_idle();
        exp4[0] = 22'sd1; exp4[1] = 22'sd2; exp4[2] = 22'sd3; exp4[3] = 22'sd4;
        check_col(exp4, "identity w, a={1,2,3,4}, one MAC");

        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                w_one[r][c] = 4'sd1;
        for (int r = 0; r < ROWS; r++) a_v[r] = 4'sd1;
        clear_all();
        load_weights(w_one);
        apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = 22'sd4;
        check_col(exp4, "all-ones w/a, one MAC");

        clear_all();
        load_weights(w_one);
        for (int t = 0; t < 5; t++) apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = 22'sd20;
        check_col(exp4, "all-ones w/a, 5 MACs");

        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                w_neg[r][c] = -4'sd8;
        for (int r = 0; r < ROWS; r++) a_v[r] = 4'sd7;
        clear_all();
        load_weights(w_neg);
        apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = -22'sd224;
        check_col(exp4, "w=-8 a=7, one MAC -> col=-224");

        clear_all();
        load_weights(w_one);
        for (int r = 0; r < ROWS; r++) a_v[r] = 4'sd1;
        apply_acts(a_v);
        apply_acts(a_v);
        apply_acts(a_v);
        clear_all();
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = '0;
        check_col(exp4, "clear-during-stream zeros col_o");

        apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = 22'sd4;
        check_col(exp4, "MAC after mid-stream clear, weights retained");

        clear_all();
        load_weights(w_one);
        for (int t = 0; t < 4; t++) apply_acts(a_v);
        load_weights(w_neg);
        clear_all();
        for (int r = 0; r < ROWS; r++) a_v[r] = 4'sd7;
        for (int t = 0; t < 4; t++) apply_acts(a_v);
        do_idle();
        for (int c = 0; c < COLS; c++) exp4[c] = -22'sd896;
        check_col(exp4, "weight reload mid-stream, w2=-8 a=7 x4");

        for (int iter = 0; iter < 100; iter++) begin : rand_loop
            automatic logic signed [DATA_W-1:0] w_rand   [ROWS][COLS];
            automatic int                       k_count;
            automatic logic signed [DATA_W-1:0] a_seq    [16][ROWS];
            automatic logic signed [ACC_W-1:0]  pe_acc_g [ROWS][COLS];
            automatic logic signed [OUT_W-1:0]  expected [COLS];
            automatic logic signed [DATA_W-1:0] cur_a    [ROWS];

            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                    w_rand[r][c] = DATA_W'($urandom());

            k_count = $urandom_range(8, 1);

            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                    pe_acc_g[r][c] = '0;

            for (int t = 0; t < k_count; t++) begin
                for (int r = 0; r < ROWS; r++)
                    a_seq[t][r] = DATA_W'($urandom());
                for (int r = 0; r < ROWS; r++)
                    for (int c = 0; c < COLS; c++)
                        pe_acc_g[r][c] = pe_acc_g[r][c]
                            + (ACC_W'(a_seq[t][r]) * ACC_W'(w_rand[r][c]));
            end

            for (int c = 0; c < COLS; c++) begin
                expected[c] = '0;
                for (int r = 0; r < ROWS; r++)
                    expected[c] = expected[c] + OUT_W'(pe_acc_g[r][c]);
            end

            clear_all();
            load_weights(w_rand);
            for (int t = 0; t < k_count; t++) begin
                for (int r = 0; r < ROWS; r++) cur_a[r] = a_seq[t][r];
                apply_acts(cur_a);
            end
            do_idle();
            check_col(expected,
                      $sformatf("rand iter %0d K=%0d", iter, k_count));
        end

        $display("[tb_mac_array_4x4] checks=%0d errors=%0d",
                 check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_mac_array_4x4 FAILED");
        $finish;
    end

    initial begin : watchdog
        #2_000_000;
        $error("[tb_mac_array_4x4] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
