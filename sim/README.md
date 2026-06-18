# sim/

Verilator simulation runs for the TurboQuant testbenches in
[../tb/](../tb/).

## Quick start

```bash
make TB=sign_lfsr run
make TB=tq_top SEED=3 VEC=1 VERBOSE=1 run
make all                          # build & run every TB
make TB=sign_lfsr clean
make list                         # list registered testbenches
make goldens                      # regenerate ../tb/golden/out/*.{mem,hex}
```

Build artifacts and logs land under `<TB>/build/` and `<TB>/logs/`, both
git-ignored. The repo root never sees `obj_dir/`.

## Testbenches

| TB             | DUT                | Compares against                                       |
| -------------- | ------------------ | ------------------------------------------------------ |
| `sign_lfsr`    | `sign_lfsr.sv`     | `tb/golden/out/signs.mem`                              |
| `codebook_rom` | `codebook_rom.sv`  | symmetry / monotonicity of `codebook_*.mem`            |
| `bit_packer`   | `bit_packer.sv`    | inline reference packing (random 3-bit indices)        |
| `wht64`        | `wht64.sv`         | `vec_<id>_y.hex`                                       |
| `norm2_acc`    | `norm2_acc.sv`     | `vec_<id>_norm2.hex`                                   |
| `rsqrt_unit`   | `rsqrt_unit.sv`    | `vec_<id>_invn.hex`                                    |
| `quant_unit`   | `quant_unit.sv`    | `vec_<id>_idx.hex`                                     |
| `tq_top`       | full encoder       | `vec_<id>_norm_bytes.hex` + `vec_<id>_packed.hex`      |

`VEC=N` selects which vector ID. `make goldens` regenerates them via
`python -m tb.golden.gen_vectors`.

## Goldens

Goldens live under `../tb/golden/out/` and are regenerated from the
Python reference in `../tb/golden/`:

```bash
make goldens                     # writes signs.mem, codebook_*.mem,
                                 # vec_<id>_*.hex (n=8 by default)
```

Each TB reads its goldens via the `$readmemh` paths shown above. The
Makefile auto-runs `goldens` if `../tb/golden/out/signs.mem` is missing,
so a fresh checkout works with a plain `make all`.

## Waveforms

Each testbench dumps an FST waveform when invoked with `+trace`:

```bash
make TB=tq_top waves              # writes tq_top/waves/waves.fst
make TB=tq_top view               # opens it in $VIEWER (gtkwave by default)
make TB=tq_top VIEWER=surfer view # use Surfer instead
```

Viewer options on Linux / WSLg / macOS:

- **GTKWave** (`brew install --cask gtkwave` on macOS, `sudo apt install gtkwave` on Linux)
- **Surfer** (`cargo install surfer` or grab a release binary) — modern,
  Rust-based, snappier UI; opens the same FST files.

Tracing is opt-in (the binary doesn't dump unless `+trace` is set), so
plain `make run` stays fast.

## Tools

- Install Verilator: `brew install verilator` (macOS) or `sudo apt install verilator`
  (Ubuntu). Tested with Verilator 5.x and `--binary -sv` flow.
- Install Icarus (alternative simulator, useful for quick smoke tests):
  `brew install icarus-verilog`. The Makefile is Verilator-only at the
  moment; iverilog support is on the wishlist.

## Adding a testbench

1. Add `tb/tb_<name>.sv` (Verilator-style; `+seed=N`, `+vec=N`, and
   `+verbose` plusargs are the project convention; finish with
   `$finish(N)` where `N != 0` indicates failure).
2. In [Makefile](Makefile), add one line:

   ```make
   SRCS_<name> := $(RTL_DIR)/<rtl_files>.sv
   ```

3. `make TB=<name> run`.
