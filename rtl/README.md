# rtl/

Source of truth for the design. Synthesizable SystemVerilog/Verilog (and any
generated RTL) lives here.

## Layout

- `<block>/` — one folder per design block; package + module files inside.
- `top/` — top-level integration of the chip / subsystem under tape-out.
- `include/` — shared `.svh` packages, parameter files, and macros.

## Conventions

- Synthesizable RTL only. No `initial` blocks, `#delays`, or simulation-only
  constructs in this tree (those belong in [`../tb/`](../tb)).
- One module per file; filename matches the module name.
- Lint clean (Verilator / Spyglass) before pushing.
- Parameters and widths centralized in `include/` packages — no magic numbers.
