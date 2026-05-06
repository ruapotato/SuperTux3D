#!/usr/bin/env python3
"""Author the eight themed worlds + a proper Mario-castle hub as
JSON blueprints.

Design goals:
- Hub: multi-room castle (foyer + east/west wings + upper hall +
  basement). Painting-warps are scattered across rooms so the player
  has to explore. Star-gates escalate.
- Each themed world has 5+ stars placed at LANDMARKS that require
  platforming to reach — peaks, gap-jumps, swim dives, jump puzzles
  across lava, hidden alcoves. Not just "scatter on flat ground".
- Stars carry STABLE NAMES so save progress survives a rebuild.

Run:

    python3 tools/build_initial_levels.py
    for f in blueprints/{grass_hub,mountain,snow,water,lava,sand,sky,bowser}.json; do
        python3 tools/build_from_blueprint.py "$f" \
            "godot/assets/levels/$(basename ${f%.json}).tscn"
    done
"""
from __future__ import annotations
import json
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BP_DIR = os.path.join(ROOT, "blueprints")
IMPORTED_DIR = os.path.join(BP_DIR, "imported")

DEFAULT_MATERIALS = {
    "brick":  "res://assets/materials/brick_stone.tres",
    "floor":  "res://assets/materials/stone_grey.tres",
    "floor2": "res://assets/materials/wood_planks.tres",
    "wood":   "res://assets/materials/wood_dark.tres",
    "red":    "res://assets/materials/fabric_red.tres",
    "metal":  "res://assets/materials/metal_grey.tres",
    "gold":   "res://assets/materials/gold.tres",
}


# ---- helpers --------------------------------------------------------

def base_blueprint(doc: str) -> dict:
    return {
        "_doc": doc, "standalone_level": True,
        "spawn_point": [0, 1, 0],
        "materials": dict(DEFAULT_MATERIALS), "wall_thickness": 0.4,
        "rooms": [], "connectors": [], "locks": [], "keys": [],
        "blocks": [], "extras": [], "terrain_patches": [],
        "enemies": [], "pickups": [], "volumes": [], "warps": [],
    }


def heightmap(size_x: float, size_z: float, res: int, fn) -> list[float]:
    cx = size_x / float(res - 1); cz = size_z / float(res - 1)
    return [float(fn(i * cx, j * cz)) for i in range(res) for j in range(res)]


def paint(size_x: float, size_z: float, res: int, fn) -> list[str]:
    cx = size_x / float(res - 1); cz = size_z / float(res - 1)
    out = []
    for ci in range(res - 1):
        for cj in range(res - 1):
            x = (ci + 0.5) * cx; z = (cj + 0.5) * cz
            out.append(str(fn(x, z)))
    return out


def add_terrain(bp, *, origin, size_x, size_z, res, heights,
                surface_grid=None, flat_color=None, slope_color=None):
    patch = {
        "name": "Ground",
        "origin": origin, "size_x": size_x, "size_z": size_z,
        "resolution": res, "heights": heights,
        "surface_grid": surface_grid or [""] * ((res - 1) * (res - 1)),
        "material": "",
    }
    if flat_color: patch["flat_color"] = list(flat_color)
    if slope_color: patch["slope_color"] = list(slope_color)
    bp["terrain_patches"].append(patch)


def sample_height(bp, wx, wz):
    if not bp["terrain_patches"]:
        return 0.0
    p = bp["terrain_patches"][0]
    ox, oy, oz = p["origin"]
    sx = float(p["size_x"]); sz = float(p["size_z"])
    res = int(p["resolution"])
    lx = wx - ox; lz = wz - oz
    if not (0 <= lx <= sx and 0 <= lz <= sz):
        return float(oy)
    cx = sx / float(res - 1); cz = sz / float(res - 1)
    i = max(0, min(res - 1, int(round(lx / cx))))
    j = max(0, min(res - 1, int(round(lz / cz))))
    return float(oy) + float(p["heights"][i * res + j])


def add_star(bp, name, x, z, *, world_y=None, y_offset=1.5):
    y = world_y if world_y is not None else sample_height(bp, x, z) + y_offset
    bp["pickups"].append({"name": name, "kind": "star", "pos": [x, y, z]})


