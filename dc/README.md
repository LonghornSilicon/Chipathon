# dc/

Synopsys Design Compiler flow: RTL → gate-level netlist.

## Layout

- `scripts/` — `*.tcl` flow scripts (`setup.tcl`, `read_design.tcl`,
  `compile.tcl`, `reports.tcl`).
- `rm_setup/` — library setup (target/link libraries, search paths, MW/NDM).
- `reports/` — timing/area/power reports per run (gitignored except summaries).
- `outputs/` — gate-level netlist, SDF, and post-synth SDC (gitignored).
- `logs/` — DC log/transcript files (gitignored).

## Inputs

- RTL from [`../rtl/`](../rtl).
- Constraints from [`../constraints/`](../constraints) (shared SDC).

## Outputs (handed off to PD)

- `outputs/<top>.mapped.v` — gate-level netlist.
- `outputs/<top>.mapped.sdc` — post-synth constraints for [`../pd/`](../pd).

## Run

```bash
dc_shell -f scripts/run_dc.tcl | tee logs/dc.log
```
