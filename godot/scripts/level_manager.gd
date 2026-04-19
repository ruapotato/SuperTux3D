extends Node3D

# Owns the currently-loaded level (mesh + collision + objects). Clearing and
# re-loading goes through load_level(name, area) which tears down any previous
# content under `world_root` and repositions Mario at the new spawn.
#
# Levels are backed by three data files we extracted from the decomp:
#   extracted/levels/<name>/script.json        — spawn, object list, warps
#   extracted/levels/<name>/area_<N>/model.json — visual geometry
#   extracted/levels/<name>/area_<N>/collision.json — collision

const LevelLoader := preload("res://scripts/level_loader.gd")
const ObjectSpawner := preload("res://scripts/object_spawner.gd")

# Level → appropriate BGM track name.
# Per-level water surface Y (Godot units). Hand-tuned to match the
# approximate surface visible in each decomp level. Levels not in this
# table get -INF (no water).
const LEVEL_WATER_Y := {
    "jrb":   0.5,
    "ddd":   0.0,
    "wdw":   0.0,
    "sa":    0.0,
    "cotmc": -15.0,
    "hmc":   -25.0,   # underground pool
    "ccm":   -30.0,   # the deep slide tunnel water
    "wmotr": 0.0,
}

const LEVEL_BGM := {
    "castle_grounds":   "bgm_castle",
    "castle_inside":    "bgm_castle",
    "castle_courtyard": "bgm_castle",
    "jrb":              "bgm_water",
    "ddd":              "bgm_water",
    "wdw":              "bgm_water",
    "cotmc":            "bgm_water",
    "sa":               "bgm_water",
    "bitdw":            "bgm_bowser",
    "bitfs":            "bgm_bowser",
    "bits":             "bgm_bowser",
    "bowser_1":         "bgm_bowser",
    "bowser_2":         "bgm_bowser",
    "bowser_3":         "bgm_bowser",
    "hmc":              "bgm_sub",
    "sl":               "bgm_sub",
    "ssl":              "bgm_sub",
    "bbh":              "bgm_sub",
    "pss":              "bgm_sub",
}

# Godot-world spawn defaults when a level has no MARIO_POS for the area.
const FALLBACK_SPAWN := Vector3(0, 5, 0)

var world_root: Node3D
var mario: CharacterBody3D
var sound_bank: Node     # optional — set by main.gd so we can swap BGM on load

# The currently-loaded level name + area (1-based), null when no level.
var current_level: String = ""
var current_area: int = 0


func setup(root: Node3D, mario_node: CharacterBody3D) -> void:
    world_root = root
    mario = mario_node


func load_level(level_name: String, area: int = 1) -> bool:
    _teardown()
    var script_path := "res://extracted/levels/%s/script.json" % level_name
    var model_path := "res://extracted/levels/%s/area_%d/model.json" % [level_name, area]
    var coll_path := "res://extracted/levels/%s/area_%d/collision.json" % [level_name, area]

    if not FileAccess.file_exists(script_path):
        push_error("level_manager: %s has no script.json" % level_name)
        return false

    # Load the visual + collision for the area. Either may be missing for a
    # handful of levels (bowser fights etc.) — warn but keep going so the
    # player at least spawns somewhere walkable.
    if FileAccess.file_exists(model_path) or FileAccess.file_exists(coll_path):
        LevelLoader.load_level(model_path, coll_path, world_root)

    # Safety floor: a big invisible plane well below the level catches the
    # player if they clip through thin collision (Bowser boss arenas have
    # very little static geometry, other levels can get wonky near edges).
    _add_safety_floor()

    # Pull the spawn for this area out of the level script summary.
    var script_data: Variant = _read_json(script_path)
    var spawn := _pick_spawn(script_data, area)
    mario.global_position = spawn
    mario.velocity = Vector3.ZERO

    # Spawn the area's decorative + interactive objects. The warps list is
    # passed along so door/painting warp triggers can resolve their
    # destination level + area at spawn time.
    if script_data is Dictionary:
        var area_data: Variant = script_data.areas.get(str(area))
        if area_data is Dictionary:
            ObjectSpawner.spawn_area_objects(
                area_data.objects, world_root, self, area_data.warps
            )

    current_level = level_name
    current_area = area
    if sound_bank != null:
        var track: String = LEVEL_BGM.get(level_name, "bgm_course")
        if sound_bank.has_method("play_bgm"):
            sound_bank.play_bgm(track)
    # Tell Mario whether this level has a water volume.
    var water_y: float = LEVEL_WATER_Y.get(level_name, -INF)
    mario.water_level_y = water_y
    print("[level_manager] loaded %s area %d, spawn=%s water=%s" % [
        level_name, area, spawn, water_y])
    return true


func teleport_to(level_name: String, area: int = 1) -> void:
    # Same as load_level but fades/plays warp sfx later. For now just swap.
    load_level(level_name, area)


func _teardown() -> void:
    if world_root == null:
        return
    for child in world_root.get_children():
        child.queue_free()


func _add_safety_floor() -> void:
    var body := StaticBody3D.new()
    body.name = "SafetyFloor"
    var cs := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(1000, 0.5, 1000)
    cs.shape = box
    body.add_child(cs)
    body.position = Vector3(0, -20, 0)
    world_root.add_child(body)


func _pick_spawn(script_data: Variant, area: int) -> Vector3:
    if script_data is Dictionary:
        var spawns: Variant = script_data.spawns
        if spawns is Dictionary:
            var s: Variant = spawns.get(str(area))
            if s is Dictionary and s.has("pos"):
                var p: Array = s.pos
                # Decomp coords → Godot units via WORLD_SCALE, plus a small
                # Y cushion so the capsule doesn't clip floor on spawn.
                return (Vector3(p[0], p[1], p[2]) * LevelLoader.WORLD_SCALE) + Vector3(0, 2, 0)
    return FALLBACK_SPAWN


func _read_json(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        return null
    var f := FileAccess.open(path, FileAccess.READ)
    return JSON.parse_string(f.get_as_text())