def add_coin_line(bp, prefix, ax, az, bx, bz, n=8, world_y=None, y_offset=1.0):
    """Drop a row of yellow coins along a line — used to mark
    platforming paths so the player knows where to jump next."""
    for k in range(n):
        t = (k + 1) / float(n + 1)
        x = ax + (bx - ax) * t
        z = az + (bz - az) * t
        y = world_y if world_y is not None else sample_height(bp, x, z) + y_offset
        bp["pickups"].append({
            "name": f"{prefix}{k}", "kind": "coin_yellow",
            "pos": [x, y, z],
        })


def add_coin_ring(bp, prefix, cx, cz, radius=4.0, n=6,
                  world_y=None, y_offset=1.0):
    for k in range(n):
        ang = 2.0 * math.pi * k / n
        x = cx + radius * math.cos(ang); z = cz + radius * math.sin(ang)
        y = world_y if world_y is not None else sample_height(bp, x, z) + y_offset
        bp["pickups"].append({
            "name": f"{prefix}{k}", "kind": "coin_yellow",
            "pos": [x, y, z],
        })


def add_platform(bp, name, x, y, z, sx=4.0, sz=4.0, sy=0.4, mat="floor"):
    bp["extras"].append({
        "type": "platform", "name": name,
        "pos": [x - sx * 0.5, y, z - sz * 0.5],
        "size": [sx, sy, sz], "material": mat,
    })


def add_pillar(bp, name, x, z, *, radius=0.4, height=4.0, mat="wood"):
    y = sample_height(bp, x, z)
    bp["extras"].append({
        "type": "pillar", "name": name,
        "pos": [x, y, z], "radius": radius, "height": height, "material": mat,
    })


def merge_imported_minus_stars(bp, level, lift=0.4):
    """Bring in enemies + non-star pickups from the marker extraction.
    Lifts onto current terrain with a small offset above."""
    src_path = os.path.join(IMPORTED_DIR, f"{level}.json")
    if not os.path.exists(src_path):
        return
    src = json.load(open(src_path))
    for e in src.get("enemies", []):
        p = e.get("pos", [0, 0, 0])
        wx, _, wz = float(p[0]), float(p[1]), float(p[2])
        wy = sample_height(bp, wx, wz) + lift
        entry = dict(e); entry["pos"] = [wx, wy, wz]
        bp["enemies"].append(entry)
    for pk in src.get("pickups", []):
        if str(pk.get("kind", "")) == "star":
            continue
        p = pk.get("pos", [0, 0, 0])
        wx, _, wz = float(p[0]), float(p[1]), float(p[2])
        wy = sample_height(bp, wx, wz) + 1.2
        entry = dict(pk); entry["pos"] = [wx, wy, wz]
        bp["pickups"].append(entry)
    if "water_level_y" in src and "water_level_y" not in bp:
        bp["water_level_y"] = src["water_level_y"]


# ---- HUB: a real multi-room castle ----------------------------------

