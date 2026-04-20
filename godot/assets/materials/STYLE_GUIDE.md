# Level Design Style Guide

## Scale constants (Godot units = meters)

Our player is a ~1.5m tall penguin (Tux-style). The physics are tuned
for these numbers. Platforms need to fit the character — a ledge that
requires a 3m vertical pop will feel terrible; a 1.5m ledge reads as
"jumpable".

| Move | Max height | Max horizontal |
|------|-----------|----------------|
| Single jump | ~2.0m | ~2.5m forward |
| Double jump | ~2.6m | ~3m |
| Triple jump | ~3.6m | ~4m |
| Backflip | ~3.5m | negative (backward) |
| Long jump | ~1.5m peak | **~8m forward** |
| Side flip | ~3.0m | ~2m |
| Wall kick | ~2.5m | off-wall |
| Ground pound | instant descent | — |

**Platforming rules of thumb:**
- **Standard walk-up step**: 0.5–0.8m. Above that becomes a jump.
- **Single-jump gap between platforms**: 2.0–2.5m horizontal. Beyond 3m
  forces a double jump or long jump.
- **Long-jump gap**: reserve 6–8m separations for clearly-telegraphed
  "only a long jump reaches this" routes. Put visible coins along the
  arc so the player reads the trajectory.
- **Ledge width minimum**: 1.5m (the character's footprint). Narrower
  is a balance-test challenge.
- **Ceiling clearance**: 3m minimum for indoor areas (triple jumps
  shouldn't bonk).

## Materials

All materials live at `res://assets/materials/*.tres`. Reference them
via ext_resource in level .tscn files. Never re-author colors inline;
keep this library as the single source of truth.

Naming convention: `{family}_{variant}.tres` — e.g. `grass_bright.tres`,
`stone_mossy.tres`. See the directory listing for what's available.

Every material is unshaded (shading_mode = 0) — we're targeting the
flat-color N64 aesthetic. Emission-flagged materials (lava, crystals,
torches, warp glows) let specific props pop without a full lighting
pass.

## Biomes and palette suggestions

- **grass_hub**: grass_bright/grass_dark, brick_stone walls, wood_planks,
  gold trim on royal elements.
- **mountain**: dirt/dirt_dark, stone_grey/stone_mossy, bark/leaves_green.
- **snow**: snow, ice (translucent), bark/leaves_dark, wood_dark.
- **water**: sand, water_blue (surface plane), water_deep (underwater),
  bark for ship timbers, stone_grey for cliffs.
- **lava**: basalt, lava, lava_crust, ember, stone_dark.
- **sand**: sandstone, sand/sand_deep, red_rock for ruins, bark for
  oasis palms.
- **sky**: cloud (semi-transparent), stone_grey for platforms, gold
  for a decorative centerpiece.
- **bowser**: basalt, stone_dark, lava ring, fabric_red throne, gold.

## Scene structure requirements

Every level .tscn must have:

1. Root `Node3D` named `LevelRoot`.
2. A `WorldEnvironment` with an `Environment` resource — set `sky_mode`
   (procedural) or `background_mode = BG_COLOR` with a palette-matching
   clear color. Ambient light on.
3. A `DirectionalLight3D` pitched to cast shadows that read well.
4. Collision: every solid surface lives in a `StaticBody3D`
   (collision_layer=1, collision_mask=1). Use the correct shape for
   the visual (BoxShape3D, CylinderShape3D, ConvexPolygonShape3D).
5. Spawn marker: an `Area3D` named `SpawnArea` with
   `set_meta("spawn_point", Vector3(x, 1, z))` at a safe starting
   position.
6. Level content via metadata on Marker3D/Node3D/Area3D children:
   - `metadata/enemy_bhv = "bhvGoomba"` (also bhvKoopa, bhvBobomb,
     bhvBobombBuddy, bhvPiranhaPlant, bhvChainChomp, bhvCuttlefish)
   - `metadata/pickup_kind = "coin_yellow"` (also coin_blue, coin_red,
     star, oneup, cap_wing, cap_metal, cap_vanish)
   - `metadata/warp_to = "level_name"` on an Area3D for level transitions
   - `metadata/requires_stars = N` on a warp Area3D to gate it behind
     star count
   - `metadata/surface_kind = "ice"` (or "burning", "slippery",
     "very_slippery", "water", "deep_quicksand", "default") on
     StaticBody3Ds to change physics

## Density guidance per level

- ~15-25 enemies (mix types that fit biome)
- ~30-60 coins (a few red coins for a 7-or-8 set; blue sparingly)
- 1-3 stars per level
- 2-4 one-ups, hidden in clever spots
- A cap power-up if it matters to a specific route
- 1-3 warps back to the hub OR to adjacent worlds

## What "A-game" means here

- **Clarity first**: from spawn, the player should see the level's
  main landmark and a path toward it. No visual soup.
- **Three distinct tiers** of vertical content (ground / mid / summit).
- **Layered secrets**: at least one obvious-but-skill-gated route AND
  one hidden nook that rewards exploration.
- **Pacing**: a short warmup → main challenge → vista/reward arc.
- **Visual identity**: pick 3-4 palette colors and STAY in that palette.
  Don't scatter 15 different material families around.
- **Camera-friendly**: big open arenas beat tight corridors for a 3D
  platformer. Avoid ceilings that the camera can't clip around.
