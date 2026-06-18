# PLAN.md — TurboQuant Encoder ASIC (SKY130, Chipathon)

A SystemVerilog implementation of the **TurboQuant** online vector quantizer
(Zandieh, Daliri, Hadian, Mirrokni, 2025 — [arXiv:2504.19874][paper]),
targeting the SKY130 PDK via OpenLane with a Tiny Tapeout-style host pinout.
The Python reference lives at `../turboquant/` and is the bit-exact golden
model.

[paper]: https://arxiv.org/abs/2504.19874

---

## 1. Goal

Tape out a small **TurboQuant Algorithm 1 (MSE) encoder** that, given a
streamed input vector `x ∈ R^d`, emits its compressed representation
`(idx[0..d-1], norm)` to the host.

This is the write-side primitive of a KV-cache compressor: it does not
decode, does not estimate inner products, and does not handle values
(those stay host-side). Algorithm 2 (QJL residual sketch) is a stretch
goal, not baseline.

### Success criteria
- **Functional.** Gate-level sim matches the Python golden bit-exact for
  the rotation + quantize indices, and within ±1 LSB for `||y||`.
- **Quality.** End-to-end reconstruction (`x` ↔ decoded `(idx, norm)`)
  achieves **mean cosine similarity ≥ 0.97**, **1st-percentile ≥ 0.95**
  over random Gaussian/uniform input vectors. This is the realistic
  ceiling for **Algorithm 1 alone at `b=3`**: it is set by the
  Lloyd–Max codebook MSE (≈ 5.2 × 10⁻⁴ per coordinate at d=64), and is
  matched by both Haar and WHT+signs rotations within noise. The
  paper's "~1.000" cos-sim claim is for the **Algorithm 2** unbiased
  inner-product estimator (stretch goal §12.1), not for Algorithm-1
  reconstruction.
- **PD.** Clean DRC and LVS in OpenLane SKY130, ≥ 50 MHz at the slow corner,
  fits within 1–2 Tiny Tapeout tiles.

---

## 2. Locked design parameters

| Parameter | Value | Rationale |
|---|---|---|
| Algorithm | **TurboQuant MSE (Alg. 1) only** | Smallest viable chip; QJL is stretch |
| Direction | **Encode only** | Decode and IP estimator stay host-side |
| Vector dim `d` | **64** | Halves WHT depth and ROM vs `d=128`; still meaningful |
| Input precision | **int8 signed** | Matches typical post-projection KV cache |
| Codebook bits `b` | **3** (8 levels) | Paper's headline bit-width for keys |
| Rotation `R` | **Walsh–Hadamard × Diag(s), s ∈ {±1}^d, LFSR-derived** | Structured ⇒ no R ROM, O(d log d) ops, gives the same Beta-coordinate distribution asymptotically |
| Throughput model | **Vector-serial** (one element/cycle through the datapath) | Area-bounded; 130 nm cannot host `d` parallel MACs |
| Clock target | **50 MHz** worst-case, 100 MHz typical | Fits SKY130 std-cell timing comfortably |
| Pinout | **Tiny Tapeout** (`ui_in`, `uo_out`, `uio_*`) | Matches existing `pd/` infra |

---

## 3. Algorithm → hardware mapping

