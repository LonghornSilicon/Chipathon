"""16-bit Galois LFSR — Python mirror of ``rtl/sign_lfsr.sv``.

Polynomial: x^16 + x^14 + x^13 + x^11 + 1 (a standard primitive
polynomial; period 65535). In Galois form the feedback mask is 0xB400.

Operation per step::

    out_bit = state & 1
    state >>= 1
    if out_bit:
        state ^= 0xB400

The output bit is the LSB of ``state`` *before* the shift. We then map
``0 -> -1, 1 -> +1`` to get a Rademacher sign.

Default seed 0xACE1 is the value baked into the RTL parameter. Any
nonzero 16-bit seed produces a valid (period-65535) sequence; zero is
forbidden (the state machine would lock at 0 forever).
"""
from __future__ import annotations

from typing import List

DEFAULT_SEED: int = 0xACE1
DEFAULT_MASK: int = 0xB400


def galois_lfsr_bits(n: int, seed: int = DEFAULT_SEED, mask: int = DEFAULT_MASK) -> List[int]:
    """Return ``n`` bits from the LFSR as a Python list of 0/1 ints.

    Each call to ``galois_lfsr_bits`` is stateless: it re-seeds and
    runs ``n`` steps. The first emitted bit is the LSB of the seed.
    """
    if seed == 0 or seed >> 16 != 0:
        raise ValueError(f"seed must be a nonzero 16-bit integer, got {seed:#x}")
    if mask >> 16 != 0:
        raise ValueError(f"mask must fit in 16 bits, got {mask:#x}")
    state = seed
    bits: List[int] = []
    for _ in range(n):
        out = state & 1
        state >>= 1
        if out:
            state ^= mask
        bits.append(out)
    return bits


def galois_lfsr_signs(n: int, seed: int = DEFAULT_SEED, mask: int = DEFAULT_MASK) -> List[int]:
    """Return ``n`` signs in ``{+1, -1}`` (mapping 0 -> -1, 1 -> +1)."""
    return [1 if b else -1 for b in galois_lfsr_bits(n, seed=seed, mask=mask)]


if __name__ == "__main__":
    # Quick self-check: print the first 64 bits + signs.
    bits = galois_lfsr_bits(64)
    signs = galois_lfsr_signs(64)
    print("first 64 bits :", "".join(str(b) for b in bits))
    print("popcount      :", sum(bits), "/ 64")
    print("first 8 signs :", signs[:8])
