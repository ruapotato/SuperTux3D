#!/usr/bin/env python3
"""Build a map from decomp texture C symbols to extracted PNG paths.

Two sources of texture declarations in the decomp:

1. Shared texture bins in `bin/*.c`:
       ALIGNED8 const Texture generic_09005800[] = {
       #include "textures/generic/bob_textures.05800.rgba16.inc.c"
       };

2. Per-level texture files in `levels/<name>/texture.inc.c`:
       ALIGNED8 static const Texture bob_seg7_texture_07000000[] = {
       #include "levels/bob/0.rgba16.inc.c"
       };

Both share the same pattern: a declaration containing a C symbol followed by
an `#include` pointing to an `*.inc.c` file. The corresponding PNG lives next
to it, named the same but with `.png` instead of `.inc.c`.

Output is a single JSON keyed by symbol:
    {
      "generic_09005800": {
          "png": "textures/generic/bob_textures.05800.rgba16.png",
          "width": 32, "height": 32, "format": "rgba16"
      },
      ...
    }
Paths are relative to the sm64 repo root so they can be resolved by either
the Python side or the Godot side.
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import sys
from pathlib import Path


# Matches a const Texture declaration followed by its include on the next
# non-empty line. Tolerant of `static`, `ALIGNED8`, etc. prefixes.
DECL_RE = re.compile(
    r"const\s+Texture\s+(\w+)\s*\[\s*\]\s*=\s*\{\s*"
    r"#include\s+\"([^\"]+)\"",
    re.MULTILINE,
)

FORMAT_RE = re.compile(r"\.(rgba16|rgba32|ia16|ia8|ia4|i8|i4|ci8|ci4)\.inc\.c$")


def png_size(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        data = f.read(24)
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"not a PNG: {path}")
    w, h = struct.unpack(">II", data[16:24])
    return w, h


def scan(sm64_root: Path) -> dict[str, dict]:
    """Walk every .c file under sm64_root and collect texture declarations."""
    out: dict[str, dict] = {}
    # We deliberately include bin/*.c and every level's texture.inc.c files.
    # Scanning broadly catches everything without hand-maintained directory
    # lists, and the regex is strict enough to avoid false positives.
    for c_file in list(sm64_root.rglob("*.c")) + list(sm64_root.rglob("*.inc.c")):
        try:
            text = c_file.read_text(errors="ignore")
        except Exception:
            continue
        if "const Texture" not in text:
            continue
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
        for symbol, include in DECL_RE.findall(text):
            if symbol in out:
                # Multiple declarations of the same symbol indicate an ambiguity
                # we haven't modelled (e.g. version-specific bins). Stick with
                # the first and warn — loud failure is better than silent wrong.
                continue
            inc_path = sm64_root / include
            png_path = Path(str(inc_path).replace(".inc.c", ".png"))
            if not png_path.exists():
                continue
            fmt_match = FORMAT_RE.search(include)
            fmt = fmt_match.group(1) if fmt_match else "unknown"
            try:
                w, h = png_size(png_path)
            except Exception as exc:
                print(f"warning: {png_path} unreadable: {exc}", file=sys.stderr)
                continue
            out[symbol] = {
                "png": str(png_path.relative_to(sm64_root)),
                "width": w,
                "height": h,
                "format": fmt,
            }
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--sm64-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "reference" / "sm64",
    )
    ap.add_argument("output", type=Path, help="where to write the symbol map JSON")
    ap.add_argument(
        "--copy-to",
        type=Path,
        default=None,
        help="if provided, copy PNGs here preserving relative paths "
        "(makes them reachable through res:// after symlinking into a Godot project)",
    )
    args = ap.parse_args()

    symbols = scan(args.sm64_root)

    if args.copy_to is not None:
        args.copy_to.mkdir(parents=True, exist_ok=True)
        copied = 0
        for sym, info in symbols.items():
            src = args.sm64_root / info["png"]
            dst = args.copy_to / info["png"]
            dst.parent.mkdir(parents=True, exist_ok=True)
            # Only copy when source is newer or destination missing, so
            # repeated runs stay idempotent and cheap.
            if (not dst.exists()) or dst.stat().st_mtime < src.stat().st_mtime:
                shutil.copy2(src, dst)
                copied += 1
        print(f"copied {copied}/{len(symbols)} PNGs to {args.copy_to}")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(symbols, indent=2, sort_keys=True))
    print(f"wrote {args.output}: {len(symbols)} texture symbols")
    return 0


if __name__ == "__main__":
    sys.exit(main())
