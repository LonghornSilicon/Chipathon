# rtl/

Synthesizable RTL source for the design.

## Layout

- `<block>/` — one directory per design block; package and module files.
- `top/` — top-level integration.
- `include/` — shared `.svh` packages, parameter files, and macros.

## Conventions

- Synthesizable constructs only. Simulation-only constructs (`initial`
  blocks, `#` delays, force/release, etc.) belong in [`../tb/`](../tb).
- One module per file; filename matches the module name.
- Lint-clean (Verilator / Spyglass) prior to merge.
- Parameters and bit widths are centralized in `include/` packages.
