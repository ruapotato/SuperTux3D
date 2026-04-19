extends CharacterBody3D

# Adapter between Godot's CharacterBody3D + Input + the decomp-style
# MarioState dispatcher in mario_state.gd. Reads input, hands it to the
# state, applies resulting velocity to CharacterBody3D, feeds floor/anim-end
# signals back for the next tick. Also routes animation requests to the
# MarioAnimator through a `main` reference.

const MarioStateScript := preload("res://scripts/mario_state.gd")

var _state: RefCounted
var _animator: RefCounted          # mario_animator.gd
var _anim_owner                    # main.gd, for anim lookup by ID
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


func bind_animator(animator: RefCounted, owner: Node) -> void:
    _animator = animator
    _anim_owner = owner


func current_action_name() -> String:
    if _state == null:
        return "(no state)"
    match _state.action:
        MarioStateScript.ACT_IDLE:                return "IDLE[%d]" % _state.action_state
        MarioStateScript.ACT_WALKING:             return "WALKING"
        MarioStateScript.ACT_BRAKING:             return "BRAKING"
        MarioStateScript.ACT_JUMP:                return "JUMP"
        MarioStateScript.ACT_FREEFALL:            return "FREEFALL"
        MarioStateScript.ACT_JUMP_LAND:           return "JUMP_LAND"
        MarioStateScript.ACT_FREEFALL_LAND:       return "FREEFALL_LAND"
        MarioStateScript.ACT_JUMP_LAND_STOP:      return "JUMP_LAND_STOP"
        MarioStateScript.ACT_FREEFALL_LAND_STOP:  return "FREEFALL_LAND_STOP"
        _:                                        return "0x%08X" % _state.action
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
    # Feed input + contact state into MarioState, run dispatch.
    _state.input_stick = Vector2(
        Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
        Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward"),
    )
    _state.input_jump_pressed = Input.is_action_just_pressed("jump")
    _state.input_camera_yaw = _camera_yaw()
    _state.is_on_floor = is_on_floor()
    _state.pos = global_position
    _state.anim_at_end = _animator != null and _animator.is_at_end()

    _state.step(delta)

    # Honor the state's animation request — load-on-demand through main.
    if _animator != null and _anim_owner != null and _state.requested_anim >= 0:
        var id: int = _state.requested_anim
        var speed: float = _state.requested_anim_speed
        if _state.requested_anim_reset or _animator.current_anim_id != id:
            var anim_data: Dictionary = _anim_owner.get_anim(id)
            if not anim_data.is_empty():
                _animator.play(anim_data, speed, id)
        else:
            _animator.set_speed(speed)

    velocity = _state.vel
    move_and_slide()
    _state.pos = global_position

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
