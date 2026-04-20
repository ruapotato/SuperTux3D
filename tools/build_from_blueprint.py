#!/usr/bin/env python3
"""Blueprint → .tscn building converter.

The pain point with CSG-based level authoring: a wall with a cut-out
doorway is fragile. If the cut's Z-depth is shorter than the wall's
thickness, the doorway stays sealed. If the cut is offset wrong, you
get a hole in the wrong place. Agents authoring 3000-line scenes
routinely ship these bugs.

The fix: author buildings as **floorplans** — a JSON/YAML schema that
describes rooms, walls as SEGMENTS with gap-openings (no CSG), doors
as explicit mesh pairs (frame + floor patch), windows as top-and-
bottom wall segments framing an open slot.

This script reads a blueprint JSON and emits a .tscn with plain
MeshInstance3D + StaticBody3D pairs. No CSG. No alignment math that
can drift. If the blueprint says there's a door, the door is there —
the geometry is assembled piece-by-piece around it.

Schema (see bottom of file for examples):

    {
      "materials": {"brick": "res://assets/materials/brick_stone.tres"},
      "floor_height": 4.0,
      "wall_thickness": 0.3,
      "rooms": [
        {
          "name": "GrandHall",
          "origin": [0, 0, 0],
          "size": [12, 4, 16],
          "material": "brick",
          "floor_material": "stone_grey",
          "walls": {
            "north": {
              "openings": [
                {"type": "door", "x": 4.5, "width": 3, "height": 3}
              ]
            },
            "south": {
              "openings": [
                {"type": "window", "x": 2, "width": 1.5, "height": 1.5, "sill": 1.5},
                {"type": "window", "x": 8, "width": 1.5, "height": 1.5, "sill": 1.5}
              ]
            }
          }
        }
      ],
      "extras": [
        {"type": "pillar", "pos": [6, 0, 4], "radius": 0.4, "height": 4, "material": "stone_grey"}
      ]
    }

Walls are one-per-side (north/south/east/west). Openings split a wall
into pieces: floor-sill-piece, jamb-left, lintel-top, jamb-right.
These get glued back together as separate MeshInstance3D+StaticBody3D
pairs so the build is mechanically guaranteed to have the gap where
it's supposed to be.

Run: python3 tools/build_from_blueprint.py <blueprint.json> <out.tscn>
"""
from __future__ import annotations
import argparse
import json
import os
import sys

# -----------------------------------------------------------------------
# TSCN emitter — we build a dict of subresources (shape + mesh) and a
# list of top-level nodes, then format the whole thing as one text file.

class Scene:
    def __init__(self) -> None:
        self.ext_resources: list[tuple[str, str, str]] = []  # (path, type, id)
        self.sub_resources: list[tuple[str, str, str]] = []  # (id, type, body)
        self.nodes: list[tuple[str, str | None, str, str]] = []  # (name, parent, type, body)
        self._next_sub = 1
        self._root_name: str | None = None

    def ext_resource(self, path: str, type_: str) -> str:
        for p, t, i in self.ext_resources:
            if p == path and t == type_:
                return i
        new_id = f"e{len(self.ext_resources) + 1}_{os.path.basename(path).split('.')[0]}"
        self.ext_resources.append((path, type_, new_id))
        return new_id

    def sub(self, type_: str, body: str) -> str:
        sid = f"s{self._next_sub}"
        self._next_sub += 1
        self.sub_resources.append((sid, type_, body))
        return sid

    def node(self, name: str, parent: str | None, type_: str, body: str = "") -> None:
        if parent is None and self._root_name is None:
            self._root_name = name
        self.nodes.append((name, parent, type_, body))

    def _normalize_parent(self, parent: str | None) -> str | None:
        # Godot TSCN wants the scene root's children to declare
        # parent=".", not parent="<root_name>". Deeper nodes use paths
        # RELATIVE to the root — strip the root-name prefix.
        if parent is None or self._root_name is None:
            return parent
        root = self._root_name
        if parent == root:
            return "."
        if parent.startswith(root + "/"):
            return parent[len(root) + 1:]
        return parent

    def format(self) -> str:
        load_steps = 1 + len(self.ext_resources) + len(self.sub_resources)
        out = [f"[gd_scene load_steps={load_steps} format=3]\n"]
        for path, type_, rid in self.ext_resources:
            out.append(f'[ext_resource type="{type_}" path="{path}" id="{rid}"]\n')
        for sid, type_, body in self.sub_resources:
            out.append(f'[sub_resource type="{type_}" id="{sid}"]\n{body}\n')
        for name, parent, type_, body in self.nodes:
            normalized = self._normalize_parent(parent)
            if normalized is None:
                out.append(f'[node name="{name}" type="{type_}"]\n')
            else:
                out.append(f'[node name="{name}" type="{type_}" parent="{normalized}"]\n')
            if body:
                out.append(body)
                if not body.endswith("\n"):
                    out.append("\n")
        return "".join(out)


# -----------------------------------------------------------------------
# Helpers

def vec(x: float, y: float, z: float) -> str:
    return f"Vector3({x}, {y}, {z})"

def xform_translate(x: float, y: float, z: float) -> str:
    # Identity rotation + translation.
    return f"Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, {x}, {y}, {z})"

def _subtract_rect(rect: tuple[float, float, float, float],
                   hole: tuple[float, float, float, float]
                   ) -> list[tuple[float, float, float, float]]:
    """Return up to 4 non-overlapping rectangles that tile
    rect \\ hole. Each rect is (x0, z0, x1, z1). If no overlap,
    returns [rect] unchanged. Clips the hole to rect first."""
    rx0, rz0, rx1, rz1 = rect
    hx0, hz0, hx1, hz1 = hole
    # Clip hole to rect.
    cx0 = max(rx0, hx0); cx1 = min(rx1, hx1)
    cz0 = max(rz0, hz0); cz1 = min(rz1, hz1)
    if cx0 >= cx1 or cz0 >= cz1:
        return [rect]  # no overlap
    out: list[tuple[float, float, float, float]] = []
    # South slab (below the hole).
    if rz0 < cz0:
        out.append((rx0, rz0, rx1, cz0))
    # North slab (above the hole).
    if cz1 < rz1:
        out.append((rx0, cz1, rx1, rz1))
    # West slab (left of the hole, only within the hole's Z band).
    if rx0 < cx0:
        out.append((rx0, cz0, cx0, cz1))
    # East slab (right of the hole, only within the hole's Z band).
    if cx1 < rx1:
        out.append((cx1, cz0, rx1, cz1))
    return out


def _emit_slab_with_holes(scene: Scene, parent: str, prefix: str,
                          sx: float, sz: float,
                          y_center: float, y_thickness: float,
                          holes: list[dict],
                          mat_id: str | None) -> None:
    """Tile a floor/ceiling plate with N rectangular holes carved out.
    Start with one rectangle = the full plate; subtract each hole by
    splitting the rect into up to 4 pieces; repeat. Every surviving
    rectangle becomes its own box slab."""
    rects: list[tuple[float, float, float, float]] = [(0.0, 0.0, sx, sz)]
    for hole in holes:
        hx = float(hole["x"]); hz = float(hole["z"])
        hw = float(hole["width"]); hd = float(hole["depth"])
        hr = (hx, hz, hx + hw, hz + hd)
        next_rects: list[tuple[float, float, float, float]] = []
        for r in rects:
            next_rects.extend(_subtract_rect(r, hr))
        rects = next_rects
    for idx, (x0, z0, x1, z1) in enumerate(rects):
        w = x1 - x0
        d = z1 - z0
        if w <= 0.001 or d <= 0.001:
            continue
        cx = (x0 + x1) * 0.5
        cz = (z0 + z1) * 0.5
        emit_box(scene, parent, f"{prefix}_{idx}",
                 (cx, y_center, cz),
                 (w, y_thickness, d), mat_id)


