#!/usr/bin/env python3
"""Author the eight themed worlds (grass_hub, mountain, snow, water,
lava, sand, sky, bowser) as JSON blueprints. Each one gets:

    - A terrain patch sized for the level's marker extents, sculpted
      with a theme-appropriate heightmap formula, and painted with
      the right surface_kinds (snow / sand / water / lava / quicksand /
      ice).
    - A spawn_point near the origin.
    - Theme-coloured sky + an apt bgm track.
    - All enemies / pickups / warps from `blueprints/imported/`,
      lifted onto the new heightmap so they don't sit underground.
    - One or two rooms / extras where it makes sense (the hub gets a
      small castle; bowser gets a tower).

Run once to seed the world:

    python3 tools/build_initial_levels.py

Then:

    for f in blueprints/{grass_hub,mountain,snow,water,lava,sand,sky,bowser}.json; do
        python3 tools/build_from_blueprint.py "$f" \
            "godot/assets/levels/$(basename ${f%.json}).tscn"
    done

The output is meant as a starting point for hand-tuning in the editor —
heightmap formulas can't compete with author intent for every gameplay
beat. Open each blueprint in the editor (or press F4 in-game) and
sculpt / paint / re-place markers until the level feels right.
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


def heightmap(size_x: float, size_z: float, res: int, fn) -> list[float]:
    """Sample fn(x_local, z_local) over a res×res grid spanning the
    patch's local space (0..size_x, 0..size_z). Returns flat row-major
    list."""
    cx = size_x / float(res - 1)
    cz = size_z / float(res - 1)
    out = []
    for i in range(res):
        for j in range(res):
            out.append(float(fn(i * cx, j * cz)))
    return out


def paint(size_x: float, size_z: float, res: int, fn) -> list[str]:
    """Same idea but for surface_grid: (res-1)² cells, fn returns a
    surface-kind string (or "" for default)."""
    cx = size_x / float(res - 1)
    cz = size_z / float(res - 1)
    out = []
    for ci in range(res - 1):
        for cj in range(res - 1):
            x = (ci + 0.5) * cx
            z = (cj + 0.5) * cz
            out.append(str(fn(x, z)))
    return out


def lift_markers(bp: dict, base_y: float, get_height) -> None:
    """Walk every marker (enemy / pickup / warp) and set its world Y
    to (terrain_height_under_marker + base_y) so it sits on the
    sculpted ground rather than at the imported flat-world Y. Works
    in patch-local x/z space, assuming the patch is centered at
    origin and we've already added it to the blueprint."""
    patch = bp["terrain_patches"][0]
    ox, oy, oz = patch["origin"]
    sx = float(patch["size_x"]); sz = float(patch["size_z"])
    res = int(patch["resolution"])
    heights = patch["heights"]
    def sample(wx: float, wz: float) -> float:
        lx = wx - ox
        lz = wz - oz
        if not (0 <= lx <= sx and 0 <= lz <= sz):
            return 0.0
        cx = sx / float(res - 1)
        cz = sz / float(res - 1)
        i = max(0, min(res - 1, int(round(lx / cx))))
        j = max(0, min(res - 1, int(round(lz / cz))))
        return float(heights[i * res + j])
    for kind in ("enemies", "pickups", "warps"):
        for item in bp.get(kind, []):
            p = item.get("pos", [0, 0, 0])
            wx, _wy, wz = float(p[0]), float(p[1]), float(p[2])
            new_y = oy + sample(wx, wz) + base_y
            item["pos"] = [wx, new_y, wz]


def merge_imported(bp: dict, level: str) -> None:
    """Copy enemies / pickups / warps + sky / water_level_y / bgm
    from the marker-only extracted file. Skips the geometry and
    materials sections — those come from the new blueprint we
    authored."""
    src_path = os.path.join(IMPORTED_DIR, f"{level}.json")
    if not os.path.exists(src_path):
        return
    src = json.load(open(src_path))
    for kind in ("enemies", "pickups", "warps"):
        bp[kind] = [dict(e) for e in src.get(kind, [])]
    if "water_level_y" in src and "water_level_y" not in bp:
        bp["water_level_y"] = src["water_level_y"]
    if "bgm" in src and "bgm" not in bp:
        bp["bgm"] = src["bgm"]


def add_terrain(bp: dict, *,
                origin: list[float],
                size_x: float, size_z: float,
                res: int,
                heights: list[float],
                surface_grid: list[str] | None = None,
                flat_color=None,
                slope_color=None) -> None:
    patch = {
        "name": "Ground",
        "origin": origin,
        "size_x": size_x,
        "size_z": size_z,
        "resolution": res,
        "heights": heights,
        "surface_grid": surface_grid or [""] * ((res - 1) * (res - 1)),
        "material": "",
    }
    if flat_color: patch["flat_color"] = list(flat_color)
    if slope_color: patch["slope_color"] = list(slope_color)
    bp["terrain_patches"].append(patch)