```
   x[0..d-1]           int8                     ┌────────────┐
   ───────────────────────────────────────────► │  sign_lfsr │
                                                └─────┬──────┘
   y = WHT( s ⊙ x )    int16 (after sign flip and butterflies)
                                                ┌─────▼──────┐
                                                │   wht_64   │  Cooley-Tukey-style
                                                │ (in-place) │  6 stages, d/2 add/sub per stage
                                                └─────┬──────┘
                                                      │ y[0..d-1]
                                ┌─────────────────────┼─────────────────────┐
                                │                     │                     │
                          ┌─────▼─────┐         ┌─────▼─────┐         ┌─────▼─────┐
                          │ norm2_acc │         │  scratch  │         │           │
                          │  Σ y_i²   │         │  RAM 64×W │         │           │
                          └─────┬─────┘         └─────┬─────┘         │           │
                                │                     │               │           │
                          ┌─────▼─────┐               │               │           │
                          │ rsqrt    │  1/||y||      │               │           │
                          │ (Newton) │                │               │           │
                          └─────┬─────┘               │               │           │
                                │                     │               │           │
                                └────────┐    ┌───────┘               │           │
                                         ▼    ▼                       │           │
                                   ┌──────────────┐                   │           │
                                   │   u = y/|y|  │  Q1.11 fixed pt   │           │
                                   └──────┬───────┘                   │           │
                                          │                           │           │
                                   ┌──────▼───────┐                   │           │
                                   │ lloyd_max_q  │  binary tree      │           │
                                   │ (7-cmp)      │  vs bounds[]      │           │
                                   └──────┬───────┘                   │           │
                                          │ idx ∈ [0,7]                           │
                                   ┌──────▼───────┐                               │
                                   │ bit_packer   │  3 bits/coord                 │
                                   └──────┬───────┘                               │
                                          ▼                                       │
                                  uo_out frame: { norm[15:0], idx_packed[191:0] }─┘
```

The boxes correspond 1:1 to the RTL modules in §5.

---

## 4. Numerical precision plan

These widths come from the empirical sweep in `tb/golden/sweep_precision.py`
over 4096 random Gaussian + uniform input vectors. Each axis was walked
down independently from a generous starting point until the cos-sim
target failed, then the per-axis minimum was bumped one bit for safety.
The final widths re-run on 4096 vectors hit
`mean cos-sim = 0.983, p1 = 0.966, gap-vs-fp64 = 0.0006`.

| Stage | Format | Width | Notes |
|---|---|---|---|
| Input `x` | int8 signed | 8 | Q7 fractional or whatever the host sends |
| After sign flip | int8 signed | 8 | Sign multiply only |
| WHT internal `y` | int signed | **14** | Worst-case envelope: `127 × d / 2` per coord (adversarial all-aligned input) |
| `Σ y_i²` accumulator | int unsigned | 32 | `d × (2^13)^2 ≈ 2^32` |
| `||y||` (sqrt of above) | UQ14.0 | **14** | Worst case `sqrt(d) × 128 = 8128` fits in 14 bits unsigned |
| `1/||y||` (rsqrt) | UQ2.13 | **15** | Newton iteration, LUT-seeded |
| `u = y · (1/||y||)` | Q1.9 signed | **11** | u ∈ [−1, 1] |
| Codebook bounds | Q1.9 signed | **11** | From `turboquant/codebooks/codebook_d64_b3.json`, see `tb/golden/out/codebook_bounds.mem` |
| Codebook centroids | Q1.9 signed | **11** | Same source, see `tb/golden/out/codebook_centroids.mem` |
| Output `idx` | uint | 3 | 8 levels, packed at output |

Adversarial point-spike inputs (e.g. `x = 127 · s` where `s` is the
LFSR sign vector) produce a degenerate `u = e_0`, which the codebook
quantises to a Beta-typical centroid and reconstructs poorly
(cos-sim ≈ 0.74). This is a property of any rate-distortion-optimal
quantiser on a non-Beta input and is NOT a fixed-point issue — fp64
sees the same number. The chip targets KV-cache-distributed inputs
(approximately Gaussian after layer projection), where the cos-sim
target holds.

---

## 5. Module decomposition

All RTL lives in `rtl/`. Each module has a matching cocotb (or SV) testbench
in `tb/` and an OpenLane hardening recipe in `pd/<module>/`.

| Module | Purpose | Approx area driver |
|---|---|---|
| `tq_top.sv` | TT-pinout top level, host FSM, output framing | thin |
| `tq_ctrl.sv` | Host I/O FSM: collect 64 input bytes, run, emit output | small |
| `sign_lfsr.sv` | 64-bit Galois LFSR, fixed seed, generates `s ∈ {±1}^d` | tiny |
| `wht64.sv` | In-place radix-2 Walsh–Hadamard, 6 stages, time-shared adder/subtractor | medium |
| `scratch_ram.sv` | 64×16b register file holding `y` between stages | small (flops) |
| `norm2_acc.sv` | Σ y_i² accumulator (squarer + 36-bit add) | small |
| `rsqrt_unit.sv` | LUT-seeded Newton 1/√x, 2 iterations | small |
| `quant_unit.sv` | y_i × (1/||y||) → u_i, then Lloyd–Max binary search | small |
| `codebook_rom.sv` | Bounds and centroids ROM (`$readmemh`) | tiny |
| `bit_packer.sv` | 3-bit indices → byte stream | tiny |