def make_grass_hub() -> dict:
    """Castle interior + south courtyard. Foyer connects to east/west
    wings via doors; each wing holds a couple of painting-warps. A
    spiral stair from the foyer reaches an upper hall (sand + sky).
    A second stair drops to a basement (bowser). Painting-warps are
    progressively star-gated; the doors themselves are open."""
    bp = base_blueprint("Castle hub. Walk into a painting to enter that world.")
    bp["spawn_point"] = [0, 2, 30]
    bp["bgm"] = "bgm_castle"
    bp["sky"] = {
        "horizon_color": [0.55, 0.78, 0.95],
        "ambient_color": [0.85, 0.90, 0.95],
        "ambient_energy": 0.85,
    }
    # Outdoor terrain: gentle hills around a flat south courtyard.
    SX, SZ, R = 200.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h - 30
        plaza = max(0.0, 1.0 - math.hypot(dx, dz) / 22.0)
        rolling = 0.5 * math.sin(x * 0.06) * math.cos(z * 0.05)
        return rolling * (1.0 - plaza)
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h))

    # ---- castle interior ------------------------------------------
    # Foyer: 24×20 at the origin, two storeys tall (so the spiral
    # stair has room to land in the upper hall).
    bp["rooms"].append({
        "name": "Foyer", "origin": [-12, 0, -10], "size": [24, 12, 20],
        "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [
                {"type": "door", "x": 10.5, "width": 3, "height": 4},
            ]},
            "east": {"openings": [
                {"type": "door", "x": 14, "width": 3, "height": 4},
                {"type": "window", "x": 4, "width": 1.5, "height": 2, "sill": 3},
                {"type": "window", "x": 7, "width": 1.5, "height": 2, "sill": 3},
            ]},
            "west": {"openings": [
                {"type": "door", "x": 14, "width": 3, "height": 4},
                {"type": "window", "x": 4, "width": 1.5, "height": 2, "sill": 3},
                {"type": "window", "x": 7, "width": 1.5, "height": 2, "sill": 3},
            ]},
            "north": {"openings": [
                {"type": "window", "x": 10.5, "width": 2, "height": 2.5, "sill": 6},
            ]},
        },
    })
    # West wing — mountain + snow paintings live here (low star reqs).
    bp["rooms"].append({
        "name": "WestWing", "origin": [-32, 0, -8], "size": [20, 8, 16],
        "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [
                {"type": "window", "x": 9, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "east": {"openings": [
                {"type": "door", "x": 6, "width": 3, "height": 4},
            ]},
            "west": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "north": {"openings": []},
        },
    })
    # East wing — water + lava (mid star reqs).
    bp["rooms"].append({
        "name": "EastWing", "origin": [12, 0, -8], "size": [20, 8, 16],
        "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [
                {"type": "window", "x": 9, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "west": {"openings": [
                {"type": "door", "x": 6, "width": 3, "height": 4},
            ]},
            "east": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "north": {"openings": []},
        },
    })
    # Upper hall — accessed by the spiral stair from the foyer. Holds
    # the sand + sky paintings (high star reqs).
    bp["rooms"].append({
        "name": "UpperHall", "origin": [-10, 12, -8], "size": [20, 8, 16],
        "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [
                {"type": "window", "x": 9, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "east": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "west": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "north": {"openings": []},
        },
    })
    # Basement — a smaller chamber under the foyer, reached by a
    # straight stair going down. Bowser painting (50★).
    bp["rooms"].append({
        "name": "Basement", "origin": [-8, -8, -6], "size": [16, 8, 12],
        "material": "brick", "floor_material": "floor", "ceiling": True,
        "walls": {
            "south": {"openings": []},
            "east":  {"openings": []},
            "west":  {"openings": []},
            "north": {"openings": []},
        },
    })

    # Stairs — spiral up to UpperHall, straight stair down to Basement.
    bp["extras"].append({
        "type": "spiral_stair", "name": "FoyerSpiral",
        "pos": [6, 0, 0],
        "steps": 24, "rise": 0.5, "radius": 2.5, "width": 1.6,
        "depth": 0.6, "angle": 0.32, "material": "floor",
        "punch_through": "UpperHall",
    })
    # The stair climbs UP from the basement floor to the foyer floor;
    # walking DOWN it from the foyer is how the player descends.
    # punch_through tells the converter to cut a hole in the foyer
    # floor (and the basement ceiling, since they share the y=0 plane).
    bp["extras"].append({
        "type": "stair", "name": "BasementStair",
        "pos": [-8, -8, 0], "direction": "+x",
        "steps": 16, "rise": 0.5, "run": 0.55, "width": 2.5,
        "material": "floor",
        "punch_through": "Foyer",
    })

    # Painting-warps. Star reqs escalate; first two are accessible
    # with zero stars so the player has somewhere to start.
    PAINTINGS = [
        # (name, target,    x,    y,    z, side,    stars)
        ("ToMountain", "mountain", -28.0, 1.5, -3.0, +1, 0),
        ("ToSnow",     "snow",     -28.0, 1.5,  3.0, +1, 1),
        ("ToWater",    "water",     28.0, 1.5, -3.0, -1, 3),
        ("ToLava",     "lava",      28.0, 1.5,  3.0, -1, 6),
        ("ToSand",     "sand",      -8.0, 13.5, -3.0, +1, 12),
        ("ToSky",      "sky",        8.0, 13.5,  3.0, -1, 25),
        ("ToBowser",   "bowser",    -4.0, -6.5, 0.0, +1, 50),
    ]
    for name, target, wx, wy, wz, side, star_req in PAINTINGS:
        bp["warps"].append({
            "name": name, "target_level": target,
            "pos": [wx, wy, wz],
            "size": [3.5, 4.0, 0.4],
            "requires_stars": star_req,
        })
    # Welcome star on top of the foyer (visible through the courtyard).
    add_star(bp, "HubWelcome", 0, -8, world_y=12.5)
    return bp


