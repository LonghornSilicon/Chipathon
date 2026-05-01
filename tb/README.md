# tb/

Verification environment for the RTL in [`../rtl/`](../rtl).

## Layout

- `uvm/` — UVM env: agents, sequencers, drivers, monitors, scoreboards.
- `tests/` — UVM tests and sequences (one file per test).
- `cocotb/` — optional Python/cocotb tests for quick block-level checks.
- `models/` — reference / golden models used by scoreboards.
- `common/` — shared interfaces, transactions, and utility packages.

## Conventions

- Testbench code is simulation-only — never imported by [`../rtl/`](../rtl).
- Each test prints a clear PASS/FAIL banner; exit code drives CI.
- Coverage (functional + code) is collected by default; results land in
  [`../sim/`](../sim) run directories.
