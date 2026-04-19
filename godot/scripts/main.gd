extends Node3D

const LevelLoader := preload("res://scripts/level_loader.gd")
const MODEL_JSON := "res://extracted/levels/bob/area_1/model.json"
const COLLISION_JSON := "res://extracted/levels/bob/area_1/collision.json"
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

# Yaw: rotation about world Y. Pitch: angle above horizontal (+ = camera above).
var _cam_yaw := 0.0
var _cam_pitch := 0.25


func _ready() -> void:
    LevelLoader.load_level(MODEL_JSON, COLLISION_JSON, world)
    mario.global_position = MARIO_SPAWN
    mario.set_camera(camera)
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    # Toggle collision shape visibility (F1); helpful while we're debugging
    # the physics handoff from the converter.
    get_tree().debug_collisions_hint = false


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


func _process(_delta: float) -> void:
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
    hud_label.text = (
        "pos: %.2f,%.2f,%.2f   floor: %s   vel.y: %.2f\n"
        + "ray down: %s\n"
        + "ray up:   %s\n"
        + "[R] respawn  [F1] collision  [Esc] cursor"
    ) % [
        mario.global_position.x, mario.global_position.y, mario.global_position.z,
        str(mario.is_on_floor()), mario.velocity.y,
        ray_down, ray_up,
    ]
