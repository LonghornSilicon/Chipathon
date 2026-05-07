// weight_rom.sv
//
// 256 x INT4 on-chip weight ROM for the int4_mac_accel block. Entries
// are signed INT4 nibbles. The ROM has one synchronous read port with
// 1-cycle latency, mirroring accum_bank's read interface.
//
// Initialisation:
//   * If the text macro `WEIGHT_ROM_INIT_FILE` is defined (e.g.
//     `+define+WEIGHT_ROM_INIT_FILE='"weights.hex"'` for the
//     simulator, or VERILOG_DEFINES for OpenLane) the ROM is loaded
//     from that hex file via $readmemh (one signed INT4 nibble per
//     line, padded to 4 bits).
//   * Otherwise the ROM is filled at elaboration with a deterministic
//     pseudorandom sequence (32-bit LFSR seeded from INIT_SEED). Both
//     this RTL and the TB compute the same sequence from the same
//     seed, so the TB can predict every entry without parsing a file.
//
// The init-file path is a `define rather than a `parameter string`
// because Yosys's Verilog-2005 frontend (used by OpenLane regardless
// of the .sv extension) does not accept `parameter string`, and no
// caller in this repo currently overrides the init-file path anyway.
//
// Yosys constant-folds either path into per-bit muxes; downstream
// instantiations (e.g. driving mac_array_4x4.weight_flat_i) collapse
// the multiplier area dramatically per the spec's "synthesized
// constants" intent.

`timescale 1ns/1ps
`default_nettype none

module weight_rom #(
    parameter int ENTRIES   = 256,
    parameter int DATA_W    = 4,
    parameter int ADDR_W    = $clog2(ENTRIES),
    parameter int INIT_SEED = 32'hC0FFEE42
) (
    input  logic                          clk,
    input  logic                          rst_n,

    input  logic                          rd_en,
    input  logic [ADDR_W-1:0]             rd_addr,
    output logic signed [DATA_W-1:0]      rd_data
);

    // 32-bit Galois LFSR step. Pure function so both RTL elaboration
    // and the TB can call it deterministically. Uses function-name
    // assignment (not `return`) so Yosys's Verilog-2005 frontend
    // accepts it; Verilator handles either form fine.
    function automatic logic [31:0] lfsr_step (input logic [31:0] s);
        logic [31:0] r;
        r = s;
        for (int i = 0; i < 8; i++) begin
            r = (r >> 1) ^ ({32{r[0]}} & 32'hEDB88320);
        end
        lfsr_step = r;
    endfunction

    function automatic logic signed [DATA_W-1:0]
            default_weight (input int idx);
        logic [31:0] s;
        s = INIT_SEED ^ {16'h0, idx[15:0]};
        s = lfsr_step(s);
        default_weight = DATA_W'(s[DATA_W-1:0]);
    endfunction

    (* rom_style = "logic" *)
    logic signed [DATA_W-1:0] rom [ENTRIES];

    initial begin
`ifdef WEIGHT_ROM_INIT_FILE
        $readmemh(`WEIGHT_ROM_INIT_FILE, rom);
`else
        for (int i = 0; i < ENTRIES; i++) begin
            rom[i] = default_weight(i);
        end
`endif
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rd_data <= '0;
        end else if (rd_en) begin
            rd_data <= rom[rd_addr];
        end
    end

endmodule

`default_nettype wire