# ---- MOUNTAIN: spiral platform climb -------------------------------

def make_mountain() -> dict:
    bp = base_blueprint("Mountain: spiral climb to the peak. Five stars.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.78, 0.85, 0.95],
        "ambient_color": [0.78, 0.80, 0.85],
        "ambient_energy": 0.75,
    }
    SX, SZ, R = 180.0, 180.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        peak = 24.0 * max(0.0, 1.0 - r / 70.0) ** 1.8
        noise = 0.6 * math.sin(x * 0.27) + 0.4 * math.cos(z * 0.31)
        return peak + noise
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                slope_color=[0.45, 0.30, 0.20])
    # Helical platform path. Eight stepping stones spiraling up the
    # mountain — each is reachable from the previous via a single
    # jump, but the LAST one is a long-jump candidate to the peak.
    PATH = []
    for k in range(8):
        ang = k * 0.85
        r = 30.0 - k * 2.5
        x = cx_h + r * math.cos(ang) - cx_h
        z = cz_h + r * math.sin(ang) - cz_h
        y = sample_height(bp, x, z) + 0.5 + k * 1.8
        add_platform(bp, f"Climb{k}", x, y, z, sx=3.0, sz=3.0, mat="floor")
        PATH.append((x, y, z))
        if k > 0:
            ax, ay, az = PATH[k - 1]
            add_coin_line(bp, f"Trail{k}", ax, az, x, z, n=3,
                          world_y=(ay + y) * 0.5 + 0.8)
    # Stars: peak (top of cone), one mid-climb (platform 4), one
    # behind a far ridge, one in a hidden alcove on the back side,
    # one at the base behind a pillar.
    add_star(bp, "MountainPeak", 0, 0, y_offset=2.5)
    px, py, pz = PATH[4]
    add_star(bp, "MidwayClimb", px, pz, world_y=py + 1.5)
    add_star(bp, "RidgeBack", -28, -22, y_offset=2.0)
    add_star(bp, "HiddenAlcove", 25, -28, y_offset=2.0)
    add_star(bp, "BasePillar", -10, 50)
    # A few decorative pillars at the base — could double as
    # platforming if the player jumps on them.
    for i, (x, z) in enumerate([(-15, 40), (15, 40), (-25, 25), (25, 25)]):
        add_pillar(bp, f"BasePillar{i}", x, z, height=4.0)
    merge_imported_minus_stars(bp, "mountain")
    return bp


# ---- SNOW: ice-platform traverse -----------------------------------

