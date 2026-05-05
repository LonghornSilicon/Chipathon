# pd/

OpenLane 2 hardening flow for each block we tape out. One subdirectory
per design; each holds its own `config.json` and references shared RTL
in `../../rtl/` and shared timing constraints in `../../constraints/`.

## Layout

```
pd/
├── .gitignore           # keeps runs/ out of git
└── <design>/
    └── config.json      # OpenLane 2 config for this block
```

Currently hardened blocks:

| Design | RTL top | SDC |
| --- | --- | --- |
| `mac_array_4x4` | [../rtl/mac_array_4x4.sv](../rtl/mac_array_4x4.sv) | [../constraints/mac_array_4x4.sdc](../constraints/mac_array_4x4.sdc) |

## Running

From the repo root, with OpenLane 2 on `PATH` and `PDK_ROOT` pointing at
a sky130A install:

```bash
openlane pd/mac_array_4x4/config.json
```

Outputs land under `pd/<design>/runs/<tag>/`:

- `results/final/gds/<design>.gds` — final layout
- `results/final/verilog/gl/<design>.v` — gate-level netlist (for sim)
- `results/final/sdf/<design>.sdf` — back-annotation for GL sim
- `reports/signoff/` — STA, DRC, LVS reports

## Notes

- `mac_array_4x4` exposes unpacked-array ports (`weight_i [ROWS][COLS]`,
  `act_i [ROWS]`, `col_o [COLS]`). Yosys flattens these for synthesis,
  which is fine for a block boundary; if this design ever becomes a
  chip top, the ports must be packed into flat buses first.
- The first-pass `DIE_AREA` (350x350 um) and `FP_CORE_UTIL` (35%) are
  intentionally loose. Tighten after the first clean signoff.
