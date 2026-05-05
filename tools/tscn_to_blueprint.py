#!/usr/bin/env python3
"""TSCN → blueprint extractor.

The hand-authored / procedurally-generated levels (grass_hub, mountain,
snow, water, lava, sand, sky, bowser) live as fully-realised .tscn
scenes — nothing in the human-editable JSON blueprint format the new
editor uses. This tool pulls the marker-style data out of those scenes
and writes a partial blueprint so authors can open the level in the
editor and start iterating without redoing every coin and goomba by
hand.

What we extract:

    - Top-level metadata: spawn_point, water_level_y, bgm.
    - Enemies: any node carrying `metadata/enemy_bhv = "..."`. Position
      derived from its `transform = Transform3D(...)` line.
    - Pickups: nodes with `metadata/pickup_kind = "..."`.
    - Warps: Area3D nodes with `metadata/warp_to = "..."`.

What we DON'T extract (the user must rebuild these in the editor):

    - Terrain mesh / heightmap. The original levels use freeform
      MeshInstance3D + StaticBody3D pairs that don't decompose into
      the editor's grid-based terrain_patches. The blueprint comes
      out with an empty `terrain_patches` list — drag a new one in
      the editor.
    - Rooms / walls. Same reason.
    - Pole/cannon objects.

Usage:

    python3 tools/tscn_to_blueprint.py godot/assets/levels/mountain.tscn \
        blueprints/imported/mountain.json

The resulting blueprint is structurally complete (every required key
is present) so the converter can immediately rebuild it back into a
.tscn — though the rebuild will be near-empty until the user adds
geometry. Markers, sky/env, bgm, water level all carry over.

We park the output under `blueprints/imported/` (NOT `blueprints/`)
so level_select doesn't pick it up and accidentally rebuild the
original .tscn into a marker-only stub. Move it up to `blueprints/`
once you've added enough terrain / rooms in the editor that you
want the JSON to BE the source of truth for that level.
"""
from __future__ import annotations
import argparse
import json
import re
import sys


# --------------------------------------------------------------------
# Lightweight TSCN parser. We don't need full Godot semantics — just
# the [node] sections, their transforms, and any metadata/* lines that
# follow each header.

NODE_RE = re.compile(
    r'^\[node\s+name="(?P<name>[^"]+)"'
    r'(?:\s+type="(?P<type>[^"]+)")?'
    r'(?:\s+parent="(?P<parent>[^"]*)")?'
    r'(?:\s+instance=ExtResource\("[^"]+"\))?'
    r'\s*\]\s*$'
)
TRANSFORM_RE = re.compile(
    r"^transform\s*=\s*Transform3D\(\s*"
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*"
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*"
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*"
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*\)\s*$"
)
POSITION_RE = re.compile(
    r"^position\s*=\s*Vector3\(\s*"
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*\)\s*$"
)
META_STRING_RE = re.compile(
    r'^metadata/(?P<key>\w+)\s*=\s*"(?P<value>[^"]*)"\s*$'
)
META_NUMBER_RE = re.compile(
    r"^metadata/(?P<key>\w+)\s*=\s*(?P<value>[-\d.eE+]+)\s*$"
)
META_VECTOR_RE = re.compile(
    r"^metadata/(?P<key>\w+)\s*=\s*Vector3\("
    r"([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\s*,\s*([-\d.eE+]+)\)\s*$"
)


class Node:
    def __init__(self, name: str, parent: str | None, type_: str) -> None:
        self.name = name
        self.parent = parent       # None for the root, "." or path otherwise
        self.type = type_
        self.position: tuple[float, float, float] | None = None
        self.transform_origin: tuple[float, float, float] | None = None
        self.metadata: dict = {}

    def world_pos(self, by_path: dict) -> tuple[float, float, float]:
        """Resolve world position by walking ancestors. We assume no
        rotation / scale on the parent chain — true for Godot levels
        emitted by build_from_blueprint.py and a reasonable
        approximation for everything else here."""
        local = self.transform_origin or self.position or (0.0, 0.0, 0.0)
        x, y, z = local
        # Walk up parents.
        p = self.parent
        while p and p != ".":
            anc = by_path.get(p)
            if anc is None:
                break
            ax, ay, az = (anc.transform_origin or anc.position or (0.0, 0.0, 0.0))
            x += ax; y += ay; z += az
            p = anc.parent
        return (x, y, z)