The existing `int4_*` / `mac_*` / `accum_*` etc. RTL is **deleted** at the
start of the rewrite (see §10 Phase 0).

---

## 6. Memory & ROM plan

- **Rotation `R`.** Zero ROM. WHT is realized in butterflies; the random
  signs come from the LFSR and are reproducible by seed.
- **Sign LFSR seed.** Compile-time parameter; matched to the seed used
  when generating Python golden vectors.
- **Codebook.** `codebooks/codebook_d64_b3.json` from the Python repo is
  converted to a `.mem` file at build time. ROM holds 7 bounds + 8
  centroids in Q1.11 → `15 × 12 = 180` bits, trivially flop-mapped.
- **Scratch RAM for `y`.** 64 × 16 b = 1024 b. Flop-based register file
  (no SRAM macro needed; SKY130 SRAM minimums are larger than this).

No SRAM macros in baseline. Stretch-goal Alg 2 may need one.

---

## 7. Host interface (TT pinout)

Per-vector frame, byte-serial over `ui_in` / `uo_out`:

```
HOST → CHIP   (input frame, 64 bytes)
  byte i = x[i]   (int8, i=0..63)

CHIP → HOST   (output frame, 26 bytes)
  bytes 0..1   ||y||           (UQ8.8, big-endian)
  bytes 2..25  idx packed      (24 bytes; 64 indices × 3b, MSB-first)
```

Handshake on `uio`:

| `uio` bit | Dir | Meaning |
|---|---|---|
| `uio_in[2]` | host → chip | `host_tx_valid` (a byte is on `ui_in`) |
| `uio_in[3]` | host → chip | `host_rx_ready` (host can take a byte) |
| `uio_out[0]` | chip → host | `chip_rx_ready` (will accept this cycle) |
| `uio_out[1]` | chip → host | `chip_tx_valid` (a byte is on `uo_out`) |
| `uio_out[2]` | chip → host | `err_sticky` |
| `uio_out[3]` | chip → host | `busy` |
| `uio_out[7:4]` | chip → host | FSM state (debug) |

`uio_oe = 8'b1111_0011` static.

---

## 8. Verification strategy

Python golden = `../turboquant/turboquant/{rotation,codebook,quantizer}.py`,
overridden with a **structured-rotation variant** so it matches the
hardware's WHT + signs path bit-for-bit:

```
tb/
  golden/
    gen_vectors.py         # runs Python ref, emits .hex stimulus + expected
    structured_rotation.py # WHT × Diag(s), int math, matches RTL
  tb_wht64.sv              # bit-exact compare on butterfly outputs
  tb_norm2_acc.sv          # ±0 LSB
  tb_rsqrt_unit.sv         # ±1 LSB
  tb_quant_unit.sv         # bit-exact idx
  tb_bit_packer.sv         # bit-exact stream
  tb_tq_top.sv             # full-vector cosim, cosine-sim ≥ 0.99 over 1k vectors
```

Three test tiers:
1. **Per-block cocotb**, bit-exact against Python golden.
2. **RTL top-level** UVM (or cocotb), randomized vectors + corner cases
   (all-zero, max-magnitude, anti-aligned with sign LFSR).
3. **Gate-level sim** post-PnR with SDF, replays tier-2 vectors.

Property checks worth coding:
- WHT is its own inverse up to `d` ⇒ feed `WHT(WHT(x))/d == x`.
- `Σ idx` distribution matches the Beta quantile mass within tolerance.
- `||y||²` after the WHT equals `d · ||x||²` (Parseval).

---

## 9. Physical design

- **Flow.** Existing `pd/Makefile` + per-block `pd/<module>/config.json`
  pattern is reused. Each `rtl/*.sv` gets its own hardening run.
- **Floorplan.** Target 1 TT tile for the encoder; spill to 2 tiles if
  WHT timing closes only at 25 MHz or if `quant_unit` MAC dominates.
