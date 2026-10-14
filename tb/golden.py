#!/usr/bin/env python3
"""Golden reference model and test-vector generator for MUL32-CMP.

Writes a full set (directed + 10^6 random) and a smoke set (directed +
10^4 random) per signedness mode:

    vec_signed.hex        vec_unsigned.hex
    vec_signed_smoke.hex  vec_unsigned_smoke.hex

Each line holds three hex fields:

    aaaaaaaa bbbbbbbb pppppppppppppppp

a, b are 32-bit operand bit patterns; p is the expected 64-bit product
bit pattern (two's complement when signed). The file begins with the
directed corner cases, followed by the random vectors.
"""

import argparse
import os
import random

MASK32 = (1 << 32) - 1
MASK64 = (1 << 64) - 1

# Directed operand values: 0, 1, -1/0xFFFFFFFF, min/0x80000000,
# max/0x7FFFFFFF, plus a few neighbours of the extremes.
CORNER_VALUES = [
    0x00000000, 0x00000001, 0x00000002,
    0xFFFFFFFF, 0xFFFFFFFE,
    0x80000000, 0x80000001,
    0x7FFFFFFF, 0x7FFFFFFE,
    0x0000FFFF, 0x00010000, 0xFFFF0000, 0x0000FFFE,
    0x55555555, 0xAAAAAAAA,
    # 16-bit half boundaries: low half with its MSB set / clear, which
    # stress the signed-high / unsigned-low split in decomposed designs.
    0x00008000, 0x00007FFF, 0xFFFF8000, 0x12348000, 0x8000FFFF,
]


def to_signed32(x):
    return x - (1 << 32) if x & 0x80000000 else x


def golden(a, b, signed):
    """Return the 64-bit product bit pattern of two 32-bit bit patterns."""
    if signed:
        return (to_signed32(a) * to_signed32(b)) & MASK64
    return (a * b) & MASK64


def self_check():
    """Hand-checked values for the corner cases named in the spec."""
    # unsigned
    assert golden(0xFFFFFFFF, 0xFFFFFFFF, False) == 0xFFFFFFFE00000001  # max*max
    assert golden(0x80000000, 0x80000000, False) == 0x4000000000000000
    assert golden(0, 0xFFFFFFFF, False) == 0
    assert golden(1, 0xFFFFFFFF, False) == 0xFFFFFFFF
    # signed
    assert golden(0x7FFFFFFF, 0x7FFFFFFF, True) == 0x3FFFFFFF00000001  # max*max
    assert golden(0x80000000, 0x80000000, True) == 0x4000000000000000  # min*min
    assert golden(0x80000000, 0xFFFFFFFF, True) == 0x0000000080000000  # min*-1
    assert golden(0xFFFFFFFF, 0xFFFFFFFF, True) == 0x0000000000000001  # -1*-1
    assert golden(0x80000000, 0x7FFFFFFF, True) == 0xC000000080000000  # min*max
    assert golden(1, 0xFFFFFFFF, True) == MASK64                       # 1*-1


def gen(path, signed, n_random, seed):
    rng = random.Random(seed)
    lines = []
    # All ordered pairs of corner values (covers 0, 1, max*max, min*min,
    # min*-1, and the mixed-sign combinations).
    for a in CORNER_VALUES:
        for b in CORNER_VALUES:
            lines.append((a, b))
    n_directed = len(lines)
    for _ in range(n_random):
        lines.append((rng.getrandbits(32), rng.getrandbits(32)))
    with open(path, "w", newline="\n") as f:
        for a, b in lines:
            f.write(f"{a:08x} {b:08x} {golden(a, b, signed):016x}\n")
    return n_directed, len(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-n", "--num-random", type=int, default=1_000_000)
    ap.add_argument("--num-smoke", type=int, default=10_000)
    ap.add_argument("-s", "--seed", type=int, default=0x5EED32)
    ap.add_argument("-o", "--outdir",
                    default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                         "..", "vectors"))
    args = ap.parse_args()

    self_check()
    os.makedirs(args.outdir, exist_ok=True)
    for signed, mode in ((True, "signed"), (False, "unsigned")):
        for suffix, n_random in (("", args.num_random), ("_smoke", args.num_smoke)):
            path = os.path.normpath(os.path.join(args.outdir, f"vec_{mode}{suffix}.hex"))
            # Different seed per mode so the two files are not the same operands.
            # The smoke set uses the same seed, so it is a prefix of the full set.
            n_dir, n_tot = gen(path, signed, n_random, args.seed + int(signed))
            print(f"{path}: {n_dir} directed + {n_tot - n_dir} random = {n_tot} vectors")


if __name__ == "__main__":
    main()