def make_snow() -> dict:
    bp = base_blueprint("Snow: traverse drift platforms. Slip and you slide back.")
    bp["spawn_point"] = [0, 2, 50]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.85, 0.92, 1.00],
        "ambient_color": [0.92, 0.95, 1.00],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        return (3.5 * math.sin(x * 0.08) * math.cos(z * 0.06)
                + 2.0 * math.sin(z * 0.04))
    def kind(x, z):
        if math.hypot(x - cx_h, z - cz_h - 50) < 8.0:
            return ""           # spawn pad
        return "snow"
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.85, 0.92, 0.95])
    # Series of safe ice platforms across the drifts. Each platform
    # is a NON-painted rect (default surface_kind=""), so jumping
    # between them gives the player solid footing while the ground
    # below is slippery.
    PLATS = [
        (0, 5, 30), (-8, 7, 18), (8, 8, 6), (-4, 10, -8),
        (10, 12, -22), (-12, 14, -36), (4, 16, -50),
    ]
    for i, (x, y, z) in enumerate(PLATS):
        add_platform(bp, f"Drift{i}", x, y, z, sx=4.0, sz=4.0, mat="floor")
    # Stars on alternating platforms (1, 3, 5) plus far-base + hidden.
    for k in [1, 3, 5]:
        x, y, z = PLATS[k]
        add_star(bp, f"DriftStar{k}", x, z, world_y=y + 1.5)
    add_star(bp, "FarBase", 30, -50)
    add_star(bp, "HiddenWest", -40, 20)
    merge_imported_minus_stars(bp, "snow")
    return bp


# ---- WATER: dive for stars -----------------------------------------

def make_water() -> dict:
    bp = base_blueprint("Water: lake with islands. Dive to the bottom for the deep star.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_water"
    bp["sky"] = {
        "horizon_color": [0.55, 0.78, 0.95],
        "ambient_color": [0.78, 0.88, 0.95],
        "ambient_energy": 0.80,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    ISLANDS = [(-15, -15), (15, 18), (-22, 20), (24, -10)]
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        basin = -3.5 * max(0.0, 1.0 - r / 60.0)
        bank = 1.2 * min(1.0, max(0.0, (r - 60.0) / 30.0))
        for ix, iz in ISLANDS:
            d = math.hypot(x - cx_h - ix, z - cz_h - iz)
            if d < 6.0:
                bank += (6.0 - d) * 0.6
        return basin + bank
    def kind(x, z):
        dx = x - cx_h; dz = z - cz_h
        if math.hypot(dx, dz) < 55.0 and h(x, z) < -0.5:
            return "water"
        return ""
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind))
    # One platform floating above the centre of the lake — long jump
    # target from any island.
    add_platform(bp, "FloatingDeck", 0, 4, 0, sx=5.0, sz=5.0)
    # Stars: deck (jump from islands), each island top, deep basin.
    add_star(bp, "FloatingDeckStar", 0, 0, world_y=5.5)
    for k, (ix, iz) in enumerate(ISLANDS):
        add_star(bp, f"Island{k}", ix, iz, y_offset=2.0)
    add_star(bp, "DeepBasin", 5, 0, world_y=-2.0)
    merge_imported_minus_stars(bp, "water")
    return bp


# ---- LAVA: jump puzzle across magma --------------------------------

def make_lava() -> dict:
    bp = base_blueprint("Lava: chain platforms across the magma. Miss = bounce + damage.")
    bp["spawn_point"] = [0, 2, 50]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.45, 0.18, 0.10],
        "ambient_color": [0.85, 0.45, 0.20],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 200.0, 200.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        rim = 2.0 * max(0.0, (r - 70.0) / 30.0)
        floor = -1.5 if r < 70.0 else 0.0
        return floor + rim
    def kind(x, z):
        dx = x - cx_h; dz = z - cz_h
        if math.hypot(dx, dz) < 65.0 and h(x, z) < -0.3:
            return "burning"
        return ""
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.35, 0.20, 0.15])
    # Jump puzzle: 8 stone platforms in a curving path from the
    # south rim across the lava pit to a big island in the middle,
    # then on to the far north rim. Each gap is a single jump.
    PUZZLE = [
        (0, 0, 50),  (5, 0, 40), (-5, 0, 30), (0, 0, 20),
        (10, 1, 10), (-10, 2, 0), (5, 3, -10), (0, 4, -25),
    ]
    for i, (x, y, z) in enumerate(PUZZLE):
        add_platform(bp, f"Stone{i}", x, y, z, sx=3.0, sz=3.0)
    # Big landing platform near the back of the pit.
    add_platform(bp, "FarPlat", 0, 5, -45, sx=8.0, sz=8.0)
    # Coins between platforms guide the route.
    for i in range(len(PUZZLE) - 1):
        ax, ay, az = PUZZLE[i]; bx, by, bz = PUZZLE[i + 1]
        add_coin_line(bp, f"Trail{i}", ax, az, bx, bz, n=3,
                      world_y=(ay + by) * 0.5 + 1.5)
    # Stars: a few in the middle of the chain (rewarding progress),
    # one on the far landing, one in a side island.
    add_star(bp, "FirstStone", 0, 50, world_y=1.5)
    add_star(bp, "MidChain", 10, 10, world_y=2.5)
    add_star(bp, "FarLanding", 0, -45, world_y=6.5)
    add_star(bp, "SideIsland", -25, 0, y_offset=2.0)
    add_star(bp, "Crater", 0, 0, world_y=-0.5)  # in the lava — risky!
    merge_imported_minus_stars(bp, "lava")
    return bp


