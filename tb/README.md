# tb/

Verification environment for the RTL in [`../rtl/`](../rtl).

## Layout

- `uvm/` — UVM env: agents, sequencers, drivers, monitors, scoreboards.
- `tests/` — UVM tests and sequences (one file per test).
- `cocotb/` — optional cocotb tests for block-level checks.
- `models/` — reference / golden models used by scoreboards.
- `common/` — shared interfaces, transactions, and utility packages.

## Conventions

- Testbench code is simulation-only and is never imported by
  [`../rtl/`](../rtl).
- Each test reports a deterministic PASS/FAIL status; the simulator exit
  code drives CI.
- Functional and code coverage are collected by default; databases are
  written to the corresponding run directory under [`../sim/`](../sim).
