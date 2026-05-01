# sim/

Repeatable simulation runs for RTL ([`../rtl/`](../rtl)) and gate-level
netlists ([`../pd/`](../pd) / [`../dc/`](../dc)).

## Layout

- `Makefile` — top-level targets: `make rtl`, `make gate`, `make cov`, `make clean`.
- `filelists/` — `.f` files describing compile order for each level (rtl, gate).
- `runs/` — per-run working directories (gitignored). Each run captures:
  - `compile.log`, `sim.log`
  - `waves.fst` / `waves.vcd`
  - coverage database
- `regress/` — regression manifests + nightly scripts.
- `waves/` — checked-in waveform configs / save files (`.gtkw`, `.do`).

## Typical commands

```bash
make rtl  TEST=smoke              # quick RTL smoke test
make rtl  TEST=<uvm_test_name>    # UVM test from ../tb/tests/
make gate NETLIST=../pd/outputs/<top>.v SDF=../pd/outputs/<top>.sdf
make cov                          # merge coverage and emit HTML report
```

## Conventions

- All run artifacts go under `runs/<timestamp>_<test>/` — never the repo root.
- Seeds are recorded so failing runs can be reproduced exactly.
