# pd/

Physical design / place-and-route flow (Cadence Innovus, Synopsys ICC2,
or OpenROAD targeting the SkyWater 130 nm shuttle).

## Layout

- `scripts/` — flow scripts: floorplan, power plan, placement, CTS,
  routing, signoff.
- `floorplan/` — DEF and floorplan TCL, pin placement, macro guides.
- `tech/` — PDK setup (technology LEF, captables, RC corners).
- `reports/` — per-stage timing, DRC, LVS, and power reports (gitignored
  except signoff summaries).
- `outputs/` — final GDS, DEF, LEF, SPEF, and netlist (gitignored).
- `logs/` — tool transcripts (gitignored).

## Inputs

- Gate-level netlist and post-synth SDC from [`../dc/`](../dc).
- Shared timing constraints from [`../constraints/`](../constraints).

## Signoff outputs

- `outputs/<top>.gds` — tape-out database.
- `outputs/<top>.spef` — parasitics for post-route STA.
- `outputs/<top>.sdf` — back-annotation for gate-level simulation in
  [`../sim/`](../sim).
