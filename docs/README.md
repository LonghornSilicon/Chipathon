# docs/

Project documentation: architecture, microarchitecture, verification
plan, and results.

## Contents

- `architecture.md` — top-level block diagram, data and control flow,
  and architectural decisions.
- [`microarchitecture/`](microarchitecture) — per-block specifications
  (interfaces, FSMs, pipeline diagrams).
- `verification_plan.md` — features, coverage goals, and the test
  matrix mapped to [`../tb/tests/`](../tb).
- `results.md` — synthesis PPA from [`../dc/`](../dc) and post-route
  signoff from [`../pd/`](../pd).
- `tapeout_checklist.md` — DRC, LVS, STA, and power signoff status.
- `images/` — diagrams and screenshots referenced from the documents
  above.

## Conventions

- Documents reference numerical results from [`../dc/reports/`](../dc)
  and [`../pd/reports/`](../pd) rather than restating them inline.
- Documents and the RTL they describe are updated in the same change
  set.