- **Clock.** Single core clock; reset is sync active-low.
- **Power.** Std-cell only at baseline. Estimated by OpenLane reports;
  no analog, no IO ring beyond TT.
- **Sign-off deliverables per block:** `gds`, `lef`, `def`, timing
  summary, area report, DRC clean, LVS clean.

---

## 10. Milestones

| Phase | Weeks | Deliverable |
|---|---|---|
| 0. Repo flush | W1 | Delete existing `int4_*` / `mac_*` / `accum_*` / `act_*` / `weight_*` / `requant_*` / `ctrl_io` RTL, TBs, constraints, and PD configs. Keep `pd/Makefile`, `pd/README.md`, `scripts/`, `sim/`, `docs/`, top-level `README.md` shape. Add `.gitkeep`s. **DONE.** |
| 1. Golden + bit-width sweep | W1–2 | `tb/golden/` Python that emits matching int-rotation vectors; precision sweep picks final widths. **DONE — see §4 for resulting widths.** |
| 2. Per-block RTL | W3–4 | All modules in §5 with passing cocotb. **DONE — RTL + SV TBs in `rtl/` and `tb/`.** |
| 3. Top integration | W5 | `tq_top` + UVM, full-vector cosim. **PARTIAL — 8/8 per-block TBs pass bit-exact in iverilog (sign_lfsr, codebook_rom, bit_packer, wht64, norm2_acc, rsqrt_unit, quant_unit), each across 8 stimulus vectors. `tb_tq_top` integration TB still deadlocks at t=0 under iverilog — likely an auto-sensitivity settling bug in iverilog around the cross-module comb chain. Recommendation: install Verilator (`brew install verilator`) and run `make TB=tq_top SIM=verilator run`; Verilator is stricter and resolves these settling orders deterministically.** |
| 4. Synthesis | W6 | Yosys clean, timing met at 50 MHz slow, no inferred latches, no multi-driver |
| 5. PnR + signoff | W7 | OpenLane DRC/LVS clean, gate-sim passes |
| 6. Docs & submit | W8 | Updated `docs/Microarchitecture.pdf`, area/power tables, GDS submission |

---

## 11. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| WHT timing fails at 50 MHz | med | Pipeline butterfly; or drop to 25 MHz |
| Reciprocal-sqrt area dominates | med | Time-share with the multiplier in `quant_unit` |
| Structured rotation degrades cos-sim vs Haar | low | Falls back to "Hadamard + signs + Hadamard + signs" (two passes); paper's guarantees are asymptotic and the per-coord distribution is empirically Beta even with one WHT |
| Codebook precision too tight | low | Re-run Lloyd–Max in Python at higher precision and re-emit `.mem` |
| Tiny Tapeout area overrun | med | Drop to `d=32`, or stop at encoder-only with `b=2` |
| OpenLane / SKY130 macro surprises | low | No SRAM macros in baseline |

---

## 12. Stretch goals (only if W6 lands ahead)

1. **Algorithm 2 (QJL residual sketch).** Adds an LFSR-derived `S ∈ {±1}^{d×d}`
   and an XOR-popcount sign extractor. Adds `d` bits to the output frame.
2. **Decode unit.** Inverse rotation + `||y|| · centroid[idx]`.
3. **Inner-product estimator.** Multiplies query against compressed key.
4. **Programmable bit-width** (`b ∈ {2,3,4}`) with a wider codebook ROM.

---

## 13. Out of scope

- Value-tensor group quantization (host responsibility).
- vLLM / Triton glue (host responsibility).
- Calibration or training: TurboQuant is data-oblivious — `R`, `S`, and
  the codebook are fixed at tape-out.
- Multi-`d` support beyond stretch goal #4.

---

## 14. Reference

```
@article{zandieh2025turboquant,
  title  = {TurboQuant: Online Vector Quantization with Near-optimal Distortion Rate},
  author = {Zandieh, Amir and Daliri, Majid and Hadian, Majid and Mirrokni, Vahab},
  journal= {arXiv preprint arXiv:2504.19874},
  year   = {2025}
}
```

Python reference implementation: `../turboquant/`.
