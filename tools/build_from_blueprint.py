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


def build_scene(blueprint: dict, scene_name: str) -> Scene:
    scene = Scene()
    root_body = ""
    if "spawn_point" in blueprint:
        sp = blueprint["spawn_point"]
        root_body = f'metadata/spawn_point = {vec(sp[0], sp[1], sp[2])}\n'
    scene.node(scene_name, None, "Node3D", root_body)
    # When requested, inject a basic Environment + Sun so the scene
    # loads as a standalone playable level. Without this the blueprint
    # output is just geometry — no lighting, black ambient.
    if blueprint.get("standalone_level", False):
        env_body = (
            'background_mode = 1\n'
            'background_color = Color(0.52, 0.75, 0.98, 1)\n'
            'ambient_light_source = 2\n'
            'ambient_light_color = Color(0.8, 0.82, 0.78, 1)\n'
            'ambient_light_energy = 0.8\n'
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

        # Floor slab. If `floor_holes` is defined, split the plate into
        # four border strips around the hole so the hole is a real
        # open shaft (not a CSG subtract that can drift). Multiple
        # holes would need a proper partitioner; one hole covers
        # atrium / stair shaft / elevator well cases.
        if room.get("floor", True):
            holes = room.get("floor_holes", [])
            if not holes:
                emit_box(scene, room_parent, "Floor",
                         (sx / 2.0, -0.1, sz / 2.0),
                         (sx, 0.2, sz), floor_mat)
            else:
                hole = holes[0]
                hx0 = float(hole["x"])
                hz0 = float(hole["z"])
                hw = float(hole["width"])
                hd = float(hole["depth"])
                hx1 = hx0 + hw
                hz1 = hz0 + hd
                # South strip (z < hz0).
                if hz0 > 0:
                    emit_box(scene, room_parent, "Floor_S",
                             (sx / 2.0, -0.1, hz0 / 2.0),
                             (sx, 0.2, hz0), floor_mat)
                # North strip (z > hz1).
                if hz1 < sz:
                    emit_box(scene, room_parent, "Floor_N",
                             (sx / 2.0, -0.1, (hz1 + sz) / 2.0),
                             (sx, 0.2, sz - hz1), floor_mat)
                # West strip (x < hx0), Z only across the hole band.
                if hx0 > 0:
                    emit_box(scene, room_parent, "Floor_W",
                             (hx0 / 2.0, -0.1, (hz0 + hz1) / 2.0),
                             (hx0, 0.2, hz1 - hz0), floor_mat)
                # East strip (x > hx1).
                if hx1 < sx:
                    emit_box(scene, room_parent, "Floor_E",
                             ((hx1 + sx) / 2.0, -0.1, (hz0 + hz1) / 2.0),
                             (sx - hx1, 0.2, hz1 - hz0), floor_mat)
        # Ceiling — thin box on top. Same hole logic when requested.
        if room.get("ceiling", True):
            c_holes = room.get("ceiling_holes", [])
            if not c_holes:
                emit_box(scene, room_parent, "Ceiling",
                         (sx / 2.0, sy + 0.1, sz / 2.0),
                         (sx, 0.2, sz), room_mat)
            else:
                hole = c_holes[0]
                hx0 = float(hole["x"]); hz0 = float(hole["z"])
                hw = float(hole["width"]); hd = float(hole["depth"])
                hx1 = hx0 + hw; hz1 = hz0 + hd
                if hz0 > 0:
                    emit_box(scene, room_parent, "Ceil_S",
                             (sx / 2.0, sy + 0.1, hz0 / 2.0),
                             (sx, 0.2, hz0), room_mat)
                if hz1 < sz:
                    emit_box(scene, room_parent, "Ceil_N",
                             (sx / 2.0, sy + 0.1, (hz1 + sz) / 2.0),
                             (sx, 0.2, sz - hz1), room_mat)
                if hx0 > 0:
                    emit_box(scene, room_parent, "Ceil_W",
                             (hx0 / 2.0, sy + 0.1, (hz0 + hz1) / 2.0),
                             (hx0, 0.2, hz1 - hz0), room_mat)
                if hx1 < sx:
                    emit_box(scene, room_parent, "Ceil_E",
                             ((hx1 + sx) / 2.0, sy + 0.1, (hz0 + hz1) / 2.0),
                             (sx - hx1, 0.2, hz1 - hz0), room_mat)

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
            rise = float(extra.get("rise", 0.4))
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
            rise = float(extra.get("rise", 0.35))
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