def emit_box(scene: Scene, parent: str, name: str,
             pos: tuple[float, float, float],
             size: tuple[float, float, float],
             mat_id: str | None) -> None:
    """Emit a solid box at `pos` with `size`. Includes StaticBody3D +
    CollisionShape3D so the piece collides. Falls back to identity
    material if mat_id is None."""
    mesh_body = f"size = {vec(*size)}\n"
    mesh_id = scene.sub("BoxMesh", mesh_body)
    shape_body = f"size = {vec(*size)}\n"
    shape_id = scene.sub("BoxShape3D", shape_body)

    body_node_body = (
        f'transform = {xform_translate(*pos)}\n'
        f'collision_layer = 1\n'
        f'collision_mask = 1\n'
    )
    scene.node(name, parent, "StaticBody3D", body_node_body)

    mi_body = f'mesh = SubResource("{mesh_id}")\n'
    if mat_id is not None:
        mi_body += f'surface_material_override/0 = ExtResource("{mat_id}")\n'
    scene.node("Mesh", f"{parent}/{name}" if parent else name,
               "MeshInstance3D", mi_body)

    col_body = f'shape = SubResource("{shape_id}")\n'
    scene.node("Col", f"{parent}/{name}" if parent else name,
               "CollisionShape3D", col_body)


def emit_wall_with_openings(
    scene: Scene,
    parent: str,
    prefix: str,
    wall_origin: tuple[float, float, float],
    wall_size: tuple[float, float, float],  # (length, height, thickness)
    axis: str,                              # "x" or "z" — length axis in room-local
    openings: list[dict],
    mat_id: str | None,
) -> None:
    """Build ONE wall by splitting it into segments that frame each
    opening. Opening rules:
      - "door":   opens from floor up to `height`, from `x` to `x+width`
                  → left jamb, right jamb, lintel above
      - "window": opening from `sill` to `sill+height`, x range as door
                  → left jamb, right jamb, lintel above, sill below
    Wall segments outside the openings are full-height.

    The length axis is `axis`. If axis=="x", size[0] is length along X.
    The thickness is size[2] regardless of axis (we rotate the axes in
    the caller).
    """
    length, height, thickness = wall_size
    # Sort openings by x position so the segmenting is clean.
    openings = sorted(openings, key=lambda o: o["x"])

    segments: list[tuple[float, float, float, float]] = []
    # Each entry: (x_start, x_end, y_start, y_end) in wall-local coords.
    cursor_x = 0.0
    for op in openings:
        ox = float(op["x"])
        ow = float(op["width"])
        oh = float(op["height"])
        sill = float(op.get("sill", 0.0))
        # Full-height segment left of the opening.
        if ox > cursor_x:
            segments.append((cursor_x, ox, 0.0, height))
        # Below-opening segment (a window's sill; for a door, sill is 0).
        if sill > 0.0:
            segments.append((ox, ox + ow, 0.0, sill))
        # Above-opening segment (lintel).
        lintel_bottom = sill + oh
        if lintel_bottom < height:
            segments.append((ox, ox + ow, lintel_bottom, height))
        cursor_x = ox + ow
    # Trailing wall segment right of the last opening.
    if cursor_x < length:
        segments.append((cursor_x, length, 0.0, height))
    # If no openings at all, just emit the full wall as one piece.
    if not openings:
        segments = [(0.0, length, 0.0, height)]

    wx, wy, wz = wall_origin
    for idx, (x0, x1, y0, y1) in enumerate(segments):
        seg_len = x1 - x0
        seg_h = y1 - y0
        if seg_len <= 0.001 or seg_h <= 0.001:
            continue
        center_x_local = (x0 + x1) * 0.5
        center_y_local = (y0 + y1) * 0.5
        if axis == "x":
            pos = (wx + center_x_local, wy + center_y_local, wz)
            size = (seg_len, seg_h, thickness)
        else:  # axis == "z"
            pos = (wx, wy + center_y_local, wz + center_x_local)
            size = (thickness, seg_h, seg_len)
        emit_box(scene, parent, f"{prefix}_seg{idx}", pos, size, mat_id)


# -----------------------------------------------------------------------
# Blueprint interpreter

def _find_room(blueprint: dict, name: str) -> dict | None:
    for r in blueprint.get("rooms", []):
        if r["name"] == name:
            return r
    return None


def _opposite(side: str) -> str:
    return {"north": "south", "south": "north",
            "east": "west", "west": "east"}.get(side, side)


def _inject_opening(room: dict, side: str, opening: dict) -> None:
    """Ensure `room['walls'][side]['openings']` contains `opening`.
    Used by connector declarations so room authors don't have to
    hand-copy the same door spec onto both sides."""
    walls = room.setdefault("walls", {})
    side_spec = walls.setdefault(side, {})
    openings = side_spec.setdefault("openings", [])
    openings.append(opening)


def _inject_hole(room: dict, axis: str, hole: dict) -> None:
    """Add a hole entry to either `floor_holes` or `ceiling_holes`.
    Used by the stair/spiral/elevator auto-punch logic so stair exits
    always have a matching hole in the upper floor."""
    key = "floor_holes" if axis == "floor" else "ceiling_holes"
    room.setdefault(key, []).append(hole)


def _auto_mirror_shared_openings(blueprint: dict, tol: float = 0.1) -> None:
    """Scan every room pair for walls that share a plane (and overlap on
    the in-plane axis), and for every door/window opening on one side,
    inject a matching opening on the other side if it isn't already
    there. Lets an author draw ONE door between two adjacent rooms and
    have both walls lose the solid segment, without needing a manual
    `connectors` entry.

    This runs BEFORE wall emission so the normal emit path sees
    already-mirrored openings and splits both walls cleanly.

    Tolerance `tol` (world units) covers small snapping errors: rooms
    that ALMOST line up (e.g. origin.z=-15 vs origin.z=-14.94) are
    treated as flush. Openings that extend past the neighbour wall's
    length get clamped to the neighbour's extent.
    """
    rooms = blueprint.get("rooms", [])

    def opposite(side: str) -> str:
        return {"north": "south", "south": "north",
                "east": "west", "west": "east"}[side]

    def wall_world_plane(room: dict, side: str) -> float:
        ox, _oy, oz = room["origin"]
        sx, _sy, sz = room["size"]
        return {"south": oz, "north": oz + sz,
                "west":  ox, "east":  ox + sx}[side]

    def wall_world_axis_range(room: dict, side: str) -> tuple[float, float]:
        # The length of the wall along the in-plane axis in WORLD coords.
        ox, _oy, oz = room["origin"]
        sx, _sy, sz = room["size"]
        if side in ("north", "south"):
            return (ox, ox + sx)
        else:
            return (oz, oz + sz)

    for a in rooms:
        a_origin = a["origin"]
        walls = a.get("walls", {})
        for side, spec in list(walls.items()):
            openings = spec.get("openings", [])
            if not openings:
                continue
            ox_a, _oy_a, oz_a = a_origin
            for op in list(openings):
                if op.get("_auto_mirrored"):
                    continue
                plane_a = wall_world_plane(a, side)
                # World-axis range of this opening (along the wall).
                lx = float(op.get("x", 0.0))
                lw = float(op.get("width", 0.0))
                if side in ("north", "south"):
                    world_start = ox_a + lx
                else:
                    world_start = oz_a + lx
                world_end = world_start + lw
                opp = opposite(side)
                for b in rooms:
                    if b is a:
                        continue
                    if abs(wall_world_plane(b, opp) - plane_a) > tol:
                        continue
                    b_start, b_end = wall_world_axis_range(b, opp)
                    # Clamp the opening to b's wall — if there's no
                    # overlap at all, skip.
                    clamped_start = max(world_start, b_start)
                    clamped_end = min(world_end, b_end)
                    if clamped_end - clamped_start < 0.5:
                        continue
                    local_x = clamped_start - b_start
                    local_w = clamped_end - clamped_start
                    b_walls = b.setdefault("walls", {})
                    b_spec = b_walls.setdefault(opp, {})
                    b_openings = b_spec.setdefault("openings", [])
                    # Skip if b already has an opening that overlaps the
                    # same span — respects explicit authoring.
                    already = False
                    for bo in b_openings:
                        bx = float(bo.get("x", 0.0))
                        bw = float(bo.get("width", 0.0))
                        if not (local_x + local_w < bx or local_x > bx + bw):
                            already = True
                            break
                    if already:
                        continue
                    mirror = dict(op)
                    mirror["x"] = local_x
                    mirror["width"] = local_w
                    mirror["_auto_mirrored"] = True
                    b_openings.append(mirror)
                    break


