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
var _pickup_area: Area3D
var _sound_bank: Node
var _prev_action_for_sfx: int = 0
var _shadow: MeshInstance3D
var _shadow_ray: RayCast3D

# Damage / invulnerability.
var health: int = 8
var invulnerable_time: float = 0.0
signal took_damage
signal died

# Collected totals + timed power-ups. HUD in main.gd reads these.
var coin_count: int = 0
var star_count: int = 0
var lives: int = 4
var power_cap: String = ""      # "wing" / "metal" / "vanish" / ""
var power_cap_time: float = 0.0  # seconds remaining

var _prev_crouch: bool = false
var _prev_attack: bool = false
# Water level Y in Godot units. -INF → no water. LevelManager sets this
# per level; only the water-themed levels (JRB, DDD, CotMC, SA, WDW)
# have a non-trivial value.
var water_level_y: float = -INF

signal star_collected

# Latest raycast observations, read by main.gd for HUD.
var debug_ray_down_hit: String = "(no hit)"
var debug_ray_up_hit: String = "(no hit)"


const _ACTION_NAMES := {
    "IDLE": 0x0C400201, "CROUCHING": 0x0C008220,
    "JUMP_LAND_STOP": 0x0C000230, "DOUBLE_JUMP_LAND_STOP": 0x0C000231,
    "FREEFALL_LAND_STOP": 0x0C000232, "SIDE_FLIP_LAND_STOP": 0x0C000233,
    "BACKFLIP_LAND_STOP": 0x0800022F, "TRIPLE_JUMP_LAND_STOP": 0x0800023A,
    "LONG_JUMP_LAND_STOP": 0x0800023B, "GROUND_POUND_LAND": 0x0080023C,
    "BRAKING_STOP": 0x0C00023D,
    "WALKING": 0x04000440, "BRAKING": 0x04000445,
    "DIVE_SLIDE": 0x00880456, "CROUCH_SLIDE": 0x04808459,
    "JUMP_LAND": 0x04000470, "FREEFALL_LAND": 0x04000471,
    "DOUBLE_JUMP_LAND": 0x04000472, "SIDE_FLIP_LAND": 0x04000473,
    "TRIPLE_JUMP_LAND": 0x04000478, "LONG_JUMP_LAND": 0x00000479,
    "BACKFLIP_LAND": 0x0400047A,
    "JUMP": 0x03000880, "DOUBLE_JUMP": 0x03000881,
    "TRIPLE_JUMP": 0x01000882, "BACKFLIP": 0x01000883,
    "WALL_KICK_AIR": 0x03000886, "SIDE_FLIP": 0x01000887,
    "LONG_JUMP": 0x03000888, "DIVE": 0x0188088A,
    "FREEFALL": 0x0100088C, "GROUND_POUND": 0x008008A9,
    "PUNCHING": 0x00800380,
}


func _ready() -> void:
    _state = MarioStateScript.new()
    _actor_anchor = get_node_or_null("ActorAnchor")

    # Pickup sensor — larger than Mario's body so coins feel generous to grab.
    _pickup_area = Area3D.new()
    _pickup_area.name = "PickupArea"
    var cs := CollisionShape3D.new()
    var sph := SphereShape3D.new()
    sph.radius = 0.9
    cs.shape = sph
    cs.position = Vector3(0, 0.8, 0)
    _pickup_area.add_child(cs)
    _pickup_area.area_entered.connect(_on_pickup)
    add_child(_pickup_area)

    _ray_down = RayCast3D.new()
    _ray_down.name = "RayDown"
    _ray_down.target_position = Vector3(0, -10.0, 0)
    _ray_down.enabled = true
    _ray_down.collide_with_bodies = true
    _ray_down.collide_with_areas = false
    _ray_down.position = Vector3(0, 0.2, 0)
    add_child(_ray_down)

    _ray_up = RayCast3D.new()
    _ray_up.name = "RayUp"
    _ray_up.target_position = Vector3(0, 10.0, 0)
    _ray_up.enabled = true
    _ray_up.collide_with_bodies = true
    _ray_up.position = Vector3(0, 1.6, 0)
    add_child(_ray_up)

    # Shadow blob — a flat dark disk projected onto the floor directly
    # under Mario via a downward raycast. Much cheaper than a real-time
    # shadow and keeps the "height over ground" cue even in camera angles
    # where the directional light's shadow doesn't render clearly.
    _shadow_ray = RayCast3D.new()
    _shadow_ray.target_position = Vector3(0, -20.0, 0)
    _shadow_ray.enabled = true
    _shadow_ray.collide_with_bodies = true
    _shadow_ray.position = Vector3(0, 0.2, 0)
    add_child(_shadow_ray)
    _shadow = MeshInstance3D.new()
    var disk := CylinderMesh.new()
    disk.top_radius = 0.4
    disk.bottom_radius = 0.4
    disk.height = 0.01
    disk.radial_segments = 16
    _shadow.mesh = disk
    var shadow_mat := StandardMaterial3D.new()
    shadow_mat.albedo_color = Color(0, 0, 0, 0.55)
    shadow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    shadow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    _shadow.material_override = shadow_mat
    _shadow.top_level = true  # world-space, not parented to Mario's rotation
    add_child(_shadow)


