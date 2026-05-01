# microarchitecture/

Per-block microarchitecture specs. One markdown file per block in
[`../../rtl/`](../../rtl) (e.g. `<block>.md`).

## What each block doc should cover

- **Purpose** — one sentence on what this block does in the chip.
- **Interfaces** — port list, protocols (valid/ready, AXI, custom), clock and
  reset domains.
- **Microarchitecture** — pipeline stages, FSMs, datapath width, key
  structures (FIFOs, RAMs, CAMs) with sizes.
- **Performance** — target throughput, latency, expected critical path.
- **Area / power budget** — rough numbers; updated from
  [`../../dc/reports/`](../../dc) once synthesis runs.
- **Verification hooks** — coverage points, assertions, links to UVM tests
  in [`../../tb/tests/`](../../tb).
- **Open issues / TODOs** — known gaps so reviewers don't have to guess.

## Conventions

- Diagrams go in [`../images/`](../images) and are referenced relatively.
- This folder describes the RTL — the RTL itself in
  [`../../rtl/`](../../rtl) remains the source of truth. Update both in the
  same PR when behavior changes.
