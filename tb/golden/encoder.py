"""Algorithm 1 (TurboQuantMSE) encoder using the structured rotation.

Two implementations live here:

- :func:`encode_fp64` — pure floating-point reference. This is the
  *quality* ground truth we measure cosine similarity against.
- :func:`encode_fixed` — fixed-point simulation, parametrised by a
  :class:`Widths` dict. Each stage rounds and saturates exactly the
  way the RTL is planned to. This is what the bit-width sweep
  optimises.

Both share the Lloyd-Max codebook shipped with the upstream Python
package at ``../../../turboquant/turboquant/codebooks/codebook_d{d}_b{b}.json``.
The codebook was computed for Haar rotations; we verify empirically in
:mod:`sweep_precision` that it still meets the cos-sim target under
WHT + signs.

Decode is also provided (:func:`decode_fp64`) for cosine-similarity
scoring; the chip itself does not implement decode in baseline.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Tuple, TypedDict

import numpy as np

from .fixedpoint import (
    from_q,
    isqrt_int,
    isqrt_nonrestoring,
    round_nearest_even,
    rsqrt_q_hardware,
    saturate_signed,
    saturate_unsigned,
    to_q,
)
from .structured_rotation import structured_rotate_fp, structured_rotate_int
from .wht import wht_inplace


# Locate the upstream codebook directory once.
_REPO_ROOT = Path(__file__).resolve().parents[3]
CODEBOOK_DIR = _REPO_ROOT / "turboquant" / "turboquant" / "codebooks"


@dataclass(frozen=True)
class Codebook:
    d: int
    bits: int
    bounds: np.ndarray      # length 2^bits + 1, first = -1, last = +1
    centroids: np.ndarray   # length 2^bits

    @property
    def interior_bounds(self) -> np.ndarray:
        return self.bounds[1:-1]


def load_codebook(d: int, bits: int) -> Codebook:
    path = CODEBOOK_DIR / f"codebook_d{d}_b{bits}.json"
    with open(path) as fp:
        data = json.load(fp)
    return Codebook(
        d=int(data["d"]),
        bits=int(data["bits"]),
        bounds=np.asarray(data["bounds"], dtype=np.float64),
        centroids=np.asarray(data["centroids"], dtype=np.float64),
    )


class Widths(TypedDict, total=False):
    """Bit widths controlling each stage of :func:`encode_fixed`.

    Keys:
        y_bits        signed width of WHT output (post-saturation)
        norm_bits     unsigned width of integer ||y|| (sqrt of Σy²);
                      controls the resolution of the output norm
        rsqrt_int     integer bits of UQ(int).(frac) reciprocal-sqrt
        rsqrt_frac    fractional bits of reciprocal-sqrt
        u_frac        fractional bits of u = y / ||y||
        cb_frac       fractional bits of codebook bounds (must be <= u_frac)
    """
    y_bits: int
    norm_bits: int
    rsqrt_int: int
    rsqrt_frac: int
    u_frac: int
    cb_frac: int


DEFAULT_WIDTHS: Widths = {
    "y_bits": 14,
    "norm_bits": 14,
    "rsqrt_int": 2,
    "rsqrt_frac": 13,
    "u_frac": 9,
    "cb_frac": 9,
}


# ---------------------------------------------------------------------- #
# fp64 reference                                                         #
# ---------------------------------------------------------------------- #
def encode_fp64(
    x: np.ndarray, signs: np.ndarray, codebook: Codebook
) -> Tuple[np.ndarray, float]:
    """Reference encode: returns ``(idx[0..d-1], norm)`` in fp64."""
    y = structured_rotate_fp(x, signs)
    norm = float(np.linalg.norm(y))
    u = y / max(norm, 1e-30)
    idx = np.searchsorted(codebook.interior_bounds, u, side="right").astype(np.int64)
    return idx, norm


def decode_fp64(
    idx: np.ndarray, norm: float, signs: np.ndarray, codebook: Codebook
) -> np.ndarray:
    """Best-effort fp64 reconstruction (used only for quality scoring)."""
    u_hat = codebook.centroids[idx.astype(np.int64)]
    y_hat = u_hat * norm
    tmp = y_hat.tolist()
    wht_inplace(tmp)
    d = len(y_hat)
    y_hat_back = np.array(tmp, dtype=np.float64) / float(d)
    return y_hat_back * signs.astype(np.float64)


# ---------------------------------------------------------------------- #
# Fixed-point sim (mirrors the RTL stage-for-stage)                      #
# ---------------------------------------------------------------------- #
def encode_fixed(
    x: np.ndarray, signs: np.ndarray, codebook: Codebook, widths: Widths = DEFAULT_WIDTHS
) -> Tuple[np.ndarray, int]:
    """Fixed-point Algorithm 1 encode.

    Stages, matching ``rtl/`` modules:

    1. ``sign_lfsr * x``           int8
    2. ``wht64``                   signed, saturated to ``y_bits``
    3. ``norm2_acc``               int Σ y² (unsaturated; widths['norm_bits']
                                   only constrains the output ``norm`` reporting)
    4. ``rsqrt_unit``              UQ<rsqrt_int>.<rsqrt_frac>, banker-rounded
    5. ``quant_unit`` mul          u_i = y_i * inv_norm in Q1.<u_frac>,
                                   saturated to ``[-1, +1]``
    6. ``quant_unit`` cmp          binary search vs Q?.<cb_frac> bounds
    """
    d = x.size
    if d != codebook.d:
        raise ValueError(f"x length {d} does not match codebook d={codebook.d}")

    # --- Stage 1+2: sign flip + WHT, then narrow to y_bits.
    y = structured_rotate_int(x.astype(np.int64), signs.astype(np.int64))
    y = saturate_signed(y, widths["y_bits"])

    # --- Stage 3: Σ y² (use Python int via int64 with explicit promotion).
    norm2 = int(np.sum(y.astype(np.int64) ** 2))
    if norm2 == 0:
        # Degenerate: all-zero vector. Emit centred indices and norm=0.
        # This is a corner-case path the FSM will also need to handle.
        n_levels = 1 << codebook.bits
        idx = np.full(d, n_levels // 2, dtype=np.int64)
        return idx, 0

    # --- Stage 4: 1/||y|| in UQ<rsqrt_int>.<rsqrt_frac>, computed via the
    # exact non-restoring sqrt + truncating-divide algorithm in
    # rtl/rsqrt_unit.sv. Bit-exact match to the RTL.
    norm_int = isqrt_nonrestoring(norm2, total_bits=32)
    norm_int = int(min(norm_int, (1 << widths["norm_bits"]) - 1))
    inv_norm_q = rsqrt_q_hardware(norm2, frac_bits=widths["rsqrt_frac"], total_bits=32)

    # --- Stage 5: u_i = y_i * inv_norm_q, then bring to Q1.<u_frac>.
    # y has 0 fractional bits; product has rsqrt_frac fractional bits.
    # Right-shift to u_frac with round-half-up (matches RTL).
    raw = y.astype(np.int64) * int(inv_norm_q)
    shift = widths["rsqrt_frac"] - widths["u_frac"]
    if shift > 0:
        half = 1 << (shift - 1)
        u_q = (raw + half) >> shift
    elif shift < 0:
        u_q = raw << (-shift)
    else:
        u_q = raw
    # Saturate to Q1.<u_frac> -> total bits = u_frac + 2 (sign + 1 integer + frac).
    u_q = saturate_signed(u_q, widths["u_frac"] + 2)

    # --- Stage 6: compare against interior codebook bounds.
    bounds_q = to_q(
        codebook.interior_bounds, widths["cb_frac"], widths["cb_frac"] + 2, signed=True
    )
    cb_shift = widths["u_frac"] - widths["cb_frac"]
    if cb_shift > 0:
        half = 1 << (cb_shift - 1)
        u_for_cmp = (u_q + half) >> cb_shift
    elif cb_shift < 0:
        u_for_cmp = u_q << (-cb_shift)
    else:
        u_for_cmp = u_q
    idx = np.searchsorted(bounds_q, u_for_cmp, side="right").astype(np.int64)

    return idx, norm_int


# ---------------------------------------------------------------------- #
# Quality helpers                                                        #
# ---------------------------------------------------------------------- #
def cos_sim(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float64)
    b = np.asarray(b, dtype=np.float64)
    na = float(np.linalg.norm(a))
    nb = float(np.linalg.norm(b))
    if na == 0 or nb == 0:
        return 0.0
    return float(np.dot(a, b) / (na * nb))