def _auto_infer_punch_through(blueprint: dict, tol: float = 0.6) -> None:
    """Pick a sensible `punch_through` room for every stair / spiral /
    elevator that didn't name one, so authors building multi-story
    levels in the editor don't have to know about the field at all:
    climb from floor A to floor B, the converter notices B lives
    `tol` meters above the climb's top AND the climb's base sits
    inside B's xz extents, and wires A → B.

    Authors who want a stair that genuinely leads nowhere can leave
    the climb top between floors or set punch_through to an empty
    string — auto-infer only fills MISSING values, never overrides.
    """
    rooms = blueprint.get("rooms", [])
    for extra in blueprint.get("extras", []):
        if "punch_through" in extra:
            continue   # author was explicit — respect it
        kind = extra.get("type", "")
        if kind not in ("stair", "spiral_stair", "elevator"):
            continue
        px, py, pz = extra["pos"]
        if kind == "stair":
            steps = int(extra.get("steps", 6))
            landing = extra.get("landing")
            landing_steps = int(landing.get("steps", steps)) if landing else 0
            rise = float(extra.get("rise", 0.4))
            top_y = float(py) + rise * (steps + landing_steps)
        elif kind == "spiral_stair":
            steps = int(extra.get("steps", 16))
            rise = float(extra.get("rise", 0.35))
            top_y = float(py) + rise * steps
        else:  # elevator
            top_y = float(extra.get("high_y", float(py) + 4.0))
        best: dict | None = None
        best_d: float = tol
        for r in rooms:
            rx, ry, rz = r["origin"]
            rsx, _rsy, rsz = r["size"]
            d = abs(float(ry) - top_y)
            if d > best_d:
                continue
            if not (float(rx) - 0.5 <= float(px) <= float(rx) + float(rsx) + 0.5):
                continue
            if not (float(rz) - 0.5 <= float(pz) <= float(rz) + float(rsz) + 0.5):
                continue
            best = r
            best_d = d
        if best is not None:
            extra["punch_through"] = best["name"]


def _spiral_step_holes(extra: dict, target_y: float,
                       rise: float) -> list[tuple[float, float, float, float]]:
    """For a spiral stair, return a list of tight axis-aligned hole
    rects (hx0, hz0, hx1, hz1) in WORLD xz that follow the climbing
    path wherever it crosses the horizontal plane y=target_y.

    A single bounding-box hole (as the earlier implementation used)
    leaves big empty corners at target_y outside the stair's actual
    circular footprint — the player can run off the top step
    tangentially and drop into those corners. Per-step holes track
    the spiral and leave the target room's floor intact everywhere
    else.

    Each step contributes a rect only when its body OR the player
    standing on it intersects the target plane (step bot ≤ target_y
    ≤ step_top + MARIO_HEIGHT). Rect is the AABB of the rotated step
    footprint plus Mario's capsule radius and a small cushion.
    """
    import math as _m
    steps = int(extra.get("steps", 16))
    radius = float(extra.get("radius", 1.6))
    width = float(extra.get("width", 1.8))
    depth = float(extra.get("depth", 0.55))
    angle_per_step = float(extra.get("angle", 0.45))
    px, py, pz = extra["pos"]
    MARIO_H = 1.6
    R = 0.4
    margin = 0.15
    rects: list[tuple[float, float, float, float]] = []
    for i in range(steps):
        step_top_y = float(py) + rise * (i + 1)
        step_bot_y = float(py) + rise * i
        if target_y < step_bot_y - 0.05:
            continue
        if target_y > step_top_y + MARIO_H + 0.2:
            continue
        theta = i * angle_per_step
        cx = float(px) + radius * _m.cos(theta)
        cz = float(pz) + radius * _m.sin(theta)
        cos_t = abs(_m.cos(theta))
        sin_t = abs(_m.sin(theta))
        # AABB of rectangle rotated by theta: tangent axis = (-sin, cos)
        # carries `width`; radial axis = (cos, sin) carries `depth`.
        # Half-extents: ex = (w/2)|sin| + (d/2)|cos|, ez = (w/2)|cos| + (d/2)|sin|.
        ex = width * 0.5 * sin_t + depth * 0.5 * cos_t + R + margin
        ez = width * 0.5 * cos_t + depth * 0.5 * sin_t + R + margin
        rects.append((cx - ex, cz - ez, cx + ex, cz + ez))
    return rects


def _effective_stair_rise(blueprint: dict, extra: dict) -> float:
    """Return the per-step rise in world units, auto-snapped when a
    `punch_through` room is declared so the top step's upper surface is
    FLUSH with the target room's origin.y — no 4–20cm lip between the
    last tread and the upper floor plate. Used identically by the
    emit-stair path and the hole-geometry path so both see the same
    climb profile.

    When no punch_through is set, returns the declared rise unchanged.
    """
    rise = float(extra.get("rise", 0.4))
    pt = extra.get("punch_through")
    if not pt:
        return rise
    pt_room = _find_room(blueprint, pt)
    if pt_room is None:
        return rise
    kind = extra.get("type")
    py = float(extra["pos"][1])
    needed = float(pt_room["origin"][1]) - py
    if needed <= 0.1:
        return rise
    if kind == "stair":
        steps = int(extra.get("steps", 6))
        landing = extra.get("landing")
        l_steps = int(landing.get("steps", steps)) if landing else 0
        total = steps + l_steps
    elif kind == "spiral_stair":
        total = int(extra.get("steps", 16))
    else:
        return rise
    if total <= 0:
        return rise
    return needed / total


