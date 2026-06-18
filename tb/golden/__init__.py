"""Bit-exact Python golden for the TurboQuant SKY130 encoder.

This package mirrors the RTL datapath one-to-one so the testbench can
compare per-stage outputs without re-deriving the math. The reference
math comes from arXiv:2504.19874 and the source-of-truth Python repo at
``../../../turboquant/``.

Modules:
- :mod:`lfsr`               16-bit Galois LFSR matching ``sign_lfsr.sv``
- :mod:`wht`                radix-2 Walsh-Hadamard, in-place, integer
- :mod:`fixedpoint`         round/saturate helpers
- :mod:`structured_rotation` ``y = WHT(s ⊙ x)`` (the chip's rotation)
- :mod:`encoder`            full Algorithm-1 encoder, fp64 + fixed-point
- :mod:`gen_vectors`        stimulus + expected dumper for ``tb_tq_top``
- :mod:`sweep_precision`    bit-width sweep against cos-sim target
"""
