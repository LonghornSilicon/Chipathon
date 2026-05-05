# Chipathon

IEEE SSCS Chipathon — 130 nm tape-out project.

## Repository layout

| Directory | Purpose |
| --- | --- |
| `rtl/` | Synthesizable RTL source (SystemVerilog / Verilog). |
| `tb/` | Verification environment (UVM, optional cocotb). |
| `constraints/` | Shared timing and design constraints (SDC). |
| `pd/` | OpenLane RTL-to-GDSII flow (Yosys synthesis + OpenROAD PnR). |
| `sim/` | Simulation run area (RTL and gate-level). |
| `docs/` | Architecture, verification plan, results. |

Per-design OpenLane configs live at `pd/<design>/config.json` and
reference the shared SDC at `constraints/<design>.sdc`. See
[pd/README.md](pd/README.md) for the per-block hardening recipe.

## Flow overview

```
rtl/ ──► pd/ (OpenLane) ──► GDS
  │       ▲
  │       │
  └── constraints/
  │
  └──► tb/ ──► sim/ (RTL + gate-level)
```
