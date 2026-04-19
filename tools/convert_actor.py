#!/usr/bin/env python3
"""Convert an SM64 decomp actor (geo.inc.c + model.inc.c) to a merged T-pose mesh JSON.

Unlike level geometry, actor meshes live inside a skeletal graph expressed as
a `GeoLayout` — a tree of commands (`GEO_OPEN_NODE` / `GEO_CLOSE_NODE`) that
push transforms and draw display lists at each bone. Animations at runtime
replace some of those transforms.

This tool walks one entry-point GeoLayout, applies the REST-POSE transforms
(translations from `GEO_ANIMATED_PART`, rest rotations from
`GEO_TRANSLATE_ROTATE`), resolves all referenced display lists, and emits a
merged mesh whose vertices are already transformed into actor-local space.
It's a T-pose Mario in a single mesh — no skeleton, no animation. Good
enough to replace a capsule placeholder.

Output schema matches the level converter's model.json so the Godot loader
doesn't need to know the difference:
{
  "source":  "<geo.inc.c path>",
  "model_source": "<model.inc.c path>",
  "entry":   "<entry geo layout symbol>",
  "sub_meshes": [ ...same schema as convert_model.py... ]
}

Supported GeoLayout commands (others are ignored — a comment is printed if
they could affect geometry):
  GEO_OPEN_NODE / GEO_CLOSE_NODE               push/pop transform stack
  GEO_TRANSLATE_ROTATE(l, tx, ty, tz, rx, ry, rz)
  GEO_TRANSLATE(l, tx, ty, tz)
  GEO_TRANSLATE_ROTATE_WITH_DL(..., dl)        translate+rotate and draw dl
  GEO_TRANSLATE_WITH_DL(l, tx, ty, tz, dl)
  GEO_ROTATION_NODE(l, rx, ry, rz)             rotate (rest pose: usually 0)
  GEO_ROTATION_NODE_WITH_DL(l, rx, ry, rz, dl)
  GEO_ANIMATED_PART(l, x, y, z, dl)            bone rest translation + dl
  GEO_DISPLAY_LIST(l, dl)                      draw dl at current transform
  GEO_SCALE(l, s)                              uniform scale (s / 65536)
  GEO_SCALE_WITH_DL(l, s, dl)
  GEO_BRANCH(link, other_layout)               dive into another layout
  GEO_RETURN                                   end of current layout
  GEO_SWITCH_CASE(n, func)                     take case 0 (rest)

Rotation angles are s16 where 65536 = 360°.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

# Reuse Vtx / Gfx parsing machinery from convert_model.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_model import (  # type: ignore[import-not-found]
    parse_vtx_arrays,
    parse_gfx_arrays,
    split_args,
    VtxEntry,
)


# Matches a Lights1 light-group declaration:
#   static const Lights1 NAME = gdSPDefLights1(
#       0x7f, 0x60, 0x3c,                 // ambient RGB
#       0xfe, 0xc1, 0x79, 0x28, 0x28, 0x28 // diffuse RGB + light direction
#   );
LIGHTS1_RE = re.compile(
    r"(?:static\s+)?const\s+Lights1\s+(\w+)\s*=\s*gdSPDefLights1\s*\(\s*"
    r"(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*"
    r"(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)\s*,\s*(0x[0-9a-fA-F]+)",
    re.DOTALL,
)


def parse_light_groups(text: str) -> dict[str, tuple[float, float, float]]:
    out: dict[str, tuple[float, float, float]] = {}
    for m in LIGHTS1_RE.finditer(text):
        name = m.group(1)
        # Use the diffuse RGB (fully-lit color) — this is what the N64's
        # shade produces when the surface is facing the light head-on.
        r = int(m.group(5), 16) / 255.0
        g = int(m.group(6), 16) / 255.0
        b = int(m.group(7), 16) / 255.0
        out[name] = (r, g, b)
    return out


def _is_shade_only_combine(mode: str) -> bool:
    """A rough classifier for N64 G_CC_* combine modes: returns True for
    modes that don't sample the bound texture (shade/vertex-color only).
    Full truth would require interpreting the combiner inputs, but the mode
    name prefix is a reliable proxy for stock decomp usage."""
    m = mode.strip()
    if not m.startswith("G_CC_"):
        return False
    # Any mode whose name starts with SHADE and does NOT involve a texture
    # operation is shade-only.
    suffix = m[len("G_CC_"):]
    for texture_tag in ("DECAL", "MODULATE", "BLEND", "TEXEL"):
        if texture_tag in suffix:
            return False
    return suffix.startswith("SHADE")


GEO_ARRAY_RE = re.compile(
    r"(?:static\s+)?const\s+GeoLayout\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)
COMMAND_RE = re.compile(r"(GEO_[A-Z0-9_]+)\s*(?:\(([^()]*(?:\([^()]*\)[^()]*)*)\))?")

# ---- transform primitives --------------------------------------------------

def identity() -> list[list[float]]:
    return [[1.0, 0, 0, 0], [0, 1.0, 0, 0], [0, 0, 1.0, 0], [0, 0, 0, 1.0]]


def mat_mul(a: list[list[float]], b: list[list[float]]) -> list[list[float]]:
    return [
        [
            a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
            for j in range(4)
        ]
        for i in range(4)
    ]


def translate(tx: float, ty: float, tz: float) -> list[list[float]]:
    m = identity()
    m[0][3] = tx
    m[1][3] = ty
    m[2][3] = tz
    return m


def rotate_xyz(rx_s16: int, ry_s16: int, rz_s16: int) -> list[list[float]]:
    """Rotate around X, Y, Z axes in sequence. Angles are s16 (65536 = 360°).
    Applied in the same order SM64 uses: R = Rz * Ry * Rx (body-frame X first)."""
    def a(s: int) -> float:
        return s * (math.tau / 65536.0)
    ax, ay, az = a(rx_s16), a(ry_s16), a(rz_s16)
    cx, sx = math.cos(ax), math.sin(ax)
    cy, sy = math.cos(ay), math.sin(ay)
    cz, sz = math.cos(az), math.sin(az)
    rx = [[1, 0, 0, 0], [0, cx, -sx, 0], [0, sx, cx, 0], [0, 0, 0, 1]]
    ry = [[cy, 0, sy, 0], [0, 1, 0, 0], [-sy, 0, cy, 0], [0, 0, 0, 1]]
    rz = [[cz, -sz, 0, 0], [sz, cz, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
    return mat_mul(rz, mat_mul(ry, rx))


def scale_uniform(s: float) -> list[list[float]]:
    m = identity()
    m[0][0] = s
    m[1][1] = s
    m[2][2] = s
    return m


def transform_point(m: list[list[float]], p: tuple[int, int, int]) -> tuple[float, float, float]:
    x, y, z = float(p[0]), float(p[1]), float(p[2])
    return (
        m[0][0] * x + m[0][1] * y + m[0][2] * z + m[0][3],
        m[1][0] * x + m[1][1] * y + m[1][2] * z + m[1][3],
        m[2][0] * x + m[2][1] * y + m[2][2] * z + m[2][3],
    )


def transform_normal(m: list[list[float]], n: tuple[float, float, float]) -> tuple[float, float, float]:
    x, y, z = n
    out = (
        m[0][0] * x + m[0][1] * y + m[0][2] * z,
        m[1][0] * x + m[1][1] * y + m[1][2] * z,
        m[2][0] * x + m[2][1] * y + m[2][2] * z,
    )
    length = math.sqrt(sum(v * v for v in out))
    if length > 1e-6:
        return (out[0] / length, out[1] / length, out[2] / length)
    return out


# ---- geo parsing -----------------------------------------------------------

def parse_geo_layouts(text: str) -> dict[str, list[tuple[str, list[str]]]]:
    out: dict[str, list[tuple[str, list[str]]]] = {}
    for name, body in GEO_ARRAY_RE.findall(text):
        cmds: list[tuple[str, list[str]]] = []
        for m in COMMAND_RE.finditer(body):
            cmd = m.group(1)
            args = split_args(m.group(2) or "") if m.group(2) is not None else []
            cmds.append((cmd, args))
        out[name] = cmds
    return out


def parse_int(s: str) -> int:
    s = s.strip()
    if s.startswith("&"):
        s = s[1:]
    return int(s, 16) if s.lower().startswith("0x") else int(s)


# ---- display-list walker (collects triangles in a given pose) --------------

@dataclass
class SubMeshBuilder:
    texture: str
    layer: str
    light_group: str = ""
    positions: list[list[float]] = field(default_factory=list)
    normals: list[list[float]] = field(default_factory=list)
    uvs: list[list[int]] = field(default_factory=list)
    colors: list[list[float]] = field(default_factory=list)
    indices: list[int] = field(default_factory=list)
    # Dedup on (rounded_pos, uv, rgba) so merged bone meshes don't blow up.
    _dedup: dict[tuple, int] = field(default_factory=dict)

    def emit(self, pos: tuple[float, float, float], v: VtxEntry,
             normal: tuple[float, float, float]) -> int:
        key = ((round(pos[0], 3), round(pos[1], 3), round(pos[2], 3)), v.uv, v.rgba)
        if key in self._dedup:
            return self._dedup[key]
        idx = len(self.positions)
        self.positions.append([pos[0], pos[1], pos[2]])
        self.normals.append([normal[0], normal[1], normal[2]])
        self.uvs.append(list(v.uv))
        self.colors.append(list(v.color))
        self._dedup[key] = idx
        return idx


class PosedDLWalker:
    def __init__(
        self,
        vtx_arrays: dict[str, list[VtxEntry]],
        gfx_arrays: dict[str, list[tuple[str, list[str]]]],
        light_groups: dict[str, tuple[float, float, float]] | None = None,
    ) -> None:
        self.vtx_arrays = vtx_arrays
        self.gfx_arrays = gfx_arrays
        self.light_groups = light_groups or {}
        self.sub_meshes: dict[tuple[str, str, str], SubMeshBuilder] = {}
        self.current_texture = "none"
        self.current_light_group = ""  # empty = unknown
        self.vtx_cache: list[tuple[VtxEntry, tuple[float, float, float], tuple[float, float, float]] | None] = [None] * 32
        self.unknown_dls: set[str] = set()
        self.triangles_emitted = 0

    def submesh(self, layer: str) -> SubMeshBuilder:
        # Light group keys a sub-mesh because Mario's untextured body parts
        # use different `gsSPLight` groups (blue overalls, red shirt/cap,
        # beige skin, white gloves, brown shoes, brown hair). Without
        # splitting by light group, they all collapse into one gray blob.
        key = (self.current_texture, layer, self.current_light_group)
        sm = self.sub_meshes.get(key)
        if sm is None:
            sm = SubMeshBuilder(
                texture=self.current_texture,
                layer=layer,
                light_group=self.current_light_group,
            )
            self.sub_meshes[key] = sm
        return sm

    def walk_dl(self, dl_name: str, transform: list[list[float]], layer: str,
                _depth: int = 0) -> None:
        if _depth > 32:
            return
        ops = self.gfx_arrays.get(dl_name)
        if ops is None:
            self.unknown_dls.add(dl_name)
            return
        for op, args in ops:
            if op == "gsSPVertex" and len(args) >= 3:
                arr_name = args[0].strip()
                if arr_name.startswith("&"):
                    arr_name = arr_name[1:]
                arr = self.vtx_arrays.get(arr_name)
                if arr is None:
                    continue
                try:
                    count = int(args[1])
                    dest = int(args[2])
                except ValueError:
                    continue
                for i in range(count):
                    if dest + i >= len(self.vtx_cache) or i >= len(arr):
                        break
                    v = arr[i]
                    pos = transform_point(transform, v.pos)
                    nrm = transform_normal(transform, v.normal)
                    self.vtx_cache[dest + i] = (v, pos, nrm)
            elif op == "gsSP1Triangle" and len(args) >= 3:
                self._emit_tri(int(args[0]), int(args[1]), int(args[2]), layer)
            elif op == "gsSP2Triangles" and len(args) >= 8:
                self._emit_tri(int(args[0]), int(args[1]), int(args[2]), layer)
                self._emit_tri(int(args[4]), int(args[5]), int(args[6]), layer)
            elif op == "gsDPSetTextureImage" and len(args) >= 4:
                self.current_texture = args[3].strip()
            elif op == "gsDPSetCombineMode" and args:
                # Track N64 combiner mode changes. When the mode is shade-only
                # (no texture sampling), subsequent triangles in this DL are
                # using only vertex/light color — they should go into the
                # "none" sub-mesh, not the previously-bound texture.
                mode = args[0].strip()
                if _is_shade_only_combine(mode):
                    self.current_texture = "none"
            elif op == "gsSPLight" and args:
                # gsSPLight(&xxx_lights_group.l, 1) binds the main light.
                # Extract the base symbol (strip "&" and ".l" or ".a"). The
                # ".l" call provides the diffuse color we care about; we
                # ignore .a (ambient).
                ref = args[0].strip()
                if ref.startswith("&"):
                    ref = ref[1:]
                if ref.endswith(".l"):
                    self.current_light_group = ref[:-2]
            elif op in ("gsSPDisplayList", "gsSPBranchList") and args:
                sub = args[0].strip()
                if sub.startswith("&"):
                    sub = sub[1:]
                self.walk_dl(sub, transform, layer, _depth + 1)
            elif op == "gsSPEndDisplayList":
                break

    def _emit_tri(self, a: int, b: int, c: int, layer: str) -> None:
        va, vb, vc = self.vtx_cache[a], self.vtx_cache[b], self.vtx_cache[c]
        if va is None or vb is None or vc is None:
            return
        sm = self.submesh(layer)
        sm.indices.extend([
            sm.emit(va[1], va[0], va[2]),
            sm.emit(vb[1], vb[0], vb[2]),
            sm.emit(vc[1], vc[0], vc[2]),
        ])
        self.triangles_emitted += 1


# ---- geo walker ------------------------------------------------------------

class GeoWalker:
    def __init__(
        self,
        geo_layouts: dict[str, list[tuple[str, list[str]]]],
        dl_walker: PosedDLWalker,
    ) -> None:
        self.layouts = geo_layouts
        self.dl = dl_walker
        self.missing_layouts: set[str] = set()
        self.ignored_cmds: dict[str, int] = {}

    def walk(self, entry: str, initial: list[list[float]] | None = None) -> None:
        # Outer frame owns the initial transform; the top-level block doesn't
        # live inside an OPEN_NODE so we pass `take_first_only=False` and don't
        # expect a CLOSE_NODE.
        t0 = initial if initial is not None else identity()
        stack = [t0]
        self._walk_siblings(self.layouts.get(entry, []), stack, 0,
                            take_first_only=False, expect_close=False)

    def _walk_siblings(
        self,
        cmds: list[tuple[str, list[str]]],
        stack: list[list[float]],
        idx: int,
        take_first_only: bool,
        expect_close: bool,
    ) -> int:
        """Walk siblings in a block. If `take_first_only` (switch semantics),
        execute just the first sibling and skip the rest to CLOSE_NODE. If
        `expect_close`, consume the matching GEO_CLOSE_NODE before returning.
        Pops one frame off `stack` if expect_close is True."""
        first_done = False
        while idx < len(cmds):
            op, _ = cmds[idx]
            if op == "GEO_CLOSE_NODE":
                if expect_close:
                    stack.pop()
                    return idx + 1
                return idx
            if op in ("GEO_RETURN", "GEO_END"):
                return idx + 1
            if take_first_only and first_done:
                # Skip remaining siblings (each potentially a node + its
                # OPEN_NODE block) until the matching CLOSE_NODE.
                depth = 0
                while idx < len(cmds):
                    op2 = cmds[idx][0]
                    if op2 == "GEO_OPEN_NODE":
                        depth += 1
                    elif op2 == "GEO_CLOSE_NODE":
                        if depth == 0:
                            if expect_close:
                                stack.pop()
                                return idx + 1
                            return idx
                        depth -= 1
                    idx += 1
                return idx
            idx = self._walk_one_sibling(cmds, stack, idx)
            first_done = True
        if expect_close:
            stack.pop()
        return idx

    def _walk_one_sibling(
        self,
        cmds: list[tuple[str, list[str]]],
        stack: list[list[float]],
        idx: int,
    ) -> int:
        """Walk one sibling: a node command plus its optional child block.
        Returns idx positioned at the next sibling (or CLOSE_NODE).

        Crucial invariant: the transform the node applies (e.g. the rest-pose
        offset of an ANIMATED_PART) must live inside this sibling's SUBTREE
        only. Subsequent siblings at the same level see the unmodified parent
        frame. We enforce that by snapshotting stack[-1] before executing the
        node and restoring it afterward."""
        if idx >= len(cmds):
            return idx
        op, args = cmds[idx]
        if op == "GEO_OPEN_NODE":
            # Block is itself the sibling. Push + walk children (normal).
            stack.append([row[:] for row in stack[-1]])
            return self._walk_siblings(cmds, stack, idx + 1,
                                       take_first_only=False, expect_close=True)

        saved_frame = [row[:] for row in stack[-1]]
        self._execute_node(op, args, stack)
        node_op = op
        idx += 1
        # If followed by a child block, descend. Children see the transformed
        # frame as their parent (current stack[-1]). Switch cases take only
        # the first sibling.
        if idx < len(cmds) and cmds[idx][0] == "GEO_OPEN_NODE":
            stack.append([row[:] for row in stack[-1]])
            is_switch = (node_op == "GEO_SWITCH_CASE")
            idx = self._walk_siblings(cmds, stack, idx + 1,
                                      take_first_only=is_switch,
                                      expect_close=True)
        # Restore the parent frame for the NEXT sibling in this block.
        stack[-1] = saved_frame
        return idx

    def _execute_node(
        self,
        op: str,
        args: list[str],
        stack: list[list[float]],
    ) -> None:
        """Apply a single geo command's side effects to the current transform
        frame (stack[-1]) and draw any display list it embeds."""
        layer = self._arg_layer(args)

        if op == "GEO_TRANSLATE_ROTATE" and len(args) >= 7:
            t = translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3]))
            r = rotate_xyz(parse_int(args[4]), parse_int(args[5]), parse_int(args[6]))
            stack[-1] = mat_mul(stack[-1], mat_mul(t, r))
        elif op == "GEO_TRANSLATE_ROTATE_WITH_DL" and len(args) >= 8:
            t = translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3]))
            r = rotate_xyz(parse_int(args[4]), parse_int(args[5]), parse_int(args[6]))
            stack[-1] = mat_mul(stack[-1], mat_mul(t, r))
            self._draw(args[7], stack[-1], layer)
        elif op == "GEO_TRANSLATE" and len(args) >= 4:
            stack[-1] = mat_mul(stack[-1],
                                translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])))
        elif op == "GEO_TRANSLATE_WITH_DL" and len(args) >= 5:
            stack[-1] = mat_mul(stack[-1],
                                translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])))
            self._draw(args[4], stack[-1], layer)
        elif op == "GEO_ROTATION_NODE" and len(args) >= 4:
            stack[-1] = mat_mul(stack[-1],
                                rotate_xyz(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])))
        elif op == "GEO_ROTATION_NODE_WITH_DL" and len(args) >= 5:
            stack[-1] = mat_mul(stack[-1],
                                rotate_xyz(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])))
            self._draw(args[4], stack[-1], layer)
        elif op == "GEO_ANIMATED_PART" and len(args) >= 5:
            tx = parse_int(args[1])
            ty = parse_int(args[2])
            tz = parse_int(args[3])
            stack[-1] = mat_mul(stack[-1], translate(tx, ty, tz))
            # In the real game each GEO_ANIMATED_PART's rotation is supplied by
            # the current animation frame. Without that data we fall back on a
            # hand-curated table of rest-pose rotations for specific joints so
            # arms and legs hang in plausible T-pose directions.
            rot = self._rest_pose_rotation_for((tx, ty, tz))
            if rot is not None:
                stack[-1] = mat_mul(stack[-1], rotate_xyz(*rot))
            self._draw(args[4], stack[-1], layer)
        elif op == "GEO_DISPLAY_LIST" and len(args) >= 2:
            self._draw(args[1], stack[-1], layer)
        elif op == "GEO_SCALE" and len(args) >= 2:
            stack[-1] = mat_mul(stack[-1], scale_uniform(parse_int(args[1]) / 65536.0))
        elif op == "GEO_SCALE_WITH_DL" and len(args) >= 3:
            stack[-1] = mat_mul(stack[-1], scale_uniform(parse_int(args[1]) / 65536.0))
            self._draw(args[2], stack[-1], layer)
        elif op in ("GEO_BRANCH", "GEO_BRANCH_AND_LINK") and args:
            sub = args[-1]
            if sub.startswith("&"):
                sub = sub[1:]
            sub = sub.strip()
            sub_cmds = self.layouts.get(sub)
            if sub_cmds is not None:
                # Dive with a copy of the current transform as a fresh frame.
                sub_stack = [[row[:] for row in stack[-1]]]
                self._walk_siblings(sub_cmds, sub_stack, 0,
                                    take_first_only=False, expect_close=False)
            else:
                self.missing_layouts.add(sub)
        elif op == "GEO_SWITCH_CASE":
            # Handled specially in _walk_one_sibling: its child OPEN_NODE
            # uses take_first_only=True. Here, as a standalone node, it has
            # no side effects.
            pass
        else:
            self.ignored_cmds[op] = self.ignored_cmds.get(op, 0) + 1

    def _arg_layer(self, args: list[str]) -> str:
        if not args:
            return "LAYER_OPAQUE"
        a = args[0].strip()
        return a if a.startswith("LAYER_") else "LAYER_OPAQUE"

    # Per-bone rest-pose rotations keyed on the (tx, ty, tz) of the
    # GEO_ANIMATED_PART. Angles are s16 (65536 = 360°). Identified by the
    # decomp's canonical Mario body skeleton offsets.
    _REST_POSE_ROTATIONS: dict[tuple[int, int, int], tuple[int, int, int]] = {
        # Left shoulder: rotate +X (up) to +Z (left of torso) so arm hangs out
        # to Mario's left. Rotate -90° around Y: ry = -16384.
        (67, -10, 79): (0, -16384, 0),
        # Right shoulder: +X to -Z (Mario's right). Rotate +90° around Y.
        (68, -10, -79): (0, 16384, 0),
        # Left hip: +X (up) to -X (down) so the leg chain hangs beneath the
        # butt. Rotate 180° around Z. Keeps Y axis so the knee still bends
        # forward the right way later.
        (13, -8, 42): (0, 0, 32768),
        (13, -8, -42): (0, 0, 32768),
    }

    def _rest_pose_rotation_for(
        self, offset: tuple[int, int, int]
    ) -> tuple[int, int, int] | None:
        return self._REST_POSE_ROTATIONS.get(offset)

    def _draw(self, dl_name: str, transform: list[list[float]], layer: str) -> None:
        dl = dl_name.strip()
        if dl in ("NULL", "0", ""):
            return
        if dl.startswith("&"):
            dl = dl[1:]
        # Each DL invoked from the geo starts with a fresh texture context.
        # Within one DL, sub-DL calls (gsSPDisplayList) inherit state naturally.
        # Mario's limbs don't bind a texture — they expect vertex color rendering
        # via combine modes like G_CC_SHADEFADEA. We approximate that by simply
        # resetting current_texture at each top-level DL entry; any Mario DL that
        # really wants a texture rebinds it with gsDPSetTextureImage.
        self.dl.current_texture = "none"
        self.dl.walk_dl(dl, transform, layer)


# ---- main ------------------------------------------------------------------

def convert(geo_path: Path, model_path: Path, entry: str,
            also_walk: list[str] | None = None) -> dict:
    geo_text = re.sub(r"/\*.*?\*/", "", geo_path.read_text(), flags=re.DOTALL)
    model_text = re.sub(r"/\*.*?\*/", "", model_path.read_text(), flags=re.DOTALL)

    geo_layouts = parse_geo_layouts(geo_text)
    vtx_arrays = parse_vtx_arrays(model_text)
    gfx_arrays = parse_gfx_arrays(model_text)
    light_groups = parse_light_groups(model_text)

    dl_walker = PosedDLWalker(vtx_arrays, gfx_arrays, light_groups)
    geo_walker = GeoWalker(geo_layouts, dl_walker)

    entries = [entry] + list(also_walk or [])
    for e in entries:
        if e not in geo_layouts:
            raise ValueError(f"entry GeoLayout {e} not found in {geo_path}")
        geo_walker.walk(e)

    sub_meshes_out: list[dict] = []
    for (tex, layer, lg), sm in dl_walker.sub_meshes.items():
        shade = light_groups.get(lg) if lg else None
        sub_meshes_out.append({
            "key": f"{tex}|{layer}|{lg}",
            "texture": tex,
            "layer": layer,
            "light_group": lg,
            "shade_color": list(shade) if shade is not None else None,
            "positions": sm.positions,
            "normals": sm.normals,
            "uvs": sm.uvs,
            "colors": sm.colors,
            "indices": sm.indices,
        })

    return {
        "source": str(geo_path),
        "model_source": str(model_path),
        "entry": entry,
        "also_walk": also_walk or [],
        "triangles_emitted": dl_walker.triangles_emitted,
        "sub_meshes": sub_meshes_out,
        "missing_layouts": sorted(geo_walker.missing_layouts),
        "unknown_display_lists": sorted(dl_walker.unknown_dls),
        "ignored_geo_cmds": geo_walker.ignored_cmds,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("actor_dir", type=Path,
                    help="e.g. reference/sm64/actors/mario")
    ap.add_argument("output", type=Path)
    ap.add_argument(
        "--entry",
        default="mario_geo_body",
        help="top-level GeoLayout symbol to walk (default: mario_geo_body)",
    )
    ap.add_argument(
        "--also-walk",
        action="append",
        default=[],
        help="additional GeoLayout symbols to walk with identity transform "
        "(useful if the body branches are declared but not reached via "
        "the main entry, e.g. internal switch cases)",
    )
    args = ap.parse_args()

    geo = args.actor_dir / "geo.inc.c"
    model = args.actor_dir / "model.inc.c"
    if not geo.exists() or not model.exists():
        print(f"expected {geo} and {model}", file=sys.stderr)
        return 1

    result = convert(geo, model, args.entry, args.also_walk)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    print(f"wrote {args.output}: {result['triangles_emitted']} tris in "
          f"{len(result['sub_meshes'])} sub-meshes")
    if result["missing_layouts"]:
        print(f"  missing layouts: {result['missing_layouts']}")
    if result["unknown_display_lists"]:
        print(f"  unknown DLs: {result['unknown_display_lists'][:5]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
