#!/usr/bin/env python3
"""Generate the shared material library as individual .tres files in
godot/assets/materials/. Level scenes reference these via ext_resource
so colors/roughness can be tuned in one place. All unshaded (N64-era
flat look) by default; emission flag enables glow on lava/crystal/etc.
"""
from __future__ import annotations
import os
import textwrap

OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    "..", "godot", "assets", "materials",
)

TEMPLATE = textwrap.dedent("""\
    [gd_resource type="StandardMaterial3D" format=3 uid="uid://{uid}"]

    [resource]
    resource_name = "{name}"
    shading_mode = 0
    albedo_color = Color({r}, {g}, {b}, {a})
    {extras}
""")

def emission(color, energy):
    r, g, b = color
    return (
        "emission_enabled = true\n"
        f"emission = Color({r}, {g}, {b}, 1)\n"
        f"emission_energy_multiplier = {energy}"
    )

def transparent(alpha_mode="TRANSPARENCY_ALPHA"):
    # 0 = disabled, 1 = alpha, 2 = alpha_scissor, 3 = alpha_hash, 4 = alpha_depth_pre
    return "transparency = 1"

def two_sided():
    # cull_mode: 0=back, 1=front, 2=disabled
    return "cull_mode = 2"

# (name, r, g, b, a, extras_lines) — tweaked for the Tux-penguin scale
# (character ~1.5m). Use unshaded flat color.
MATERIALS = [
    # NATURAL GROUND
    ("grass_bright",  0.42, 0.72, 0.25, 1.0, ""),
    ("grass_dark",    0.20, 0.46, 0.16, 1.0, ""),
    ("grass_path",    0.68, 0.60, 0.35, 1.0, ""),  # trampled path
    ("dirt",          0.45, 0.30, 0.18, 1.0, ""),
    ("dirt_dark",     0.27, 0.17, 0.10, 1.0, ""),
    ("sand",          0.90, 0.78, 0.50, 1.0, ""),
    ("sand_deep",     0.68, 0.55, 0.32, 1.0, ""),
    ("snow",          0.97, 0.98, 1.00, 1.0, ""),
    ("ice",           0.72, 0.88, 0.98, 0.85, transparent()),
    ("mud",           0.32, 0.24, 0.15, 1.0, ""),

    # ROCK
    ("stone_grey",    0.58, 0.60, 0.62, 1.0, ""),
    ("stone_dark",    0.32, 0.34, 0.38, 1.0, ""),
    ("stone_mossy",   0.42, 0.52, 0.36, 1.0, ""),
    ("basalt",        0.18, 0.18, 0.22, 1.0, ""),
    ("sandstone",     0.82, 0.68, 0.45, 1.0, ""),
    ("red_rock",      0.62, 0.32, 0.22, 1.0, ""),
    ("crystal_blue",  0.40, 0.70, 0.95, 0.80,
        transparent() + "\n" + emission((0.25, 0.55, 0.95), 0.3)),

    # ARCHITECTURE
    ("wood_light",    0.78, 0.55, 0.32, 1.0, ""),
    ("wood_dark",     0.48, 0.30, 0.18, 1.0, ""),
    ("wood_planks",   0.62, 0.42, 0.24, 1.0, ""),
    ("brick_red",     0.68, 0.28, 0.22, 1.0, ""),
    ("brick_stone",   0.72, 0.68, 0.60, 1.0, ""),
    ("metal_grey",    0.55, 0.58, 0.62, 1.0, ""),
    ("gold",          0.95, 0.78, 0.22, 1.0, ""),
    ("silver",        0.80, 0.82, 0.85, 1.0, ""),
    ("copper",        0.78, 0.48, 0.22, 1.0, ""),
    ("fabric_red",    0.72, 0.18, 0.22, 1.0, ""),
    ("fabric_blue",   0.22, 0.32, 0.72, 1.0, ""),
    ("fabric_gold",   0.88, 0.72, 0.25, 1.0, ""),

    # FOLIAGE
    ("leaves_green",  0.28, 0.62, 0.22, 1.0, ""),
    ("leaves_fall",   0.78, 0.42, 0.15, 1.0, ""),
    ("leaves_dark",   0.18, 0.40, 0.15, 1.0, ""),
    ("bark",          0.35, 0.22, 0.14, 1.0, ""),
    ("moss",          0.22, 0.48, 0.24, 1.0, ""),
    ("petal_pink",    0.95, 0.62, 0.75, 1.0, ""),
    ("petal_purple",  0.62, 0.35, 0.78, 1.0, ""),
    ("flower_yellow", 0.98, 0.82, 0.25, 1.0, ""),

    # WATER
    ("water_blue",    0.24, 0.54, 0.92, 0.75,
        transparent() + "\n" + emission((0.18, 0.45, 0.78), 0.2)),
    ("water_deep",    0.10, 0.28, 0.55, 0.80, transparent()),
    ("water_murky",   0.35, 0.48, 0.32, 0.80, transparent()),

    # HOT / COLD / GLOW
    ("lava",          1.00, 0.42, 0.10, 1.0,
        emission((1.0, 0.48, 0.12), 2.2)),
    ("lava_crust",    0.45, 0.10, 0.05, 1.0,
        emission((0.95, 0.22, 0.06), 0.6)),
    ("ember",         1.00, 0.60, 0.20, 1.0,
        emission((1.0, 0.55, 0.18), 2.6)),
    ("torch_flame",   1.00, 0.78, 0.25, 1.0,
        emission((1.0, 0.72, 0.22), 2.0)),

    # SKY / CLOUD
    ("sky_day",       0.52, 0.75, 0.98, 1.0, ""),
    ("sky_dusk",      0.95, 0.58, 0.35, 1.0, ""),
    ("sky_stormy",    0.38, 0.42, 0.48, 1.0, ""),
    ("sky_underground", 0.10, 0.08, 0.15, 1.0, ""),
    ("cloud",         0.95, 0.96, 0.98, 0.90, transparent()),

    # DECORATIONS / UI / SPECIAL
    ("emissive_white", 1.0, 1.0, 1.0, 1.0,
        emission((1.0, 1.0, 0.95), 1.0)),
    ("emissive_cyan",  0.40, 0.92, 0.98, 1.0,
        emission((0.30, 0.90, 0.98), 1.6)),
    ("emissive_gold",  1.00, 0.82, 0.30, 1.0,
        emission((1.0, 0.82, 0.30), 1.4)),
    ("plain_white",    1.0, 1.0, 1.0, 1.0, ""),
    ("plain_black",    0.05, 0.05, 0.08, 1.0, ""),
    ("warp_glow",      0.65, 0.35, 0.95, 0.6,
        transparent() + "\n" + emission((0.55, 0.32, 0.95), 2.0)),
]

def uid_for(name: str) -> str:
    # Short deterministic UID from the material name. Godot uses base-36
    # 22-char UIDs; a stable pseudo-unique one works for local files.
    import hashlib
    h = hashlib.sha1(name.encode()).hexdigest()[:16]
    return "c" + h  # prefix keeps format consistent

def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    count = 0
    for name, r, g, b, a, extras in MATERIALS:
        path = os.path.join(OUT_DIR, f"{name}.tres")
        with open(path, "w") as f:
            f.write(TEMPLATE.format(
                uid=uid_for(name),
                name=name,
                r=r, g=g, b=b, a=a,
                extras=extras,
            ))
        count += 1
    print(f"wrote {count} materials to {OUT_DIR}")

if __name__ == "__main__":
    main()
