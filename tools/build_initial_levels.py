#!/usr/bin/env python3
"""Author the eight themed worlds + hub as JSON blueprints.

Design goals (after the first marker-only pass):

- One coherent hub level (`grass_hub`) with named warp doors to each
  themed world. Warps are progressively star-gated: snow needs 1,
  water 3, lava 6, sand 12, sky 25, bowser 50.
- Multiple stars per themed world (5-7), placed at distinctive spots
  (peak / island / hidden lava platform / etc.) so collecting them is
  a small navigation puzzle, not just walking to one waypoint.
- Stars carry STABLE NAMES across levels (the save_data.collected_stars
  map keys on level + name) so a regen here doesn't lose progress —
  unless we add or rename stars.
- Sky / bgm / water_level_y per theme.
- Less reliance on imported markers: we keep enemies + non-star
  pickups from the imported set, but stars come from this script so
  positions are intentional.

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


def base_blueprint(doc: str) -> dict:
    return {
        "_doc": doc,
        "standalone_level": True,
        "spawn_point": [0, 1, 0],
        "materials": dict(DEFAULT_MATERIALS),
        "wall_thickness": 0.4,
        "rooms": [], "connectors": [], "locks": [], "keys": [],
        "blocks": [], "extras": [], "terrain_patches": [],
        "enemies": [], "pickups": [], "volumes": [], "warps": [],
    }


def heightmap(size_x: float, size_z: float, res: int, fn) -> list[float]:
    cx = size_x / float(res - 1)
    cz = size_z / float(res - 1)
    out = []
    for i in range(res):
        for j in range(res):
            out.append(float(fn(i * cx, j * cz)))
    return out


def paint(size_x: float, size_z: float, res: int, fn) -> list[str]:
    cx = size_x / float(res - 1)
    cz = size_z / float(res - 1)
    out = []
    for ci in range(res - 1):
        for cj in range(res - 1):
            x = (ci + 0.5) * cx
            z = (cj + 0.5) * cz
            out.append(str(fn(x, z)))
    return out


def add_terrain(bp: dict, *, origin: list[float],
                size_x: float, size_z: float, res: int,
                heights: list[float],
                surface_grid: list[str] | None = None,
                flat_color=None, slope_color=None) -> None:
    patch = {
        "name": "Ground",
        "origin": origin,
        "size_x": size_x, "size_z": size_z, "resolution": res,
        "heights": heights,
        "surface_grid": surface_grid or [""] * ((res - 1) * (res - 1)),
        "material": "",
    }
    if flat_color: patch["flat_color"] = list(flat_color)
    if slope_color: patch["slope_color"] = list(slope_color)
    bp["terrain_patches"].append(patch)


def sample_height(bp: dict, wx: float, wz: float) -> float:
    """Look up the height of the (single) terrain patch at world xz."""
    if not bp["terrain_patches"]:
        return 0.0
    p = bp["terrain_patches"][0]
    ox, oy, oz = p["origin"]
    sx = float(p["size_x"]); sz = float(p["size_z"])
    res = int(p["resolution"])
    heights = p["heights"]
    lx = wx - ox; lz = wz - oz
    if not (0 <= lx <= sx and 0 <= lz <= sz):
        return float(oy)
    cx = sx / float(res - 1); cz = sz / float(res - 1)
    i = max(0, min(res - 1, int(round(lx / cx))))
    j = max(0, min(res - 1, int(round(lz / cz))))
    return float(oy) + float(heights[i * res + j])


def add_star(bp: dict, name: str, x: float, z: float,
             y_offset: float = 1.5, *, world_y: float | None = None) -> None:
    """Place a star pickup at (x, sampled_terrain_y + y_offset, z),
    or at an explicit world_y when supplied (for star-on-platform)."""
    y = world_y if world_y is not None else sample_height(bp, x, z) + y_offset
    bp["pickups"].append({
        "name": name, "kind": "star", "pos": [x, y, z],
    })


def add_coin_ring(bp: dict, prefix: str, cx: float, cz: float,
                  radius: float = 6.0, n: int = 8,
                  y_offset: float = 1.0) -> None:
    """Drop a ring of yellow coins around a point — used to hint at
    landmarks (the painting at the centre, the star above, etc.)."""
    for k in range(n):
        ang = 2.0 * math.pi * k / n
        x = cx + radius * math.cos(ang)
        z = cz + radius * math.sin(ang)
        y = sample_height(bp, x, z) + y_offset
        bp["pickups"].append({
            "name": f"{prefix}{k}", "kind": "coin_yellow",
            "pos": [x, y, z],
        })


def merge_imported_minus_stars(bp: dict, level: str) -> None:
    """Pull enemies + non-star pickups from the marker extraction so
    the level still has its hand-placed combat / coin loadout, but
    skip imported stars — those are now scripted to land at deliberate
    spots. Lifts y to terrain + small offset."""
    src_path = os.path.join(IMPORTED_DIR, f"{level}.json")
    if not os.path.exists(src_path):
        return
    src = json.load(open(src_path))
    for e in src.get("enemies", []):
        p = e.get("pos", [0, 0, 0])
        wx, _, wz = float(p[0]), float(p[1]), float(p[2])
        wy = sample_height(bp, wx, wz) + 0.4
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


# --------------------------------------------------------------------
# Themed world builders. Each adds 5-7 stars at landmark positions.

def make_grass_hub() -> dict:
    """Castle courtyard hub. Doors warp to each themed world; doors
    are progressively star-gated."""
    bp = base_blueprint("Hub courtyard. Walk to a painting to enter that world.")
    bp["spawn_point"] = [0, 2, 30]
    bp["bgm"] = "bgm_castle"
    bp["sky"] = {
        "horizon_color": [0.65, 0.85, 1.00],
        "ambient_color": [0.85, 0.92, 0.95],
        "ambient_energy": 0.85,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        # Flat plaza; gentle outer lawn.
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        plaza = max(0.0, 1.0 - r / 22.0)
        rolling = 0.5 * math.sin(x * 0.06) * math.cos(z * 0.05)
        return rolling * (1.0 - plaza)
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h))
    # Castle keep — 1 big room, door facing south.
    bp["rooms"].append({
        "name": "CastleHall",
        "origin": [-15, 0, -10], "size": [30, 8, 22],
        "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [{"type": "door", "x": 13.5, "width": 3, "height": 4}]},
            "east": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
                {"type": "window", "x": 18, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "west": {"openings": [
                {"type": "window", "x": 6, "width": 1.5, "height": 2, "sill": 2.5},
                {"type": "window", "x": 18, "width": 1.5, "height": 2, "sill": 2.5},
            ]},
            "north": {"openings": []},
        },
    })
    # Eight painting-doors arranged in an arc at the south / east /
    # west edges of the courtyard. Star requirements escalate.
    PAINTINGS = [
        ("ToMountain", "mountain",  -32,  20, 0,
         "Mountain — climb to the peak"),
        ("ToSnow",     "snow",      -36,   0, 1,
         "Snow — 1 star to enter"),
        ("ToWater",    "water",     -32, -20, 3,
         "Water — 3 stars to enter"),
        ("ToLava",     "lava",       32,  20, 6,
         "Lava — 6 stars to enter"),
        ("ToSand",     "sand",       36,   0, 12,
         "Sand — 12 stars to enter"),
        ("ToSky",      "sky",        32, -20, 25,
         "Sky — 25 stars to enter"),
        ("ToBowser",   "bowser",      0, -45, 50,
         "Bowser's keep — 50 stars to enter"),
    ]
    for name, target, wx, wz, star_req, doc in PAINTINGS:
        bp["warps"].append({
            "name": name, "target_level": target,
            "pos": [wx, sample_height(bp, wx, wz), wz],
            "size": [3.5, 4.5, 0.4],
            "requires_stars": star_req,
            "_doc": doc,
        })
        # Coins ring out from each portal so they're easy to find.
        add_coin_ring(bp, f"{name}_ring", wx, wz, radius=4.0, n=6)
    # Hub welcome star (free) on top of the keep.
    add_star(bp, "HubWelcome", 0, -8, world_y=9.5)
    return bp


def make_mountain() -> dict:
    bp = base_blueprint("Mountain: a peak to climb. Five stars hidden along the way.")
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
        peak = 32.0 * max(0.0, 1.0 - r / 70.0) ** 1.5
        noise = 1.0 * math.sin(x * 0.27) + 0.8 * math.cos(z * 0.31)
        return peak + noise
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                slope_color=[0.45, 0.30, 0.20])
    # Stars: peak, midway clockwise band, hidden behind (-x side).
    add_star(bp, "MountainPeak",       0,  0, y_offset=2.5)
    add_star(bp, "MidwayEast",        25, 10)
    add_star(bp, "MidwayWest",       -22, -8)
    add_star(bp, "HiddenNorth",       -2, -32)
    add_star(bp, "BaseSouth",          0, 55, y_offset=1.5)
    merge_imported_minus_stars(bp, "mountain")
    return bp


def make_snow() -> dict:
    bp = base_blueprint("Snow: rolling slippery drifts with five stars across the ridges.")
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
        dx = x - cx_h; dz = z - cz_h - 50
        if math.hypot(dx, dz) < 8.0:
            return ""           # spawn pad — no slip
        return "snow"
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.85, 0.92, 0.95])
    add_star(bp, "DriftEast",        30,  10, y_offset=1.5)
    add_star(bp, "DriftNorth",        0, -30)
    add_star(bp, "RidgeWest",       -30,   5)
    add_star(bp, "FarPeak",          15, -55)
    add_star(bp, "HiddenValley",    -25, -50)
    merge_imported_minus_stars(bp, "snow")
    return bp


def make_water() -> dict:
    bp = base_blueprint("Water: a lake with islands. Most stars require swimming.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_water"
    bp["sky"] = {
        "horizon_color": [0.55, 0.78, 0.95],
        "ambient_color": [0.78, 0.88, 0.95],
        "ambient_energy": 0.80,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        basin = -3.5 * max(0.0, 1.0 - r / 60.0)
        bank = 1.2 * min(1.0, max(0.0, (r - 60.0) / 30.0))
        for ix, iz in [(-15, -15), (15, 18), (-22, 20)]:
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
    # Stars: shore, three islands, deep lake.
    add_star(bp, "ShoreSouth",        0,  55)
    add_star(bp, "Island1",         -15, -15, y_offset=2.0)
    add_star(bp, "Island2",          15,  18, y_offset=2.0)
    add_star(bp, "Island3",         -22,  20, y_offset=2.0)
    add_star(bp, "DeepBasin",         5,   0, world_y=-2.0)
    merge_imported_minus_stars(bp, "water")
    return bp


def make_lava() -> dict:
    bp = base_blueprint("Lava: stone islands across magma. One star per island, one above.")
    bp["spawn_point"] = [0, 2, 50]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.45, 0.18, 0.10],
        "ambient_color": [0.85, 0.45, 0.20],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 200.0, 200.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    ISLANDS = [(-10, -5), (12, 0), (0, 14), (-18, 12), (16, -16)]
    def h(x, z):
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        rim = 2.0 * max(0.0, (r - 70.0) / 30.0)
        floor = -1.5 if r < 70.0 else 0.0
        islands = 0.0
        for ix, iz in ISLANDS:
            d = math.hypot(x - cx_h - ix, z - cz_h - iz)
            if d < 5.0:
                islands += (5.0 - d) * 0.7
        return floor + rim + islands
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
    for k, (ix, iz) in enumerate(ISLANDS):
        add_star(bp, f"LavaIsland{k}", ix, iz, y_offset=2.5)
    merge_imported_minus_stars(bp, "lava")
    return bp


def make_sand() -> dict:
    bp = base_blueprint("Sand: dunes with quicksand traps and five stars across the desert.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.96, 0.84, 0.55],
        "ambient_color": [1.00, 0.92, 0.70],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx_h = SX * 0.5; cz_h = SZ * 0.5
    QUICK_PITS = [(-15, -10), (20, 5), (-5, 25)]
    def h(x, z):
        return (3.0 * math.sin(x * 0.05 + z * 0.03)
                + 1.5 * math.sin(x * 0.11)
                + 1.0 * math.cos(z * 0.09))
    def kind(x, z):
        dx = x - cx_h; dz = z - cz_h
        for ix, iz in QUICK_PITS:
            if math.hypot(dx - ix, dz - iz) < 5.0:
                return "shallow_quicksand"
        return "sand"
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.92, 0.80, 0.45])
    add_star(bp, "DuneEast",         32,  10)
    add_star(bp, "DuneWest",        -28,  -5)
    add_star(bp, "OasisCenter",      -2, -15, y_offset=2.0)
    add_star(bp, "FarSouth",          0,  55)
    add_star(bp, "FarNorth",          5, -55)
    merge_imported_minus_stars(bp, "sand")
    return bp


def make_sky() -> dict:
    bp = base_blueprint("Sky: cloud base + floating platforms. Stars on the high ones.")
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
    PLATS = [
        (-20, 4, -10), (10, 6, -20), (-5, 9, -30),
        (15, 12, -35), (-15, 14, -45), (5, 17, -50),
    ]
    for i, (x, y, z) in enumerate(PLATS):
        bp["extras"].append({
            "type": "platform", "name": f"Plat{i}",
            "pos": [x - 2.5, y, z - 2.5],
            "size": [5.0, 0.4, 5.0], "material": "floor",
        })
    # Star on every other platform — top-most pair are the bonus targets.
    add_star(bp, "PlatStar1", -20, -10, world_y=5.5)
    add_star(bp, "PlatStar2",  -5, -30, world_y=10.5)
    add_star(bp, "PlatStar3", -15, -45, world_y=15.5)
    add_star(bp, "PlatStar4",   5, -50, world_y=18.5)
    add_star(bp, "CloudStar",   0,   0, y_offset=3.0)
    merge_imported_minus_stars(bp, "sky")
    return bp


def make_bowser() -> dict:
    bp = base_blueprint("Bowser's keep — final star at the top of the tower.")
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
        dx = x - cx_h; dz = z - cz_h
        r = math.hypot(dx, dz)
        if 18.0 < r < 35.0:
            return "burning"
        return ""
    add_terrain(bp,
                origin=[-cx_h, 0, -cz_h],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.32, 0.25, 0.30])
    bp["extras"].append({
        "type": "platform", "name": "MoatBridge",
        "pos": [-2.0, 1.4, -36.0],
        "size": [4.0, 0.4, 22.0], "material": "wood",
    })
    bp["rooms"].append({
        "name": "KeepGround", "origin": [-12, 1.5, -12],
        "size": [24, 6, 24], "material": "brick", "floor_material": "floor",
        "walls": {
            "south": {"openings": [{"type": "door", "x": 10.5, "width": 3, "height": 4}]},
            "north": {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
            "east":  {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
            "west":  {"openings": [{"type": "window", "x": 10.5, "width": 1.5, "height": 2, "sill": 2}]},
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
    add_star(bp, "BowserCrown", 0, 0, world_y=14.0)
    merge_imported_minus_stars(bp, "bowser")
    return bp


# --------------------------------------------------------------------

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
        n_terrain = len(bp["terrain_patches"])
        n_rooms = len(bp["rooms"])
        n_enemy = len(bp["enemies"])
        n_star = sum(1 for p in bp["pickups"] if p.get("kind") == "star")
        n_other = sum(1 for p in bp["pickups"] if p.get("kind") != "star")
        n_warp = len(bp["warps"])
        print(f"{name:<10} → {path}  "
              f"(rooms {n_rooms}, enemies {n_enemy}, "
              f"stars {n_star}, other-pickups {n_other}, warps {n_warp})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
