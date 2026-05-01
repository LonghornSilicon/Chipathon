# microarchitecture/

Per-block microarchitecture specifications. One markdown document per
block in [`../../rtl/`](../../rtl), named `<block>.md`.

## Document template

Each block document contains:

- **Purpose** — role of the block in the system.
- **Interfaces** — port list, protocols (valid/ready, AXI, custom),
  clock and reset domains.
- **Microarchitecture** — pipeline stages, FSMs, datapath width, and
  storage structures (FIFOs, RAMs, CAMs) with sizes.
- **Performance** — target throughput, latency, and expected critical
  path.
- **Area and power** — budgeted values; updated from
  [`../../dc/reports/`](../../dc) once synthesis is run.
- **Verification** — coverage points, assertions, and links to UVM
  tests in [`../../tb/tests/`](../../tb).
- **Open items** — known gaps and pending work.

## Conventions

- Diagrams are stored in [`../images/`](../images) and referenced via
  relative paths.
- The RTL in [`../../rtl/`](../../rtl) is the source of truth;
  microarchitecture documents and RTL are updated in the same change
  set when behavior changes.
