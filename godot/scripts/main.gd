extends Node3D

const LevelLoader := preload("res://scripts/level_loader.gd")
const MarioAnimator := preload("res://scripts/mario_animator.gd")
const MODEL_JSON := "res://extracted/levels/bob/area_1/model.json"
const COLLISION_JSON := "res://extracted/levels/bob/area_1/collision.json"
const MARIO_MESH_JSON := "res://extracted/actors/mario/mesh.json"
const ANIMS_DIR := "res://extracted/actors/mario/anims"
# Actual spawn from decomp levels/bob/script.c: MARIO_POS(1, 135, -6558, 0, 6464).
# Scaled to Godot world scale (see LevelLoader.WORLD_SCALE). +2 Y offset for
# a small cushion so the capsule doesn't start clipped into the floor.
const MARIO_SPAWN := Vector3(-6558.0, 0.0, 6464.0) * LevelLoader.WORLD_SCALE + Vector3(0, 2, 0)

# Orbit camera settings (Godot world scale ~= meters).
# Lakitu-ish defaults: ~7 units behind Mario, pitched slightly down.
const CAM_DISTANCE := 7.0
const MOUSE_SENSITIVITY := 0.005
# Focus point offset from Mario's feet (~chest height).
const FOCUS_OFFSET := Vector3(0, 1.0, 0)

@onready var world: Node3D = $World
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var camera_rig: Node3D = $CameraRig
@onready var mario: CharacterBody3D = $Mario
@onready var hud_label: Label = $UI/HUD

var _animator: RefCounted
# Animation cache keyed by decomp ID (MARIO_ANIM_* integer). Loaded lazily
# the first time a state requests it.
var _anim_cache: Dictionary = {}

# Yaw: rotation about world Y. Pitch: angle above horizontal (+ = camera above).
var _cam_yaw := 0.0
var _cam_pitch := 0.25


func _ready() -> void:
    LevelLoader.load_level(MODEL_JSON, COLLISION_JSON, world)
    var anchor: Node3D = mario.get_node("ActorAnchor")
    var actor: Dictionary = LevelLoader.load_actor(MARIO_MESH_JSON, anchor)
    _setup_animator(actor)
    mario.global_position = MARIO_SPAWN
    mario.set_camera(camera)
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    get_tree().debug_collisions_hint = false


func _setup_animator(actor: Dictionary) -> void:
    if actor.is_empty():
        return
    _animator = MarioAnimator.new()
    var rest_rots: Array = []
    var rest_model: Variant = _read_json(MARIO_MESH_JSON)
    if rest_model is Dictionary:
        for b in rest_model.bones:
            var r: Array = b.rest_rotation
            var to_rad: float = TAU / 65536.0
            rest_rots.append(Vector3(r[0] * to_rad, r[1] * to_rad, r[2] * to_rad))
    _animator.setup(actor.bones, rest_rots)
    # Hand the animator to Mario so MarioState can request animations by ID.
    if mario.has_method("bind_animator"):
        mario.bind_animator(_animator, self)


func get_anim(anim_id: int) -> Dictionary:
    # Resolve a MARIO_ANIM_* ID to the parsed animation JSON, lazily loading
    # from disk on first request and caching thereafter.
    if _anim_cache.has(anim_id):
        return _anim_cache[anim_id]
    var path := "%s/anim_%02X.json" % [ANIMS_DIR, anim_id]
    var parsed: Variant = _read_json(path)
    if parsed is Dictionary:
        _anim_cache[anim_id] = parsed
        return parsed
    push_warning("main: missing animation 0x%02X at %s" % [anim_id, path])
    _anim_cache[anim_id] = {}
    return {}


func _read_json(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        return null
    var f := FileAccess.open(path, FileAccess.READ)
    return JSON.parse_string(f.get_as_text())


func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        _cam_yaw -= event.relative.x * MOUSE_SENSITIVITY
        # Mouse up → look up (camera pitches lower so it looks upward).
        _cam_pitch = clamp(_cam_pitch + event.relative.y * MOUSE_SENSITIVITY,
                           -0.4, 1.2)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        Input.mouse_mode = (Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
                            else Input.MOUSE_MODE_CAPTURED)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
        _respawn()
    elif event is InputEventKey and event.pressed and event.keycode == KEY_F1:
        get_tree().debug_collisions_hint = not get_tree().debug_collisions_hint
        # debug_collisions_hint only affects NEW shapes — re-add existing ones.
        _reload_debug_shapes()


func _respawn() -> void:
    mario.global_position = MARIO_SPAWN
    mario.velocity = Vector3.ZERO


func _update_animation(delta: float) -> void:
    if _animator == null:
        return
    _animator.tick(delta)


func _reload_debug_shapes() -> void:
    # Toggling debug_collisions_hint at runtime only affects newly-added
    # collision shapes, so re-parent all CollisionShape3D nodes in `world` to
    # force them to re-register with a debug mesh attached.
    for body in world.get_children():
        for child in body.get_children():
            if child is CollisionShape3D:
                var parent := child.get_parent()
                parent.remove_child(child)
                parent.add_child(child)


func _process(delta: float) -> void:
    _update_animation(delta)
    var focus: Vector3 = mario.global_position + FOCUS_OFFSET
    # Standard orbital: pitch > 0 lifts the camera above the focus.
    var offset := Vector3(
        sin(_cam_yaw) * cos(_cam_pitch),
        sin(_cam_pitch),
        cos(_cam_yaw) * cos(_cam_pitch),
    ) * CAM_DISTANCE
    camera_rig.global_position = focus + offset
    camera_rig.look_at(focus, Vector3.UP)
    # Auto-respawn if we fall below the level.
    if mario.global_position.y < -50.0:
        _respawn()
    var mario_stub := mario as CharacterBody3D
    var ray_down: String = mario.get("debug_ray_down_hit")
    var ray_up: String = mario.get("debug_ray_up_hit")
    var anim_state: String = "(none)"
    if _animator != null:
        anim_state = _animator.debug_state()
    var action_name: String = ""
    if mario.has_method("current_action_name"):
        action_name = mario.current_action_name()
    hud_label.text = (
        "pos: %.2f,%.2f,%.2f   floor: %s   vel: (%.2f,%.2f,%.2f)\n"
        + "action: %s\n"
        + "anim: %s\n"
        + "[R] respawn  [F1] collision  [Esc] cursor"
    ) % [
        mario.global_position.x, mario.global_position.y, mario.global_position.z,
        str(mario.is_on_floor()),
        mario.velocity.x, mario.velocity.y, mario.velocity.z,
        action_name, anim_state,
    ]