def _auto_punch_for_stair(blueprint: dict, extra: dict) -> None:
    """When a stair/spiral_stair/elevator extra declares
    `punch_through: "RoomName"`, compute a hole that covers its top
    exit and add it to the target room's floor_holes AND to whichever
    room is below.

    The old implementation extended the hole symmetrically past the
    stair top (`tx ± 2*run`), which created a visible pit in the upper
    floor *beyond* the stair exit — the player would walk off the top
    tread and fall. The corrected geometry:

      - On the CLIMB side (where the climber is still ascending), the
        hole extends back `head_pad` — enough room for the climber's
        head while they're still below the upper floor plane. Derived
        from 1.7m ÷ rise × run, so taller risers need less setback.
      - On the EXIT side (forward from the stair top), the hole extends
        only `exit_pad` — just a lip so the player has a moment to
        transition onto the upper floor without clipping the hole edge.
    """
    target = extra.get("punch_through")
    if not target:
        return
    target_room = _find_room(blueprint, target)
    if target_room is None:
        return
    px, py, pz = extra["pos"]
    pad = float(extra.get("punch_pad", 0.4))
    kind = extra.get("type")
    exit_pad = 0.25  # forward margin past the stair top
    if kind == "stair":
        direction = extra.get("direction", "+z")
        steps = int(extra.get("steps", 6))
        rise = _effective_stair_rise(blueprint, extra)
        run = float(extra.get("run", 0.6))
        width = float(extra.get("width", 2.0))
        landing = extra.get("landing")
        # head_pad = how far BACK along the climb the hole extends from
        # the stair top so Mario's capsule clears the upper-floor edge
        # while his head is still above the climb line.
        #
        # Derivation:
        #   MARIO_HEIGHT = 1.6m, CAPSULE_RADIUS = 0.4m.
        #   First step where the head pokes above target_y:
        #     i* = ceil((target_y - py - MARIO_HEIGHT) / rise) - 1
        #   When Mario just step-upped onto step i*, his body_center
        #   sits at (px + run*i* - CAPSULE_RADIUS) so body_back can be
        #   as far back as (px + run*i* - 2*CAPSULE_RADIUS). The hole
        #   must reach at least there, i.e.
        #     hole_back <= px + run*i* - 2*CAPSULE_RADIUS
        #   → head_pad + pad >= run*(steps - i*) + 2*CAPSULE_RADIUS.
        #
        # The old formula (1.7/rise * run) only counted steps that
        # poke, missed Mario's body radius on both ends, and left a
        # ~0.35m gap at the back of the hole — the player would slam
        # their head on the upper-floor lip while climbing.
        import math as _math
        MARIO_H = 1.6
        R = 0.4
        target_y = float(target_room["origin"][1])
        head_steps = steps - (int(_math.ceil(
            (target_y - float(py) - MARIO_H) / max(rise, 0.01))) - 1)
        head_steps = max(head_steps, 1)
        # +0.2m safety so the hole edge isn't flush with Mario's back.
        head_pad = head_steps * run + 2.0 * R + 0.2 - pad
        if direction == "+z":
            dx, dz = 0, 1
        elif direction == "-z":
            dx, dz = 0, -1
        elif direction == "+x":
            dx, dz = 1, 0
        else:
            dx, dz = -1, 0
        tx = px + dx * run * steps
        tz = pz + dz * run * steps
        if landing:
            # L-shape: hole covers the landing + second flight. Exit
            # margin is applied to the FAR end of the second flight
            # along its climb direction.
            l_size = float(landing.get("size", width))
            l_steps = int(landing.get("steps", steps))
            l_dir = landing.get("direction", "+z")
            if l_dir == "+z":
                ddx, ddz = 0, 1
            elif l_dir == "-z":
                ddx, ddz = 0, -1
            elif l_dir == "+x":
                ddx, ddz = 1, 0
            else:
                ddx, ddz = -1, 0
            land_cx = px + dx * (run * steps + l_size * 0.5)
            land_cz = pz + dz * (run * steps + l_size * 0.5)
            foot_x = land_cx + ddx * run * l_steps
            foot_z = land_cz + ddz * run * l_steps
            if abs(ddx) > 0:
                if ddx > 0:
                    hx0 = land_cx - l_size * 0.5 - pad
                    hx1 = foot_x + exit_pad
                else:
                    hx0 = foot_x - exit_pad
                    hx1 = land_cx + l_size * 0.5 + pad
                hz0 = land_cz - width * 0.5 - pad
                hz1 = land_cz + width * 0.5 + pad
            else:
                if ddz > 0:
                    hz0 = land_cz - l_size * 0.5 - pad
                    hz1 = foot_z + exit_pad
                else:
                    hz0 = foot_z - exit_pad
                    hz1 = land_cz + l_size * 0.5 + pad
                hx0 = land_cx - width * 0.5 - pad
                hx1 = land_cx + width * 0.5 + pad
        else:
            # Single flight: head_pad back along climb, exit_pad forward.
            if dx > 0:
                hx0 = tx - head_pad - pad
                hx1 = tx + exit_pad
                hz0 = pz - width * 0.5 - pad
                hz1 = pz + width * 0.5 + pad
            elif dx < 0:
                hx0 = tx - exit_pad
                hx1 = tx + head_pad + pad
                hz0 = pz - width * 0.5 - pad
                hz1 = pz + width * 0.5 + pad
            elif dz > 0:
                hz0 = tz - head_pad - pad
                hz1 = tz + exit_pad
                hx0 = px - width * 0.5 - pad
                hx1 = px + width * 0.5 + pad
            else:
                hz0 = tz - exit_pad
                hz1 = tz + head_pad + pad
                hx0 = px - width * 0.5 - pad
                hx1 = px + width * 0.5 + pad
    elif kind == "spiral_stair":
        # Spiral gets special treatment: per-step holes tight to the
        # climbing path rather than one bounding box that leaves the
        # corners fall-throughable. Handled below in a dedicated
        # branch; we return after injecting the holes ourselves.
        import math as _math
        rise = _effective_stair_rise(blueprint, extra)
        target_y = float(target_room["origin"][1])
        base_y = float(py)
        rx, _, rz = target_room["origin"]
        for (a, b, c, d) in _spiral_step_holes(extra, target_y, rise):
            _inject_hole(target_room, "floor", {
                "x": a - rx, "z": b - rz,
                "width": c - a, "depth": d - b,
            })
        for r in blueprint.get("rooms", []):
            if r is target_room:
                continue
            rx2, ry2, rz2 = r["origin"]
            rsx2, rsy2, rsz2 = r["size"]
            r_ceiling = float(ry2) + float(rsy2)
            if not (base_y + 0.05 < r_ceiling <= target_y + 0.05):
                continue
            for (a, b, c, d) in _spiral_step_holes(extra, r_ceiling, rise):
                if c < float(rx2) or a > float(rx2) + float(rsx2):
                    continue
                if d < float(rz2) or b > float(rz2) + float(rsz2):
                    continue
                _inject_hole(r, "ceiling", {
                    "x": a - float(rx2), "z": b - float(rz2),
                    "width": c - a, "depth": d - b,
                })
        return
    elif kind == "elevator":
        w = float(extra.get("width", 2.4))
        d = float(extra.get("depth", 2.4))
        hx0 = px - w * 0.5 - pad
        hx1 = px + w * 0.5 + pad
        hz0 = pz - d * 0.5 - pad
        hz1 = pz + d * 0.5 + pad
    else:
        return

    # Convert WORLD xz to target-room-local xz.
    rx, _, rz = target_room["origin"]
    local = {
        "x": hx0 - rx,
        "z": hz0 - rz,
        "width": hx1 - hx0,
        "depth": hz1 - hz0,
    }
    _inject_hole(target_room, "floor", local)
    # Ceiling holes: punch the ceiling of every room whose ceiling Y
    # sits between the stair's BASE y and the TARGET y — i.e., every
    # ceiling the climb passes through on its way up. The earlier
    # version only matched ceilings that were flush with the target
    # floor (tol 0.05m), which missed the common case of a short
    # intermediate room with a gap above it before the next floor
    # (e.g. Room4 y=5..9 under a target at y=10 — a 1m air pocket).
    # Requires xz overlap too so we don't punch unrelated rooms that
    # happen to sit at the right height elsewhere on the map.
    base_y = float(extra["pos"][1])
    if kind == "elevator":
        base_y = float(extra.get("low_y", base_y))
    target_y = float(target_room["origin"][1])
    for r in blueprint.get("rooms", []):
        if r is target_room:
            continue
        rx2, ry2, rz2 = r["origin"]
        rsx2, _rsy, rsz2 = r["size"]
        r_ceiling: float = float(ry2) + float(_rsy)
        # Strictly above the base (so the lower room whose ceiling IS
        # the stair's base doesn't get punched) and at or below the
        # target (with a small cushion for floating-point drift).
        if not (base_y + 0.05 < r_ceiling <= target_y + 0.05):
            continue
        # xz overlap: hole rect vs room rect.
        if hx1 < float(rx2) or hx0 > float(rx2) + float(rsx2):
            continue
        if hz1 < float(rz2) or hz0 > float(rz2) + float(rsz2):
            continue
        _inject_hole(r, "ceiling", {
            "x": hx0 - float(rx2),
            "z": hz0 - float(rz2),
            "width": hx1 - hx0,
            "depth": hz1 - hz0,
        })


