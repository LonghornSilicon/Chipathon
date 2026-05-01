# dc/

Synopsys Design Compiler synthesis flow (RTL to gate-level netlist).

## Layout

- `scripts/` — flow scripts (`setup.tcl`, `read_design.tcl`,
  `compile.tcl`, `reports.tcl`).
- `rm_setup/` — library setup (target/link libraries, search paths,
  Milkyway / NDM references).
- `reports/` — timing, area, and power reports per run (gitignored except
  signoff summaries).
- `outputs/` — gate-level netlist, SDF, post-synth SDC (gitignored).
- `logs/` — tool transcripts (gitignored).

## Inputs

- RTL from [`../rtl/`](../rtl).
- Constraints from [`../constraints/`](../constraints).

## Outputs

- `outputs/<top>.mapped.v` — gate-level netlist consumed by
  [`../pd/`](../pd).
- `outputs/<top>.mapped.sdc` — post-synth constraints consumed by
  [`../pd/`](../pd).

## Invocation

```bash
dc_shell -f scripts/run_dc.tcl | tee logs/dc.log
```
