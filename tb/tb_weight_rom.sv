// tb_weight_rom.sv
//
// Self-checking Verilator testbench for rtl/weight_rom.sv. Mirrors
// the DUT's default LFSR-driven init so we can predict every entry
// without an external init file. Tests both the default init path
// and read-port behaviour (latency, hold-on-no-rd_en, reset).

`timescale 1ns/1ps
`default_nettype none

module tb_weight_rom;

    localparam int ENTRIES   = 256;
    localparam int DATA_W    = 4;
    localparam int ADDR_W    = $clog2(ENTRIES);
    localparam int INIT_SEED = 32'hC0FFEE42;

    logic                       clk;
    logic                       rst_n;
    logic                       rd_en;
    logic [ADDR_W-1:0]          rd_addr;
    logic signed [DATA_W-1:0]   rd_data;

    int unsigned err_count   = 0;
    int unsigned check_count = 0;
    bit          verbose     = 1'b0;

    weight_rom #(
        .ENTRIES   (ENTRIES),
        .DATA_W    (DATA_W),
        .INIT_SEED (INIT_SEED)
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .rd_en   (rd_en),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    initial clk = 1'b0;
    always #5 clk <= ~clk;

    function automatic logic [31:0] lfsr_step (input logic [31:0] s);
        logic [31:0] r;
        r = s;
        for (int i = 0; i < 8; i++) begin
            r = (r >> 1) ^ ({32{r[0]}} & 32'hEDB88320);
        end
        return r;
    endfunction

    function automatic logic signed [DATA_W-1:0]
            ref_weight (input int idx);
        logic [31:0] s;
        s = INIT_SEED ^ {16'h0, idx[15:0]};
        s = lfsr_step(s);
        return DATA_W'(s[DATA_W-1:0]);
    endfunction

    task automatic apply_reset(input int n_cycles = 4);
        rst_n   = 1'b0;
        rd_en   = 1'b0;
        rd_addr = '0;
        repeat (n_cycles) @(posedge clk);
        rst_n = 1'b1;
    endtask

    task automatic do_read (
        input  logic [ADDR_W-1:0]      addr,
        output logic signed [DATA_W-1:0] got
    );
        rd_en   = 1'b1;
        rd_addr = addr;
        @(posedge clk);
        rd_en   = 1'b0;
        rd_addr = '0;
        got     = rd_data;
    endtask

    task automatic check_addr (
        input logic [ADDR_W-1:0] addr,
        input string             msg
    );
        logic signed [DATA_W-1:0] got;
        logic signed [DATA_W-1:0] exp;
        do_read(addr, got);
        exp = ref_weight(int'(addr));
        check_count++;
        if (got !== exp) begin
            err_count++;
            $error("[%0t] %s addr=%0d: expected %0d got %0d",
                   $time, msg, addr, exp, got);
        end else if (verbose) begin
            $display("[%0t] %s addr=%0d: OK (=%0d)", $time, msg, addr, got);
        end
    endtask

    initial begin : main
        logic signed [DATA_W-1:0] got;
        int seed_val;

        if ($value$plusargs("seed=%d", seed_val)) begin
            $display("[tb_weight_rom] seed=%0d", seed_val);
            void'($urandom(seed_val));
        end
        verbose = ($test$plusargs("verbose") != 0);
        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_weight_rom);
            $display("[tb_weight_rom] tracing to waves.fst");
        end

        $display("[tb_weight_rom] starting");
        apply_reset();

        check_count++;
        if (rd_data !== '0) begin
            err_count++;
            $error("[%0t] post-reset: rd_data should be 0, got %0d", $time, rd_data);
        end

        for (int a = 0; a < ENTRIES; a++) begin
            check_addr(ADDR_W'(a), $sformatf("sweep addr=%0d", a));
        end

        for (int iter = 0; iter < 200; iter++) begin
            check_addr(ADDR_W'($urandom_range(ENTRIES-1, 0)),
                       $sformatf("rand iter %0d", iter));
        end

        do_read(ADDR_W'(7), got);
        rd_en   = 1'b0;
        rd_addr = ADDR_W'(99);
        @(posedge clk);
        check_count++;
        if (rd_data !== ref_weight(7)) begin
            err_count++;
            $error("[%0t] hold-on-rd_en=0 violated: expected %0d got %0d",
                   $time, ref_weight(7), rd_data);
        end

        $display("[tb_weight_rom] checks=%0d errors=%0d", check_count, err_count);
        if (err_count != 0) $fatal(1, "tb_weight_rom FAILED");
        $finish;
    end

    initial begin : watchdog
        #5_000_000;
        $error("[tb_weight_rom] watchdog timeout");
        $fatal(1, "watchdog");
    end

endmodule

`default_nettype wire