def build_scene(blueprint: dict, scene_name: str) -> Scene:
    scene = Scene()
    root_body = ""
    if "spawn_point" in blueprint:
        sp = blueprint["spawn_point"]
        root_body += f'metadata/spawn_point = {vec(sp[0], sp[1], sp[2])}\n'
    # Optional per-level overrides read by level_manager.gd at load time.
    # `water_level_y` is auto-derived from the TOP surface of any water
    # volume if not specified — authors don't have to duplicate it.
    effective_water_y = blueprint.get("water_level_y")
    if effective_water_y is None:
        for vol in blueprint.get("volumes", []):
            if str(vol.get("kind", "")) != "water":
                continue
            oy = float(vol["origin"][1])
            sy = float(vol.get("size", [0, 0, 0])[1])
            top = oy + sy
            if effective_water_y is None or top > effective_water_y:
                effective_water_y = top
    if effective_water_y is not None:
        root_body += f'metadata/water_level_y = {float(effective_water_y)}\n'
    if "bgm" in blueprint:
        root_body += f'metadata/bgm = "{str(blueprint["bgm"])}"\n'
    scene.node(scene_name, None, "Node3D", root_body)
    # When requested, inject a basic Environment + Sun so the scene
    # loads as a standalone playable level. Without this the blueprint
    # output is just geometry — no lighting, black ambient.
    if blueprint.get("standalone_level", False):
        sky = blueprint.get("sky") or {}
        def _col(k: str, default: tuple[float, float, float]) -> str:
            c = sky.get(k) if sky.get(k) else default
            return f"Color({float(c[0])}, {float(c[1])}, {float(c[2])}, 1)"
        bg = _col("horizon_color", (0.52, 0.75, 0.98))
        amb = _col("ambient_color", (0.8, 0.82, 0.78))
        amb_energy = float(sky.get("ambient_energy", 0.8))
        env_body = (
            'background_mode = 1\n'
            f'background_color = {bg}\n'
            'ambient_light_source = 2\n'
            f'ambient_light_color = {amb}\n'
            f'ambient_light_energy = {amb_energy}\n'
        )
        env_id = scene.sub("Environment", env_body)
        scene.node("WorldEnvironment", scene_name, "WorldEnvironment",
                   f'environment = SubResource("{env_id}")\n')
        scene.node("Sun", scene_name, "DirectionalLight3D",
                   'transform = Transform3D(0.7, -0.5, 0.5, 0.0, 0.7, 0.7, -0.7, -0.5, 0.5, 0, 6, 0)\n')
    mats = blueprint.get("materials", {})
    mat_ids: dict[str, str] = {}
    for name, path in mats.items():
        mat_ids[name] = scene.ext_resource(path, "Material")

    wall_t = float(blueprint.get("wall_thickness", 0.3))

    # Fill in missing punch_through values from room geometry before
    # running the punch pass — saves authors from having to wire each
    # multi-story stair by hand.
    _auto_infer_punch_through(blueprint)

    # Auto-punch holes in floors/ceilings for stairs/elevators that
    # declare `punch_through`. Must run BEFORE rooms emit so the holes
    # are baked into the slab partitioner.
    for extra in blueprint.get("extras", []):
        _auto_punch_for_stair(blueprint, extra)

    # Mirror openings across shared walls so a door drawn once opens
    # BOTH sides — otherwise Room1's south door would render but
    # Room2's adjacent wall would stay solid.
    _auto_mirror_shared_openings(blueprint)

    # Resolve connectors FIRST so rooms emit their walls with the
    # injected openings already in place. A connector links two
    # rooms by name and adds a matching door/window opening on
    # each room's adjacent wall.
    for conn in blueprint.get("connectors", []):
        ra = _find_room(blueprint, conn["room_a"])
        rb = _find_room(blueprint, conn["room_b"])
        if ra is None or rb is None:
            continue
        opening_a = {
            "type": conn.get("type", "door"),
            "x": conn["x_a"],
            "width": conn.get("width", 2.0),
            "height": conn.get("height", 3.0),
            "sill": conn.get("sill", 0.0),
        }
        opening_b = dict(opening_a)
        opening_b["x"] = conn["x_b"]
        _inject_opening(ra, conn["side_a"], opening_a)
        _inject_opening(rb, _opposite(conn["side_a"]), opening_b)

    for room in blueprint.get("rooms", []):
        rname = room["name"]
        ox, oy, oz = room["origin"]
        sx, sy, sz = room["size"]
        room_mat = mat_ids.get(room.get("material", ""))
        floor_mat = mat_ids.get(room.get("floor_material", room.get("material", "")))

        # Room root node for namespacing.
        scene.node(rname, scene_name, "Node3D",
                   f'transform = {xform_translate(ox, oy, oz)}\n')
        room_parent = f"{scene_name}/{rname}"

        # Floor + ceiling slabs. Both support multiple `holes`
        # (rectangles in room-local xz) — we iteratively subtract each
        # hole from the set of free rectangles, starting from the full
        # plate. Every remaining rectangle becomes its own slab.
        if room.get("floor", True):
            _emit_slab_with_holes(
                scene, room_parent, "Floor",
                sx, sz, -0.1, 0.2,
                room.get("floor_holes", []), floor_mat,
            )
        if room.get("ceiling", True):
            _emit_slab_with_holes(
                scene, room_parent, "Ceiling",
                sx, sz, sy + 0.1, 0.2,
                room.get("ceiling_holes", []), room_mat,
            )

        walls = room.get("walls", {})
        # NORTH: at z = sz, length along X. Openings x=0..sx.
        if "north" in walls:
            emit_wall_with_openings(
                scene, room_parent, "WallN",
                (0.0, 0.0, sz),
                (sx, sy, wall_t),
                "x",
                walls["north"].get("openings", []),
                room_mat,
            )
        # SOUTH: at z = 0, length along X.
        if "south" in walls:
            emit_wall_with_openings(
                scene, room_parent, "WallS",
                (0.0, 0.0, 0.0),
                (sx, sy, wall_t),
                "x",
                walls["south"].get("openings", []),
                room_mat,
            )
        # EAST: at x = sx, length along Z.
        if "east" in walls:
            emit_wall_with_openings(
                scene, room_parent, "WallE",
                (sx, 0.0, 0.0),
                (sz, sy, wall_t),
                "z",
                walls["east"].get("openings", []),
                room_mat,
            )
        # WEST: at x = 0, length along Z.
        if "west" in walls:
            emit_wall_with_openings(
                scene, room_parent, "WallW",
                (0.0, 0.0, 0.0),
                (sz, sy, wall_t),
                "z",
                walls["west"].get("openings", []),
                room_mat,
            )

    # Breakable blocks — meta('breakable'=true). Optionally meta
    # ('reward_kind') spawns a pickup at the block's position when
    # ground-pounded.
    for block in blueprint.get("blocks", []):
        bx, by, bz = block["pos"]
        sx, sy, sz = block.get("size", [1.4, 1.4, 1.4])
        mat = mat_ids.get(block.get("material", ""))
        name = block.get("name") or f"Block_{bx}_{by}_{bz}"
        mesh_id = scene.sub("BoxMesh", f"size = {vec(sx, sy, sz)}\n")
        shape_id = scene.sub("BoxShape3D", f"size = {vec(sx, sy, sz)}\n")
        body = (
            f'transform = {xform_translate(bx, by + sy * 0.5, bz)}\n'
            f'collision_layer = 1\n'
            f'collision_mask = 1\n'
        )
        if block.get("breakable", False):
            body += 'metadata/breakable = true\n'
            if "reward" in block:
                body += f'metadata/reward_kind = "{block["reward"]}"\n'
        scene.node(name, scene_name, "StaticBody3D", body)
        mi_body = f'mesh = SubResource("{mesh_id}")\n'
        if mat is not None:
            mi_body += f'surface_material_override/0 = ExtResource("{mat}")\n'
        scene.node("Mesh", f"{scene_name}/{name}", "MeshInstance3D", mi_body)
        scene.node("Col", f"{scene_name}/{name}", "CollisionShape3D",
                   f'shape = SubResource("{shape_id}")\n')

    # Keys — just pickup Area3Ds with meta('pickup_kind'='key_<color>').
    # object_spawner already knows key_bronze/silver/gold. In the
    # blueprint we just drop a marker and the runtime seeder handles it.
    for key in blueprint.get("keys", []):
        kx, ky, kz = key["pos"]
        color = key.get("color", "bronze")
        name = key.get("name") or f"Key_{color}_{kx}_{ky}_{kz}"
        body = (
            f'transform = {xform_translate(kx, ky, kz)}\n'
            f'metadata/pickup_kind = "key_{color}"\n'
        )
        scene.node(name, scene_name, "Marker3D", body)

    # Locked doors. Two forms:
    # 1. "warp"      — Area3D that warps to another level but blocks
    #                   until player has the key.
    # 2. "barrier"   — Area3D + barrier mesh that removes itself when
    #                   the player consumes the key. No level warp.
    for lock in blueprint.get("locks", []):
        lx, ly, lz = lock["pos"]
        key_color = lock.get("key", "bronze")
        width = float(lock.get("width", 2.0))
        height = float(lock.get("height", 3.5))
        depth = float(lock.get("depth", 0.5))
        name = lock.get("name") or f"Lock_{lx}_{ly}_{lz}"
        if lock["type"] == "warp":
            body = (
                f'transform = {xform_translate(lx, ly + height * 0.5, lz)}\n'
                f'collision_layer = 0\n'
                f'collision_mask = 1\n'
                f'metadata/warp_to = "{lock.get("warp_to", "")}"\n'
                f'metadata/lock_key = "{key_color}"\n'
            )
            scene.node(name, scene_name, "Area3D", body)
            # Trigger volume.
            shape_id = scene.sub("BoxShape3D", f"size = {vec(width, height, depth)}\n")
            scene.node("Col", f"{scene_name}/{name}", "CollisionShape3D",
                       f'shape = SubResource("{shape_id}")\n')
        else:
            # Barrier: parent Area3D holds a child StaticBody3D that
            # gets freed when the key is consumed.
            body = (
                f'transform = {xform_translate(lx, ly + height * 0.5, lz)}\n'
                f'collision_layer = 0\n'
                f'collision_mask = 1\n'
                f'metadata/lock_key = "{key_color}"\n'
                f'metadata/lock_barrier = "Barrier"\n'
            )
            scene.node(name, scene_name, "Area3D", body)
            shape_id = scene.sub("BoxShape3D", f"size = {vec(width, height, depth)}\n")
            scene.node("Col", f"{scene_name}/{name}", "CollisionShape3D",
                       f'shape = SubResource("{shape_id}")\n')
            # Barrier mesh + collision inside the Area3D.
            barrier_body = (
                'collision_layer = 1\n'
                'collision_mask = 1\n'
            )
            scene.node("Barrier", f"{scene_name}/{name}",
                       "StaticBody3D", barrier_body)
            bmesh = scene.sub("BoxMesh", f"size = {vec(width, height, depth)}\n")
            bshape = scene.sub("BoxShape3D",
                                f"size = {vec(width, height, depth)}\n")
            bmat = mat_ids.get(lock.get("material", ""), None)
            bmi = f'mesh = SubResource("{bmesh}")\n'
            if bmat is not None:
                bmi += f'surface_material_override/0 = ExtResource("{bmat}")\n'
            scene.node("Mesh",
                       f"{scene_name}/{name}/Barrier",
                       "MeshInstance3D", bmi)
            scene.node("Col",
                       f"{scene_name}/{name}/Barrier",
                       "CollisionShape3D",
                       f'shape = SubResource("{bshape}")\n')

    # Extras: pillars, stairs, platforms, etc. — purely additive primitives.
    for extra in blueprint.get("extras", []):
        kind = extra.get("type")
        px, py, pz = extra["pos"]
        mat = mat_ids.get(extra.get("material", ""))
        name = extra.get("name") or f"Extra_{kind}_{px}_{py}_{pz}"
        if kind == "pillar":
            r = float(extra.get("radius", 0.4))
            h = float(extra.get("height", 4.0))
            # Approximate a cylinder via a slim tall box for now.
            emit_box(scene, scene_name, name,
                     (px, py + h / 2.0, pz),
                     (r * 2.0, h, r * 2.0), mat)
        elif kind == "platform":
            s = extra["size"]
            emit_box(scene, scene_name, name,
                     (px + s[0] / 2.0, py + s[1] / 2.0, pz + s[2] / 2.0),
                     tuple(s), mat)
        elif kind == "stair":
            # Stair with orientation. direction chooses which way the
            # climb goes: +z (default), -z, +x, -x. Optional landing
            # at half-height forms an L-shape via a second flight in
            # a perpendicular direction.
            steps = int(extra.get("steps", 6))
            # Use the punch-through-aware rise so the top tread lands
            # flush with the target room's floor; falls through to the
            # declared rise when punch_through is absent.
            rise = _effective_stair_rise(blueprint, extra)
            run = float(extra.get("run", 0.6))
            width = float(extra.get("width", 2.0))
            direction = extra.get("direction", "+z")
            # Unit vectors for the climb axis (dx, dz) and the width
            # axis (wx, wz — the direction the step's width extends).
            if direction == "+z":
                dx, dz, wx, wz = 0, 1, 1, 0
            elif direction == "-z":
                dx, dz, wx, wz = 0, -1, 1, 0
            elif direction == "+x":
                dx, dz, wx, wz = 1, 0, 0, 1
            else:  # "-x"
                dx, dz, wx, wz = -1, 0, 0, 1
            for i in range(steps):
                step_cx = px + dx * run * (i + 0.5)
                step_cz = pz + dz * run * (i + 0.5)
                step_cy = py + rise * (i + 0.5)
                size_x = width if wx else run
                size_z = width if wz else run
                emit_box(scene, scene_name, f"{name}_step{i}",
                         (step_cx, step_cy, step_cz),
                         (size_x, rise, size_z),
                         mat)
            # Optional landing + second flight for L-shape / switchback.
            landing = extra.get("landing", None)
            if landing:
                # Landing is a square platform at the top of the first
                # flight. Second flight continues from the landing's
                # far edge in `landing.direction`.
                l_size = float(landing.get("size", width))
                top_y = py + rise * steps
                land_cx = px + dx * (run * steps + l_size * 0.5)
                land_cz = pz + dz * (run * steps + l_size * 0.5)
                emit_box(scene, scene_name, f"{name}_landing",
                         (land_cx, top_y + 0.1, land_cz),
                         (l_size if wx else l_size, 0.2, l_size),
                         mat)
                l_dir = landing.get("direction", "+z")
                l_steps = int(landing.get("steps", steps))
                if l_dir == "+z":
                    ddx, ddz, dwx, dwz = 0, 1, 1, 0
                elif l_dir == "-z":
                    ddx, ddz, dwx, dwz = 0, -1, 1, 0
                elif l_dir == "+x":
                    ddx, ddz, dwx, dwz = 1, 0, 0, 1
                else:
                    ddx, ddz, dwx, dwz = -1, 0, 0, 1
                for i in range(l_steps):
                    sx = land_cx + ddx * run * (i + 0.5)
                    sz = land_cz + ddz * run * (i + 0.5)
                    sy = top_y + rise * (i + 0.5)
                    sizex = width if dwx else run
                    sizez = width if dwz else run
                    emit_box(scene, scene_name, f"{name}_up_step{i}",
                             (sx, sy, sz), (sizex, rise, sizez), mat)
        elif kind == "spiral_stair":
            # Helical staircase winding around a vertical axis at
            # (px, py, pz). Each step is a wedge-shaped box rotated
            # around Y by its angular offset. For a cheap wedge we use
            # a thin box positioned outward from the axis.
            steps = int(extra.get("steps", 16))
            rise = _effective_stair_rise(blueprint, extra)
            radius = float(extra.get("radius", 1.6))
            width = float(extra.get("width", 1.8))
            depth = float(extra.get("depth", 0.55))
            angle_per_step = float(extra.get("angle", 0.45))  # radians
            import math as _m
            for i in range(steps):
                theta = i * angle_per_step
                cx_world = px + radius * _m.cos(theta)
                cz_world = pz + radius * _m.sin(theta)
                cy_world = py + rise * (i + 0.5)
                # Each step is an axis-aligned box oriented along the
                # radial direction. We can't rotate via Transform3D
                # without building a full basis; instead we emit
                # shallow boxes and let Godot's imperfect result look
                # "carved stone" rather than "pie slice." Good enough
                # for a playable spiral.
                # Size: width along the tangent, depth along the radial.
                emit_rotated_box(
                    scene, scene_name, f"{name}_step{i}",
                    (cx_world, cy_world, cz_world),
                    (width, rise, depth),
                    theta,
                    mat,
                )
            # Central column so the stair has something to hug.
            h = rise * steps
            emit_box(scene, scene_name, f"{name}_column",
                     (px, py + h * 0.5, pz),
                     (radius * 0.5, h, radius * 0.5), mat)
        elif kind == "elevator":
            # Moving platform shuttling between two Y levels. The
            # runtime script (scripts/elevator.gd) reads meta values
            # to know the Y range, speed, and trigger behavior.
            low_y = float(extra.get("low_y", py))
            high_y = float(extra.get("high_y", py + 4.0))
            eh = float(extra.get("thickness", 0.4))
            ew = float(extra.get("width", 2.4))
            ed = float(extra.get("depth", 2.4))
            speed = float(extra.get("speed", 2.0))
            mode = extra.get("mode", "toggle")  # toggle|loop|call
            body_transform = xform_translate(px, low_y + eh * 0.5, pz)
            body_body = (
                f'transform = {body_transform}\n'
                f'collision_layer = 1\n'
                f'collision_mask = 1\n'
                f'metadata/elevator_low_y = {low_y}\n'
                f'metadata/elevator_high_y = {high_y}\n'
                f'metadata/elevator_speed = {speed}\n'
                f'metadata/elevator_mode = "{mode}"\n'
                f'script = ExtResource("{scene.ext_resource("res://scripts/elevator.gd", "Script")}")\n'
            )
            scene.node(name, scene_name, "AnimatableBody3D", body_body)
            mesh_id = scene.sub("BoxMesh", f"size = {vec(ew, eh, ed)}\n")
            shape_id = scene.sub("BoxShape3D", f"size = {vec(ew, eh, ed)}\n")
            mi = f'mesh = SubResource("{mesh_id}")\n'
            if mat is not None:
                mi += f'surface_material_override/0 = ExtResource("{mat}")\n'
            scene.node("Mesh", f"{scene_name}/{name}", "MeshInstance3D", mi)
            scene.node("Col", f"{scene_name}/{name}", "CollisionShape3D",
                       f'shape = SubResource("{shape_id}")\n')

    # Terrain patches: each entry declares a rectangular heightmap grid.
    # The actual mesh + collision are rebuilt at runtime by
    # scripts/terrain_patch.gd using the metadata we emit here — this
    # keeps the .tscn small (just a single node + a Float32 array) and
    # lets sculpt edits round-trip through the JSON without anyone
    # touching generated .tscn files.
    for patch in blueprint.get("terrain_patches", []):
        ox, oy, oz = patch["origin"]
        pname = patch.get("name") or f"Terrain_{ox}_{oy}_{oz}"
        size_x = float(patch.get("size_x", 10.0))
        size_z = float(patch.get("size_z", 10.0))
        res = int(patch.get("resolution", 8))
        mat_name = patch.get("material", "")
        mat_path = mats.get(mat_name, "") if mat_name else ""
        heights = patch.get("heights") or [0.0] * (res * res)
        if len(heights) != res * res:
            heights = (list(heights) + [0.0] * (res * res))[: res * res]
        heights_literal = "PackedFloat32Array(" + ", ".join(
            f"{float(h):.4f}" for h in heights) + ")"
        # Slope-aware colouring defaults: grass on flats, dirt on slopes.
        # Authors can override by setting flat_color / slope_color /
        # slope_threshold / slope_softness on the JSON patch.
        flat_c = patch.get("flat_color") or [0.35, 0.55, 0.22]
        slope_c = patch.get("slope_color") or [0.45, 0.32, 0.18]
        slope_thr = float(patch.get("slope_threshold", 0.72))
        slope_soft = float(patch.get("slope_softness", 0.15))
        script_id = scene.ext_resource(
            "res://scripts/terrain_patch.gd", "Script")
        # Sink the whole patch 2cm to stop Z-fighting with room floor
        # slabs that share the same origin.y.
        TERRAIN_Z_OFFSET = 0.02
        body = (
            f'transform = {xform_translate(ox, oy - TERRAIN_Z_OFFSET, oz)}\n'
            f'script = ExtResource("{script_id}")\n'
            f'metadata/terrain_heights = {heights_literal}\n'
            f'metadata/terrain_size_x = {size_x}\n'
            f'metadata/terrain_size_z = {size_z}\n'
            f'metadata/terrain_resolution = {res}\n'
            f'metadata/terrain_material = "{mat_path}"\n'
            f'metadata/terrain_flat_color = [{flat_c[0]}, {flat_c[1]}, {flat_c[2]}]\n'
            f'metadata/terrain_slope_color = [{slope_c[0]}, {slope_c[1]}, {slope_c[2]}]\n'
            f'metadata/terrain_slope_threshold = {slope_thr}\n'
            f'metadata/terrain_slope_softness = {slope_soft}\n'
        )
        # Per-cell surface-kind paint grid ((res-1)² entries). Empty
        # string means "no paint, use the default body for collision".
        # Runtime splits collision into one StaticBody3D per unique
        # kind, each carrying its own metadata/surface_kind so mario's
        # floor_surface check resolves per-cell.
        surface_grid = patch.get("surface_grid") or []
        if len(surface_grid) != (res - 1) * (res - 1):
            surface_grid = [""] * ((res - 1) * (res - 1))
        grid_literal = "[" + ", ".join(
            f'"{str(s)}"' for s in surface_grid) + "]"
        body += f'metadata/terrain_surface_grid = {grid_literal}\n'
        scene.node(pname, scene_name, "Node3D", body)

    # Enemies: level_manager._spawn_markers walks the scene for nodes
    # with `metadata/enemy_bhv` and spawns real enemy.gd bodies at each
    # marker's world position. The marker itself stays in place (free
    # Node3D, no children); we keep it parented so save/load + scene
    # inspection show authored positions.
    for enemy in blueprint.get("enemies", []):
        ex, ey, ez = enemy["pos"]
        bhv = str(enemy.get("bhv", "bhvGoomba"))
        ename = enemy.get("name") or f"Enemy_{bhv}_{ex}_{ey}_{ez}"
        body = (
            f'transform = {xform_translate(ex, ey, ez)}\n'
            f'metadata/enemy_bhv = "{bhv}"\n'
        )
        if enemy.get("patrol_radius") is not None:
            body += f'metadata/enemy_patrol_radius = {float(enemy["patrol_radius"])}\n'
        scene.node(ename, scene_name, "Node3D", body)

    # Pickups: same pattern — metadata/pickup_kind, level_manager spawns
    # the visual + Area3D at runtime. Kinds come from the ObjectSpawner
    # whitelist (coin_*, star, oneup, cap_*, key_*).
    for pickup in blueprint.get("pickups", []):
        px_p, py_p, pz_p = pickup["pos"]
        kind = str(pickup.get("kind", "coin_yellow"))
        pname = pickup.get("name") or f"Pickup_{kind}_{px_p}_{py_p}_{pz_p}"
        body = (
            f'transform = {xform_translate(px_p, py_p, pz_p)}\n'
            f'metadata/pickup_kind = "{kind}"\n'
        )
        scene.node(pname, scene_name, "Node3D", body)

    # Warps: Area3D with `metadata/warp_to` + optional requires_stars /
    # lock_key. level_manager wires body_entered → load_level at load
    # time, including the gating logic the existing lock system uses.
    for warp in blueprint.get("warps", []):
        wx, wy, wz = warp["pos"]
        sz_w = warp.get("size", [2.5, 3.0, 2.5])
        wname = warp.get("name") or f"Warp_{wx}_{wy}_{wz}"
        target = str(warp.get("target_level", ""))
        body = (
            f'transform = {xform_translate(wx, wy + float(sz_w[1]) * 0.5, wz)}\n'
            f'collision_layer = 0\n'
            f'collision_mask = 1\n'
            f'metadata/warp_to = "{target}"\n'
        )
        if warp.get("requires_stars"):
            body += f'metadata/requires_stars = {int(warp["requires_stars"])}\n'
        if warp.get("requires_key"):
            body += f'metadata/lock_key = "{str(warp["requires_key"])}"\n'
        scene.node(wname, scene_name, "Area3D", body)
        shape_id = scene.sub(
            "BoxShape3D",
            f"size = {vec(float(sz_w[0]), float(sz_w[1]), float(sz_w[2]))}\n",
        )
        scene.node("Col", f"{scene_name}/{wname}", "CollisionShape3D",
                   f'shape = SubResource("{shape_id}")\n')
        # Glowing portal visual — hints at where the warp is.
        mesh_id = scene.sub(
            "BoxMesh",
            f"size = {vec(float(sz_w[0]) * 0.8, float(sz_w[1]), 0.2)}\n",
        )
        glow = scene.sub(
            "StandardMaterial3D",
            (
                "albedo_color = Color(0.4, 0.7, 1.0, 0.45)\n"
                "emission_enabled = true\n"
                "emission = Color(0.3, 0.6, 1.0, 1)\n"
                "emission_energy_multiplier = 1.6\n"
                "transparency = 1\n"
            ),
        )
        scene.node(
            "Mesh", f"{scene_name}/{wname}", "MeshInstance3D",
            f'mesh = SubResource("{mesh_id}")\n'
            f'surface_material_override/0 = SubResource("{glow}")\n',
        )

    # Volumes: water/lava/ice/quicksand. Water gets a translucent blue
    # top surface + sets root water_level_y if not already authored.
    # Lava/ice/quicksand each emit a StaticBody3D with surface_kind meta
    # so mario_state's floor_surface check reads the right friction +
    # hazard behaviour.
    VOLUME_VISUALS = {
        "water":     {"color": (0.20, 0.45, 0.95, 0.55), "emit": (0.10, 0.22, 0.45), "surface": "water"},
        "lava":      {"color": (1.00, 0.40, 0.08, 0.95), "emit": (1.00, 0.25, 0.02), "surface": "burning"},
        "ice":       {"color": (0.70, 0.90, 1.00, 0.75), "emit": (0.25, 0.45, 0.55), "surface": "ice"},
        "quicksand": {"color": (0.78, 0.65, 0.30, 0.95), "emit": (0.30, 0.22, 0.08), "surface": "shallow_quicksand"},
    }
    for vol in blueprint.get("volumes", []):
        vk = str(vol.get("kind", "water"))
        spec = VOLUME_VISUALS.get(vk)
        if spec is None:
            continue
        vox, voy, voz = vol["origin"]
        vsx, vsy, vsz = vol.get("size", [4.0, 1.0, 4.0])
        vname = vol.get("name") or f"Vol_{vk}_{vox}_{voy}_{voz}"
        c = spec["color"]; e = spec["emit"]
        body = (
            f'transform = {xform_translate(float(vox) + float(vsx) * 0.5, float(voy) + float(vsy) * 0.5, float(voz) + float(vsz) * 0.5)}\n'
            f'collision_layer = 1\n'
            f'collision_mask = 1\n'
            f'metadata/volume_kind = "{vk}"\n'
            f'metadata/surface_kind = "{spec["surface"]}"\n'
        )
        scene.node(vname, scene_name, "StaticBody3D", body)
        mesh_id = scene.sub(
            "BoxMesh",
            f"size = {vec(float(vsx), float(vsy), float(vsz))}\n",
        )
        mat_src = (
            f"albedo_color = Color({c[0]}, {c[1]}, {c[2]}, {c[3]})\n"
            "emission_enabled = true\n"
            f"emission = Color({e[0]}, {e[1]}, {e[2]}, 1)\n"
            "emission_energy_multiplier = 0.6\n"
            "roughness = 0.3\n"
        )
        if c[3] < 0.99:
            mat_src += "transparency = 1\n"
        mat_id = scene.sub("StandardMaterial3D", mat_src)
        scene.node("Mesh", f"{scene_name}/{vname}", "MeshInstance3D",
                   f'mesh = SubResource("{mesh_id}")\n'
                   f'surface_material_override/0 = SubResource("{mat_id}")\n')
        shape_id = scene.sub(
            "BoxShape3D",
            f"size = {vec(float(vsx), float(vsy), float(vsz))}\n",
        )
        scene.node("Col", f"{scene_name}/{vname}", "CollisionShape3D",
                   f'shape = SubResource("{shape_id}")\n')

    return scene


