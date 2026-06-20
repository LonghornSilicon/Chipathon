// tb_sign_lfsr.sv
//
// Self-checking testbench for sign_lfsr.sv.
//
// Loads tb/golden/out/signs.mem (64 lines of 0/1 produced by the Python
// golden) and verifies the RTL emits the same bit sequence over D=64
// cycles after a single-cycle ``start`` pulse.
//
// Usage:  make TB=sign_lfsr run

`timescale 1ns/1ps
`default_nettype none

module tb_sign_lfsr;
    localparam int D = 64;

    logic clk = 0;
    logic rst_n = 0;
    logic start = 0;
    logic valid;
    logic sign_bit;
    logic last;

    sign_lfsr #(.D(D)) dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .step(1'b1),
        .valid(valid), .sign_bit(sign_bit), .last(last)
    );

    always #5 clk = ~clk;

    // Golden bits as 0/1.
    logic [0:0] golden [D];
    int errors = 0;
    int i;

    initial begin
        $readmemh("../../tb/golden/out/signs.mem", golden);
    end

    initial begin
        // Reset
        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);
        // Pulse start
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Capture D valid sign_bits
        i = 0;
        while (i < D) begin
            @(posedge clk);
            if (valid) begin
                if (sign_bit !== golden[i][0]) begin
                    $display("[FAIL] cycle %0d: rtl=%0d golden=%0d", i, sign_bit, golden[i][0]);
                    errors = errors + 1;
                end
                if (i == D - 1 && !last) begin
                    $display("[FAIL] last not asserted on final bit");
                    errors = errors + 1;
                end
                i = i + 1;
            end
        end

        // After D bits, valid should be low next cycle.
        @(posedge clk);
        if (valid) begin
            $display("[FAIL] valid still high after D bits");
            errors = errors + 1;
        end

        if (errors == 0) $display("[PASS] sign_lfsr matched golden over %0d bits", D);
        else             $display("[FAIL] %0d mismatches", errors);
        $finish(errors == 0 ? 0 : 1);
    end

`ifdef DUMP_FST
    initial begin
        if ($test$plusargs("trace")) begin
            $dumpfile("waves.fst");
            $dumpvars(0, tb_sign_lfsr);
        end
    end
`endif

endmodule

`default_nettype wire
