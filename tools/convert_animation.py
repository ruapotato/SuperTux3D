#!/usr/bin/env python3
"""Convert one or more decomp `anim_XX.inc.c` files into JSON.

Each animation file contains a `struct Animation` header, a `u16` indices
table and an `s16` values table. We unpack all three into an easier-to-read
JSON while preserving the runtime semantics exactly:

  indices[2*i + 0] = number of frames in track i
  indices[2*i + 1] = offset into values[] where track i's samples begin
  frame_value      = values[offset + min(current_frame, num_frames - 1)]

Tracks are ordered:
  i = 0, 1, 2  → root translation X, Y, Z
  i = 3+3*b+0  → bone b rotation X
  i = 3+3*b+1  → bone b rotation Y
  i = 3+3*b+2  → bone b rotation Z

Output:
{
  "name": "anim_0E",
  "flags": 1,
  "y_trans_divisor": 189,
  "start_frame": 0,
  "loop_start": 0,
  "loop_end": 1,
  "length": 0,
  "bone_count": 20,
  "indices": [[nframes, offset], ...],
  "values":  [ ...s16 ints... ]
}

Angles in values[] are signed 16-bit (-32768..32767) where 65536 = 360°.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


STRUCT_RE = re.compile(
    r"const\s+struct\s+Animation\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)
INDICES_RE = re.compile(
    r"const\s+u16\s+(\w+_indices)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)
VALUES_RE = re.compile(
    r"const\s+s16\s+(\w+_values)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)


def parse_int_token(tok: str) -> int:
    tok = tok.strip().rstrip(",").strip()
    if not tok:
        return 0
    if tok.lower().startswith("0x"):
        return int(tok, 16)
    # Accept decimal integers too.
    try:
        return int(tok)
    except ValueError:
        return 0


def parse_number_list(body: str) -> list[int]:
    # Strip block comments and end-of-line comments.
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
    body = re.sub(r"//[^\n]*", "", body)
    tokens = [t for t in body.replace("\n", ",").split(",") if t.strip()]
    return [parse_int_token(t) for t in tokens]


def parse_s16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def parse_animation(c_text: str) -> list[dict]:
    """One .inc.c file may contain multiple animations (e.g. anim_01_02.inc.c).
    Each animation references an _indices + _values pair with matching name."""
    indices_tables: dict[str, list[int]] = {}
    values_tables: dict[str, list[int]] = {}
    for m in INDICES_RE.finditer(c_text):
        indices_tables[m.group(1)] = [v & 0xFFFF for v in parse_number_list(m.group(2))]
    for m in VALUES_RE.finditer(c_text):
        values_tables[m.group(1)] = [parse_s16(v) for v in parse_number_list(m.group(2))]

    animations: list[dict] = []
    for m in STRUCT_RE.finditer(c_text):
        name = m.group(1)
        body = m.group(2).strip()
        # Strip comments from the body so the field splitter doesn't see them.
        body = re.sub(r"/\*.*?\*/", "", body, flags=re.DOTALL)
        body = re.sub(r"//[^\n]*", "", body)
        fields = [f.strip() for f in body.split(",")]
        fields = [f for f in fields if f]
        if len(fields) < 9:
            print(f"warning: {name} has {len(fields)} fields (<9)", file=sys.stderr)
            continue
        flags = parse_int_token(fields[0])
        y_trans_divisor = parse_int_token(fields[1])
        start_frame = parse_int_token(fields[2])
        loop_start = parse_int_token(fields[3])
        loop_end = parse_int_token(fields[4])
        # fields[5] is ANIMINDEX_NUMPARTS(...) — we derive bone count from
        # the indices array length rather than parsing the macro.
        values_sym = fields[6]
        indices_sym = fields[7]
        length = parse_int_token(fields[8])

        idx_table = indices_tables.get(indices_sym)
        val_table = values_tables.get(values_sym)
        if idx_table is None or val_table is None:
            print(f"warning: {name} missing indices/values tables "
                  f"({indices_sym}/{values_sym})", file=sys.stderr)
            continue

        # Indices come in pairs. Expected: 3 root translation + 3*bone_count
        # rotation = 6 * (bone_count + 1) u16 entries.
        n_pairs = len(idx_table) // 2
        bone_count = (n_pairs - 3) // 3
        pairs = [[idx_table[2 * i], idx_table[2 * i + 1]] for i in range(n_pairs)]

        # loop_end caps the playable frame count; start_frame is where Mario
        # was in the rest pose when the decomp authored this animation.
        animations.append({
            "name": name,
            "flags": flags,
            "y_trans_divisor": y_trans_divisor,
            "start_frame": start_frame,
            "loop_start": loop_start,
            "loop_end": loop_end,
            "length": length,
            "bone_count": bone_count,
            "indices": pairs,
            "values": val_table,
        })
    return animations


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "input",
        type=Path,
        help="A single anim_XX.inc.c file, or the directory "
        "reference/sm64/assets/anims to convert all animations.",
    )
    ap.add_argument(
        "output",
        type=Path,
        help="Output JSON path. If input is a directory, this becomes a "
        "directory with one JSON per animation.",
    )
    args = ap.parse_args()

    if args.input.is_dir():
        args.output.mkdir(parents=True, exist_ok=True)
        total = 0
        for f in sorted(args.input.glob("anim_*.inc.c")):
            anims = parse_animation(f.read_text(errors="ignore"))
            for anim in anims:
                out_path = args.output / f"{anim['name']}.json"
                out_path.write_text(json.dumps(anim, indent=2))
                total += 1
        print(f"wrote {total} animations to {args.output}")
    else:
        anims = parse_animation(args.input.read_text(errors="ignore"))
        args.output.parent.mkdir(parents=True, exist_ok=True)
        if len(anims) == 1:
            args.output.write_text(json.dumps(anims[0], indent=2))
            print(f"wrote {args.output}: {anims[0]['name']} "
                  f"({anims[0]['bone_count']} bones, "
                  f"{anims[0]['loop_end']} loop frames)")
        else:
            # Emit a list of animations.
            args.output.write_text(json.dumps(anims, indent=2))
            print(f"wrote {args.output}: {len(anims)} animations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
