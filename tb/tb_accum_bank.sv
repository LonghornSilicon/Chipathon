// tb_accum_bank.sv
//
// Self-checking Verilator testbench for rtl/accum_bank.sv.
//
// Run:
//   $ verilator --binary -sv --trace-fst --top-module tb_accum_bank \
//       rtl/accum_bank.sv tb/tb_accum_bank.sv
//   $ ./obj_dir/Vtb_accum_bank [+seed=N] [+verbose] [+trace]
//
// With +trace, an FST waveform is written to ./waves.fst (relative to
// the binary's working directory). View with `gtkwave waves.fst` or
// `surfer waves.fst`.
//
// Latency model:
//   - write_row()/bank_clear() drive controls before a posedge, wait
//     one @(posedge clk), then deassert. After write_row() returns,
//     mem has already absorbed the write.
//   - read_addr() drives rd_en + rd_addr, waits one @(posedge clk),
//     then captures rd_data. rd_data is registered, so this is the
//     only correct way to get the result.
//
// Reference model:
//   - Maintains a software shadow of the bank in `ref_mem` and applies
//     the same saturating semantics as the DUT. All checks compare
//     ref_mem against the registered read.

`timescale 1ns/1ps
`default_nettype none

module tb_accum_bank;

    localparam int ROWS    = 4;
    localparam int COLS    = 4;
    localparam int BANKS   = 2;
    localparam int ACC_W   = 20;
    localparam int IN_W    = ACC_W + $clog2(ROWS);
    localparam int ROW_AW  = $clog2(ROWS);
    localparam int COL_AW  = $clog2(COLS);
    localparam int BANK_AW = $clog2(BANKS);
    localparam int ADDR_W  = $clog2(ROWS*COLS*BANKS);

    localparam logic signed [ACC_W-1:0] ACC_MAX = (1 <<< (ACC_W-1)) - 1;
    localparam logic signed [ACC_W-1:0] ACC_MIN = -(1 <<< (ACC_W-1));

    logic                        clk;
    logic                        rst_n;
    logic                        wr_en;
    logic                        wr_mode;
    logic [BANK_AW-1:0]          wr_bank;
    logic [ROW_AW-1:0]           wr_row;
    logic signed [COLS*IN_W-1:0] wr_data_flat;
    logic                        clear_bank_en;
    logic [BANK_AW-1:0]          clear_bank;
    logic                        rd_en;
    logic [ADDR_W-1:0]           rd_addr;
    logic signed [ACC_W-1:0]     rd_data;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    // Software reference model.
    logic signed [ACC_W-1:0] ref_mem [BANKS][ROWS][COLS];

    accum_bank #(
        .ROWS    (ROWS),
        .COLS    (COLS),
        .BANKS   (BANKS),
        .ACC_W   (ACC_W),
        .IN_W    (IN_W)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .wr_en         (wr_en),
        .wr_mode       (wr_mode),
        .wr_bank       (wr_bank),
        .wr_row        (wr_row),
        .wr_data_flat  (wr_data_flat),
        .clear_bank_en (clear_bank_en),
        .clear_bank    (clear_bank),
        .rd_en         (rd_en),
        .rd_addr       (rd_addr),
        .rd_data       (rd_data)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    // Software saturating clamp from a wide signed value to ACC_W.
    function automatic logic signed [ACC_W-1:0]
            sat_acc (input longint x);
        if (x > longint'(ACC_MAX))      sat_acc = ACC_MAX;
        else if (x < longint'(ACC_MIN)) sat_acc = ACC_MIN;
        else                            sat_acc = x[ACC_W-1:0];
    endfunction

    function automatic logic signed [IN_W-1:0]
            pack_get (input logic signed [COLS*IN_W-1:0] flat, input int c);
        return flat[c*IN_W +: IN_W];
    endfunction

    task automatic apply_reset(input int n_cycles = 4);
        rst_n         = 1'b0;
        wr_en         = 1'b0;
        wr_mode       = 1'b0;
        wr_bank       = '0;
        wr_row        = '0;
        wr_data_flat  = '0;
        clear_bank_en = 1'b0;
        clear_bank    = '0;
        rd_en         = 1'b0;
        rd_addr       = '0;
        for (int b = 0; b < BANKS; b++)
            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                    ref_mem[b][r][c] = '0;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic do_idle();
        wr_en         = 1'b0;
        wr_mode       = 1'b0;
        wr_data_flat  = '0;
        clear_bank_en = 1'b0;
        rd_en         = 1'b0;
        @(posedge clk);
    endtask

    task automatic bank_clear(input logic [BANK_AW-1:0] b);
        wr_en         = 1'b0;
        clear_bank_en = 1'b1;
        clear_bank    = b;
        rd_en         = 1'b0;
        @(posedge clk);
        clear_bank_en = 1'b0;
        for (int r = 0; r < ROWS; r++)
            for (int c = 0; c < COLS; c++)
                ref_mem[b][r][c] = '0;
    endtask

    task automatic write_row (
        input logic [BANK_AW-1:0]     b,
        input logic [ROW_AW-1:0]      r,
        input logic                   mode,
        input logic signed [IN_W-1:0] data [COLS]
    );
        clear_bank_en = 1'b0;
        wr_en         = 1'b1;
        wr_mode       = mode;
        wr_bank       = b;
        wr_row        = r;
        rd_en         = 1'b0;
        for (int c = 0; c < COLS; c++)
            wr_data_flat[c*IN_W +: IN_W] = data[c];
        @(posedge clk);
        wr_en        = 1'b0;
        wr_data_flat = '0;
        for (int c = 0; c < COLS; c++) begin
            if (mode) begin
                ref_mem[b][r][c] = sat_acc(longint'(ref_mem[b][r][c])
                                          + longint'(data[c]));
            end else begin
                ref_mem[b][r][c] = sat_acc(longint'(data[c]));
            end
        end
    endtask

    // Drive a registered single-entry read; returns the value visible
    // on rd_data after the next posedge.
    task automatic read_addr (
        input  logic [ADDR_W-1:0]     addr,
        output logic signed [ACC_W-1:0] data
    );
        wr_en         = 1'b0;
        clear_bank_en = 1'b0;
        rd_en         = 1'b1;
        rd_addr       = addr;
        @(posedge clk);
        rd_en   = 1'b0;
        rd_addr = '0;
        data    = rd_data;
    endtask

    function automatic logic [ADDR_W-1:0] make_addr (
        input int b, input int r, input int c
    );
        return {b[BANK_AW-1:0], r[ROW_AW-1:0], c[COL_AW-1:0]};
    endfunction

    task automatic check_entry (
        input int b, input int r, input int c, input string msg
    );
        logic signed [ACC_W-1:0] got;
        logic signed [ACC_W-1:0] exp;
        check_count++;
        read_addr(make_addr(b, r, c), got);
        exp = ref_mem[b][r][c];
        if (got !== exp) begin
            err_count++;
            $error("[%0t] %s [b=%0d r=%0d c=%0d]: expected %0d, got %0d",
                   $time, msg, b, r, c, exp, got);
        end else if (verbose) begin
            $display("[%0t] %s [b=%0d r=%0d c=%0d]: OK (=%0d)",
                     $time, msg, b, r, c, got);
        end
    endtask

    task automatic check_all(input string msg);
        for (int b = 0; b < BANKS; b++)
            for (int r = 0; r < ROWS; r++)
                for (int c = 0; c < COLS; c++)
                    check_entry(b, r, c, msg);
    endtask

    initial begin : main
        logic signed [IN_W-1:0]  data    [COLS];
        logic signed [IN_W-1:0]  big_pos [COLS];
        logic signed [IN_W-1:0]  big_neg [COLS];
        logic signed [ACC_W-1:0] got;
        int seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_accum_bank] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);

        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_accum_bank);
            $display("[tb_accum_bank] tracing to waves.fst");
        end

        $display("[tb_accum_bank] starting");

        apply_reset();
        check_all("post-reset");

        // Plain overwrite: distinct constants into every entry.
        for (int b = 0; b < BANKS; b++) begin
            for (int r = 0; r < ROWS; r++) begin
                for (int c = 0; c < COLS; c++) begin
                    data[c] = IN_W'((b*100) + (r*10) + c + 1);
                end
                write_row(b[BANK_AW-1:0], r[ROW_AW-1:0], 1'b0, data);
            end
        end
        check_all("plain overwrite, distinct constants");

        // Accumulate into bank 0 row 0 starting from a known clear.
        bank_clear(BANK_AW'(0));
        check_entry(0, 0, 0, "post-clear bank 0");
        for (int c = 0; c < COLS; c++) data[c] = IN_W'(c + 1);  // {1,2,3,4}
        for (int t = 0; t < 5; t++) begin
            write_row(BANK_AW'(0), ROW_AW'(0), 1'b1, data);
        end
        check_entry(0, 0, 0, "5x +=1 -> 5");
        check_entry(0, 0, 1, "5x +=2 -> 10");
        check_entry(0, 0, 2, "5x +=3 -> 15");
        check_entry(0, 0, 3, "5x +=4 -> 20");

        // Saturate on overwrite: a 22-bit value above INT20 max and
        // below INT20 min should clamp on entry.
        for (int c = 0; c < COLS; c++) big_pos[c] = IN_W'(22'sd1_500_000);
        for (int c = 0; c < COLS; c++) big_neg[c] = -IN_W'(22'sd1_500_000);
        write_row(BANK_AW'(1), ROW_AW'(0), 1'b0, big_pos);
        write_row(BANK_AW'(1), ROW_AW'(1), 1'b0, big_neg);
        check_entry(1, 0, 0, "sat-on-OW +1.5M -> ACC_MAX");
        check_entry(1, 0, 3, "sat-on-OW +1.5M -> ACC_MAX");
        check_entry(1, 1, 0, "sat-on-OW -1.5M -> ACC_MIN");
        check_entry(1, 1, 3, "sat-on-OW -1.5M -> ACC_MIN");

        // Saturate on accumulate: prime to ACC_MAX, += 1 stays at MAX.
        // Symmetric for negative.
        for (int c = 0; c < COLS; c++) data[c] = IN_W'(ACC_MAX);
        write_row(BANK_AW'(1), ROW_AW'(2), 1'b0, data);
        for (int c = 0; c < COLS; c++) data[c] = IN_W'(1);
        write_row(BANK_AW'(1), ROW_AW'(2), 1'b1, data);
        check_entry(1, 2, 0, "sat-on-ACC: ACC_MAX + 1 -> ACC_MAX");
        check_entry(1, 2, 3, "sat-on-ACC: ACC_MAX + 1 -> ACC_MAX");

        for (int c = 0; c < COLS; c++) data[c] = IN_W'(ACC_MIN);
        write_row(BANK_AW'(1), ROW_AW'(3), 1'b0, data);
        for (int c = 0; c < COLS; c++) data[c] = -IN_W'(1);
        write_row(BANK_AW'(1), ROW_AW'(3), 1'b1, data);
        check_entry(1, 3, 0, "sat-on-ACC: ACC_MIN - 1 -> ACC_MIN");
        check_entry(1, 3, 3, "sat-on-ACC: ACC_MIN - 1 -> ACC_MIN");

        // Bank ping-pong isolation: clear bank 0; bank 1's contents
        // (set above) must survive untouched.
        bank_clear(BANK_AW'(0));
        check_all("clear bank 0 leaves bank 1 alone");

        // Write bank 1 row 0 again, verify bank 0 stays zero.
        for (int c = 0; c < COLS; c++) data[c] = IN_W'(c + 100);
        write_row(BANK_AW'(1), ROW_AW'(0), 1'b0, data);
        check_all("write bank 1, bank 0 unchanged");

        // Concurrent rd_en + wr_en sanity: writing one cell while
        // reading another must produce the right registered read.
        bank_clear(BANK_AW'(0));
        bank_clear(BANK_AW'(1));
        for (int c = 0; c < COLS; c++) data[c] = IN_W'(c + 7);
        write_row(BANK_AW'(0), ROW_AW'(1), 1'b0, data);
        // Now drive a write and a read in the same cycle.
        wr_en        = 1'b1;
        wr_mode      = 1'b0;
        wr_bank      = BANK_AW'(1);
        wr_row       = ROW_AW'(2);
        for (int c = 0; c < COLS; c++)
            wr_data_flat[c*IN_W +: IN_W] = IN_W'(c + 50);
        rd_en   = 1'b1;
        rd_addr = make_addr(0, 1, 2);  // value 9 from earlier write
        @(posedge clk);
        wr_en        = 1'b0;
        wr_data_flat = '0;
        rd_en        = 1'b0;
        for (int c = 0; c < COLS; c++)
            ref_mem[1][2][c] = sat_acc(longint'(c) + 64'sd50);
        check_count++;
        if (rd_data !== ref_mem[0][1][2]) begin
            err_count++;
            $error("[%0t] concurrent rd+wr: expected %0d, got %0d",
                   $time, ref_mem[0][1][2], rd_data);
        end else if (verbose) begin
            $display("[%0t] concurrent rd+wr: OK (=%0d)", $time, rd_data);
        end
        check_entry(1, 2, 0, "concurrent write committed");
        check_entry(1, 2, 3, "concurrent write committed");

        // Random soak: 100 iters of clears / overwrites / accumulates
        // against the ref model, checking every entry at the end of
        // each iter.
        for (int iter = 0; iter < 100; iter++) begin : rand_loop
            automatic int                       n_ops;
            automatic int                       op_kind;
            automatic int                       b_sel;
            automatic int                       r_sel;
            automatic logic signed [IN_W-1:0]   row_data [COLS];

            n_ops = $urandom_range(8, 1);
            for (int o = 0; o < n_ops; o++) begin
                op_kind = $urandom_range(9, 0);
                if (op_kind < 2) begin
                    b_sel = $urandom_range(BANKS-1, 0);
                    bank_clear(BANK_AW'(b_sel));
                end else begin
                    b_sel = $urandom_range(BANKS-1, 0);
                    r_sel = $urandom_range(ROWS-1, 0);
                    for (int c = 0; c < COLS; c++)
                        row_data[c] = IN_W'($urandom());
                    write_row(BANK_AW'(b_sel),
                              ROW_AW'(r_sel),
                              ((op_kind & 1) != 0),
                              row_data);
                end
            end
            check_all($sformatf("rand iter %0d ops=%0d", iter, n_ops));
        end

        $display("[tb_accum_bank] checks=%0d errors=%0d",
                 check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_accum_bank FAILED");
        $finish;
    end

    initial begin : watchdog
        #20_000_000;
        $error("[tb_accum_bank] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
