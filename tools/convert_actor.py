#!/usr/bin/env python3
"""Convert an SM64 decomp actor (geo.inc.c + model.inc.c) to an articulated
skeleton JSON suitable for runtime animation.

Unlike `convert_model.py` (static level geometry), actor meshes live inside a
skeletal graph expressed as a `GeoLayout`. Each `GEO_ANIMATED_PART` node is a
"bone" that can be rotated by an animation at runtime; the decomp's animation
data provides per-frame rotation triplets for each bone in a specific
traversal order.

This tool walks the GeoLayout and emits a `bones` array keyed by that same
traversal order, plus per-bone mesh data (vertices in the bone's LOCAL frame,
i.e. before parent chains are applied). Non-animated transforms that live
inside a bone's subtree (`GEO_TRANSLATE_ROTATE`, `GEO_SCALE`, etc.) are baked
into the vertex positions so the runtime doesn't have to interpret them.

Rest rotations (the hand-curated table below) are attached per bone so the
rig looks like a T-pose when no animation plays. Animations' rotation deltas
replace these at runtime.

Output schema:
{
  "source":       "<geo.inc.c path>",
  "model_source": "<model.inc.c path>",
  "entry":        "<entry GeoLayout symbol>",
  "triangles_emitted": N,
  "bones": [
    {
      "index":         i,
      "parent":        parent_index or -1,
      "name":          "mario_butt" or "bone_3",
      "translation":   [tx, ty, tz],       # raw decomp units
      "rest_rotation": [rx, ry, rz],       # s16 angles (65536=360°)
      "sub_meshes":    [ ... same schema as convert_model.py's sub_meshes,
                         vertices in this bone's local frame ... ]
    },
    ...
  ]
}
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


GEO_ARRAY_RE = re.compile(
    r"(?:static\s+)?const\s+GeoLayout\s+(\w+)\s*\[\s*\]\s*=\s*\{(.*?)\};",
    re.DOTALL,
)
COMMAND_RE = re.compile(r"(GEO_[A-Z0-9_]+)\s*(?:\(([^()]*(?:\([^()]*\)[^()]*)*)\))?")

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
        r = int(m.group(5), 16) / 255.0
        g = int(m.group(6), 16) / 255.0
        b = int(m.group(7), 16) / 255.0
        out[name] = (r, g, b)
    return out


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


# ---- combine mode detection ------------------------------------------------

def _is_shade_only_combine(mode: str) -> bool:
    m = mode.strip()
    if not m.startswith("G_CC_"):
        return False
    suffix = m[len("G_CC_"):]
    for texture_tag in ("DECAL", "MODULATE", "BLEND", "TEXEL"):
        if texture_tag in suffix:
            return False
    return suffix.startswith("SHADE")


# ---- data model ------------------------------------------------------------

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
    _dedup: dict[tuple, int] = field(default_factory=dict)

    def emit_vertex(
        self,
        pos: tuple[float, float, float],
        uv: tuple[int, int],
        rgba: tuple[int, int, int, int],
        normal: tuple[float, float, float],
        color: tuple[float, float, float, float],
    ) -> int:
        key = ((round(pos[0], 3), round(pos[1], 3), round(pos[2], 3)), uv, rgba)
        if key in self._dedup:
            return self._dedup[key]
        idx = len(self.positions)
        self.positions.append([pos[0], pos[1], pos[2]])
        self.normals.append([normal[0], normal[1], normal[2]])
        self.uvs.append(list(uv))
        self.colors.append(list(color))
        self._dedup[key] = idx
        return idx


@dataclass
class Bone:
    parent: int
    name: str
    translation: tuple[int, int, int]
    rest_rotation: tuple[int, int, int]
    sub_meshes: dict[tuple[str, str, str], SubMeshBuilder] = field(default_factory=dict)


# ---- articulated walker ---------------------------------------------------

class ArticulatedWalker:
    """Walks a GeoLayout tree and produces a bone list. Within each bone,
    non-animated transforms (GEO_TRANSLATE_ROTATE, GEO_SCALE, …) are baked
    into the vertex positions so the runtime skeleton only needs to apply
    per-bone rotations. Each GEO_ANIMATED_PART creates a new bone whose rest
    translation/rotation can be overridden by an animation track."""

    # Per-bone rest-pose rotations keyed on the (tx, ty, tz) of the
    # GEO_ANIMATED_PART. Without animation data these make arms and legs
    # hang in a believable T-pose instead of all extending "up" in +X.
    _REST_POSE_ROTATIONS: dict[tuple[int, int, int], tuple[int, int, int]] = {
        (67, -10, 79):  (0, -16384, 0),  # left shoulder: +X → +Z (arm left)
        (68, -10, -79): (0, 16384, 0),   # right shoulder: +X → -Z (arm right)
        (13, -8, 42):   (0, 0, 32768),   # left hip: +X → -X (leg down)
        (13, -8, -42):  (0, 0, 32768),   # right hip
    }

    def __init__(
        self,
        geo_layouts: dict[str, list[tuple[str, list[str]]]],
        vtx_arrays: dict[str, list[VtxEntry]],
        gfx_arrays: dict[str, list[tuple[str, list[str]]]],
        light_groups: dict[str, tuple[float, float, float]],
    ) -> None:
        self.layouts = geo_layouts
        self.vtx_arrays = vtx_arrays
        self.gfx_arrays = gfx_arrays
        self.light_groups = light_groups

        # Per-bone state (current bone for DL emission, its ancestry chain).
        self.bones: list[Bone] = []
        self._current_bone: int = -1  # no bone yet; set to root on first ANIMATED_PART
        # Stack of (bone_index, local_transform_stack) saved when we enter
        # a child bone, restored on exit.
        self._bone_stack: list[tuple[int, list[list[list[float]]]]] = []
        # Local-transform stack INSIDE the current bone — resets when we
        # enter a new bone. stack[-1] is the currently active frame.
        self._local_stack: list[list[list[float]]] = [identity()]

        # Current rendering state.
        self._current_texture = "none"
        self._current_light_group = ""
        self._vtx_cache: list[tuple[VtxEntry, tuple[float, float, float], tuple[float, float, float]] | None] = [None] * 32

        # Diagnostics.
        self.triangles_emitted = 0
        self.missing_layouts: set[str] = set()
        self.ignored_cmds: dict[str, int] = {}
        self.unknown_dls: set[str] = set()

    # -- bone management ----------------------------------------------------

    def _ensure_root_bone(self) -> None:
        # Lazily create a synthetic root bone only when triangles need to be
        # emitted and no GEO_ANIMATED_PART has been seen yet. Static actors
        # (star, coin, 1up) have no ANIMATED_PART so without this their
        # geometry would land on bone index -1 and crash. For actors with
        # real animated skeletons (Mario, goomba, etc.) the first
        # ANIMATED_PART runs before any draws, so this is a no-op.
        if not self.bones:
            self.bones.append(
                Bone(parent=-1, name="root",
                     translation=(0, 0, 0), rest_rotation=(0, 0, 0))
            )
            self._current_bone = 0

    def _begin_bone(
        self,
        translation: tuple[int, int, int],
        rest_rotation: tuple[int, int, int],
        name: str,
    ) -> int:
        parent = self._current_bone  # -1 for the first bone
        idx = len(self.bones)
        self.bones.append(
            Bone(parent=parent, name=name, translation=translation, rest_rotation=rest_rotation)
        )
        self._bone_stack.append((self._current_bone, self._local_stack))
        self._current_bone = idx
        self._local_stack = [identity()]
        return idx

    def _end_bone(self) -> None:
        assert self._bone_stack, "pop with no push"
        self._current_bone, self._local_stack = self._bone_stack.pop()

    # -- DL walker (draws into current bone) --------------------------------

    def _current_submesh(self, layer: str) -> SubMeshBuilder:
        self._ensure_root_bone()
        bone = self.bones[self._current_bone]
        key = (self._current_texture, layer, self._current_light_group)
        sm = bone.sub_meshes.get(key)
        if sm is None:
            sm = SubMeshBuilder(
                texture=self._current_texture,
                layer=layer,
                light_group=self._current_light_group,
            )
            bone.sub_meshes[key] = sm
        return sm

    def _emit_tri(self, a: int, b: int, c: int, layer: str) -> None:
        va, vb, vc = self._vtx_cache[a], self._vtx_cache[b], self._vtx_cache[c]
        if va is None or vb is None or vc is None:
            return
        sm = self._current_submesh(layer)
        sm.indices.extend([
            sm.emit_vertex(va[1], va[0].uv, va[0].rgba, va[2], va[0].color),
            sm.emit_vertex(vb[1], vb[0].uv, vb[0].rgba, vb[2], vb[0].color),
            sm.emit_vertex(vc[1], vc[0].uv, vc[0].rgba, vc[2], vc[0].color),
        ])
        self.triangles_emitted += 1

    def _walk_dl(self, dl_name: str, layer: str, _depth: int = 0) -> None:
        if _depth > 32:
            return
        ops = self.gfx_arrays.get(dl_name)
        if ops is None:
            self.unknown_dls.add(dl_name)
            return
        transform = self._local_stack[-1]
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
                    if dest + i >= len(self._vtx_cache) or i >= len(arr):
                        break
                    v = arr[i]
                    pos = transform_point(transform, v.pos)
                    nrm = transform_normal(transform, v.normal)
                    self._vtx_cache[dest + i] = (v, pos, nrm)
            elif op == "gsSP1Triangle" and len(args) >= 3:
                self._emit_tri(int(args[0]), int(args[1]), int(args[2]), layer)
            elif op == "gsSP2Triangles" and len(args) >= 8:
                self._emit_tri(int(args[0]), int(args[1]), int(args[2]), layer)
                self._emit_tri(int(args[4]), int(args[5]), int(args[6]), layer)
            elif op == "gsDPSetTextureImage" and len(args) >= 4:
                self._current_texture = args[3].strip()
            elif op == "gsDPSetCombineMode" and args:
                mode = args[0].strip()
                if _is_shade_only_combine(mode):
                    self._current_texture = "none"
            elif op == "gsSPLight" and args:
                ref = args[0].strip()
                if ref.startswith("&"):
                    ref = ref[1:]
                if ref.endswith(".l"):
                    self._current_light_group = ref[:-2]
            elif op in ("gsSPDisplayList", "gsSPBranchList") and args:
                sub = args[0].strip()
                if sub.startswith("&"):
                    sub = sub[1:]
                self._walk_dl(sub, layer, _depth + 1)
            elif op == "gsSPEndDisplayList":
                break

    # -- geo walker ---------------------------------------------------------

    def walk(self, entry: str) -> None:
        # Don't pre-create a root bone here. _ensure_root_bone is called
        # lazily when triangles actually need to be emitted, so actors
        # whose first geo command is GEO_ANIMATED_PART (Mario, goomba, …)
        # aren't shifted by a phantom root bone.
        self._walk_siblings(self.layouts.get(entry, []), 0,
                            take_first_only=False, expect_close=False)

    def _walk_siblings(
        self,
        cmds: list[tuple[str, list[str]]],
        idx: int,
        take_first_only: bool,
        expect_close: bool,
    ) -> int:
        first_done = False
        while idx < len(cmds):
            op = cmds[idx][0]
            if op == "GEO_CLOSE_NODE":
                if expect_close:
                    return idx + 1
                return idx
            if op in ("GEO_RETURN", "GEO_END"):
                return idx + 1
            if take_first_only and first_done:
                depth = 0
                while idx < len(cmds):
                    op2 = cmds[idx][0]
                    if op2 == "GEO_OPEN_NODE":
                        depth += 1
                    elif op2 == "GEO_CLOSE_NODE":
                        if depth == 0:
                            if expect_close:
                                return idx + 1
                            return idx
                        depth -= 1
                    idx += 1
                return idx
            idx = self._walk_one_sibling(cmds, idx)
            first_done = True
        return idx

    def _walk_one_sibling(self, cmds: list[tuple[str, list[str]]], idx: int) -> int:
        """One sibling: a node command + optional OPEN_NODE children block.

        The current local_stack top is saved so non-animated transforms the
        node applies (e.g. GEO_TRANSLATE_ROTATE) affect this sibling's
        subtree only, not the parent's other children.

        GEO_ANIMATED_PART is special: it opens a new BONE, not just a new
        local frame, so we enter a fresh bone scope whose own local_stack
        resets to identity. The current_bone is restored on exit.
        """
        if idx >= len(cmds):
            return idx
        op, args = cmds[idx]
        if op == "GEO_OPEN_NODE":
            self._local_stack.append([row[:] for row in self._local_stack[-1]])
            idx = self._walk_siblings(cmds, idx + 1, False, True)
            self._local_stack.pop()
            return idx

        is_animated_part = (op == "GEO_ANIMATED_PART")
        saved_frame = [row[:] for row in self._local_stack[-1]]
        bone_entered = False

        if is_animated_part and len(args) >= 5:
            tx = parse_int(args[1])
            ty = parse_int(args[2])
            tz = parse_int(args[3])
            rest_rot = self._REST_POSE_ROTATIONS.get((tx, ty, tz), (0, 0, 0))
            dl = args[4].strip()
            if dl.startswith("&"):
                dl = dl[1:]
            name = dl if dl not in ("NULL", "0", "") else f"bone_{len(self.bones)}"
            # Enter a new bone. Its translation and rest rotation are the
            # rest-pose transform relative to parent; inside this bone the
            # local_stack begins at identity so non-animated transforms here
            # are expressed in the bone's own frame.
            self._begin_bone((tx, ty, tz), rest_rot, name)
            bone_entered = True
            # If the ANIMATED_PART carries a DL, draw it at the new bone's
            # identity local transform.
            if dl not in ("NULL", "0", ""):
                layer = self._arg_layer(args)
                self._walk_dl(dl, layer)
        else:
            self._execute_non_bone_node(op, args)

        idx += 1
        # If followed by an OPEN_NODE, descend into children.
        if idx < len(cmds) and cmds[idx][0] == "GEO_OPEN_NODE":
            self._local_stack.append([row[:] for row in self._local_stack[-1]])
            is_switch = (op == "GEO_SWITCH_CASE")
            idx = self._walk_siblings(cmds, idx + 1, is_switch, True)
            self._local_stack.pop()

        if bone_entered:
            self._end_bone()
        else:
            # Non-animated transforms restore to the parent's frame.
            self._local_stack[-1] = saved_frame
        return idx

    def _execute_non_bone_node(self, op: str, args: list[str]) -> None:
        layer = self._arg_layer(args)
        if op == "GEO_TRANSLATE_ROTATE" and len(args) >= 7:
            t = translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3]))
            r = rotate_xyz(parse_int(args[4]), parse_int(args[5]), parse_int(args[6]))
            self._local_stack[-1] = mat_mul(self._local_stack[-1], mat_mul(t, r))
        elif op == "GEO_TRANSLATE_ROTATE_WITH_DL" and len(args) >= 8:
            t = translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3]))
            r = rotate_xyz(parse_int(args[4]), parse_int(args[5]), parse_int(args[6]))
            self._local_stack[-1] = mat_mul(self._local_stack[-1], mat_mul(t, r))
            self._draw(args[7], layer)
        elif op == "GEO_TRANSLATE" and len(args) >= 4:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1],
                translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])),
            )
        elif op == "GEO_TRANSLATE_WITH_DL" and len(args) >= 5:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1],
                translate(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])),
            )
            self._draw(args[4], layer)
        elif op == "GEO_ROTATION_NODE" and len(args) >= 4:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1],
                rotate_xyz(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])),
            )
        elif op == "GEO_ROTATION_NODE_WITH_DL" and len(args) >= 5:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1],
                rotate_xyz(parse_int(args[1]), parse_int(args[2]), parse_int(args[3])),
            )
            self._draw(args[4], layer)
        elif op == "GEO_DISPLAY_LIST" and len(args) >= 2:
            self._draw(args[1], layer)
        elif op == "GEO_SCALE" and len(args) >= 2:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1], scale_uniform(parse_int(args[1]) / 65536.0)
            )
        elif op == "GEO_SCALE_WITH_DL" and len(args) >= 3:
            self._local_stack[-1] = mat_mul(
                self._local_stack[-1], scale_uniform(parse_int(args[1]) / 65536.0)
            )
            self._draw(args[2], layer)
        elif op in ("GEO_BRANCH", "GEO_BRANCH_AND_LINK") and args:
            sub = args[-1].strip()
            if sub.startswith("&"):
                sub = sub[1:]
            sub_cmds = self.layouts.get(sub)
            if sub_cmds is not None:
                # Dive into the other layout with our current bone scope
                # (new bones created inside continue to descend from current).
                self._walk_siblings(sub_cmds, 0, False, False)
            else:
                self.missing_layouts.add(sub)
        elif op == "GEO_SWITCH_CASE":
            pass  # handled by take_first_only in children
        else:
            self.ignored_cmds[op] = self.ignored_cmds.get(op, 0) + 1

    def _arg_layer(self, args: list[str]) -> str:
        if not args:
            return "LAYER_OPAQUE"
        a = args[0].strip()
        return a if a.startswith("LAYER_") else "LAYER_OPAQUE"

    def _draw(self, dl_name: str, layer: str) -> None:
        dl = dl_name.strip()
        if dl in ("NULL", "0", ""):
            return
        if dl.startswith("&"):
            dl = dl[1:]
        # Each DL invocation starts with a clean texture binding. Bodies
        # with no texture are drawn via shade-only combine modes.
        self._current_texture = "none"
        self._ensure_root_bone()
        self._walk_dl(dl, layer)


# ---- main ----------------------------------------------------------------

def convert(geo_path: Path, model_path: Path, entry: str) -> dict:
    geo_text = re.sub(r"/\*.*?\*/", "", geo_path.read_text(), flags=re.DOTALL)
    model_text = re.sub(r"/\*.*?\*/", "", model_path.read_text(), flags=re.DOTALL)

    geo_layouts = parse_geo_layouts(geo_text)
    vtx_arrays = parse_vtx_arrays(model_text)
    gfx_arrays = parse_gfx_arrays(model_text)
    light_groups = parse_light_groups(model_text)

    walker = ArticulatedWalker(geo_layouts, vtx_arrays, gfx_arrays, light_groups)
    if entry not in geo_layouts:
        raise ValueError(f"entry GeoLayout {entry} not found in {geo_path}")
    walker.walk(entry)

    bones_out: list[dict] = []
    for i, bone in enumerate(walker.bones):
        sub_meshes = []
        for (tex, layer, lg), sm in bone.sub_meshes.items():
            shade = light_groups.get(lg) if lg else None
            sub_meshes.append({
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
        bones_out.append({
            "index": i,
            "parent": bone.parent,
            "name": bone.name,
            "translation": list(bone.translation),
            "rest_rotation": list(bone.rest_rotation),
            "sub_meshes": sub_meshes,
        })

    return {
        "source": str(geo_path),
        "model_source": str(model_path),
        "entry": entry,
        "bone_count": len(walker.bones),
        "triangles_emitted": walker.triangles_emitted,
        "bones": bones_out,
        "missing_layouts": sorted(walker.missing_layouts),
        "unknown_display_lists": sorted(walker.unknown_dls),
        "ignored_geo_cmds": walker.ignored_cmds,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("actor_dir", type=Path)
    ap.add_argument("output", type=Path)
    ap.add_argument("--entry", default="mario_geo_body")
    args = ap.parse_args()

    geo = args.actor_dir / "geo.inc.c"
    model = args.actor_dir / "model.inc.c"
    if not geo.exists() or not model.exists():
        print(f"expected {geo} and {model}", file=sys.stderr)
        return 1

    result = convert(geo, model, args.entry)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2))
    bone_with_geom = sum(1 for b in result["bones"] if b["sub_meshes"])
    print(f"wrote {args.output}: {result['bone_count']} bones "
          f"({bone_with_geom} with geometry), {result['triangles_emitted']} tris")
    if result["missing_layouts"]:
        print(f"  missing layouts: {result['missing_layouts']}")
    if result["unknown_display_lists"]:
        print(f"  unknown DLs: {result['unknown_display_lists'][:3]}...")
    return 0


if __name__ == "__main__":
    sys.exit(main())
