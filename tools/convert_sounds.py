#!/usr/bin/env python3
"""Convert a hand-picked set of SM64 decomp AIFF samples to WAV for use as
Godot AudioStreamWAV sources. The decomp has already expanded the ROM's
ADPCM samples to 16-bit PCM AIFFs at extract time; we just need to repack
them as WAV headers Godot's AudioStreamWAV-from-raw-PCM loader can read.

Mapping is intentionally small and opinionated: pick identifiable Mario
voice clips + footsteps + a few generic sfx. Stream IDs that require the
decomp's sound-event table to resolve (coin chime, star fanfare) stay on
the placeholder synthesized tones for now."""
from __future__ import annotations

import aifc
import argparse
import struct
import sys
import wave
from pathlib import Path


# event name → path under reference/sm64/sound/samples
MAPPING = {
    "jump":         "sfx_mario/00_mario_jump_hoo.aiff",
    "jump2":        "sfx_mario/01_mario_jump_wah.aiff",
    "yah":          "sfx_mario/02_mario_yah.aiff",
    "haha":         "sfx_mario/03_mario_haha.aiff",
    "yahoo":        "sfx_mario/04_mario_yahoo.aiff",
    "uh":           "sfx_mario/05_mario_uh.aiff",
    "whoa":         "sfx_mario/08_mario_whoa.aiff",
    "ooof":         "sfx_mario/0B_mario_ooof.aiff",
    "here_we_go":   "sfx_mario/0C_mario_here_we_go.aiff",
    "doh":          "sfx_mario/10_mario_doh.aiff",
    "game_over":    "sfx_mario/11_mario_game_over.aiff",
    "attacked":     "sfx_mario/0A_mario_attacked.aiff",
    "step":         "sfx_terrain/00_step_default.aiff",
    "step_grass":   "sfx_terrain/01_step_grass.aiff",
    "step_stone":   "sfx_terrain/02_step_stone.aiff",
    "step_snow":    "sfx_terrain/04_step_snow.aiff",
    "plop":         "sfx_1/04_plop.aiff",
    "heavy_land":   "sfx_1/05_heavy_landing.aiff",
    "hand_touch":   "sfx_1/02_hand_touch.aiff",
}


def aiff_to_wav(src: Path, dst: Path) -> None:
    # The aifc module reads AIFF-C (and plain AIFF); these decomp files are
    # uncompressed big-endian signed 16-bit PCM. We read all frames,
    # byte-swap to little-endian, and write a standard WAV.
    with aifc.open(str(src), "rb") as a:
        channels = a.getnchannels()
        width = a.getsampwidth()
        rate = a.getframerate()
        n = a.getnframes()
        raw = a.readframes(n)
    # AIFF samples are signed BE; repack as LE (wave expects LE).
    if width == 2:
        samples = [struct.unpack(">h", raw[i:i+2])[0] for i in range(0, len(raw), 2)]
        raw = b"".join(struct.pack("<h", s) for s in samples)
    with wave.open(str(dst), "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(width)
        w.setframerate(rate)
        w.writeframes(raw)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--sm64-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "reference" / "sm64",
    )
    ap.add_argument("out_dir", type=Path)
    args = ap.parse_args()
    args.out_dir.mkdir(parents=True, exist_ok=True)

    samples_root = args.sm64_root / "sound" / "samples"
    wrote = 0
    for name, rel in MAPPING.items():
        src = samples_root / rel
        if not src.exists():
            print(f"missing {src}", file=sys.stderr)
            continue
        dst = args.out_dir / f"{name}.wav"
        try:
            aiff_to_wav(src, dst)
            wrote += 1
        except Exception as e:
            print(f"failed {name}: {e}", file=sys.stderr)
    print(f"converted {wrote}/{len(MAPPING)} AIFFs to {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