func set_camera(cam: Camera3D) -> void:
    _camera_node = cam


func bind_animator(animator: RefCounted, owner: Node) -> void:
    _animator = animator
    _anim_owner = owner


func bind_sound_bank(bank: Node) -> void:
    _sound_bank = bank


func _play_sfx(name: String) -> void:
    if _sound_bank != null:
        _sound_bank.play(name)


func take_damage(amount: int, _source: String) -> void:
    if invulnerable_time > 0.0 or power_cap == "metal":
        return
    health = max(health - amount, 0)
    invulnerable_time = 1.2
    _play_sfx("punch")
    emit_signal("took_damage")
    if health <= 0:
        _play_sfx("death")
        emit_signal("died")
        health = 8  # respawn with refresh; level_manager handles repositioning


func on_enemy_squished() -> void:
    # Small hop rebound after squishing an enemy, matches SM64 feel.
    velocity.y = max(velocity.y, 8.0)
    _play_sfx("punch")


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
    # Crouch = Ctrl (held). Attack/dive/punch = Shift (press).
    _state.input_crouch = Input.is_key_pressed(KEY_CTRL)
    _state.input_crouch_pressed = (
        Input.is_key_pressed(KEY_CTRL) and not _prev_crouch
    )
    _prev_crouch = Input.is_key_pressed(KEY_CTRL)
    # Attack / dive / punch — Shift key OR left mouse click.
    var attack_held := (
        Input.is_key_pressed(KEY_SHIFT)
        or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
    )
    _state.input_attack_pressed = attack_held and not _prev_attack
    _prev_attack = attack_held
    _state.input_camera_yaw = _camera_yaw()
    _state.is_on_floor = is_on_floor()
    _state.is_on_wall = is_on_wall()
    _state.wall_normal = get_wall_normal() if is_on_wall() else Vector3.ZERO
    _state.pos = global_position
    _state.anim_at_end = _animator != null and _animator.is_at_end()
    _state.power_cap = power_cap
    _state.water_level_y = water_level_y

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
    # Pick the surface kind we're standing on (each surface type got its
    # own collision body in level_loader). Default if we weren't touching
    # anything tagged — e.g. safety floor or pickups.
    _state.floor_surface = "default"
    for i in range(get_slide_collision_count()):
        var c := get_slide_collision(i)
        if c == null:
            continue
        var normal := c.get_normal()
        if normal.y > 0.5:  # floor-ish
            var collider := c.get_collider()
            if collider is Node and collider.has_meta("surface_kind"):
                _state.floor_surface = collider.get_meta("surface_kind")
                break

    if _actor_anchor != null:
        _actor_anchor.rotation.y = _state.face_yaw

    _sample_rays()
    _update_shadow()
    _play_state_sfx()
    if power_cap_time > 0.0:
        power_cap_time = max(power_cap_time - delta, 0.0)
        if power_cap_time == 0.0:
            power_cap = ""
    if invulnerable_time > 0.0:
        invulnerable_time = max(invulnerable_time - delta, 0.0)
    # I-frame blink: toggle mesh visibility at ~8 Hz so the player can see
    # they're invulnerable without a full material modification pass.
    if _actor_anchor != null:
        var want_visible := true
        if invulnerable_time > 0.0:
            want_visible = int(Time.get_ticks_msec() / 80) % 2 == 0
        _actor_anchor.visible = want_visible


