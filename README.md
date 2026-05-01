# Chipathon

IEEE SSCS Chipathon — 130 nm tape-out project.

## Repository layout

| Directory | Purpose |
| --- | --- |
| [`rtl/`](rtl) | Synthesizable RTL source (SystemVerilog / Verilog). |
| [`tb/`](tb) | Verification environment (UVM, optional cocotb). |
| [`constraints/`](constraints) | Shared timing and design constraints (SDC). |
| [`dc/`](dc) | Synopsys Design Compiler synthesis flow. |
| [`pd/`](pd) | Physical design / place-and-route flow. |
| [`sim/`](sim) | Simulation run area (RTL and gate-level). |
| [`docs/`](docs) | Architecture, microarchitecture, verification plan, results. |

Each subdirectory contains a `README.md` describing its contents, inputs,
outputs, and conventions.

## Flow overview

```
rtl/ ──► dc/ ──► pd/ ──► GDS
  │       ▲       ▲
  │       │       │
  └── constraints/ ┘
  │
  └──► tb/ ──► sim/ (RTL + gate-level)
```

## Documentation entry points

- [`docs/architecture.md`](docs) — top-level architecture (to be added).
- [`docs/microarchitecture/`](docs/microarchitecture) — per-block specs.
- [`docs/verification_plan.md`](docs) — coverage and test plan.
- [`docs/results.md`](docs) — synthesis and post-route results.
