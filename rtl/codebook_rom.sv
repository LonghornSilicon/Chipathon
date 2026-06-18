// codebook_rom.sv
//
// Constant ROM holding the Lloyd-Max codebook for the d=64, b=3
// TurboQuant Algorithm 1 quantiser. Two arrays are exposed:
//
//   bounds_all[0..6]    : the 7 interior decision boundaries, signed Q1.9
//   centroids_all[0..7] : the 8 centroid values (also signed Q1.9)
//
// Both are exposed combinationally as flat unpacked arrays — the
// downstream comparator tree in ``quant_unit`` reads all 7 bounds in
// parallel each cycle, and the (stretch-goal) decode path can use the
// centroids the same way. Synthesis flattens this into wires + constants
// since the ROM is initialised from $readmemh.
//
// The .mem files are produced by ``tb/golden/gen_vectors.py`` and live
// at ``tb/golden/out/codebook_{bounds,centroids}.mem``. Update the
// MEM_DIR plusarg / parameter at the simulator level if you move them.
// The contents are 11-bit two's-complement Q1.9 fixed-point.

`timescale 1ns/1ps
`default_nettype none

module codebook_rom #(
    parameter int    N_BOUNDS    = 7,
    parameter int    N_CENTROIDS = 8,
    parameter int    W           = 11,
    parameter        BOUNDS_FILE    = "codebook_bounds.mem",
    parameter        CENTROIDS_FILE = "codebook_centroids.mem"
) (
    output logic signed [W-1:0] bounds_all    [N_BOUNDS],
    output logic signed [W-1:0] centroids_all [N_CENTROIDS]
);

    logic signed [W-1:0] bounds_rom    [N_BOUNDS];
    logic signed [W-1:0] centroids_rom [N_CENTROIDS];

    initial begin
        $readmemh(BOUNDS_FILE,    bounds_rom);
        $readmemh(CENTROIDS_FILE, centroids_rom);
    end

    // Direct (genvar-style) continuous assigns avoid the unpacked-array
    // copy-loop that some simulators struggle with at t=0 settling.
    genvar i;
    generate
        for (i = 0; i < N_BOUNDS;    i = i + 1) assign bounds_all[i]    = bounds_rom[i];
        for (i = 0; i < N_CENTROIDS; i = i + 1) assign centroids_all[i] = centroids_rom[i];
    endgenerate

endmodule

`default_nettype wire
