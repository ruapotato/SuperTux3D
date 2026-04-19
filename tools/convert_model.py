#!/usr/bin/env python3
"""Convert an SM64 decomp level model (model.inc.c + geo.inc.c) to a Godot-friendly JSON.

The decomp stores geometry as F3D display lists that call `gsSPVertex` to load
up to 32 vertices into the RSP vertex cache, then `gsSP1Triangle` / `gsSP2Triangles`
to draw triangles using cache indices. We walk those lists, tracking the currently
bound texture + draw layer, and emit one sub-mesh per (texture, layer) combination.

Entry-point display lists come from a companion geo.inc.c via `GEO_DISPLAY_LIST`
macros. Each entry-point DL gets walked (recursively through `gsSPDisplayList`
branches) into a single merged mesh, because Godot will render them together as
part of one level.

Output schema (JSON):
{
  "source":     "<model.inc.c path>",
  "geo_source": "<geo.inc.c path or null>",
  "entry_display_lists": ["bob_seg7_dl_...", ...],
  "sub_meshes": [
    {
      "key":     "<texture>|<layer>",
      "texture": "<C symbol or 'none'>",
      "layer":   "LAYER_OPAQUE" | "LAYER_ALPHA" | "LAYER_TRANSPARENT_DECAL" | ...,
      "positions": [[x, y, z], ...],       # raw decomp units (s16)
      "normals":   [[nx, ny, nz], ...],    # float, s8 / 127
      "uvs":       [[u, v], ...],          # raw Q10.5 (needs /32 then /tex_size on import)
      "colors":    [[r, g, b, a], ...],    # float, u8 / 255
      "indices":   [i0, i1, i2, ...]
    }
  ]
}

Vertex data carries BOTH a normal and color interpretation because the decomp
vertex struct stores 4 bytes that are either normals (lighting on) or colors
(lighting off). We can't always know from the DL alone, so we emit both — the
Godot side picks based on material setup.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


# ---------------- Vtx array parsing ----------------

VTX_ARRAY_RE = re.compile(
    r"(?:static\s+)?const\s+Vtx\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)

# One Vtx entry: {{{x, y, z}, flag, {u, v}, {nx, ny, nz, a}}}
VTX_ENTRY_RE = re.compile(
    r"\{\s*\{\s*\{\s*"
    r"(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)"
    r"\s*\}\s*,\s*(-?\d+)\s*,\s*\{\s*"
    r"(-?\d+)\s*,\s*(-?\d+)"
    r"\s*\}\s*,\s*\{\s*"
    r"(0x[0-9a-fA-F]+|-?\d+)\s*,\s*(0x[0-9a-fA-F]+|-?\d+)\s*,"
    r"\s*(0x[0-9a-fA-F]+|-?\d+)\s*,\s*(0x[0-9a-fA-F]+|-?\d+)"
    r"\s*\}\s*\}\s*\}",
    re.DOTALL,
)


def parse_byte(s: str) -> int:
    s = s.strip()
    v = int(s, 16) if s.lower().startswith("0x") else int(s)
    return v & 0xFF


def s8(b: int) -> int:
    return b - 256 if b >= 128 else b


@dataclass
class VtxEntry:
    pos: tuple[int, int, int]
    uv: tuple[int, int]
    rgba: tuple[int, int, int, int]  # raw bytes
    # derived
    normal: tuple[float, float, float]
    color: tuple[float, float, float, float]


def parse_vtx_arrays(text: str) -> dict[str, list[VtxEntry]]:
    arrays: dict[str, list[VtxEntry]] = {}
    for name, body in VTX_ARRAY_RE.findall(text):
        entries: list[VtxEntry] = []
        for m in VTX_ENTRY_RE.finditer(body):
            x, y, z = int(m.group(1)), int(m.group(2)), int(m.group(3))
            u, v = int(m.group(5)), int(m.group(6))
            rgba = tuple(parse_byte(m.group(i)) for i in (7, 8, 9, 10))
            nx, ny, nz = s8(rgba[0]), s8(rgba[1]), s8(rgba[2])
            normal = (nx / 127.0, ny / 127.0, nz / 127.0)
            color = (rgba[0] / 255.0, rgba[1] / 255.0, rgba[2] / 255.0, rgba[3] / 255.0)
            entries.append(
                VtxEntry(
                    pos=(x, y, z),
                    uv=(u, v),
                    rgba=rgba,
                    normal=normal,
                    color=color,
                )
            )
        arrays[name] = entries
    return arrays


# ---------------- Gfx (display list) parsing ----------------

GFX_ARRAY_RE = re.compile(
    r"(?:static\s+)?const\s+Gfx\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)

# Match gsXxx(args) opcodes. We use balanced-ish matching: args can't contain
# nested parens in the opcodes we actually care about, but they can contain
# comma-separated literals. Use a lazy match and rely on `gs...(` token boundary.
OPCODE_RE = re.compile(r"(gs[A-Za-z0-9_]+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)")


def split_args(args: str) -> list[str]:
    """Split a comma-separated arg list, respecting one level of nested parens."""
    out: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in args:
        if ch == "(":
            depth += 1
            cur.append(ch)
        elif ch == ")":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out


def parse_gfx_arrays(text: str) -> dict[str, list[tuple[str, list[str]]]]:
    arrays: dict[str, list[tuple[str, list[str]]]] = {}
    for name, body in GFX_ARRAY_RE.findall(text):
        ops: list[tuple[str, list[str]]] = []
        for m in OPCODE_RE.finditer(body):
            op = m.group(1)
            args = split_args(m.group(2))
            ops.append((op, args))
        arrays[name] = ops
    return arrays


# ---------------- Geo.inc.c entry discovery ----------------

GEO_DL_RE = re.compile(r"GEO_DISPLAY_LIST\s*\(\s*(\w+)\s*,\s*(\w+)\s*\)")


def discover_entry_dls(geo_path: Path | None) -> list[tuple[str, str]]:
    if geo_path is None or not geo_path.exists():
        return []
    text = geo_path.read_text()
    # Strip block comments so we don't pick up commented-out entries.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return [(m.group(1), m.group(2)) for m in GEO_DL_RE.finditer(text)]


# ---------------- DL walker ----------------

@dataclass
class SubMesh:
    texture: str
    layer: str
    positions: list[list[int]] = field(default_factory=list)
    normals: list[list[float]] = field(default_factory=list)
    uvs: list[list[int]] = field(default_factory=list)
    colors: list[list[float]] = field(default_factory=list)
    indices: list[int] = field(default_factory=list)
    # key -> emitted vertex index, for dedup within this submesh.
    _dedup: dict[tuple, int] = field(default_factory=dict)

    def emit_vertex(self, v: VtxEntry) -> int:
        key = (v.pos, v.uv, v.rgba)
        idx = self._dedup.get(key)
        if idx is not None:
            return idx
        idx = len(self.positions)
        self.positions.append(list(v.pos))
        self.normals.append(list(v.normal))
        self.uvs.append(list(v.uv))
        self.colors.append(list(v.color))
        self._dedup[key] = idx
        return idx


class Walker:
    def __init__(
        self,
        vtx_arrays: dict[str, list[VtxEntry]],
        gfx_arrays: dict[str, list[tuple[str, list[str]]]],
    ) -> None:
        self.vtx_arrays = vtx_arrays
        self.gfx_arrays = gfx_arrays
        self.sub_meshes: dict[tuple[str, str], SubMesh] = {}
        self.current_texture = "none"
        self.current_layer = "LAYER_OPAQUE"
        self.vtx_cache: list[VtxEntry | None] = [None] * 32
        # stats
        self.unknown_dls: set[str] = set()
        self.triangles_emitted = 0

    def submesh(self) -> SubMesh:
        key = (self.current_texture, self.current_layer)
        sm = self.sub_meshes.get(key)
        if sm is None:
            sm = SubMesh(texture=self.current_texture, layer=self.current_layer)
            self.sub_meshes[key] = sm
        return sm

    def emit_tri(self, a: int, b: int, c: int) -> None:
        va, vb, vc = self.vtx_cache[a], self.vtx_cache[b], self.vtx_cache[c]
        if va is None or vb is None or vc is None:
            return  # cache miss — DL referenced a slot never loaded
        sm = self.submesh()
        sm.indices.extend([sm.emit_vertex(va), sm.emit_vertex(vb), sm.emit_vertex(vc)])
        self.triangles_emitted += 1

    def load_vertices(self, arr_name: str, count: int, dest: int) -> None:
        arr = self.vtx_arrays.get(arr_name)
        if arr is None:
            print(f"warning: unknown vtx array {arr_name}", file=sys.stderr)
            return
        for i in range(count):
            if dest + i < len(self.vtx_cache) and i < len(arr):
                self.vtx_cache[dest + i] = arr[i]

    def walk(self, dl_name: str, layer: str, _depth: int = 0) -> None:
        if _depth > 32:
            print(f"warning: display list recursion too deep at {dl_name}", file=sys.stderr)
            return
        prev_layer = self.current_layer
        if layer:
            self.current_layer = layer

        ops = self.gfx_arrays.get(dl_name)
        if ops is None:
            self.unknown_dls.add(dl_name)
            self.current_layer = prev_layer
            return

        for op, args in ops:
            if op == "gsSPVertex":
                # gsSPVertex(arr, count, dest)
                if len(args) >= 3:
                    arr_name = args[0].strip()
                    # Strip a leading & if present.
                    if arr_name.startswith("&"):
                        arr_name = arr_name[1:]
                    try:
                        count = int(args[1])
                        dest = int(args[2])
                    except ValueError:
                        continue
                    self.load_vertices(arr_name, count, dest)
            elif op == "gsSP1Triangle":
                if len(args) >= 3:
                    try:
                        a, b, c = int(args[0]), int(args[1]), int(args[2])
                    except ValueError:
                        continue
                    self.emit_tri(a, b, c)
            elif op == "gsSP2Triangles":
                # gsSP2Triangles(a0,b0,c0,f0, a1,b1,c1,f1)
                if len(args) >= 8:
                    try:
                        a0, b0, c0 = int(args[0]), int(args[1]), int(args[2])
                        a1, b1, c1 = int(args[4]), int(args[5]), int(args[6])
                    except ValueError:
                        continue
                    self.emit_tri(a0, b0, c0)
                    self.emit_tri(a1, b1, c1)
            elif op == "gsDPSetTextureImage":
                # gsDPSetTextureImage(fmt, size, width, ptr)
                if len(args) >= 4:
                    self.current_texture = args[3].strip()
            elif op == "gsSPDisplayList" or op == "gsSPBranchList":
                if args:
                    sub = args[0].strip()
                    if sub.startswith("&"):
                        sub = sub[1:]
                    self.walk(sub, "", _depth + 1)
            elif op == "gsSPEndDisplayList":
                break
            # All other opcodes (render mode, combine mode, tile setup, light,
            # geometry mode toggles, fog, etc.) affect rendering state we don't
            # model. Ignored intentionally.

        self.current_layer = prev_layer


# ---------------- main ----------------

def _load_model_file(model_path: Path) -> tuple[dict, dict]:
    text = model_path.read_text()
    text_nc = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return parse_vtx_arrays(text_nc), parse_gfx_arrays(text_nc)


def convert(
    model_paths: list[Path],
    geo_path: Path | None,
    entry_overrides: list[tuple[str, str]] | None,
) -> dict:
    vtx_arrays: dict[str, list[VtxEntry]] = {}
    gfx_arrays: dict[str, list[tuple[str, list[str]]]] = {}
    for mp in model_paths:
        vs, gs = _load_model_file(mp)
        # Detect symbol collisions — a real problem would indicate we're
        # mixing incompatible files.
        for name in vs:
            if name in vtx_arrays:
                print(f"warning: duplicate Vtx symbol {name} across model files", file=sys.stderr)
        for name in gs:
            if name in gfx_arrays:
                print(f"warning: duplicate Gfx symbol {name} across model files", file=sys.stderr)
        vtx_arrays.update(vs)
        gfx_arrays.update(gs)

    entries: list[tuple[str, str]]
    if entry_overrides:
        entries = entry_overrides
    else:
        entries = discover_entry_dls(geo_path)

    walker = Walker(vtx_arrays, gfx_arrays)
    for layer, dl in entries:
        # Only walk DLs that live in this model file.
        if dl in gfx_arrays:
            walker.walk(dl, layer)

    sub_meshes_out: list[dict] = []
    for (tex, layer), sm in walker.sub_meshes.items():
        sub_meshes_out.append(
            {
                "key": f"{tex}|{layer}",
                "texture": tex,
                "layer": layer,
                "positions": sm.positions,
                "normals": sm.normals,
                "uvs": sm.uvs,
                "colors": sm.colors,
                "indices": sm.indices,
            }
        )

    return {
        "sources": [str(p) for p in model_paths],
        "geo_source": str(geo_path) if geo_path else None,
        "entry_display_lists": [f"{layer} {dl}" for layer, dl in entries],
        "vtx_arrays": len(vtx_arrays),
        "gfx_arrays": len(gfx_arrays),
        "triangles_emitted": walker.triangles_emitted,
        "unknown_display_lists": sorted(walker.unknown_dls),
        "sub_meshes": sub_meshes_out,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "input",
        type=Path,
        help="either a model.inc.c file OR a level area directory "
        "(e.g. levels/bob/areas/1) to auto-discover all model.inc.c files + geo.inc.c",
    )
    ap.add_argument("output", type=Path, help="path to write JSON")
    ap.add_argument(
        "--geo",
        type=Path,
        default=None,
        help="path to geo.inc.c (overrides auto-discovery)",
    )
    ap.add_argument(
        "--entry-dl",
        action="append",
        default=[],
        metavar="LAYER:SYMBOL",
        help="override: manually specify entry DLs (repeatable)",
    )
    args = ap.parse_args()

    if args.input.is_dir():
        model_paths = sorted(args.input.glob("*/model.inc.c"))
        if not model_paths:
            # Some levels have model.inc.c right in the area dir, not subdirs.
            direct = args.input / "model.inc.c"
            if direct.exists():
                model_paths = [direct]
        if not model_paths:
            print(f"no model.inc.c files found under {args.input}", file=sys.stderr)
            return 1
        geo_path = args.geo or (args.input / "geo.inc.c")
    else:
        model_paths = [args.input]
        # Common layout: areas/<n>/<sub>/model.inc.c -> ../geo.inc.c
        geo_path = args.geo or (args.input.parent.parent / "geo.inc.c")
        if not geo_path.exists():
            geo_path = None

    if geo_path and not geo_path.exists():
        geo_path = None

    entry_overrides = None
    if args.entry_dl:
        entry_overrides = []
        for spec in args.entry_dl:
            if ":" not in spec:
                print(f"bad --entry-dl {spec}; expected LAYER:SYMBOL", file=sys.stderr)
                return 1
            layer, sym = spec.split(":", 1)
            entry_overrides.append((layer.strip(), sym.strip()))

    result = convert(model_paths, geo_path, entry_overrides)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(
        f"wrote {args.output}: "
        f"{result['triangles_emitted']} tris in {len(result['sub_meshes'])} sub-meshes "
        f"(from {result['vtx_arrays']} Vtx arrays, {result['gfx_arrays']} Gfx arrays)"
    )
    if result["unknown_display_lists"]:
        print(f"  unknown DLs (not in this file): {result['unknown_display_lists']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
