extends Node3D

# Owns the currently-loaded level scene. Loading happens by instantiating
# res://assets/levels/<name>.tscn under world_root. The previous level's
# children are freed first. Mario is repositioned to the level's
# SpawnArea metadata.

# Level → background-music track name. The music-synth pipeline isn't
# wired yet, but this is where per-level BGM selection will live.
const LEVEL_BGM := {
    "grass_hub": "bgm_castle",
    "mountain":  "bgm_course",
    "snow":      "bgm_course",
    "water":     "bgm_water",
    "lava":      "bgm_course",
    "sand":      "bgm_course",
    "sky":       "bgm_course",
    "bowser":    "bgm_bowser",
}

# Per-level water surface Y (Godot units). Only the water world carries
# a non-trivial value; everything else is -INF (no swim state).
const LEVEL_WATER_Y := {
    "water": 0.0,
}

const EnemyScript := preload("res://scripts/enemy.gd")
const ObjectSpawner := preload("res://scripts/object_spawner.gd")

const FALLBACK_SPAWN := Vector3(0, 2, 0)

var world_root: Node3D
var mario: CharacterBody3D
var sound_bank: Node
var save_data: Node

signal level_loaded(level_name: String, area: int)

var current_level: String = ""
var current_area: int = 0


func setup(root: Node3D, mario_node: CharacterBody3D) -> void:
    world_root = root
    mario = mario_node


func load_level(level_name: String, area: int = 1) -> bool:
    _teardown()
    var scene_path := "res://assets/levels/%s.tscn" % level_name
    if not ResourceLoader.exists(scene_path):
        push_error("level_manager: missing level scene %s" % scene_path)
        return false
    var scene: PackedScene = load(scene_path)
    var level_root: Node3D = scene.instantiate()
    world_root.add_child(level_root)

    _add_safety_floor()

    var spawn: Vector3 = _find_spawn(level_root)
    mario.global_position = spawn
    mario.velocity = Vector3.ZERO

    _spawn_markers(level_root)

    current_level = level_name
    current_area = area
    if sound_bank != null and sound_bank.has_method("play_bgm"):
        sound_bank.play_bgm(LEVEL_BGM.get(level_name, "bgm_course"))
    mario.water_level_y = LEVEL_WATER_Y.get(level_name, -INF)
    if save_data != null:
        save_data.last_level = level_name
        save_data.last_area = area
        save_data.coins = mario.coin_count
        save_data.stars = mario.star_count
        save_data.lives = mario.lives
        save_data.save_file()
    emit_signal("level_loaded", level_name, area)
    print("[level_manager] loaded %s, spawn=%s water=%s" % [
        level_name, spawn, mario.water_level_y])
    return true


func teleport_to(level_name: String, area: int = 1) -> void:
    load_level(level_name, area)


func _teardown() -> void:
    if world_root == null:
        return
    for child in world_root.get_children():
        child.queue_free()


func _add_safety_floor() -> void:
    # A big invisible floor well below the level catches the player if
    # they clip through thin collision. Per-level scenes don't need to
    # worry about it.
    var body := StaticBody3D.new()
    body.name = "SafetyFloor"
    var cs := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(1000, 0.5, 1000)
    cs.shape = box
    body.add_child(cs)
    body.position = Vector3(0, -40, 0)
    world_root.add_child(body)


func _spawn_markers(level_root: Node) -> void:
    # Walk the level scene for metadata markers and create gameplay
    # objects at their world positions. Supported metadata keys:
    #   enemy_bhv   → spawns enemy.gd CharacterBody3D
    #   pickup_kind → spawns pickup Area3D
    #   warp_to     → the Area3D becomes a level-transition trigger;
    #                 when Mario enters, load the named level
    var spawn_count := {"enemy": 0, "pickup": 0, "warp": 0}
    var queue: Array = [level_root]
    while not queue.is_empty():
        var n: Node = queue.pop_front()
        for c in n.get_children():
            queue.append(c)
        if n is Node3D:
            var n3: Node3D = n
            if n.has_meta("enemy_bhv"):
                var bhv: String = str(n.get_meta("enemy_bhv"))
                var world_pos: Vector3 = n3.global_position
                var world_yaw: float = n3.rotation.y
                var e := CharacterBody3D.new()
                e.set_script(EnemyScript)
                e.set("bhv_name", bhv)
                e.name = "Enemy_" + bhv
                # Add to the tree first, THEN set global_position — Godot
                # raises a "!is_inside_tree" error if we touch the global
                # transform of a node that isn't parented yet.
                world_root.add_child(e)
                e.global_position = world_pos
                e.rotation.y = world_yaw
                spawn_count.enemy += 1
            if n.has_meta("pickup_kind"):
                var kind: String = str(n.get_meta("pickup_kind"))
                var world_pos_p: Vector3 = n3.global_position
                var p: Node3D = ObjectSpawner._make_pickup(kind)
                world_root.add_child(p)
                p.global_position = world_pos_p
                spawn_count.pickup += 1
            if n.has_meta("warp_to") and n is Area3D:
                var target_level: String = str(n.get_meta("warp_to"))
                var area: Area3D = n as Area3D
                # Force mask=1 so Mario's layer-1 body triggers the warp —
                # the scene authoring set mask=2 which misses everything.
                area.collision_mask = 1
                area.body_entered.connect(
                    func(body: Node) -> void:
                        if body == mario:
                            call_deferred("load_level", target_level, 1))
                spawn_count.warp += 1
    if spawn_count.enemy > 0 or spawn_count.pickup > 0 or spawn_count.warp > 0:
        print("[level_manager] seeded %d enemies, %d pickups, %d warps from scene markers"
              % [spawn_count.enemy, spawn_count.pickup, spawn_count.warp])


func _find_spawn(level_root: Node) -> Vector3:
    # Walk the loaded level scene looking for a node with a spawn_point
    # meta. The world-scenes agent places this on an Area3D named
    # "SpawnArea" under LevelRoot.
    var queue: Array = [level_root]
    while not queue.is_empty():
        var n: Node = queue.pop_front()
        if n.has_meta("spawn_point"):
            var v: Variant = n.get_meta("spawn_point")
            if v is Vector3:
                return v
        for c in n.get_children():
            queue.append(c)
    return FALLBACK_SPAWN
