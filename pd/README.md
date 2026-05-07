# pd/

OpenLane 2 hardening flow for each block we tape out. One subdirectory
per design; each holds its own `config.json` and references shared RTL
in `../../rtl/` and shared timing constraints in `../../constraints/`.

## Layout

```
pd/
├── .gitignore           # keeps runs/ out of git
├── Makefile             # wrapper around `openlane`
└── <design>/
    └── config.json      # OpenLane 2 config for this block
```

Currently hardened blocks:

| Design | RTL top | SDC |
| --- | --- | --- |
| `mac_array_4x4` | [../rtl/mac_array_4x4.sv](../rtl/mac_array_4x4.sv) | [../constraints/mac_array_4x4.sdc](../constraints/mac_array_4x4.sdc) |
| `accum_bank` | [../rtl/accum_bank.sv](../rtl/accum_bank.sv) | [../constraints/accum_bank.sdc](../constraints/accum_bank.sdc) |
| `requant_sat` | [../rtl/requant_sat.sv](../rtl/requant_sat.sv) | [../constraints/requant_sat.sdc](../constraints/requant_sat.sdc) |
| `act_lut` | [../rtl/act_lut.sv](../rtl/act_lut.sv) | [../constraints/act_lut.sdc](../constraints/act_lut.sdc) |
| `weight_rom` | [../rtl/weight_rom.sv](../rtl/weight_rom.sv) | [../constraints/weight_rom.sdc](../constraints/weight_rom.sdc) |
| `act_streamer` | [../rtl/act_streamer.sv](../rtl/act_streamer.sv) | [../constraints/act_streamer.sdc](../constraints/act_streamer.sdc) |
| `ctrl_io` | [../rtl/ctrl_io.sv](../rtl/ctrl_io.sv) | [../constraints/ctrl_io.sdc](../constraints/ctrl_io.sdc) |
| `int4_mac_accel` | [../rtl/int4_mac_accel.sv](../rtl/int4_mac_accel.sv) | [../constraints/int4_mac_accel.sdc](../constraints/int4_mac_accel.sdc) |

## Running

Prereqs: OpenLane 2 Python package on `PATH`, `PDK_ROOT` set (e.g.
`volare enable --pdk sky130`), and either Docker (default) or the
native EDA tools (yosys, openroad, magic, netgen, klayout) installed.

From this directory:

```bash
make check                       # verify openlane + PDK_ROOT + config
make harden                      # default DESIGN=mac_array_4x4, DOCKERIZED=1
make DESIGN=mac_array_4x4 harden # explicit form
make DOCKERIZED=0 harden         # use native EDA tools instead of the container
make summary                     # last run's metrics + report file list
make view-gds                    # open final GDS in klayout
make clean                       # wipe this design's runs/
make list                        # list registered designs
```

`DOCKERIZED=1` (the default) runs OpenLane inside the official container
image, which bundles all EDA tools. The first run pulls a multi-GB
image; subsequent runs reuse the cache.

Equivalent raw invocations (what `harden` does):

```bash
openlane --dockerized pd/mac_array_4x4/config.json   # DOCKERIZED=1
openlane               pd/mac_array_4x4/config.json   # DOCKERIZED=0
```

Outputs land under `pd/<design>/runs/<tag>/final/`:

- `gds/<design>.gds` — final layout
- `nl/<design>.nl.v` — gate-level netlist (for sim)
- `sdf/<design>.sdf` — SDF for back-annotated GL sim
- `reports/signoff/` — STA, DRC, LVS reports

## Notes

- `mac_array_4x4` exposes unpacked-array ports (`weight_i [ROWS][COLS]`,
  `act_i [ROWS]`, `col_o [COLS]`). Yosys flattens these for synthesis,
  which is fine for a block boundary; if this design ever becomes a
  chip top, the ports must be packed into flat buses first.
- The first-pass `DIE_AREA` (350x350 um) and `FP_CORE_UTIL` (35%) are
  intentionally loose. Tighten after the first clean signoff.
