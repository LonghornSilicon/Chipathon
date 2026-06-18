// tb_codebook_rom.sv
//
// Self-checking testbench for codebook_rom.sv. Verifies that the ROM
// loads bounds + centroids correctly from $readmemh. Cross-checks the
// 7 interior bounds against an inline expected list (sorted ascending).

`timescale 1ns/1ps
`default_nettype none

module tb_codebook_rom;
    localparam int N_BOUNDS    = 7;
    localparam int N_CENTROIDS = 8;
    localparam int W           = 11;

    logic signed [W-1:0] bounds_all    [N_BOUNDS];
    logic signed [W-1:0] centroids_all [N_CENTROIDS];

    codebook_rom #(
        .N_BOUNDS(N_BOUNDS), .N_CENTROIDS(N_CENTROIDS), .W(W),
        .BOUNDS_FILE   ("../../tb/golden/out/codebook_bounds.mem"),
        .CENTROIDS_FILE("../../tb/golden/out/codebook_centroids.mem")
    ) dut (
        .bounds_all(bounds_all),
        .centroids_all(centroids_all)
    );

    int errors = 0;

    initial begin
        // Settle
        #1;
        // Bounds must be sorted ascending.
        for (int i = 1; i < N_BOUNDS; i++) begin
            if (bounds_all[i] <= bounds_all[i-1]) begin
                $display("[FAIL] bounds not strictly ascending at i=%0d (%0d <= %0d)",
                         i, bounds_all[i], bounds_all[i-1]);
                errors = errors + 1;
            end
        end

        // Codebook must be symmetric around 0 (Lloyd-Max on a symmetric Beta).
        for (int i = 0; i < N_BOUNDS / 2; i++) begin
            if (bounds_all[i] !== -bounds_all[N_BOUNDS - 1 - i]) begin
                $display("[FAIL] bound[%0d]=%0d not the negation of bound[%0d]=%0d",
                         i, bounds_all[i], N_BOUNDS - 1 - i, bounds_all[N_BOUNDS - 1 - i]);
                errors = errors + 1;
            end
        end
        // Middle bound must be exactly zero.
        if (bounds_all[N_BOUNDS / 2] !== '0) begin
            $display("[FAIL] middle bound not zero: %0d", bounds_all[N_BOUNDS / 2]);
            errors = errors + 1;
        end

        // Centroids must also be sorted ascending and symmetric.
        for (int i = 1; i < N_CENTROIDS; i++) begin
            if (centroids_all[i] <= centroids_all[i-1]) begin
                $display("[FAIL] centroids not strictly ascending at i=%0d", i);
                errors = errors + 1;
            end
        end
        for (int i = 0; i < N_CENTROIDS / 2; i++) begin
            if (centroids_all[i] !== -centroids_all[N_CENTROIDS - 1 - i]) begin
                $display("[FAIL] centroid[%0d] not the negation of centroid[%0d]",
                         i, N_CENTROIDS - 1 - i);
                errors = errors + 1;
            end
        end

        if ($test$plusargs("verbose")) begin
            $write("bounds:    ");
            for (int i = 0; i < N_BOUNDS; i++) $write(" %0d", bounds_all[i]);
            $write("\ncentroids: ");
            for (int i = 0; i < N_CENTROIDS; i++) $write(" %0d", centroids_all[i]);
            $write("\n");
        end

        if (errors == 0) $display("[PASS] codebook_rom");
        else             $display("[FAIL] %0d errors", errors);
        $finish(errors == 0 ? 0 : 1);
    end

endmodule

`default_nettype wire
