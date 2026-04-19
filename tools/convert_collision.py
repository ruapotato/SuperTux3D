#!/usr/bin/env python3
"""Convert an SM64 decomp collision.inc.c file to a Godot-friendly JSON.

Output schema:
{
  "source": "<path relative to sm64 repo>",
  "symbol": "<C symbol name>",
  "vertices": [[x, y, z], ...],
  "triangle_groups": [
    {"surface": "SURFACE_DEFAULT", "surface_id": 0,
     "force": 0, "triangles": [[a, b, c], ...]},
    ...
  ]
}

Only the common collision macros are handled: COL_INIT, COL_VERTEX_INIT,
COL_VERTEX, COL_TRI_INIT, COL_TRI, COL_TRI_STOP, COL_END. Water boxes,
special objects, and environment regions are ignored for now and reported
as skipped macros in the output.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


MACRO_RE = re.compile(r"(COL_[A-Z_0-9]+)\s*\(([^)]*)\)")
SYMBOL_RE = re.compile(r"Collision\s+(\w+)\s*\[\s*\]")


def parse_int(s: str) -> int:
    s = s.strip()
    return int(s, 16) if s.lower().startswith("0x") else int(s)


def load_surface_types(sm64_root: Path) -> dict[str, int]:
    """Parse include/surface_terrains.h for SURFACE_* #defines."""
    path = sm64_root / "include" / "surface_terrains.h"
    define_re = re.compile(r"^\s*#define\s+(SURFACE_\w+)\s+(0x[0-9A-Fa-f]+|\d+)\b")
    out: dict[str, int] = {}
    for line in path.read_text().splitlines():
        m = define_re.match(line)
        if m:
            out[m.group(1)] = parse_int(m.group(2))
    return out


def convert(c_path: Path, surface_ids: dict[str, int]) -> dict:
    text = c_path.read_text()
    symbol_match = SYMBOL_RE.search(text)
    symbol = symbol_match.group(1) if symbol_match else c_path.stem

    vertices: list[list[int]] = []
    triangle_groups: list[dict] = []
    current_group: dict | None = None
    skipped_macros: dict[str, int] = {}
    declared_vertex_count: int | None = None

    for macro_name, args in MACRO_RE.findall(text):
        args_list = [a.strip() for a in args.split(",")] if args.strip() else []

        if macro_name == "COL_INIT":
            continue
        if macro_name == "COL_END":
            continue
        if macro_name == "COL_VERTEX_INIT":
            declared_vertex_count = parse_int(args_list[0])
            continue
        if macro_name == "COL_VERTEX":
            vertices.append([parse_int(a) for a in args_list[:3]])
            continue
        if macro_name == "COL_TRI_INIT":
            surface_name = args_list[0]
            surface_id = surface_ids.get(surface_name)
            if surface_id is None:
                print(f"warning: unknown surface {surface_name} — using -1", file=sys.stderr)
                surface_id = -1
            current_group = {
                "surface": surface_name,
                "surface_id": surface_id,
                "force": 0,
                "triangles": [],
            }
            triangle_groups.append(current_group)
            continue
        if macro_name == "COL_TRI":
            if current_group is None:
                raise ValueError(f"COL_TRI before COL_TRI_INIT in {c_path}")
            indices = [parse_int(a) for a in args_list[:3]]
            current_group["triangles"].append(indices)
            # Some triangles in the decomp carry a 4th "force" arg; attach it
            # to the last tri as metadata so we can surface it later. Rare
            # enough that a per-group force is fine for now.
            if len(args_list) >= 4:
                current_group["force"] = parse_int(args_list[3])
            continue
        if macro_name == "COL_TRI_STOP":
            current_group = None
            continue

        skipped_macros[macro_name] = skipped_macros.get(macro_name, 0) + 1

    if declared_vertex_count is not None and declared_vertex_count != len(vertices):
        print(
            f"warning: declared {declared_vertex_count} vertices, parsed {len(vertices)}",
            file=sys.stderr,
        )

    return {
        "source": str(c_path),
        "symbol": symbol,
        "vertex_count": len(vertices),
        "triangle_count": sum(len(g["triangles"]) for g in triangle_groups),
        "vertices": vertices,
        "triangle_groups": triangle_groups,
        "skipped_macros": skipped_macros,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("input", type=Path, help="path to collision.inc.c")
    ap.add_argument("output", type=Path, help="path to write JSON")
    ap.add_argument(
        "--sm64-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "reference" / "sm64",
        help="path to the n64decomp/sm64 repo (for surface_terrains.h)",
    )
    args = ap.parse_args()

    surface_ids = load_surface_types(args.sm64_root)
    result = convert(args.input, surface_ids)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(
        f"wrote {args.output}: "
        f"{result['vertex_count']} verts, "
        f"{result['triangle_count']} tris in "
        f"{len(result['triangle_groups'])} surface groups"
    )
    if result["skipped_macros"]:
        print(f"  skipped macros: {result['skipped_macros']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
