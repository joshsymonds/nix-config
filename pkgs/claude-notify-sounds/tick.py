"""The notification tick: one light tap, synthesised with the standard library.

A 1320 Hz sine that dies in a few hundredths of a second, with a breath of
darkened noise at the front for the tap, a trace of room, and a short fade.
Usage: tick.py OUT.wav
"""
import math
import random
import struct
import sys
import wave

SR = 48000
TAU = 2 * math.pi
FREQ = 1320.0
PEAK_DBFS = -6.0


def tap():
    """The dry tap: 0.14 s of decaying sine plus 4 ms of low-passed noise."""
    rng = random.Random(1)
    out = [0.0] * int(0.14 * SR)
    phase = 0.0
    for i in range(len(out)):
        phase += TAU * FREQ / SR
        out[i] = math.sin(phase) * math.exp(-(i / SR) / 0.028)
    lp = 0.0
    for i in range(int(0.004 * SR)):
        lp += 0.35 * (rng.uniform(-1, 1) - lp)
        out[i] += 0.5 * lp * math.exp(-i / (0.0015 * SR))
    attack = int(0.001 * SR)
    for i in range(attack):
        out[i] *= 0.5 - 0.5 * math.cos(math.pi * i / attack)
    return out


def room(dry, wet):
    """A small room: four comb filters and two allpasses, mixed in at `wet`."""
    n = len(dry)
    acc = [0.0] * n
    for ms, fb in ((29.7, 0.70), (37.1, 0.68), (41.1, 0.66), (43.7, 0.64)):
        d = int(ms / 1000 * SR)
        buf = [0.0] * n
        for i in range(n):
            buf[i] = dry[i] + (fb * buf[i - d] if i >= d else 0.0)
        for i in range(n):
            acc[i] += buf[i] / 4
    for ms in (5.0, 1.7):
        d = int(ms / 1000 * SR)
        y = [0.0] * n
        for i in range(n):
            xd = acc[i - d] if i >= d else 0.0
            yd = y[i - d] if i >= d else 0.0
            y[i] = -0.7 * acc[i] + xd + 0.7 * yd
        acc = y
    return [dry[i] + wet * acc[i] for i in range(n)]


def render(level):
    """The finished tick, peak-normalised to `level` (0 to 1)."""
    mix = room(tap(), 0.05)
    fade = int(0.03 * SR)
    for i in range(fade):
        mix[len(mix) - 1 - i] *= i / fade
    peak = max(abs(s) for s in mix)
    return [s / peak * level for s in mix]


def main():
    samples = render(10 ** (PEAK_DBFS / 20))
    with wave.open(sys.argv[1], "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))


if __name__ == "__main__":
    main()
