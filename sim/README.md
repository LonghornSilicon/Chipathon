# sim/

Verilator simulation runs for the testbenches in [../tb/](../tb/).

## Quick start

```bash
make TB=int4_pe run
make TB=mac_array_4x4 SEED=42 VERBOSE=1 run
make all                     # run every registered testbench
make TB=int4_pe clean
make list                    # list registered testbenches
```

Build artifacts and logs land under `<TB>/build/` and `<TB>/logs/`,
both git-ignored. The repo root never sees `obj_dir/`.

## Waveforms

Each testbench dumps an FST waveform when invoked with `+trace`. The
Makefile wraps that for you:

```bash
make TB=int4_pe waves                  # writes int4_pe/waves/waves.fst
make TB=mac_array_4x4 SEED=7 waves     # writes mac_array_4x4/waves/waves.fst
make TB=int4_pe view                   # opens it in $VIEWER (gtkwave by default)
make TB=int4_pe VIEWER=surfer view     # use Surfer instead
```

Viewer options on Linux / WSLg:

- **GTKWave** (`sudo apt install gtkwave`) — classic, FST/VCD support.
- **Surfer** (`cargo install surfer` or grab a release binary) — modern,
  Rust-based, snappier UI; opens the same FST files.

Tracing is opt-in (the binary doesn't dump unless `+trace` is set), so
plain `make run` stays fast.

## Adding a testbench

1. Add `tb/tb_<name>.sv` (Verilator-style; `+seed=N` and `+verbose`
   plusargs are the project convention).
2. In [Makefile](Makefile), add one line next to the existing
   `SRCS_*` definitions:

   ```make
   SRCS_<name> := $(RTL_DIR)/<rtl_files>.sv
   ```

3. `make TB=<name> run`.
