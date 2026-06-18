// tb_tq_top.sv
//
// End-to-end self-checking testbench for tq_top. Drives 64 input bytes
// for a chosen golden vector, then reads back the 26-byte output frame
// and compares against vec_<id>_norm_bytes.hex (2 bytes) and
// vec_<id>_packed.hex (24 bytes).
//
// Pin connections to tq_top match PLAN.md §7. Run with:
//   make TB=tq_top run                  # vec=0
//   make TB=tq_top SEED=3 VERBOSE=1 run  # SEED selects vec id

`timescale 1ns/1ps
`default_nettype none

module tb_tq_top;
    localparam int D       = 64;
    localparam int N_OUT_BYTES = 26;

    logic clk = 0;
    logic rst_n = 0;
    logic ena = 0;
    logic [7:0] ui_in   = '0;
    logic [7:0] uo_out;
    logic [7:0] uio_in  = '0;
    logic [7:0] uio_out;
    logic [7:0] uio_oe;

    tq_top #(
        .BOUNDS_FILE   ("../../tb/golden/out/codebook_bounds.mem"),
        .CENTROIDS_FILE("../../tb/golden/out/codebook_centroids.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n), .ena(ena),
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe)
    );

    always #5 clk = ~clk;

    // Convenience aliases for handshake bits.
    logic chip_rx_ready;
    logic chip_tx_valid;
    assign chip_rx_ready = uio_out[0];
    assign chip_tx_valid = uio_out[1];

    int    vec_id = 0;
    string xfile, nbfile, pfile;

    logic [7:0] x_arr        [D];
    logic [7:0] norm_bytes_g [2];
    logic [7:0] packed_g     [N_OUT_BYTES - 2];   // 24
    logic [7:0] cap_bytes    [N_OUT_BYTES];
    int captured = 0;
    int errors   = 0;

    initial begin
        if (!$value$plusargs("vec=%d", vec_id)) vec_id = 0;
        $sformat(xfile,  "../../tb/golden/out/vec_%03d_x.hex",          vec_id);
        $sformat(nbfile, "../../tb/golden/out/vec_%03d_norm_bytes.hex", vec_id);
        $sformat(pfile,  "../../tb/golden/out/vec_%03d_packed.hex",     vec_id);
        $readmemh(xfile,  x_arr);
        $readmemh(nbfile, norm_bytes_g);
        $readmemh(pfile,  packed_g);

        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        ena   = 1;
        @(posedge clk);
        $display("[t=%0t] reset done, state_dbg=%0d, chip_rx_ready=%b",
                 $time, dut.state_dbg, chip_rx_ready);

        // ---- Drive 64 input bytes via standard ready/valid handshake ----
        // Host holds valid+data until chip_rx_ready goes high at a posedge,
        // at which point the byte was latched and we advance to the next.
        for (int i = 0; i < D; i++) begin
            ui_in     <= x_arr[i];
            uio_in[2] <= 1'b1;        // host_tx_valid
            // Limit waiting to 100 cycles per byte to avoid infinite loop.
            for (int w = 0; w < 100; w++) begin
                @(posedge clk);
                if (chip_rx_ready) break;
                if (w == 99) begin
                    $display("[t=%0t] STUCK: byte %0d not consumed, state_dbg=%0d, chip_rx_ready=%b",
                             $time, i, dut.state_dbg, chip_rx_ready);
                    $finish(2);
                end
            end
            if (i < 4 || i % 16 == 15) $display("[t=%0t] sent byte %0d, state_dbg=%0d", $time, i, dut.state_dbg);
        end
        uio_in[2] <= 1'b0;
        ui_in     <= '0;
        $display("[t=%0t] RX done, waiting for output", $time);

        // ---- Read 26 output bytes with host_rx_ready=1 always ----
        uio_in[3] <= 1'b1;
        while (captured < N_OUT_BYTES) @(posedge clk);
        uio_in[3] <= 1'b0;

        // ---- Compare ----
        for (int i = 0; i < 2; i++) begin
            if (cap_bytes[i] !== norm_bytes_g[i]) begin
                $display("[FAIL] norm byte[%0d] rtl=0x%02h ref=0x%02h",
                         i, cap_bytes[i], norm_bytes_g[i]);
                errors = errors + 1;
            end
        end
        for (int i = 0; i < N_OUT_BYTES - 2; i++) begin
            if (cap_bytes[i + 2] !== packed_g[i]) begin
                $display("[FAIL] packed byte[%0d] rtl=0x%02h ref=0x%02h",
                         i, cap_bytes[i + 2], packed_g[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("[PASS] tq_top vec=%0d  %0d output bytes match", vec_id, N_OUT_BYTES);
        else
            $display("[FAIL] tq_top vec=%0d  %0d errors", vec_id, errors);
        $finish(errors == 0 ? 0 : 1);
    end

    // Capture chip output bytes when chip_tx_valid AND host_rx_ready.
    always_ff @(posedge clk) begin
        if (rst_n && chip_tx_valid && uio_in[3] && captured < N_OUT_BYTES) begin
            cap_bytes[captured] = uo_out;
            captured = captured + 1;
            if ($test$plusargs("verbose"))
                $display("  out[%0d] = 0x%02h", captured - 1, uo_out);
        end
    end

    initial begin #20000 $display("[FAIL] tq_top timeout (sim_t=%0t)", $time); $finish(1); end

endmodule

`default_nettype wire
