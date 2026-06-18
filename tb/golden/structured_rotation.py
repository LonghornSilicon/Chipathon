"""Structured rotation: ``y = WHT(s ⊙ x)`` where ``s ∈ {±1}^d``.

This is the rotation primitive baked into the chip. ``H @ Diag(s)`` is
orthogonal up to a global ``sqrt(d)`` factor (since ``H @ H.T = d * I``).
The TurboQuant pipeline only ever sees ``y`` through ``y / ||y||``, so
the constant factor cancels out — there is no need to scale by
``1/sqrt(d)`` in hardware.

Why this works
--------------
The TurboQuant proof needs the per-coordinate distribution of ``y/||y||``
to be approximately Beta(1/2, (d-1)/2). For Haar-uniform rotations this
is exact in expectation. For ``H @ Diag(s)`` with random Rademacher
``s``, the same property holds asymptotically — this is the SRHT
construction used in countless sketching papers. ``d = 64`` is large
enough that the empirical distortion matches the Haar reference to
within the codebook MSE.
"""
from __future__ import annotations

import numpy as np

from .lfsr import DEFAULT_SEED, galois_lfsr_signs
from .wht import wht_inplace


def make_signs(d: int, seed: int = DEFAULT_SEED) -> np.ndarray:
    """Return ``d`` signs in ``{-1, +1}`` from the LFSR as int8."""
    return np.array(galois_lfsr_signs(d, seed=seed), dtype=np.int8)


def structured_rotate_int(x: np.ndarray, signs: np.ndarray) -> np.ndarray:
    """Integer ``y = WHT(s ⊙ x)``. ``x`` and ``signs`` cast to int64.

    No saturation here — the caller is responsible for narrowing ``y``
    to the chip's internal width (saturate_signed in :mod:`fixedpoint`).
    """
    x = np.asarray(x, dtype=np.int64)
    s = np.asarray(signs, dtype=np.int64)
    if x.shape != s.shape or x.ndim != 1:
        raise ValueError(f"shape mismatch: x={x.shape}, signs={s.shape}")
    y = (x * s).tolist()
    wht_inplace(y)
    return np.array(y, dtype=np.int64)


def structured_rotate_fp(x: np.ndarray, signs: np.ndarray) -> np.ndarray:
    """Float ``y = WHT(s ⊙ x)``. The fp64 reference."""
    x = np.asarray(x, dtype=np.float64)
    s = np.asarray(signs, dtype=np.float64)
    if x.shape != s.shape or x.ndim != 1:
        raise ValueError(f"shape mismatch: x={x.shape}, signs={s.shape}")
    y = (x * s).tolist()
    wht_inplace(y)
    return np.array(y, dtype=np.float64)


def structured_unrotate_fp(y: np.ndarray, signs: np.ndarray) -> np.ndarray:
    """Inverse of :func:`structured_rotate_fp`. WHT is self-inverse up
    to a factor of ``d``, and ``Diag(s)^{-1} = Diag(s)`` since ``s_i = ±1``.
    """
    y = np.asarray(y, dtype=np.float64)
    s = np.asarray(signs, dtype=np.float64)
    d = y.size
    tmp = y.tolist()
    wht_inplace(tmp)
    out = np.array(tmp, dtype=np.float64) / float(d)
    return out * s
