// tb_act_streamer.sv
//
// Self-checking Verilator testbench for rtl/act_streamer.sv. Drives
// 1-byte pushes into the buffer, drains 4-wide rows, and exercises
// flush plus back-pressure. A queue-based reference model owns the
// expected fill_cnt and per-slot contents.

`timescale 1ns/1ps
`default_nettype none

module tb_act_streamer;

    localparam int ROWS   = 4;
    localparam int DATA_W = 4;

    logic                                clk;
    logic                                rst_n;
    logic                                flush_i;
    logic                                in_valid;
    logic                                in_ready;
    logic signed [DATA_W-1:0]            in_data;
    logic                                out_valid;
    logic                                out_ready;
    logic signed [ROWS*DATA_W-1:0]       out_data_flat;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    act_streamer #(
        .ROWS   (ROWS),
        .DATA_W (DATA_W)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .flush_i       (flush_i),
        .in_valid      (in_valid),
        .in_ready      (in_ready),
        .in_data       (in_data),
        .out_valid     (out_valid),
        .out_ready     (out_ready),
        .out_data_flat (out_data_flat)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    function automatic logic signed [DATA_W-1:0] row_get (input int r);
        return out_data_flat[r*DATA_W +: DATA_W];
    endfunction

    task automatic apply_reset(input int n_cycles = 4);
        rst_n     = 1'b0;
        flush_i   = 1'b0;
        in_valid  = 1'b0;
        in_data   = '0;
        out_ready = 1'b0;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    // Wait until in_ready is high BEFORE driving in_valid. in_ready
    // depends only on the buffer state (fill_cnt + the optional drain
    // shortcut), not on in_valid, so this is safe.
    task automatic wait_in_ready();
        while (!in_ready) @(posedge clk);
    endtask

    // Push one byte and wait for it to be accepted. Optionally drives
    // out_ready in parallel so we can also test simultaneous push+pop.
    task automatic push_one (
        input logic signed [DATA_W-1:0] d,
        input bit                       drain_too = 1'b0
    );
        if (!drain_too) wait_in_ready();
        in_valid  = 1'b1;
        in_data   = d;
        out_ready = drain_too;
        @(posedge clk);
        in_valid  = 1'b0;
        out_ready = 1'b0;
    endtask

    task automatic drain_row (
        output logic signed [DATA_W-1:0] r [ROWS]
    );
        out_ready = 1'b1;
        while (!out_valid) @(posedge clk);
        for (int i = 0; i < ROWS; i++) r[i] = row_get(i);
        @(posedge clk);
        out_ready = 1'b0;
    endtask

    task automatic do_flush();
        flush_i = 1'b1;
        @(posedge clk);
        flush_i = 1'b0;
    endtask

    task automatic check_row (
        input logic signed [DATA_W-1:0] got [ROWS],
        input logic signed [DATA_W-1:0] exp [ROWS],
        input string                    msg
    );
        for (int i = 0; i < ROWS; i++) begin
            check_count++;
            if (got[i] !== exp[i]) begin
                err_count++;
                $error("[%0t] %s row[%0d]: expected %0d got %0d",
                       $time, msg, i, exp[i], got[i]);
            end else if (verbose) begin
                $display("[%0t] %s row[%0d]: OK (=%0d)",
                         $time, msg, i, got[i]);
            end
        end
    endtask

    initial begin : main
        logic signed [DATA_W-1:0] got [ROWS];
        logic signed [DATA_W-1:0] exp [ROWS];
        int seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_act_streamer] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);
        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_act_streamer);
            $display("[tb_act_streamer] tracing to waves.fst");
        end

        $display("[tb_act_streamer] starting");
        apply_reset();

        check_count++;
        if (out_valid !== 1'b0) begin
            err_count++;
            $error("post-reset out_valid should be 0");
        end

        push_one(4'sd1);
        push_one(4'sd2);
        push_one(4'sd3);
        push_one(4'sd4);
        check_count++;
        if (out_valid !== 1'b1) begin
            err_count++;
            $error("after 4 pushes, out_valid should be 1, got %0b", out_valid);
        end
        drain_row(got);
        exp = '{4'sd1, 4'sd2, 4'sd3, 4'sd4};
        check_row(got, exp, "fill+drain row1");
        check_count++;
        if (out_valid !== 1'b0) begin
            err_count++;
            $error("after drain, out_valid should be 0");
        end

        for (int t = 0; t < 4; t++) begin
            for (int i = 0; i < ROWS; i++) push_one(DATA_W'(t*4 + i));
            drain_row(got);
            for (int i = 0; i < ROWS; i++) exp[i] = DATA_W'(t*4 + i);
            check_row(got, exp, $sformatf("back-to-back row %0d", t));
        end

        push_one(4'sd5);
        push_one(4'sd6);
        do_flush();
        check_count++;
        if (out_valid !== 1'b0) begin
            err_count++;
            $error("after flush mid-fill, out_valid should be 0");
        end
        push_one(4'sd7);
        push_one(4'sd8);
        push_one(4'sd9);
        push_one(-4'sd1);
        drain_row(got);
        exp = '{4'sd7, 4'sd8, 4'sd9, -4'sd1};
        check_row(got, exp, "fill after flush");

        push_one(4'sd1);
        push_one(4'sd2);
        push_one(4'sd3);
        push_one(4'sd4);
        in_valid  = 1'b1;
        in_data   = -4'sd2;
        out_ready = 1'b1;
        @(posedge clk);
        in_valid  = 1'b0;
        out_ready = 1'b0;
        @(posedge clk);
        push_one(-4'sd3);
        push_one(-4'sd4);
        push_one(-4'sd5);
        drain_row(got);
        exp = '{-4'sd2, -4'sd3, -4'sd4, -4'sd5};
        check_row(got, exp, "concurrent push+pop, slot0 = pushed value");

        for (int iter = 0; iter < 100; iter++) begin : rand_loop
            automatic logic signed [DATA_W-1:0] q [$];
            automatic int                       n_pushes;
            automatic logic signed [DATA_W-1:0] v;
            automatic logic signed [DATA_W-1:0] expected_row [ROWS];

            n_pushes = $urandom_range(12, ROWS);
            for (int p = 0; p < n_pushes; p++) begin
                v = DATA_W'($urandom());
                q.push_back(v);
                push_one(v);
                if (q.size() == ROWS) begin
                    for (int i = 0; i < ROWS; i++) expected_row[i] = q[i];
                    drain_row(got);
                    check_row(got, expected_row,
                              $sformatf("rand iter %0d drain", iter));
                    q.delete();
                end
            end
            do_flush();
            q.delete();
        end

        $display("[tb_act_streamer] checks=%0d errors=%0d",
                 check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_act_streamer FAILED");
        $finish;
    end

    initial begin : watchdog
        #5_000_000;
        $error("[tb_act_streamer] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