# --------------------------------------------------------------------
# Per-level builders. Each is small + opinionated; meant to be a
# starting point, not the final design.

def make_grass_hub() -> dict:
    bp = base_blueprint("Grass hub: outdoor courtyard with a small castle keep.")
    bp["spawn_point"] = [0, 2, 30]
    bp["bgm"] = "bgm_castle"
    bp["sky"] = {
        "horizon_color": [0.65, 0.85, 1.00],
        "ambient_color": [0.85, 0.92, 0.95],
        "ambient_energy": 0.85,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        # Gentle rolling hills, central plaza flat.
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        plaza = max(0.0, 1.0 - r / 18.0)  # 0..1, 1 in centre
        rolling = 0.8 * math.sin(x * 0.07) * math.cos(z * 0.05) + 0.4 * math.sin(z * 0.11)
        return rolling * (1.0 - plaza)
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h))
    # Castle keep — single big room with a door facing the spawn.
    bp["rooms"].append({
        "name": "CastleHall",
        "origin": [-15, 0, -15],
        "size": [30, 8, 22],
        "material": "brick",
        "floor_material": "floor",
        "walls": {
            "south": {"openings": [
                {"type": "door", "x": 13.5, "width": 3, "height": 4},
            ]},
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
    # Pillars in front of the castle.
    bp["extras"].extend([
        {"type": "pillar", "name": "P1", "pos": [-10, 0, -10],
         "radius": 0.4, "height": 4.0, "material": "wood"},
        {"type": "pillar", "name": "P2", "pos": [10, 0, -10],
         "radius": 0.4, "height": 4.0, "material": "wood"},
    ])
    merge_imported(bp, "grass_hub")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_mountain() -> dict:
    bp = base_blueprint("Mountain: climb to the peak. Rocky slopes, narrow paths.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.78, 0.85, 0.95],
        "ambient_color": [0.78, 0.80, 0.85],
        "ambient_energy": 0.75,
    }
    SX, SZ, R = 180.0, 180.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        # Cone with a cosine roll-off, plus low-amplitude rocky noise.
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        peak = 30.0 * max(0.0, 1.0 - r / 70.0) ** 1.6
        noise = 1.2 * (math.sin(x * 0.27) * math.cos(z * 0.31)
                       + math.sin((x + z) * 0.13))
        return peak + noise
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                slope_color=[0.45, 0.30, 0.20])
    merge_imported(bp, "mountain")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_snow() -> dict:
    bp = base_blueprint("Snow: rolling slippery drifts. Watch your footing.")
    bp["spawn_point"] = [0, 2, 50]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.85, 0.92, 1.00],
        "ambient_color": [0.92, 0.95, 1.00],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        dx = x - cx; dz = z - cz
        return (3.5 * math.sin(x * 0.08) * math.cos(z * 0.06)
                + 1.5 * math.sin((x + z) * 0.05)
                + 2.0 * math.sin(z * 0.04))
    def kind(x, z):
        # Snow everywhere except around the spawn so the player isn't
        # immediately sliding.
        dx = x - cx; dz = z - cz - 50
        r = math.hypot(dx, dz)
        if r < 8.0:
            return ""
        return "snow"
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.85, 0.92, 0.95])
    merge_imported(bp, "snow")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_water() -> dict:
    bp = base_blueprint("Water: lake with sandy island shores. Swim between landmarks.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_water"
    bp["sky"] = {
        "horizon_color": [0.55, 0.78, 0.95],
        "ambient_color": [0.78, 0.88, 0.95],
        "ambient_energy": 0.80,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        # Lake basin: depressed in centre, raised banks beyond r=60.
        basin = -3.5 * max(0.0, 1.0 - r / 60.0)
        bank = 0.0
        if r > 60.0:
            bank = 1.5 * min(1.0, (r - 60.0) / 30.0)
        # Couple of islands inside the basin.
        for ix, iz in [(-15, -15), (15, 18), (-22, 20)]:
            d = math.hypot(x - cx - ix, z - cz - iz)
            if d < 6.0:
                bank += (6.0 - d) * 0.6
        return basin + bank
    def kind(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        if r < 55.0 and h(x, z) < -0.5:
            return "water"
        return ""
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind))
    merge_imported(bp, "water")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_lava() -> dict:
    bp = base_blueprint("Lava: stone islands across a magma pool. Don't fall.")
    bp["spawn_point"] = [0, 2, 50]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.45, 0.18, 0.10],
        "ambient_color": [0.85, 0.45, 0.20],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 200.0, 200.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        # Crater: edges raised, floor low. Stone islands at fixed
        # positions sticking up out of the lava floor.
        rim = 2.0 * max(0.0, (r - 70.0) / 30.0)
        floor = -1.5 if r < 70.0 else 0.0
        islands = 0.0
        for ix, iz in [(-10, -5), (12, 0), (0, 14), (-18, 12), (16, -16)]:
            d = math.hypot(x - cx - ix, z - cz - iz)
            if d < 5.0:
                islands += (5.0 - d) * 0.7
        return floor + rim + islands
    def kind(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        if r < 65.0 and h(x, z) < -0.3:
            return "burning"
        return ""
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.35, 0.20, 0.15])
    merge_imported(bp, "lava")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_sand() -> dict:
    bp = base_blueprint("Sand: dunes with quicksand pits. Step carefully.")
    bp["spawn_point"] = [0, 2, 60]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.96, 0.84, 0.55],
        "ambient_color": [1.00, 0.92, 0.70],
        "ambient_energy": 0.95,
    }
    SX, SZ, R = 220.0, 220.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        # Long dunes running diagonally.
        return (3.0 * math.sin(x * 0.05 + z * 0.03)
                + 1.5 * math.sin(x * 0.11)
                + 1.0 * math.cos(z * 0.09))
    def kind(x, z):
        dx = x - cx; dz = z - cz
        # Quicksand pits at fixed positions.
        for ix, iz in [(-15, -10), (20, 5), (-5, 25)]:
            if math.hypot(x - cx - ix, z - cz - iz) < 5.0:
                return "shallow_quicksand"
        return "sand"
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.92, 0.80, 0.45])
    merge_imported(bp, "sand")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_sky() -> dict:
    bp = base_blueprint("Sky: scattered floating platforms. Don't miss your jumps.")
    bp["spawn_point"] = [0, 2, 35]
    bp["bgm"] = "bgm_course"
    bp["sky"] = {
        "horizon_color": [0.45, 0.65, 0.95],
        "ambient_color": [0.85, 0.92, 1.00],
        "ambient_energy": 1.00,
    }
    # Sky world: a small cloud-base terrain at low elevation, plus a
    # collection of platform extras at varying heights.
    SX, SZ, R = 140.0, 140.0, 192
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        # Very gentle dome so the cloud has a feeling of mass.
        return max(0.0, 1.5 - r / 50.0)
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                flat_color=[0.95, 0.97, 1.00])
    # Floating stone platforms.
    for i, (x, y, z) in enumerate([
        (-20, 4, -10), (10, 6, -20), (-5, 9, -30),
        (15, 12, -35), (-15, 14, -45), (5, 17, -50),
    ]):
        bp["extras"].append({
            "type": "platform", "name": f"Plat{i}",
            "pos": [x - 2.5, y, z - 2.5],
            "size": [5.0, 0.4, 5.0], "material": "floor",
        })
    merge_imported(bp, "sky")
    lift_markers(bp, base_y=0.6, get_height=h)
    return bp


