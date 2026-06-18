# pd/

OpenLane 2 hardening flow for each TurboQuant block. One subdirectory
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

## Blocks (planned)

These match the modules in [PLAN.md §5](../PLAN.md#5-module-decomposition).
Per-block configs and SDCs land here as RTL stabilises.

| Design          | RTL top                                 | Notes                              |
| --------------- | --------------------------------------- | ---------------------------------- |
| `sign_lfsr`     | [../rtl/sign_lfsr.sv](../rtl/sign_lfsr.sv)         | tiny — 16 flops + xor + fsm        |
| `wht64`         | [../rtl/wht64.sv](../rtl/wht64.sv)                 | dominant area: 64×14b reg file     |
| `norm2_acc`     | [../rtl/norm2_acc.sv](../rtl/norm2_acc.sv)         | one mult + 32-bit adder            |
| `rsqrt_unit`    | [../rtl/rsqrt_unit.sv](../rtl/rsqrt_unit.sv)       | sequential isqrt + divider         |
| `quant_unit`    | [../rtl/quant_unit.sv](../rtl/quant_unit.sv)       | mult + 7 parallel comparators      |
| `codebook_rom`  | [../rtl/codebook_rom.sv](../rtl/codebook_rom.sv)   | trivial — flop-mapped constants    |
| `bit_packer`    | [../rtl/bit_packer.sv](../rtl/bit_packer.sv)       | trivial — 11-bit shift register    |
| `tq_top`        | [../rtl/tq_top.sv](../rtl/tq_top.sv)               | full encoder, TT pinout            |

`tq_top` is the chip-level deliverable. The other entries are useful
for area / timing characterisation per block during bring-up.

## Running

Prereqs: OpenLane 2 Python package on `PATH`, `PDK_ROOT` set (e.g.
`volare enable --pdk sky130`), and either Docker (default) or the
native EDA tools (yosys, openroad, magic, netgen, klayout) installed.

From this directory:

```bash
make check                     # verify openlane + PDK_ROOT + config
make harden                    # default DESIGN=tq_top, DOCKERIZED=1
make DESIGN=wht64 harden       # explicit form
make DOCKERIZED=0 harden       # use native EDA tools instead of the container
make summary                   # last run's metrics + report file list
make view-gds                  # open final GDS in klayout
make clean                     # wipe this design's runs/
make list                      # list registered designs
```

`DOCKERIZED=1` (the default) runs OpenLane inside the official container
image, which bundles all EDA tools. The first run pulls a multi-GB
image; subsequent runs reuse the cache.

Equivalent raw invocations (what `harden` does):

```bash
openlane --dockerized pd/tq_top/config.json   # DOCKERIZED=1
openlane              pd/tq_top/config.json   # DOCKERIZED=0
```

Outputs land under `pd/<design>/runs/<tag>/final/`:

- `gds/<design>.gds` — final layout
- `nl/<design>.nl.v` — gate-level netlist (for sim)
- `sdf/<design>.sdf` — SDF for back-annotated GL sim
- `reports/signoff/` — STA, DRC, LVS reports

## Notes

- `wht64` carries the chip's largest reg file (64 × 14 bits = 896
  flops). Watch its post-synth area to decide whether SKY130 SRAM
  macros are warranted in the next spin.
- `quant_unit.bounds_in` is an unpacked-array port. Yosys flattens
  these for block-level synthesis but if any of these blocks ever
  become a chip-top by themselves, the ports must be packed into
  flat buses first.
- First-pass `DIE_AREA` and `FP_CORE_UTIL` per design will be intentionally
  loose. Tighten after the first clean signoff.