def parse_tscn(path: str) -> tuple[dict, list[Node]]:
    """Return (root_metadata, list_of_nodes). Nodes are in declaration
    order; each carries its parent path string ("." for scene root or
    a slash-delimited tree path)."""
    with open(path) as f:
        lines = f.readlines()
    root_meta: dict = {}
    nodes: list[Node] = []
    current: Node | None = None
    root_name: str | None = None
    for raw in lines:
        line = raw.rstrip("\n")
        if not line:
            continue
        m = NODE_RE.match(line)
        if m:
            current = Node(
                m.group("name"),
                m.group("parent"),
                m.group("type") or "",
            )
            if current.parent is None:
                root_name = current.name
            nodes.append(current)
            continue
        if current is None:
            continue
        mp = POSITION_RE.match(line)
        if mp:
            current.position = (float(mp.group(1)), float(mp.group(2)), float(mp.group(3)))
            continue
        mt = TRANSFORM_RE.match(line)
        if mt:
            # Transform3D(b00..b22, ox, oy, oz). Origin is the last 3.
            current.transform_origin = (float(mt.group(10)), float(mt.group(11)), float(mt.group(12)))
            continue
        ms = META_STRING_RE.match(line)
        if ms:
            current.metadata[ms.group("key")] = ms.group("value")
            continue
        mn = META_NUMBER_RE.match(line)
        if mn:
            current.metadata[mn.group("key")] = float(mn.group("value"))
            continue
        mv = META_VECTOR_RE.match(line)
        if mv:
            current.metadata[mv.group("key")] = [
                float(mv.group(2)), float(mv.group(3)), float(mv.group(4))
            ]
            continue
    if not nodes:
        return root_meta, []
    # Root metadata = metadata on the first (root) node.
    root_meta = dict(nodes[0].metadata)
    return root_meta, nodes


def build_path_index(nodes: list[Node]) -> tuple[str, dict[str, Node]]:
    """Return (root_name, dict mapping node-paths to Node instances).
    Path "." is the root; "Foo" is a direct child; "Foo/Bar" is a
    grandchild — same convention Godot uses."""
    if not nodes:
        return "", {}
    root = nodes[0]
    by_path: dict[str, Node] = {".": root}
    for n in nodes[1:]:
        if n.parent == ".":
            by_path[n.name] = n
        elif n.parent:
            by_path[f"{n.parent}/{n.name}"] = n
        else:
            by_path[n.name] = n
    return root.name, by_path


def extract(path_in: str, level_stem: str) -> dict:
    root_meta, nodes = parse_tscn(path_in)
    _root_name, by_path = build_path_index(nodes)

    bp: dict = {
        "_doc": (
            f"Imported from {path_in.split('/')[-1]}. Markers (enemies, "
            "pickups, warps) carried over; geometry was not — drag in "
            "terrain / rooms in the blueprint editor."
        ),
        "standalone_level": True,
        "spawn_point": list(root_meta.get("spawn_point", [0, 1, 0])),
        "materials": {
            "brick":  "res://assets/materials/brick_stone.tres",
            "floor":  "res://assets/materials/stone_grey.tres",
            "wood":   "res://assets/materials/wood_dark.tres",
            "metal":  "res://assets/materials/metal_grey.tres",
            "gold":   "res://assets/materials/gold.tres",
        },
        "wall_thickness": 0.4,
        "rooms": [],
        "connectors": [],
        "locks": [],
        "keys": [],
        "blocks": [],
        "extras": [],
        "terrain_patches": [],
        "enemies": [],
        "pickups": [],
        "volumes": [],
        "warps": [],
    }
    if "water_level_y" in root_meta:
        bp["water_level_y"] = float(root_meta["water_level_y"])
    if "bgm" in root_meta:
        bp["bgm"] = str(root_meta["bgm"])

    enemy_count = pickup_count = warp_count = 0
    for n in nodes:
        if n is nodes[0]:
            continue   # skip root
        meta = n.metadata
        wx, wy, wz = n.world_pos(by_path)
        if "enemy_bhv" in meta:
            entry = {
                "name": n.name,
                "bhv": str(meta["enemy_bhv"]),
                "pos": [wx, wy, wz],
            }
            if "enemy_patrol_radius" in meta:
                entry["patrol_radius"] = float(meta["enemy_patrol_radius"])
            bp["enemies"].append(entry)
            enemy_count += 1
        if "pickup_kind" in meta:
            bp["pickups"].append({
                "name": n.name,
                "kind": str(meta["pickup_kind"]),
                "pos": [wx, wy, wz],
            })
            pickup_count += 1
        if "warp_to" in meta:
            entry = {
                "name": n.name,
                "target_level": str(meta["warp_to"]),
                "pos": [wx, wy, wz],
                "size": [2.5, 3.0, 0.4],
            }
            if "requires_stars" in meta:
                entry["requires_stars"] = int(float(meta["requires_stars"]))
            if "lock_key" in meta:
                entry["requires_key"] = str(meta["lock_key"])
            bp["warps"].append(entry)
            warp_count += 1

    print(
        f"Extracted from {path_in}: "
        f"{enemy_count} enemies, {pickup_count} pickups, {warp_count} warps"
    )
    return bp


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tscn_in")
    ap.add_argument("json_out")
    args = ap.parse_args()
    stem = args.tscn_in.split("/")[-1].rsplit(".", 1)[0]
    bp = extract(args.tscn_in, stem)
    with open(args.json_out, "w") as f:
        json.dump(bp, f, indent=2, sort_keys=True)
    print(f"wrote {args.json_out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