# ---- SAND: pyramid climb -------------------------------------------

def make_sand() -> dict:
    bp = base_blueprint("Sand: dunes around a stepped pyramid. Climb the stairs inside.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.96, 0.84, 0.55],
        "ambient_color": [1.00, 0.92, 0.70],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    QUICK = [(-15, -10), (20, 5), (-5, 25)]
    def h(x, z):
        return (2.5 * math.sin(x * 0.05 + z * 0.03)
                + 1.2 * math.cos(z * 0.09))
    def kind(x, z):
        for ix, iz in QUICK:
            if math.hypot(x - cx_h - ix, z - cz_h - iz) < 5.0:
                return "shallow_quicksand"
        return "sand"
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.92, 0.80, 0.45])
    # Pyramid: stepped tiers via stacking platforms of decreasing size.
    for i in range(6):
        size = 14.0 - i * 2.0
        add_platform(bp, f"PyramidTier{i}", 0, i * 2.0, -10,
                     sx=size, sz=size, mat="brick")
    # Stars: top of pyramid (climb), each quicksand pit's safe ridge,
    # two off in the dunes.
    add_star(bp, "PyramidPeak", 0, -10, world_y=12.5)
    add_star(bp, "PyramidNorth", 0, -40)
    for k, (qx, qz) in enumerate(QUICK):
        add_star(bp, f"QuickEdge{k}", qx + 6, qz)
    merge_imported_minus_stars(bp, "sand")
    return bp


# ---- SKY: vertical platform climb ---------------------------------

def make_sky() -> dict:
    bp = base_blueprint("Sky: vertical climb. Each platform is a leap of faith.")
    bp["spawn_point"] = [0, 2, 35]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.45, 0.65, 0.95],
        "ambient_color": [0.85, 0.92, 1.00],
        "ambient_energy": 1.00,
    }
    SX, SZ, R = 140.0, 140.0, 192
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        return max(0.0, 1.5 - r / 50.0)
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                flat_color=[0.95, 0.97, 1.00])
    # Tall vertical climb of small platforms. Each pair is offset
    # horizontally so the player has to time double-jumps.
    PLATS = []
    for k in range(12):
        offset = (-1 if k % 2 == 0 else 1) * (4.0 + 0.4 * k)
        x = offset; z = -k * 4.5
        y = 4.0 + k * 2.5
        size = max(2.5, 4.0 - 0.15 * k)   # platforms shrink as you climb
        add_platform(bp, f"Climb{k}", x, y, z, sx=size, sz=size)
        PLATS.append((x, y, z))
    # Top reward platform.
    tx, ty, tz = PLATS[-1][0] + 4, PLATS[-1][1] + 2.5, PLATS[-1][2] - 2.0
    add_platform(bp, "Apex", tx, ty, tz, sx=6.0, sz=6.0, mat="gold")
    # Stars: every fourth platform plus the apex and a hidden one
    # under the spawn cloud.
    for k in [3, 7, 11]:
        x, y, z = PLATS[k]
        add_star(bp, f"ClimbStar{k}", x, z, world_y=y + 1.5)
    add_star(bp, "ApexReward", tx, tz, world_y=ty + 1.5)
    add_star(bp, "CloudHidden", 0, 30)
    merge_imported_minus_stars(bp, "sky")
    return bp


# ---- BOWSER: castle interior with traps ---------------------------