def emit_rotated_box(scene: Scene, parent: str, name: str,
                     pos: tuple[float, float, float],
                     size: tuple[float, float, float],
                     y_rotation: float,
                     mat_id: str | None) -> None:
    """Spiral-stair helper: emit a box with a Y-axis rotation baked
    into the StaticBody3D transform. Used for spiral steps that wind
    around an axis."""
    import math as _m
    c = _m.cos(y_rotation)
    s = _m.sin(y_rotation)
    mesh_id = scene.sub("BoxMesh", f"size = {vec(*size)}\n")
    shape_id = scene.sub("BoxShape3D", f"size = {vec(*size)}\n")
    tx, ty, tz = pos
    # Rotation around Y axis (columns are X, Y, Z direction vectors).
    body_body = (
        f'transform = Transform3D({c}, 0, {-s}, 0, 1, 0, {s}, 0, {c}, '
        f'{tx}, {ty}, {tz})\n'
        f'collision_layer = 1\n'
        f'collision_mask = 1\n'
    )
    scene.node(name, parent, "StaticBody3D", body_body)
    mi = f'mesh = SubResource("{mesh_id}")\n'
    if mat_id is not None:
        mi += f'surface_material_override/0 = ExtResource("{mat_id}")\n'
    scene.node("Mesh", f"{parent}/{name}", "MeshInstance3D", mi)
    scene.node("Col", f"{parent}/{name}", "CollisionShape3D",
               f'shape = SubResource("{shape_id}")\n')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("blueprint", help="path to the blueprint JSON")
    ap.add_argument("output", help="where to write the .tscn")
    ap.add_argument("--name", default="BuildingRoot",
                    help="name for the scene root Node3D")
    args = ap.parse_args()
    with open(args.blueprint) as f:
        blueprint = json.load(f)
    scene = build_scene(blueprint, args.name)
    with open(args.output, "w") as f:
        f.write(scene.format())
    print(f"wrote {args.output} — {len(scene.nodes)} nodes, "
          f"{len(scene.sub_resources)} subresources, "
          f"{len(scene.ext_resources)} ext resources")
    return 0


if __name__ == "__main__":
    sys.exit(main())
