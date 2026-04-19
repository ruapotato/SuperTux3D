#!/usr/bin/env python3
"""Generate a small set of placeholder WAV sound effects for the Godot
project. The decomp's real audio pipeline (sequenced M64 music + ADPCM
sample banks) is a future port; for now these procedurally-synthesized
tones are enough to give audible feedback on coin pickups, jumps, etc.

Each sound is a short PCM-16 mono WAV. Godot loads them directly as
AudioStreamWAV without any editor-time import.
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
import wave
from pathlib import Path


SAMPLE_RATE = 22050


def write_wav(path: Path, samples: list[int]) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(b"".join(struct.pack("<h", s) for s in samples))


def env(i: int, total: int, attack: float, release: float) -> float:
    t = i / SAMPLE_RATE
    dur = total / SAMPLE_RATE
    a = min(t / attack, 1.0) if attack > 0 else 1.0
    left = dur - t
    r = min(left / release, 1.0) if release > 0 else 1.0
    return max(0.0, min(1.0, a * r))


def tone(freq: float, duration: float, amp: float = 0.3,
         freq_end: float | None = None,
         wave_type: str = "sine",
         attack: float = 0.02,
         release: float = 0.1) -> list[int]:
    n = int(duration * SAMPLE_RATE)
    out: list[int] = []
    for i in range(n):
        t = i / SAMPLE_RATE
        f = freq
        if freq_end is not None:
            f = freq + (freq_end - freq) * (i / n)
        phase = 2 * math.pi * f * t
        if wave_type == "square":
            s = 1.0 if math.sin(phase) >= 0 else -1.0
        elif wave_type == "triangle":
            s = 2.0 * abs(((phase / (2 * math.pi)) % 1.0) * 2.0 - 1.0) - 1.0
        else:
            s = math.sin(phase)
        s *= amp * env(i, n, attack, release)
        out.append(max(-32767, min(32767, int(s * 32767))))
    return out


def layer(sounds: list[list[int]]) -> list[int]:
    n = max(len(s) for s in sounds)
    out = [0] * n
    for s in sounds:
        for i, v in enumerate(s):
            out[i] = max(-32767, min(32767, out[i] + v))
    return out


def seq(parts: list[list[int]]) -> list[int]:
    out: list[int] = []
    for p in parts:
        out.extend(p)
    return out


SOUNDS = {
    # Cheery two-note coin chime.
    "coin": lambda: seq([
        tone(988, 0.06, 0.45),
        tone(1319, 0.18, 0.55, release=0.15),
    ]),
    # Falling "whoa" slide for death/fall-off.
    "death": lambda: tone(440, 0.7, 0.5, freq_end=130, wave_type="triangle"),
    # Mario voice-ish "yah!" for jump — quick rising blip.
    "jump": lambda: tone(440, 0.13, 0.4, freq_end=880, release=0.06),
    # Landing thud — low triangle.
    "land": lambda: tone(160, 0.08, 0.5, wave_type="triangle", release=0.06),
    # Star fanfare — ascending arp.
    "star": lambda: seq([
        tone(659, 0.12, 0.5),
        tone(784, 0.12, 0.5),
        tone(988, 0.2, 0.6, release=0.15),
    ]),
    # Punch — short white-noise-ish burst via dissonant layer.
    "punch": lambda: layer([
        tone(220, 0.08, 0.3, wave_type="square"),
        tone(311, 0.08, 0.2, wave_type="square"),
    ]),
    # Ground pound — descending thud.
    "ground_pound": lambda: tone(300, 0.25, 0.55, freq_end=70,
                                   wave_type="triangle", release=0.12),
    # Cap pickup — bright arp.
    "cap": lambda: seq([
        tone(523, 0.08, 0.5),
        tone(659, 0.08, 0.5),
        tone(784, 0.14, 0.55, release=0.1),
    ]),
    # 1up — classic rising.
    "oneup": lambda: seq([
        tone(784, 0.09, 0.5),
        tone(1047, 0.09, 0.5),
        tone(1319, 0.09, 0.5),
        tone(1568, 0.22, 0.6, release=0.15),
    ]),
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("out_dir", type=Path)
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for name, make in SOUNDS.items():
        samples = make()
        write_wav(args.out_dir / f"{name}.wav", samples)
    print(f"wrote {len(SOUNDS)} placeholder sfx WAV files to {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
