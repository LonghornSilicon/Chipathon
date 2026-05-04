# Chipathon

IEEE SSCS Chipathon — 130 nm tape-out project.

## Repository layout

| Directory | Purpose |
| --- | --- |
| `rtl/` | Synthesizable RTL source (SystemVerilog / Verilog). |
| `tb/` | Verification environment (UVM, optional cocotb). |
| `constraints/` | Shared timing and design constraints (SDC). |
| `dc/` | Synopsys Design Compiler synthesis flow. |
| `pd/` | Physical design / place-and-route flow. |
| `sim/` | Simulation run area (RTL and gate-level). |
| `docs/` | Architecture, microarchitecture, verification plan, results. |

All subdirectories are currently empty placeholders awaiting initial
content.

## Flow overview

```
rtl/ ──► dc/ ──► pd/ ──► GDS
  │       ▲       ▲
  │       │       │
  └── constraints/ ┘
  │
  └──► tb/ ──► sim/ (RTL + gate-level)
```
