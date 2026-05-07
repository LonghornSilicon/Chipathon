// tb_requant_sat.sv
//
// Self-checking Verilator testbench for rtl/requant_sat.sv.
//
// Run:
//   $ verilator --binary -sv --trace-fst --top-module tb_requant_sat \
//       rtl/requant_sat.sv tb/tb_requant_sat.sv
//   $ ./obj_dir/Vtb_requant_sat [+seed=N] [+verbose] [+trace]
//
// Reference model `ref_requant` mirrors the DUT math exactly so we can
// drive random stimulus and check for parity.

`timescale 1ns/1ps
`default_nettype none

module tb_requant_sat;

    localparam int ACC_W   = 20;
    localparam int OUT_W   = 8;
    localparam int SHIFT_W = $clog2(ACC_W) + 1;

    logic                        clk;
    logic                        rst_n;
    logic                        valid_i;
    logic                        ready_o;
    logic signed [ACC_W-1:0]     data_i;
    logic [SHIFT_W-1:0]          shift_i;
    logic                        mode_i;
    logic                        round_i;
    logic                        valid_o;
    logic                        ready_i;
    logic signed [OUT_W-1:0]     data_o;
    logic                        overflow_o;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    requant_sat #(
        .ACC_W   (ACC_W),
        .OUT_W   (OUT_W),
        .SHIFT_W (SHIFT_W)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .valid_i    (valid_i),
        .ready_o    (ready_o),
        .data_i     (data_i),
        .shift_i    (shift_i),
        .mode_i     (mode_i),
        .round_i    (round_i),
        .valid_o    (valid_o),
        .ready_i    (ready_i),
        .data_o     (data_o),
        .overflow_o (overflow_o)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    // Software reference. Returns sat result; sets ovfl high on clamp.
    function automatic logic signed [OUT_W-1:0] ref_requant (
        input  longint                 d,
        input  int                     sh,
        input  bit                     m8,
        input  bit                     rd,
        output bit                     ovfl
    );
        longint bias;
        longint shifted;
        longint hi;
        longint lo;
        bias = (rd && (sh != 0)) ? (longint'(1) <<< (sh-1)) : 0;
        shifted = (d + bias) >>> sh;
        hi = m8 ?  127 :  7;
        lo = m8 ? -128 : -8;
        if (shifted > hi)      begin ovfl = 1'b1; ref_requant = OUT_W'(hi); end
        else if (shifted < lo) begin ovfl = 1'b1; ref_requant = OUT_W'(lo); end
        else                   begin ovfl = 1'b0; ref_requant = OUT_W'(shifted); end
    endfunction

    task automatic apply_reset(input int n_cycles = 4);
        rst_n   = 1'b0;
        valid_i = 1'b0;
        data_i  = '0;
        shift_i = '0;
        mode_i  = 1'b0;
        round_i = 1'b0;
        ready_i = 1'b1;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    // Drive one transaction: assert valid_i for 1 cycle (with ready_o
    // high), then wait one more cycle for the registered output, then
    // sample. Returns observed (data_o, overflow_o).
    task automatic do_op (
        input  logic signed [ACC_W-1:0] d,
        input  logic [SHIFT_W-1:0]      sh,
        input  logic                    m,
        input  logic                    r,
        output logic signed [OUT_W-1:0] got_data,
        output logic                    got_ovfl
    );
        valid_i = 1'b1;
        data_i  = d;
        shift_i = sh;
        mode_i  = m;
        round_i = r;
        ready_i = 1'b1;
        @(posedge clk);
        valid_i = 1'b0;
        @(posedge clk);
        got_data = data_o;
        got_ovfl = overflow_o;
    endtask

    task automatic check_op (
        input logic signed [ACC_W-1:0] d,
        input logic [SHIFT_W-1:0]      sh,
        input logic                    m,
        input logic                    r,
        input logic signed [OUT_W-1:0] exp_data,
        input bit                      exp_set_ovfl,
        input string                   msg
    );
        logic signed [OUT_W-1:0] got_data;
        logic                    got_ovfl;
        bit                      pre_ovfl;
        pre_ovfl = overflow_o;
        do_op(d, sh, m, r, got_data, got_ovfl);
        check_count++;
        if (got_data !== exp_data) begin
            err_count++;
            $error("[%0t] %s data: expected %0d, got %0d (d=%0d sh=%0d m=%0d r=%0d)",
                   $time, msg, exp_data, got_data, d, sh, m, r);
        end else if (verbose) begin
            $display("[%0t] %s OK data=%0d ovfl=%0b", $time, msg, got_data, got_ovfl);
        end
        if (exp_set_ovfl && !got_ovfl) begin
            err_count++;
            check_count++;
            $error("[%0t] %s expected sticky overflow to set", $time, msg);
        end
    endtask

    initial begin : main
        logic signed [OUT_W-1:0] got;
        bit                      gotov;
        int                      seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_requant_sat] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);

        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_requant_sat);
            $display("[tb_requant_sat] tracing to waves.fst");
        end

        $display("[tb_requant_sat] starting");
        apply_reset();

        // Pass-through (shift=0, INT8 mode, value in range).
        check_op(20'sd5,  6'd0, 1'b1, 1'b0,  8'sd5,  1'b0, "passthrough +5 INT8");
        check_op(-20'sd9, 6'd0, 1'b1, 1'b0, -8'sd9,  1'b0, "passthrough -9 INT8");

        // Truncation (round=0).
        check_op(20'sd16, 6'd4, 1'b1, 1'b0,  8'sd1,  1'b0, "trunc 16>>4 -> 1");
        check_op(20'sd31, 6'd4, 1'b1, 1'b0,  8'sd1,  1'b0, "trunc 31>>4 -> 1");
        check_op(-20'sd16, 6'd4, 1'b1, 1'b0, -8'sd1, 1'b0, "trunc -16>>4 -> -1");
        check_op(-20'sd1,  6'd4, 1'b1, 1'b0, -8'sd1, 1'b0, "trunc -1 >>4 -> -1 (arith)");

        // Rounding (round=1, half-up).
        check_op(20'sd8,  6'd4, 1'b1, 1'b1,  8'sd1,  1'b0, "round 8 >>4 -> 1 (half up)");
        check_op(20'sd7,  6'd4, 1'b1, 1'b1,  8'sd0,  1'b0, "round 7 >>4 -> 0");
        check_op(20'sd24, 6'd4, 1'b1, 1'b1,  8'sd2,  1'b0, "round 24>>4 -> 2");
        check_op(-20'sd8, 6'd4, 1'b1, 1'b1,  8'sd0,  1'b0,
                  "round -8>>4 with +bias -> 0 (half up)");

        // INT4 saturation.
        check_op(20'sd15, 6'd0, 1'b0, 1'b0,  8'sd7,  1'b1, "INT4 sat +15 -> +7");
        check_op(-20'sd9, 6'd0, 1'b0, 1'b0, -8'sd8,  1'b1, "INT4 sat -9 -> -8");
        check_op(20'sd7,  6'd0, 1'b0, 1'b0,  8'sd7,  1'b0, "INT4 +7 in range");
        check_op(-20'sd8, 6'd0, 1'b0, 1'b0, -8'sd8,  1'b0, "INT4 -8 in range");

        // INT8 saturation.
        check_op(20'sd200,  6'd0, 1'b1, 1'b0,  8'sd127, 1'b1, "INT8 sat +200 -> +127");
        check_op(-20'sd200, 6'd0, 1'b1, 1'b0, -8'sd128, 1'b1, "INT8 sat -200 -> -128");

        // Stickiness: after an overflow above, do an in-range op and
        // verify overflow_o stays high until next reset.
        do_op(20'sd1, 6'd0, 1'b1, 1'b0, got, gotov);
        check_count++;
        if (!gotov) begin
            err_count++;
            $error("[%0t] sticky: overflow should remain after clean op", $time);
        end

        // Reset clears the sticky bit.
        apply_reset();
        check_count++;
        if (overflow_o !== 1'b0) begin
            err_count++;
            $error("[%0t] post-reset: overflow_o should be 0", $time);
        end

        // Random soak.
        for (int iter = 0; iter < 100; iter++) begin : rand_loop
            automatic logic signed [ACC_W-1:0] d;
            automatic logic [SHIFT_W-1:0]      sh;
            automatic logic                    m;
            automatic logic                    r;
            automatic logic signed [OUT_W-1:0] exp_data;
            automatic bit                      exp_ovfl_event;

            d  = ACC_W'($urandom());
            sh = SHIFT_W'($urandom_range(ACC_W-1, 0));
            m  = ($urandom() & 32'h1) != 0;
            r  = ($urandom() & 32'h1) != 0;

            exp_data = ref_requant(longint'(d), int'(sh), m, r, exp_ovfl_event);
            check_op(d, sh, m, r, exp_data, exp_ovfl_event,
                     $sformatf("rand iter %0d", iter));
        end

        $display("[tb_requant_sat] checks=%0d errors=%0d", check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_requant_sat FAILED");
        $finish;
    end

    initial begin : watchdog
        #2_000_000;
        $error("[tb_requant_sat] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