func _update_shadow() -> void:
    if _shadow_ray == null or _shadow == null:
        return
    if _shadow_ray.is_colliding():
        var hit: Vector3 = _shadow_ray.get_collision_point()
        _shadow.visible = true
        _shadow.global_position = hit + Vector3(0, 0.02, 0)
        # Flatten to the floor's orientation.
        var up: Vector3 = _shadow_ray.get_collision_normal()
        if up.length() > 0.001:
            var basis := Basis.looking_at(Vector3.FORWARD, up.normalized())
            _shadow.global_transform.basis = basis
        # Dim and shrink the shadow as Mario rises (depth cue).
        var alt := global_position.y - hit.y
        var mat := _shadow.material_override as StandardMaterial3D
        if mat != null:
            var a: float = clamp(0.55 - alt * 0.1, 0.1, 0.55)
            mat.albedo_color.a = a
        var scale_factor: float = clamp(1.0 - alt * 0.05, 0.4, 1.0)
        _shadow.scale = Vector3(scale_factor, 1.0, scale_factor)
    else:
        _shadow.visible = false


func _play_state_sfx() -> void:
    # Trigger a sound on specific action transitions. We key off the action
    # code changing rather than the animation event, so wall-kicks,
    # double jumps, etc. all trigger once when they start.
    var a: int = _state.action
    if a == _prev_action_for_sfx:
        return
    _prev_action_for_sfx = a
    match a:
        MarioStateScript.ACT_JUMP, \
        MarioStateScript.ACT_DOUBLE_JUMP, \
        MarioStateScript.ACT_TRIPLE_JUMP, \
        MarioStateScript.ACT_BACKFLIP, \
        MarioStateScript.ACT_SIDE_FLIP, \
        MarioStateScript.ACT_LONG_JUMP, \
        MarioStateScript.ACT_WALL_KICK_AIR:
            _play_sfx("jump")
        MarioStateScript.ACT_JUMP_LAND, \
        MarioStateScript.ACT_DOUBLE_JUMP_LAND, \
        MarioStateScript.ACT_TRIPLE_JUMP_LAND, \
        MarioStateScript.ACT_LONG_JUMP_LAND, \
        MarioStateScript.ACT_BACKFLIP_LAND, \
        MarioStateScript.ACT_SIDE_FLIP_LAND, \
        MarioStateScript.ACT_FREEFALL_LAND:
            _play_sfx("land")
        MarioStateScript.ACT_GROUND_POUND_LAND:
            _play_sfx("ground_pound")
        MarioStateScript.ACT_PUNCHING:
            _play_sfx("punch")


func _on_pickup(other: Area3D) -> void:
    if not other.has_meta("pickup_kind"):
        return
    var kind: String = other.get_meta("pickup_kind")
    match kind:
        "coin_yellow":
            coin_count += 1
            _play_sfx("coin")
        "coin_blue":
            coin_count += 5
            _play_sfx("coin")
        "coin_red":
            coin_count += 2
            _play_sfx("coin")
        "oneup":
            lives += 1
            _play_sfx("oneup")
        "star":
            star_count += 1
            _play_sfx("star")
            emit_signal("star_collected")
        "cap_wing":
            power_cap = "wing"
            power_cap_time = 20.0
            _play_sfx("cap")
        "cap_metal":
            power_cap = "metal"
            power_cap_time = 20.0
            _play_sfx("cap")
        "cap_vanish":
            power_cap = "vanish"
            power_cap_time = 20.0
            _play_sfx("cap")
    other.queue_free()


func _camera_yaw() -> float:
    if _camera_node == null:
        return 0.0
    # Yaw is the rotation of camera forward around Y. atan2(-fwd.x, -fwd.z)
    # gives 0 when the camera looks along -Z (Godot forward).
    var fwd := -_camera_node.global_transform.basis.z
    return atan2(-fwd.x, -fwd.z)
