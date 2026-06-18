"""Stimulus + expected-output dumper for ``tb_tq_top``.

Run::

    python -m tb.golden.gen_vectors --n 64

Outputs (all under ``tb/golden/out/``):
- ``signs.mem``                64 lines of "0" or "1" (LFSR sign bits, MSB ignored)
- ``codebook_bounds.mem``      7 lines, hex of Q1.<cb_frac> interior bounds
- ``codebook_centroids.mem``   8 lines, hex of Q1.<cb_frac> centroids
- ``vec_<id>_x.hex``           64 lines, signed int8 hex (one byte per coord)
- ``vec_<id>_idx.hex``         64 lines, hex of 3-bit index per coord
- ``vec_<id>_norm.hex``        1 line, hex of integer ||y|| (UQ<norm_bits>.0)
- ``vec_<id>_meta.txt``        human-readable summary (cos-sim, sum-of-idx)

The .mem and .hex files are intended for ``$readmemh`` in SystemVerilog.
Each line contains exactly one value, no comments, padded to the natural
hex width of its field.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

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
from .fixedpoint import (
    isqrt_nonrestoring,
    rsqrt_q_hardware,
    saturate_signed,
    to_q,
)
from .lfsr import DEFAULT_SEED, galois_lfsr_bits
from .structured_rotation import make_signs, structured_rotate_int


OUT_DIR = Path(__file__).parent / "out"


def _hex_width(bits: int) -> int:
    return (bits + 3) // 4


def _twos(value: int, bits: int) -> int:
    """Two's-complement representation of ``value`` in ``bits`` bits."""
    if value < 0:
        return value + (1 << bits)
    return value


def _writeln_int(fp, value: int, bits: int) -> None:
    fp.write(f"{_twos(int(value), bits):0{_hex_width(bits)}x}\n")


def emit_signs(d: int, seed: int) -> Path:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    bits = galois_lfsr_bits(d, seed=seed)
    path = OUT_DIR / "signs.mem"
    with open(path, "w") as fp:
        for b in bits:
            fp.write(f"{b}\n")
    return path


