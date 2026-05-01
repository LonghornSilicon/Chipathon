# pd/

Physical design / place-and-route flow (e.g. Cadence Innovus, Synopsys ICC2,
or OpenROAD for the SkyWater 130 nm Chipathon shuttle).

## Layout

- `scripts/` — flow scripts: floorplan, powerplan, placement, CTS, routing,
  signoff.
- `floorplan/` — DEF/FP TCL, pin placement, macro placement guides.
- `tech/` — PDK setup (tech LEF, captables, RC corners).
- `reports/` — per-stage timing/DRC/LVS/power reports (gitignored except
  signoff summaries).
- `outputs/` — final GDS, DEF, LEF, SPEF, netlist (gitignored — large).
- `logs/` — tool transcripts (gitignored).

## Inputs

- Gate-level netlist + post-synth SDC from [`../dc/`](../dc).
- Shared timing constraints from [`../constraints/`](../constraints).

## Signoff outputs

- `outputs/<top>.gds` — for tape-out.
- `outputs/<top>.spef` — for post-route STA.
- `outputs/<top>.sdf` — for gate-level simulation in [`../sim/`](../sim).
