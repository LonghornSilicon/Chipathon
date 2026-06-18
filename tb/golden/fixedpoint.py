"""Fixed-point helpers: round-to-nearest-even and saturating clip.

Centralised here so the encoder, the testbench, and the sweep script
all round and saturate identically. Anything that has to match RTL
bit-for-bit MUST go through these helpers.

Round mode: banker's rounding (NumPy's default ``np.round``). RTL is
expected to implement convergent rounding to match.
"""
from __future__ import annotations

import numpy as np


def round_nearest_even(x: np.ndarray) -> np.ndarray:
    """Banker's rounding to int64."""
    return np.rint(np.asarray(x, dtype=np.float64)).astype(np.int64)


def saturate_signed(x: np.ndarray, total_bits: int) -> np.ndarray:
    """Saturating clip to a signed two's-complement range of width ``total_bits``."""
    lo = -(1 << (total_bits - 1))
    hi = (1 << (total_bits - 1)) - 1
    return np.clip(np.asarray(x, dtype=np.int64), lo, hi)


def saturate_unsigned(x: np.ndarray, total_bits: int) -> np.ndarray:
    hi = (1 << total_bits) - 1
    return np.clip(np.asarray(x, dtype=np.int64), 0, hi)


def to_q(value, frac_bits: int, total_bits: int, signed: bool = True) -> np.ndarray:
    """Convert float -> fixed-point integer with explicit width.

    The output has ``frac_bits`` fractional bits and is round-to-nearest-even
    plus saturating-clip into a 2's-complement (or unsigned) range of
    ``total_bits`` total bits.
    """
    scaled = round_nearest_even(np.asarray(value, dtype=np.float64) * (1 << frac_bits))
    if signed:
        return saturate_signed(scaled, total_bits)
    return saturate_unsigned(scaled, total_bits)


def from_q(value, frac_bits: int) -> np.ndarray:
    """Convert fixed-point integer -> float by scaling down."""
    return np.asarray(value, dtype=np.float64) / float(1 << frac_bits)


def isqrt_int(n: int) -> int:
    """Integer square root (floor). Mirrors a future hardware iSqrt."""
    if n < 0:
        raise ValueError("isqrt of negative")
    if n < 2:
        return n
    # Newton with integer arithmetic; converges in O(log log n) steps.
    x = n
    y = (x + 1) // 2
    while y < x:
        x = y
        y = (x + n // x) // 2
    return x


def isqrt_nonrestoring(n: int, total_bits: int = 32) -> int:
    """Bit-exact mirror of ``rtl/rsqrt_unit.sv`` Phase A.

    Non-restoring binary square root with a fixed number of iterations
    (``total_bits / 2``). Produces ``floor(sqrt(n))`` for any ``n`` in
    ``[0, 2^total_bits)``. The fixed iteration count, the per-iteration
    pair extraction, and the test-and-shift pattern all match the RTL
    so that the testbench compares bit-for-bit.
    """
    if n < 0:
        raise ValueError("isqrt_nonrestoring of negative")
    n_iter = total_bits // 2
    rem = 0
    res = 0
    for i in range(n_iter - 1, -1, -1):
        rem = (rem << 2) | ((n >> (2 * i)) & 3)
        test = (res << 2) | 1
        if rem >= test:
            rem -= test
            res = (res << 1) | 1
        else:
            res = res << 1
    return res


def rsqrt_q_hardware(norm2: int, frac_bits: int = 13, total_bits: int = 32) -> int:
    """Hardware-equivalent ``round_floor((1 << frac_bits) / sqrt(norm2))``.

    Uses ``isqrt_nonrestoring`` for the sqrt and truncating integer
    division for the reciprocal — exactly what ``rtl/rsqrt_unit.sv``
    computes. Saturates to ``UQ2.<frac_bits>`` max (15 bits unsigned for
    ``frac_bits = 13``).
    """
    sat = (1 << (frac_bits + 2)) - 1
    if norm2 <= 0:
        return sat
    sqrt_val = isqrt_nonrestoring(norm2, total_bits=total_bits)
    if sqrt_val == 0:
        return sat
    return min((1 << frac_bits) // sqrt_val, sat)
