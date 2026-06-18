"""Bit-width sweep: find the smallest widths that hold the cos-sim target.

The encoder has five tunable widths (see :class:`encoder.Widths`):

    y_bits       signed width of WHT output (saturation point)
    norm_bits    unsigned width of the integer ||y|| reported to host
    rsqrt_frac   fractional bits of the reciprocal-sqrt
    u_frac       fractional bits of u = y / ||y||
    cb_frac      fractional bits of codebook bounds (must be <= u_frac)

Each width adds area in RTL. ``y_bits`` and ``rsqrt_frac`` are the
biggest area drivers (multiplier widths). ``norm_bits`` is essentially
free (just a register width).

Strategy
--------
1. Establish the fp64 cos-sim baseline (the ceiling).
2. Run the default widths from PLAN.md §4 and confirm the gap to fp64
   is small (< 0.001 mean cos-sim).
3. Sweep each width downward independently from the default, holding
   others fixed, and report the smallest value that keeps the gap
   small. The minimum-area vector is the per-axis minimum (assuming
   approximate independence).

Targets (from PLAN.md §1):

    mean cos-sim >= 0.97
    1st percentile cos-sim >= 0.95
    fixed-vs-fp64 mean cos-sim gap <= 0.002

Runs over :data:`N_VECTORS` random vectors per configuration. Output:
human-readable table to stdout plus ``out/sweep_results.json``.
"""
from __future__ import annotations

import json
from copy import deepcopy
from pathlib import Path
from typing import Dict, List

import numpy as np

from .encoder import (
    DEFAULT_WIDTHS,
    Widths,
    cos_sim,
    decode_fp64,
    encode_fixed,
    encode_fp64,
    load_codebook,
)
from .structured_rotation import make_signs


N_VECTORS = 2048
RNG_SEED = 0
SIGMA = 32.0
TARGET_MEAN = 0.97
TARGET_P1 = 0.95
TARGET_GAP = 0.002


OUT_DIR = Path(__file__).parent / "out"


def _gen_vectors(d: int, n: int = N_VECTORS, rng_seed: int = RNG_SEED) -> np.ndarray:
    rng = np.random.default_rng(rng_seed)
    out = np.empty((n, d), dtype=np.int8)
    for i in range(n):
        if i % 4 == 3:
            out[i] = rng.integers(-128, 128, size=d).astype(np.int8)
        else:
            out[i] = np.clip(rng.normal(0, SIGMA, size=d).round(), -128, 127).astype(np.int8)
    return out


def _eval(widths: Widths, x: np.ndarray, signs, cb) -> Dict:
    n = x.shape[0]
    cos_fp = np.empty(n, dtype=np.float64)
    cos_fx = np.empty(n, dtype=np.float64)
    for i in range(n):
        idx_fp, norm_fp = encode_fp64(x[i].astype(np.float64), signs, cb)
        idx_fx, norm_fx = encode_fixed(x[i], signs, cb, widths)
        cos_fp[i] = cos_sim(x[i], decode_fp64(idx_fp, float(norm_fp), signs, cb))
        cos_fx[i] = cos_sim(x[i], decode_fp64(idx_fx, float(norm_fx), signs, cb))
    return {
        "mean_fp": float(cos_fp.mean()),
        "p1_fp": float(np.percentile(cos_fp, 1)),
        "mean_fx": float(cos_fx.mean()),
        "p1_fx": float(np.percentile(cos_fx, 1)),
        "min_fx": float(cos_fx.min()),
        "gap_mean": float(cos_fp.mean() - cos_fx.mean()),
    }


def passes(res: Dict) -> bool:
    return (
        res["mean_fx"] >= TARGET_MEAN
        and res["p1_fx"] >= TARGET_P1
        and res["gap_mean"] <= TARGET_GAP
    )


def sweep(d: int = 64, b: int = 3, n: int = N_VECTORS) -> Dict:
    cb = load_codebook(d, b)
    signs = make_signs(d)
    x = _gen_vectors(d, n=n)

    print(f"Sweep d={d} b={b} n={n}")
    print(f"Targets: mean cos-sim >= {TARGET_MEAN}, p1 >= {TARGET_P1}, gap <= {TARGET_GAP}")
    print()

    base = _eval(DEFAULT_WIDTHS, x, signs, cb)
    print(
        f"DEFAULT  {DEFAULT_WIDTHS}\n"
        f"  fp64  mean={base['mean_fp']:.5f} p1={base['p1_fp']:.5f}\n"
        f"  fixed mean={base['mean_fx']:.5f} p1={base['p1_fx']:.5f} "
        f"min={base['min_fx']:.5f} gap={base['gap_mean']:+.5f}  "
        f"{'PASS' if passes(base) else 'FAIL'}"
    )
    print()

    # Per-axis minimum: walk each width down until the config fails.
    axes: Dict[str, List[int]] = {
        "y_bits":     list(range(16, 9, -1)),     # 16, 15, ..., 10
        "rsqrt_frac": list(range(14, 7, -1)),
        "u_frac":     list(range(11, 4, -1)),
        "cb_frac":    list(range(11, 3, -1)),
        "norm_bits":  list(range(18, 9, -1)),
    }

    minima: Dict[str, int] = {}
    rows: List[Dict] = []
    for axis, values in axes.items():
        last_pass = DEFAULT_WIDTHS[axis]
        for v in values:
            w = deepcopy(DEFAULT_WIDTHS)
            w[axis] = v
            # u_frac must dominate cb_frac.
            if axis == "u_frac" and w["cb_frac"] > w["u_frac"]:
                w["cb_frac"] = w["u_frac"]
            if axis == "cb_frac" and w["cb_frac"] > w["u_frac"]:
                continue
            res = _eval(w, x, signs, cb)
            ok = passes(res)
            rows.append({"axis": axis, "value": v, **res, "pass": ok})
            tag = "ok" if ok else "FAIL"
            print(
                f"  {axis:>11s}={v:>3d}  mean={res['mean_fx']:.5f} p1={res['p1_fx']:.5f} "
                f"gap={res['gap_mean']:+.5f}  [{tag}]"
            )
            if ok:
                last_pass = v
            else:
                break
        minima[axis] = last_pass
        print(f"  -> minimum {axis} that passes = {last_pass}")
        print()

    # Combined run with all per-axis minima.
    combined = deepcopy(DEFAULT_WIDTHS)
    for k, v in minima.items():
        combined[k] = v
    if combined["cb_frac"] > combined["u_frac"]:
        combined["cb_frac"] = combined["u_frac"]
    cres = _eval(combined, x, signs, cb)
    cok = passes(cres)
    print(
        f"COMBINED minima  {combined}\n"
        f"  fixed mean={cres['mean_fx']:.5f} p1={cres['p1_fx']:.5f} "
        f"gap={cres['gap_mean']:+.5f}  {'PASS' if cok else 'FAIL'}"
    )

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUT_DIR / "sweep_results.json"
    with open(out_path, "w") as fp:
        json.dump(
            {
                "d": d,
                "b": b,
                "n": n,
                "default_widths": DEFAULT_WIDTHS,
                "default_result": base,
                "axes": axes,
                "rows": rows,
                "per_axis_minima": minima,
                "combined_widths": combined,
                "combined_result": cres,
                "combined_passes": cok,
                "targets": {
                    "mean": TARGET_MEAN, "p1": TARGET_P1, "gap": TARGET_GAP
                },
            },
            fp,
            indent=2,
        )
    print(f"\nresults -> {out_path}")
    return {"combined": combined, "passes": cok, "result": cres}


if __name__ == "__main__":
    sweep()
