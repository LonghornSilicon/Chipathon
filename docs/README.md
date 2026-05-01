# docs/

Recruiter- and reviewer-facing documentation. This is the first stop for
anyone who didn't write the RTL.

## Suggested contents

- `architecture.md` — block diagram, top-level data/control flow, key choices.
- `microarchitecture/` — per-block specs (interfaces, FSMs, pipeline diagrams).
- `verification_plan.md` — features, coverage goals, test matrix mapped to
  [`../tb/tests/`](../tb).
- `results.md` — synthesis area/power/timing summary from [`../dc/`](../dc)
  and post-route signoff from [`../pd/`](../pd).
- `tapeout_checklist.md` — DRC/LVS/STA/power signoff sign-offs for the shuttle.
- `images/` — diagrams, screenshots (waveforms, layouts, reports).

## Conventions

- Lead with a one-page summary: what the chip does, why it's interesting,
  headline PPA numbers, and a layout screenshot.
- Link out to the actual source / reports — don't duplicate numbers that
  live in [`../dc/reports/`](../dc) or [`../pd/reports/`](../pd).
