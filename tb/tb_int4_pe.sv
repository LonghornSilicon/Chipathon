// tb_int4_pe.sv
//
// Self-checking Verilator testbench for rtl/int4_pe.sv.
//
// Run:
//   $ verilator --binary -sv --trace-fst --top-module tb_int4_pe \
//       rtl/int4_pe.sv tb/tb_int4_pe.sv
//   $ ./obj_dir/Vtb_int4_pe [+seed=N] [+verbose] [+trace]
//
// With +trace, an FST waveform is written to ./waves.fst (relative to
// the binary's working directory). View with `gtkwave waves.fst` or
// `surfer waves.fst`.
//
// Latency model: each helper task drives controls before a posedge,
// waits one @(posedge clk), then deasserts. After do_mac() returns
// the new acc_o is already visible (the PE has 1-cycle latency from
// inputs to acc_q).

`timescale 1ns/1ps
`default_nettype none

module tb_int4_pe;

    localparam int DATA_W = 4;
    localparam int ACC_W  = 20;

    logic                     clk;
    logic                     rst_n;
    logic                     en;
    logic                     load_weight;
    logic                     clear_acc;
    logic signed [DATA_W-1:0] weight_i;
    logic signed [DATA_W-1:0] act_i;
    logic signed [ACC_W-1:0]  acc_o;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    int4_pe #(
        .DATA_W (DATA_W),
        .ACC_W  (ACC_W)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .en          (en),
        .load_weight (load_weight),
        .clear_acc   (clear_acc),
        .weight_i    (weight_i),
        .act_i       (act_i),
        .acc_o       (acc_o)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    task automatic apply_reset(input int n_cycles = 4);
        rst_n       = 1'b0;
        en          = 1'b0;
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        weight_i    = '0;
        act_i       = '0;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic do_load(input logic signed [DATA_W-1:0] w);
        load_weight = 1'b1;
        clear_acc   = 1'b0;
        en          = 1'b0;
        weight_i    = w;
        act_i       = '0;
        @(posedge clk);
        load_weight = 1'b0;
        weight_i    = '0;
    endtask

    task automatic do_clear();
        load_weight = 1'b0;
        clear_acc   = 1'b1;
        en          = 1'b0;
        weight_i    = '0;
        act_i       = '0;
        @(posedge clk);
        clear_acc = 1'b0;
    endtask

    task automatic do_mac(input logic signed [DATA_W-1:0] a);
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        en          = 1'b1;
        weight_i    = '0;
        act_i       = a;
        @(posedge clk);
        en    = 1'b0;
        act_i = '0;
    endtask

    task automatic do_idle();
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        en          = 1'b0;
        weight_i    = '0;
        act_i       = '0;
        @(posedge clk);
    endtask

    task automatic check(input logic signed [ACC_W-1:0] exp, input string msg);
        check_count++;
        if (acc_o !== exp) begin
            err_count++;
            $error("[%0t] %s: expected %0d, got %0d", $time, msg, exp, acc_o);
        end else if (verbose) begin
            $display("[%0t] %s: OK (=%0d)", $time, msg, acc_o);
        end
    endtask

    initial begin : main
        int seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_int4_pe] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);

        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_int4_pe);
            $display("[tb_int4_pe] tracing to waves.fst");
        end

        $display("[tb_int4_pe] starting");

        apply_reset();
        check(20'sd0, "post-reset acc_o");

        do_load(4'sd3);
        check(20'sd0, "after load w=3, no MAC yet");
        do_idle();
        check(20'sd0, "idle, still no MAC");

        do_mac(4'sd2);
        check(20'sd6, "first MAC w=3 a=2");

        do_mac(4'sd2);
        do_mac(4'sd2);
        do_mac(4'sd2);
        check(20'sd24, "four total MACs of w=3 a=2");

        do_clear();
        check(20'sd0, "after clear, weight retained");
        do_mac(4'sd1);
        check(20'sd3, "MAC after clear, w still 3");

        do_clear();
        do_load(-4'sd8);
        do_mac(4'sd7);
        check(-20'sd56, "w=-8 a=7");

        do_clear();
        do_mac(-4'sd8);
        check(20'sd64, "w=-8 a=-8");

        do_clear();
        do_load(4'sd7);
        do_mac(-4'sd8);
        check(-20'sd56, "w=7 a=-8");

        // Priority: load > clear > en. Asserting all three should
        // only latch the new weight; accumulator must hold.
        // State on entry: w=7, acc=-56.
        load_weight = 1'b1;
        clear_acc   = 1'b1;
        en          = 1'b1;
        weight_i    = 4'sd2;
        act_i       = 4'sd3;
        @(posedge clk);
        load_weight = 1'b0;
        clear_acc   = 1'b0;
        en          = 1'b0;
        weight_i    = '0;
        act_i       = '0;
        check(-20'sd56, "priority: load wins, acc held");

        do_mac(4'sd3);
        check(-20'sd50, "MAC after priority: new w=2 a=3 -> -56+6");

        rst_n = 1'b0;
        @(posedge clk);
        rst_n = 1'b1;
        check(20'sd0, "after sync reset mid-stream");

        for (int iter = 0; iter < 100; iter++) begin : rand_loop
            automatic logic signed [DATA_W-1:0] w_rand;
            automatic int                       k_count;
            automatic logic signed [DATA_W-1:0] a_rand [16];
            automatic logic signed [ACC_W-1:0]  expected;

            w_rand   = DATA_W'($urandom());
            k_count  = $urandom_range(12, 1);
            expected = '0;
            for (int i = 0; i < k_count; i++) begin
                a_rand[i] = DATA_W'($urandom());
                expected  = expected + (ACC_W'(a_rand[i]) * ACC_W'(w_rand));
            end

            do_clear();
            do_load(w_rand);
            for (int i = 0; i < k_count; i++) begin
                do_mac(a_rand[i]);
            end
            check(expected,
                  $sformatf("rand iter %0d K=%0d w=%0d", iter, k_count, w_rand));
        end

        $display("[tb_int4_pe] checks=%0d errors=%0d", check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_int4_pe FAILED");
        $finish;
    end

    initial begin : watchdog
        #1_000_000;
        $error("[tb_int4_pe] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
