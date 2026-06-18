"""Radix-2 in-place Walsh-Hadamard transform, natural order.

Pure-Python integer-or-float butterfly, designed to mirror the SV
``wht64.sv`` module exactly. Length must be a power of two.

Conventions
-----------
This is the *unscaled* Hadamard transform: ``H @ H.T = d * I``. To get
an orthogonal rotation use ``H / sqrt(d)``. TurboQuant only needs unit
vectors after normalisation, so the global ``sqrt(d)`` factor cancels
out — there is no need to apply it in hardware.

Bit growth: after ``log2(d)`` butterfly stages, ``|y_max| <= d * |x_max|``
worst case, but the typical magnitude is ``sqrt(d) * |x|``. For
``d = 64`` and 8-bit signed input, ``y`` fits in 14 bits worst-case.

Butterfly stages
----------------
``h`` doubles each stage; pairs are ``(j, j + h)`` over indices spaced
by ``2h``::

    stage 0  h=1   pairs (0,1), (2,3), (4,5), ...
    stage 1  h=2   pairs (0,2), (1,3), (4,6), ...
    ...
    stage k  h=2^k pairs (i, i+h) for i in range(0, d, 2h), j in range(i, i+h)

The same indexing pattern applies in the SV version.
"""
from __future__ import annotations

from typing import List, MutableSequence, TypeVar

T = TypeVar("T", int, float)


def wht_inplace(y: MutableSequence[T]) -> MutableSequence[T]:
    """Apply the unscaled Walsh-Hadamard transform to ``y`` in place.

    Works on any indexable mutable sequence whose elements support
    ``+`` and ``-`` (so plain Python lists of ints, lists of floats,
    or 1-D numpy arrays all work).
    """
    d = len(y)
    if d <= 0 or (d & (d - 1)) != 0:
        raise ValueError(f"length must be a positive power of 2, got {d}")
    h = 1
    while h < d:
        i = 0
        while i < d:
            for j in range(i, i + h):
                a = y[j]
                b = y[j + h]
                y[j] = a + b
                y[j + h] = a - b
            i += h * 2
        h *= 2
    return y


def wht(y) -> List:
    """Functional wrapper: returns a new list with WHT applied."""
    out = list(y)
    wht_inplace(out)
    return out


if __name__ == "__main__":
    # Self-check: WHT(WHT(x)) == d * x.
    import random
    random.seed(0)
    d = 64
    x = [random.randint(-100, 100) for _ in range(d)]
    y = wht(x)
    z = wht(y)
    assert all(z[i] == d * x[i] for i in range(d)), "WHT involution check failed"
    print(f"WHT(WHT(x)) == {d} * x  -> ok")
    print(f"||y||^2 / d == {sum(v * v for v in y) / d}, expected {sum(v * v for v in x)}")
