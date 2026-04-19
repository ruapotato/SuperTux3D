extends CharacterBody3D

# Placeholder capsule controller used to validate level geometry + collision.
# Will be replaced with the real decomp-ported Mario state machine.

# Units are Godot world units (see LevelLoader.WORLD_SCALE = 0.01). So 1 unit
# here maps to 100 decomp units: walk_speed=16 means Mario moves 1600 decomp
# units/sec, close to Mario's decomp run speed.
@export var walk_speed: float = 16.0     # units/sec
@export var jump_speed: float = 24.0     # initial vertical velocity (units/sec)
@export var gravity: float = 70.0        # units/sec^2

var _camera_node: Camera3D
var _ray_down: RayCast3D
var _ray_up: RayCast3D

# Latest raycast observations, read by main.gd for HUD.
var debug_ray_down_hit: String = "(no hit)"
var debug_ray_up_hit: String = "(no hit)"


func _ready() -> void:
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
    var input_dir := Vector2(
        Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
        Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward"),
    )

    # Camera-relative movement on the horizontal plane.
    var basis_xz := Basis()
    if _camera_node != null:
        var cb := _camera_node.global_transform.basis
        var fwd := -cb.z
        fwd.y = 0.0
        if fwd.length() > 0.001:
            fwd = fwd.normalized()
        var right := cb.x
        right.y = 0.0
        if right.length() > 0.001:
            right = right.normalized()
        basis_xz = Basis(right, Vector3.UP, -fwd)

    var move_xz := basis_xz * Vector3(input_dir.x, 0.0, input_dir.y)
    velocity.x = move_xz.x * walk_speed
    velocity.z = move_xz.z * walk_speed

    if is_on_floor():
        # Small downward pull keeps the body snapped to slopes so ramps don't
        # bounce. move_and_slide cancels the residual velocity on contact.
        velocity.y = -1.0
        if Input.is_action_just_pressed("jump"):
            velocity.y = jump_speed
    else:
        velocity.y -= gravity * delta

    move_and_slide()
    _sample_rays()
