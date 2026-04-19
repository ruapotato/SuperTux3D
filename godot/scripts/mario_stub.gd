extends CharacterBody3D

# Thin adapter between Godot's CharacterBody3D + Input system and the decomp-
# style MarioState dispatcher in mario_state.gd. Reads input, hands it to the
# state machine, lets the state set velocity, runs move_and_slide, feeds floor
# contact back into the state for the next tick. Also orients the visible
# Mario mesh under ActorAnchor to match the state's face_yaw.
#
# The physics constants and action semantics live in mario_state.gd — this
# file is just plumbing.

const MarioStateScript := preload("res://scripts/mario_state.gd")

var _state: RefCounted
var _camera_node: Camera3D
var _ray_down: RayCast3D
var _ray_up: RayCast3D
var _actor_anchor: Node3D

# Latest raycast observations, read by main.gd for HUD.
var debug_ray_down_hit: String = "(no hit)"
var debug_ray_up_hit: String = "(no hit)"


func _ready() -> void:
    _state = MarioStateScript.new()
    _actor_anchor = get_node_or_null("ActorAnchor")
    _ray_down = RayCast3D.new()
    _ray_down.name = "RayDown"
    _ray_down.target_position = Vector3(0, -10.0, 0)  # 10 units = 1000 decomp
    _ray_down.enabled = true
    _ray_down.collide_with_bodies = true
    _ray_down.collide_with_areas = false
    # Start above the capsule's base to avoid self-intersection.
    _ray_down.position = Vector3(0, 0.2, 0)
    add_child(_ray_down)

    _ray_up = RayCast3D.new()
    _ray_up.name = "RayUp"
    _ray_up.target_position = Vector3(0, 10.0, 0)
    _ray_up.enabled = true
    _ray_up.collide_with_bodies = true
    _ray_up.position = Vector3(0, 1.6, 0)
    add_child(_ray_up)


func set_camera(cam: Camera3D) -> void:
    _camera_node = cam


func _sample_rays() -> void:
    if _ray_down and _ray_down.is_colliding():
        var p: Vector3 = _ray_down.get_collision_point()
        var c: Object = _ray_down.get_collider()
        debug_ray_down_hit = "%s @ (%.1f,%.1f,%.1f) dist %.2f" % [
            c.name if c else "?", p.x, p.y, p.z, global_position.distance_to(p),
        ]
    else:
        debug_ray_down_hit = "(no hit)"
    if _ray_up and _ray_up.is_colliding():
        var p2: Vector3 = _ray_up.get_collision_point()
        var c2: Object = _ray_up.get_collider()
        debug_ray_up_hit = "%s @ (%.1f,%.1f,%.1f) dist %.2f" % [
            c2.name if c2 else "?", p2.x, p2.y, p2.z, global_position.distance_to(p2),
        ]
    else:
        debug_ray_up_hit = "(no hit)"


func _physics_process(delta: float) -> void:
    # Pull input into the MarioState, step the action dispatch, apply vel.
    _state.input_stick = Vector2(
        Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
        Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward"),
    )
    _state.input_jump_pressed = Input.is_action_just_pressed("jump")
    _state.input_camera_yaw = _camera_yaw()
    _state.is_on_floor = is_on_floor()
    _state.pos = global_position

    _state.step(delta)

    velocity = _state.vel
    move_and_slide()
    _state.pos = global_position

    # Orient the visible Mario mesh under ActorAnchor to the state's face_yaw.
    if _actor_anchor != null:
        _actor_anchor.rotation.y = _state.face_yaw

    _sample_rays()


func _camera_yaw() -> float:
    if _camera_node == null:
        return 0.0
    # Yaw is the rotation of camera forward around Y. atan2(-fwd.x, -fwd.z)
    # gives 0 when the camera looks along -Z (Godot forward).
    var fwd := -_camera_node.global_transform.basis.z
    return atan2(-fwd.x, -fwd.z)
