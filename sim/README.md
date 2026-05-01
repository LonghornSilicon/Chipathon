# sim/

Simulation run area for RTL ([`../rtl/`](../rtl)) and gate-level
netlists ([`../dc/`](../dc), [`../pd/`](../pd)).

## Layout

- `Makefile` — top-level targets: `rtl`, `gate`, `cov`, `clean`.
- `filelists/` — `.f` files defining compile order per netlist level.
- `runs/` — per-run working directories (gitignored). Each run captures:
  - `compile.log`, `sim.log`
  - `waves.fst` / `waves.vcd`
  - coverage database
- `regress/` — regression manifests and nightly scripts.
- `waves/` — checked-in waveform configurations (`.gtkw`, `.do`).

## Typical commands

```bash
make rtl  TEST=smoke
make rtl  TEST=<uvm_test_name>
make gate NETLIST=../pd/outputs/<top>.v SDF=../pd/outputs/<top>.sdf
make cov
```

## Conventions

- All run artifacts are written under `runs/<timestamp>_<test>/`.
- Random seeds are recorded with each run so failures are reproducible.
