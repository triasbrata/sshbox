#!/usr/bin/env python3
"""How far the picture under a point moved between two screenshots.

Usage: e2e_band_shift.py BEFORE AFTER Y [HALF [LO HI]]

BEFORE and AFTER are raw `adb exec-out screencap` dumps (a 12 or 16 byte
header of width, height and format, then RGBA). The band of rows Y-HALF to
Y+HALF of BEFORE is looked for in AFTER, shifted by -600 to +600 rows, or,
with LO and HI, only so far that the band stays within rows LO to HI of
AFTER (the part of the screen that can move, so a still header or keyboard
is never what matches). Printed: the shift where it matches best, how well
it matched (the mean difference per sampled pixel, 0 for identical) and how
well no shift does: "<shift> <best diff> <diff at 0>".
"""
import struct
import sys


def load(path):
    data = open(path, 'rb').read()
    w, h = struct.unpack('<II', data[:8])
    size = w * h * 4
    head = len(data) - size
    if head not in (12, 16):
        sys.exit(f'{path}: {len(data)} bytes is no {w}x{h} RGBA screencap')
    # Rows as greys sampled every 4th pixel, 10% in from each side.
    rows = []
    xs = range(w // 10, w - w // 10, 4)
    for y in range(h):
        base = head + y * w * 4
        rows.append([sum(data[base + 4 * x:base + 4 * x + 3]) // 3 for x in xs])
    return rows


def main():
    before, after = load(sys.argv[1]), load(sys.argv[2])
    y = int(sys.argv[3])
    half = int(sys.argv[4]) if len(sys.argv) > 4 else 90
    lo = int(sys.argv[5]) if len(sys.argv) > 6 else 0
    hi = int(sys.argv[6]) if len(sys.argv) > 6 else len(after)
    band = range(max(0, y - half), min(len(before), y + half))

    def diff(s):
        total = n = 0
        for r in band:
            if not lo <= r + s < hi:
                return float('inf')
            a, b = before[r], after[r + s]
            total += sum(abs(p - q) for p, q in zip(a, b))
            n += len(a)
        return total / n

    best = min(range(-600, 601), key=diff)
    print(best, f'{diff(best):.2f}', f'{diff(0):.2f}')


main()
