# constraints/

Timing and design constraints shared across synthesis ([`../dc/`](../dc)),
physical design ([`../pd/`](../pd)), and STA / gate-level simulation
([`../sim/`](../sim)).

## Layout

- `<top>.sdc` — primary SDC for the top-level design.
- `<block>.sdc` — block-level constraints reused for hierarchical flows.
- `clocks.tcl` — clock definitions, groups, and uncertainty (sourced by SDCs).
- `io.tcl` — input/output delay budgets and driving cells / loads.
- `exceptions.tcl` — false paths, multicycle paths (with justifications in
  comments).

## Conventions

- One source of truth — DC and PD both read from this folder; never fork.
- Every exception has a comment explaining *why* (architectural reason).
- Corners (typ/fast/slow, voltage/temperature) parameterized so the same
  SDC works across MMMC views.