def make_bowser() -> dict:
    bp = base_blueprint("Bowser's keep: dark stone halls over a lava moat.")
    bp["spawn_point"] = [0, 2, 30]
    bp["bgm"] = "bgm_bowser"
    bp["sky"] = {
        "horizon_color": [0.18, 0.12, 0.20],
        "ambient_color": [0.55, 0.40, 0.45],
        "ambient_energy": 0.55,
    }
    # Square lava moat with a stone keep on top — the keep is a tall
    # tower with three floors. Player spawns at the south edge and
    # has to walk to the keep.
    SX, SZ, R = 100.0, 140.0, 256
    cx = SX * 0.5; cz = SZ * 0.5
    def h(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        # Outer rim raised, inner area dipped (lava moat ring),
        # very-inner area raised again (the keep platform).
        if r < 18.0:
            return 1.5
        if r < 35.0:
            return -2.0
        return 0.0
    def kind(x, z):
        dx = x - cx; dz = z - cz
        r = math.hypot(dx, dz)
        if 18.0 < r < 35.0:
            return "burning"
        return ""
    add_terrain(bp,
                origin=[-cx, 0, -cz],
                size_x=SX, size_z=SZ, res=R,
                heights=heightmap(SX, SZ, R, h),
                surface_grid=paint(SX, SZ, R, kind),
                flat_color=[0.32, 0.25, 0.30])
    # Bridge across the moat (south side).
    bp["extras"].append({
        "type": "platform", "name": "MoatBridge",
        "pos": [-2.0, 1.4, -36.0],
        "size": [4.0, 0.4, 22.0], "material": "wood",
    })
    # Tower: 3-floor keep at the centre with a spiral stair.
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
    merge_imported(bp, "bowser")
    lift_markers(bp, base_y=0.6, get_height=h)
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
        n_pickup = len(bp["pickups"])
        n_warp = len(bp["warps"])
        print(f"{name:<10} → {path}  "
              f"(terrain {n_terrain}, rooms {n_rooms}, "
              f"enemies {n_enemy}, pickups {n_pickup}, warps {n_warp})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