def make_bowser() -> dict:
    bp = base_blueprint("Bowser's keep: lava moat, multi-storey tower, crown at the top.")
    bp["spawn_point"] = [0, 2, 30]
    bp["bgm"] = "bgm_bowser"
    bp["sky"] = {
        "horizon_color": [0.18, 0.12, 0.20],
        "ambient_color": [0.55, 0.40, 0.45],
        "ambient_energy": 0.55,
    }
    SX, SZ, R = 100.0, 140.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        if r < 18.0: return 1.5
        if r < 35.0: return -2.0
        return 0.0
    def kind(x, z):
        r = math.hypot(x - cx_h, z - cz_h)
        if 18.0 < r < 35.0: return "burning"
        return ""
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.32, 0.25, 0.30])
    # Series of stepping platforms across the lava moat (south side).
    for i, (x, z) in enumerate([(-3, -32), (3, -28), (-2, -24), (2, -22)]):
        add_platform(bp, f"MoatStep{i}", x, 1.0 + i * 0.1, z,
                     sx=2.5, sz=2.5, mat="floor")
    # Tower: ground room + upper room + spiral connector.
    bp["rooms"].append({
        "name": "KeepGround", "origin": [-12, 1.5, -12],
        "size": [24, 6, 24], "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [{"type": "door", "x": 10.5, "width": 3, "height": 4}]},
            "north": {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
            "east": {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
            "west": {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
        },
    })
    bp["rooms"].append({
        "name": "KeepUpper", "origin": [-10, 7.5, -10],
        "size": [20, 6, 20], "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [{"type": "window", "x": 8.5, "width": 1.5, "height": 2, "sill": 2}]},
            "north": {"openings": [{"type": "window", "x": 8.5, "width": 1.5, "height": 2, "sill": 2}]},
            "east":  {"openings": [{"type": "window", "x": 8.5, "width": 1.5, "height": 2, "sill": 2}]},
            "west":  {"openings": [{"type": "window", "x": 8.5, "width": 1.5, "height": 2, "sill": 2}]},
        },
    })
    bp["extras"].append({
        "type": "spiral_stair", "name": "KeepSpiral",
        "pos": [0.0, 1.5, 0.0],
        "steps": 20, "rise": 0.3, "radius": 2.0, "width": 1.6,
        "depth": 0.6, "angle": 0.42, "material": "floor",
        "punch_through": "KeepUpper",
    })
    # Decorative pillars in the keep ground floor.
    for i, (x, z) in enumerate([(-7, -7), (7, -7), (-7, 7), (7, 7)]):
        add_pillar(bp, f"KeepPillar{i}", x, z, height=5.5)
    # Stars: top of the spiral (BowserCrown), hidden behind one
    # pillar, on a moat platform reward.
    add_star(bp, "BowserCrown", 0, 0, world_y=14.0)
    add_star(bp, "BehindPillar", -7, 7, world_y=2.5)
    add_star(bp, "MoatReward", 0, -25, world_y=1.5)
    merge_imported_minus_stars(bp, "bowser")
    return bp


# ---- main ----------------------------------------------------------

LEVELS = [
    ("grass_hub", make_grass_hub),
    ("mountain",  make_mountain),
    ("snow",      make_snow),
    ("water",     make_water),
    ("lava",      make_lava),
    ("sand",      make_sand),
    ("sky",       make_sky),
    ("bowser",    make_bowser),
]


def main() -> int:
    for name, builder in LEVELS:
        bp = builder()
        path = os.path.join(BP_DIR, f"{name}.json")
        with open(path, "w") as f:
            json.dump(bp, f, indent=2, sort_keys=True)
        n_rooms = len(bp["rooms"])
        n_extras = len(bp["extras"])
        n_enemy = len(bp["enemies"])
        n_star = sum(1 for p in bp["pickups"] if p.get("kind") == "star")
        n_warp = len(bp["warps"])
        print(f"{name:<10} → {path}  "
              f"(rooms {n_rooms}, extras {n_extras}, enemies {n_enemy}, "
              f"stars {n_star}, warps {n_warp})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
