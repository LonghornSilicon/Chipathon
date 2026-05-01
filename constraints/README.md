# constraints/

Timing and design constraints shared across synthesis
([`../dc/`](../dc)), physical design ([`../pd/`](../pd)), and STA /
gate-level simulation ([`../sim/`](../sim)).

## Layout

- `<top>.sdc` — primary SDC for the top-level design.
- `<block>.sdc` — block-level constraints for hierarchical flows.
- `clocks.tcl` — clock definitions, clock groups, and uncertainty.
- `io.tcl` — input/output delay budgets, driving cells, and loads.
- `exceptions.tcl` — false paths and multicycle paths, with justifying
  comments.

## Conventions

- Single source of truth: synthesis and physical design read from this
  directory; do not fork.
- Every timing exception is annotated with the architectural reason.
- Corner-dependent values are parameterized so the same SDC applies
  across MMMC views (typical / fast / slow, voltage, temperature).