def emit_codebook(d: int, b: int, widths: Widths) -> tuple[Path, Path]:
    cb = load_codebook(d, b)
    bw = widths["cb_frac"] + 2  # sign + 1 + frac (Q1.<cb_frac>)
    bounds_q = to_q(cb.interior_bounds, widths["cb_frac"], bw, signed=True)
    cents_q = to_q(cb.centroids, widths["cb_frac"], bw, signed=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    p1 = OUT_DIR / "codebook_bounds.mem"
    p2 = OUT_DIR / "codebook_centroids.mem"
    with open(p1, "w") as fp:
        for v in bounds_q:
            _writeln_int(fp, int(v), bw)
    with open(p2, "w") as fp:
        for v in cents_q:
            _writeln_int(fp, int(v), bw)
    return p1, p2


def gen_one(
    vec_id: int,
    x: np.ndarray,
    signs: np.ndarray,
    cb,
    widths: Widths,
) -> dict:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    d = x.size
    idx_fp, norm_fp = encode_fp64(x.astype(np.float64), signs, cb)
    idx_fx, norm_fx = encode_fixed(x, signs, cb, widths)

    # x: signed int8 -> two-byte hex per line (one byte, but $readmemh tolerates 02x).
    px = OUT_DIR / f"vec_{vec_id:03d}_x.hex"
    with open(px, "w") as fp:
        for v in x:
            _writeln_int(fp, int(v), 8)

    # Post-WHT integer y, saturated to widths['y_bits']. Used by the
    # wht64 testbench for bit-exact compare.
    y = structured_rotate_int(x.astype(np.int64), signs.astype(np.int64))
    y = saturate_signed(y, widths["y_bits"])
    py = OUT_DIR / f"vec_{vec_id:03d}_y.hex"
    with open(py, "w") as fp:
        for v in y:
            _writeln_int(fp, int(v), widths["y_bits"])

    # Σ y² and the hardware-equivalent rsqrt output, for bit-exact TB
    # of norm2_acc and rsqrt_unit.
    norm2 = int(np.sum(y.astype(np.int64) ** 2))
    inv_norm_q = rsqrt_q_hardware(norm2, frac_bits=widths["rsqrt_frac"], total_bits=32)
    pn2 = OUT_DIR / f"vec_{vec_id:03d}_norm2.hex"
    with open(pn2, "w") as fp:
        _writeln_int(fp, norm2, 32)
    pinv = OUT_DIR / f"vec_{vec_id:03d}_invn.hex"
    with open(pinv, "w") as fp:
        _writeln_int(fp, inv_norm_q, widths["rsqrt_int"] + widths["rsqrt_frac"])

    pi = OUT_DIR / f"vec_{vec_id:03d}_idx.hex"
    with open(pi, "w") as fp:
        for i in idx_fx:
            _writeln_int(fp, int(i), cb.bits)

    # Packed output bytes: 24 bytes MSB-first across 64 × 3-bit indices.
    n_bytes = (d * cb.bits + 7) // 8
    packed = bytearray(n_bytes)
    bitpos = 0
    for v in idx_fx:
        for b in range(cb.bits - 1, -1, -1):
            bit_v = (int(v) >> b) & 1
            packed[bitpos // 8] |= bit_v << (7 - (bitpos % 8))
            bitpos += 1
    pp = OUT_DIR / f"vec_{vec_id:03d}_packed.hex"
    with open(pp, "w") as fp:
        for v in packed:
            _writeln_int(fp, int(v), 8)

    # Output frame norm bytes: 2 bytes big-endian, with the 14-bit norm
    # in the low 14 of the 16-bit field (top 2 bits are 0). Matches the
    # slicing in tq_ctrl: byte0 = norm_q[13:6], byte1 = {2'b00, norm_q[5:0]}.
    pnb = OUT_DIR / f"vec_{vec_id:03d}_norm_bytes.hex"
    nq_int = int(norm_fx) & ((1 << widths["norm_bits"]) - 1)
    with open(pnb, "w") as fp:
        _writeln_int(fp, (nq_int >> 6) & 0xFF, 8)
        _writeln_int(fp, nq_int & 0x3F, 8)

    pn = OUT_DIR / f"vec_{vec_id:03d}_norm.hex"
    with open(pn, "w") as fp:
        _writeln_int(fp, int(norm_fx), widths["norm_bits"])

    cs_fx = cos_sim(x, decode_fp64(idx_fx, float(norm_fx), signs, cb))
    cs_fp = cos_sim(x, decode_fp64(idx_fp, float(norm_fp), signs, cb))
    pm = OUT_DIR / f"vec_{vec_id:03d}_meta.txt"
    with open(pm, "w") as fp:
        fp.write(
            f"vec_id={vec_id}\n"
            f"d={d}, b={cb.bits}\n"
            f"||x||={float(np.linalg.norm(x.astype(np.float64))):.4f}\n"
            f"norm_fp64={norm_fp:.4f}  norm_fixed_int={norm_fx}\n"
            f"cos_sim_fp64={cs_fp:.5f}  cos_sim_fixed={cs_fx:.5f}\n"
            f"idx_match_fraction={float(np.mean(idx_fp == idx_fx)):.4f}\n"
        )
    return {
        "id": vec_id,
        "norm_fp": float(norm_fp),
        "norm_fx": int(norm_fx),
        "cos_fp": cs_fp,
        "cos_fx": cs_fx,
        "idx_match": float(np.mean(idx_fp == idx_fx)),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate TurboQuant test vectors")
    parser.add_argument("--d", type=int, default=64)
    parser.add_argument("--b", type=int, default=3)
    parser.add_argument("--n", type=int, default=64, help="number of test vectors")
    parser.add_argument("--seed", type=int, default=0xACE1, help="LFSR seed (16-bit, nonzero)")
    parser.add_argument("--rng-seed", type=int, default=0)
    parser.add_argument("--sigma", type=float, default=32.0,
                        help="Gaussian sigma for input vectors before clip to int8")
    args = parser.parse_args()

    cb = load_codebook(args.d, args.b)
    signs = make_signs(args.d, seed=args.seed)
    widths = DEFAULT_WIDTHS

    s_path = emit_signs(args.d, args.seed)
    b_path, c_path = emit_codebook(args.d, args.b, widths)
    print(f"signs:      {s_path}")
    print(f"bounds:     {b_path}")
    print(f"centroids:  {c_path}")

    rng = np.random.default_rng(args.rng_seed)
    summary = []
    for i in range(args.n):
        # Mix Gaussian and uniform stimuli for distribution coverage.
        if i % 4 == 3:
            x = rng.integers(-128, 128, size=args.d).astype(np.int8)
        else:
            x = np.clip(rng.normal(0, args.sigma, size=args.d).round(), -128, 127).astype(np.int8)
        summary.append(gen_one(i, x, signs, cb, widths))

    cos_fp = np.array([r["cos_fp"] for r in summary])
    cos_fx = np.array([r["cos_fx"] for r in summary])
    print(
        f"\nSummary over n={args.n} vectors:\n"
        f"  fp64  cos-sim  mean={cos_fp.mean():.5f}  p1={np.percentile(cos_fp,1):.5f}\n"
        f"  fixed cos-sim  mean={cos_fx.mean():.5f}  p1={np.percentile(cos_fx,1):.5f}\n"
        f"  idx-match (fixed vs fp64) mean={np.mean([r['idx_match'] for r in summary]):.5f}"
    )
    with open(OUT_DIR / "summary.json", "w") as fp:
        json.dump({"d": args.d, "b": args.b, "n": args.n, "widths": widths,
                   "vectors": summary}, fp, indent=2)
    print(f"summary -> {OUT_DIR / 'summary.json'}")


if __name__ == "__main__":
    main()
