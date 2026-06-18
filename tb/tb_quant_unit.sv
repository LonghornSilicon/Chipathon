// tb_quant_unit.sv
//
// Self-checking testbench for quant_unit.sv. For a chosen vector,
// streams the 64 post-WHT y values + the per-vector inv_norm constant,
// captures the 64 emitted indices, and compares against the golden
// ``vec_<id>_idx.hex``. Bounds load from the same .mem file the chip
// reads.

`timescale 1ns/1ps
`default_nettype none

module tb_quant_unit;
    localparam int D          = 64;
    localparam int Y_W        = 14;
    localparam int INV_W      = 15;
    localparam int RSQRT_FRAC = 13;
    localparam int U_FRAC     = 9;
    localparam int CB_FRAC    = 9;
    localparam int N_BOUNDS   = 7;
    localparam int CB_W       = CB_FRAC + 2;
    localparam int IDX_W      = 3;

    logic clk = 0;
    logic rst_n = 0;
    logic in_valid = 0;
    logic signed [Y_W-1:0] y_i = '0;
    logic [INV_W-1:0]      inv_norm = '0;
    logic out_valid;
    logic [IDX_W-1:0] idx_out;
    logic signed [CB_W-1:0] bounds [N_BOUNDS];

    // Load bounds into an internal ROM via a wrapper module so $readmemh
    // hits the same .mem the chip uses.
    codebook_rom #(.N_BOUNDS(N_BOUNDS), .N_CENTROIDS(8), .W(CB_W),
        .BOUNDS_FILE   ("../../tb/golden/out/codebook_bounds.mem"),
        .CENTROIDS_FILE("../../tb/golden/out/codebook_centroids.mem")
    ) cb (
        .bounds_all(bounds),
        .centroids_all()
    );

    quant_unit #(
        .Y_W(Y_W), .INV_W(INV_W),
        .RSQRT_FRAC(RSQRT_FRAC), .U_FRAC(U_FRAC), .CB_FRAC(CB_FRAC),
        .N_BOUNDS(N_BOUNDS), .CB_W(CB_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .y_i(y_i), .inv_norm(inv_norm),
        .bounds_in(bounds),
        .out_valid(out_valid), .idx_out(idx_out)
    );

    always #5 clk = ~clk;

    int    vec_id = 0;
    string yfile, ifile, infile;
    logic [Y_W-1:0]      y_arr  [D];
    logic [IDX_W-1:0]    ref_idx [D];
    logic [INV_W-1:0]    inv_arr [1];
    logic [IDX_W-1:0]    cap [D];
    int captured = 0;
    int errors = 0;

    initial begin
        if (!$value$plusargs("vec=%d", vec_id)) vec_id = 0;
        $sformat(yfile, "../../tb/golden/out/vec_%03d_y.hex", vec_id);
        $sformat(ifile, "../../tb/golden/out/vec_%03d_idx.hex", vec_id);
        $sformat(infile, "../../tb/golden/out/vec_%03d_invn.hex", vec_id);
        $readmemh(yfile, y_arr);
        $readmemh(ifile, ref_idx);
        $readmemh(infile, inv_arr);

        rst_n = 0;
        repeat (3) @(posedge clk);
        rst_n = 1;
        inv_norm <= inv_arr[0];
        @(posedge clk);

        for (int i = 0; i < D; i++) begin
            y_i      <= $signed(y_arr[i]);
            in_valid <= 1'b1;
            @(posedge clk);
        end
        in_valid <= 1'b0;
        y_i      <= '0;

        // Drain pipeline (1-cycle latency).
        @(posedge clk);
        @(posedge clk);

        if (captured != D) begin
            $display("[FAIL] captured %0d indices (expected %0d)", captured, D);
            errors = errors + 1;
        end
        for (int i = 0; i < D && i < captured; i++) begin
            if (cap[i] !== ref_idx[i]) begin
                $display("[FAIL] idx[%0d] rtl=%0d ref=%0d (y=0x%0h inv=0x%0h)",
                         i, cap[i], ref_idx[i], y_arr[i], inv_arr[0]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("[PASS] quant_unit vec=%0d  %0d indices match", vec_id, D);
        else
            $display("[FAIL] quant_unit vec=%0d  %0d errors", vec_id, errors);
        $finish(errors == 0 ? 0 : 1);
    end

    always_ff @(posedge clk) begin
        if (rst_n && out_valid && captured < D) begin
            cap[captured] = idx_out;
            captured = captured + 1;
        end
    end

    initial begin #5000 $display("[FAIL] quant_unit timeout"); $finish(1); end

endmodule

`default_nettype wire
