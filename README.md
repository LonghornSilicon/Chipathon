# Chipathon

IEEE SSCS Chipathon — 130 nm tape-out project. This is LonghornSilicon's
**130 nm track** on the **SkyWater Sky130** open PDK: a TurboQuant KV-compression
encoder targeting Sky130 tape-out via OpenLane. Nothing has been fabricated yet.

*(The 130 nm work lives here; the flagship Lambda accelerator is a separate
TSMC 16 nm design. This repo supersedes the retired "LASSO" name.)*

## Repository layout

| Directory | Purpose |
| --- | --- |
| `rtl/` | Synthesizable RTL source (SystemVerilog / Verilog). |
| `tb/` | Verification environment (SystemVerilog testbenches + Python golden; maturing toward a UVM flow). |
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
