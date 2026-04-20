extends CharacterBody3D

# Adapter between Godot's CharacterBody3D + Input + the MarioState
# dispatcher in mario_state.gd. Reads input, hands it to the state,
# applies resulting velocity to CharacterBody3D, feeds floor/anim-end
# signals back for the next tick. Routes animation requests to the
# clean-room procedural animator via a `main` reference.

const MarioStateScript := preload("res://scripts/mario_state.gd")

var _state: RefCounted
var _animator: RefCounted          # clean_character_anim.gd
var _anim_owner                    # main.gd, for anim lookup by ID
var _camera_node: Camera3D
var _ray_down: RayCast3D
var _ray_up: RayCast3D
var _actor_anchor: Node3D
var _pickup_area: Area3D
# Narrow Area3D at Mario's feet that watches for WaterArea nodes
# emitted by terrain_patch.gd on painted water cells. The swim state
# requires both pos.y < water_level_y AND this sensor overlapping a
# water_area — otherwise walking out of a pond onto grass at the
# same Y would keep Mario looped in swim.
var _water_sensor: Area3D
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
# Inventory of collected keys ("bronze", "silver", "gold"). Locked
# doors check has_key() before letting the player through.
var keys: Array[String] = []


func has_key(color: String) -> bool:
    return color in keys


func consume_key(color: String) -> bool:
    # Remove one copy of the key; returns true if it was there. Lets
    # doors be one-shot (consumes) or reusable (peek via has_key).
    var idx: int = keys.find(color)
    if idx < 0:
        return false
    keys.remove_at(idx)
    return true

var _prev_crouch: bool = false
var _prev_attack: bool = false
# Horizontal velocity we asked move_and_slide to apply this tick,
# captured BEFORE the slide runs. After a slide, a wall-blocked motion
# zeroes the velocity field — the step-up logic needs the *intended*
# motion direction to know "which way was I trying to go?"
var _intended_h_vel: Vector3 = Vector3.ZERO
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

    # Feet-level water sensor. Narrow box at the player's feet so only
    # being *directly over* a painted water cell counts. Layer/mask
    # match the pickup area so water Area3Ds (emitted on layer 1 with
    # meta water_area) register here.
    _water_sensor = Area3D.new()
    _water_sensor.name = "WaterSensor"
    _water_sensor.collision_layer = 0
    _water_sensor.collision_mask = 1
    var ws_cs := CollisionShape3D.new()
    var ws_box := BoxShape3D.new()
    ws_box.size = Vector3(0.55, 0.4, 0.55)
    ws_cs.shape = ws_box
    ws_cs.position = Vector3(0, 0.2, 0)
    _water_sensor.add_child(ws_cs)
    add_child(_water_sensor)

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
    _play_sfx("damage")     # Mario's "attacked" grunt from decomp
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
    # A stair riser is a 30–50cm vertical face — technically a wall, so
    # is_on_wall() returns true. Feeding that raw into the state trips
    # ACT_WALL_KICK_AIR every time Mario's toe bumps the next tread,
    # launching him away from the stairs. Instead probe INTO the wall
    # at head height — only TALL walls (full-height faces) count for
    # wall kicks, so short risers get ignored and the stair plays nicely.
    _state.is_on_wall = _is_on_tall_wall()
    _state.wall_normal = get_wall_normal() if is_on_wall() else Vector3.ZERO
    _state.pos = global_position
    _state.anim_at_end = _animator != null and _animator.is_at_end()
    _state.power_cap = power_cap
    _state.water_level_y = water_level_y
    # Am I horizontally over a painted water cell? Required for swim
    # state to trigger OR stay active — the global water_level_y alone
    # would false-fire on grass that happens to sit near the water's Y.
    _state.in_water_area = false
    if _water_sensor != null:
        for wa in _water_sensor.get_overlapping_areas():
            if wa.has_meta("water_area"):
                _state.in_water_area = true
                break
    # Report pole-zone overlap to the state. We test the pickup Area3D's
    # overlaps; anything with meta("pole_zone") is climbable.
    _state.near_pole = false
    if _pickup_area != null:
        for area in _pickup_area.get_overlapping_areas():
            if area.has_meta("pole_zone"):
                _state.near_pole = true
                _state.pole_origin = area.global_position
                _state.pole_top_y = area.global_position.y + 3.0
                _state.pole_bottom_y = area.global_position.y - 0.5
                break

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

    # If the state moved Mario directly (e.g. pole snap), honor it before
    # move_and_slide so velocity-driven motion starts from the snapped pos.
    if _state.pos.distance_to(global_position) > 0.001:
        global_position = _state.pos
    velocity = _state.vel
    _intended_h_vel = Vector3(velocity.x, 0.0, velocity.z)
    move_and_slide()
    _state.pos = global_position
    # Pick the surface kind we're standing on. Level .tscn files can tag
    # their StaticBody3Ds with set_meta("surface_kind", "ice"/"slippery"/
    # "very_slippery"/"burning"/"water"/...) to change Mario's friction
    # or apply damage. Default when nothing is tagged.
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

    # Step-up pass: if horizontal motion got pinched against a short
    # obstacle while Mario was on the floor, lift him over it so stairs
    # (and curb-height ledges) are just walkable — no jump required.
    _try_step_up()

    _sample_rays()
    _update_shadow()
    _play_state_sfx()
    if power_cap_time > 0.0:
        power_cap_time = max(power_cap_time - delta, 0.0)
        if power_cap_time == 0.0:
            power_cap = ""
    # Below the world → take lethal damage. Catches falls into pits
    # before the safety floor does (the floor exists to prevent
    # infinite falls, not to save the player).
    if global_position.y < -15.0 and invulnerable_time <= 0.0:
        take_damage(health, "void")
    if invulnerable_time > 0.0:
        invulnerable_time = max(invulnerable_time - delta, 0.0)
    # I-frame blink: toggle mesh visibility at ~8 Hz so the player can see
    # they're invulnerable without a full material modification pass.
    if _actor_anchor != null:
        var want_visible := true
        if invulnerable_time > 0.0:
            want_visible = int(Time.get_ticks_msec() / 80) % 2 == 0
        _actor_anchor.visible = want_visible


# Max ledge height Mario can auto-climb without jumping. Tuned just
# above the tallest stair riser we generate (~0.42m) so every stair
# walks cleanly while a genuine 0.6m ledge still blocks forward motion.
const STEP_UP_MAX := 0.55
# Only walls reaching above this y-offset from Mario's feet qualify as
# "tall" — stair risers (≤ 0.5m) and curb-height blocks get ignored so
# they don't false-trigger wall kicks.
const TALL_WALL_HEAD_Y := 1.1


func _is_on_tall_wall() -> bool:
    if not is_on_wall():
        return false
    var n := get_wall_normal()
    if n.length() < 0.01:
        return false
    # Probe from HEAD height directly into the wall (opposite the
    # wall normal). If the ray hits solid geometry within a short
    # reach, the wall extends up past Mario's shoulders and is a real
    # wall worth kicking off; if it misses, we're brushing a low riser.
    var from: Vector3 = global_position + Vector3(0, TALL_WALL_HEAD_Y, 0)
    var to: Vector3 = from + (-n) * 0.6
    var space := get_world_3d().direct_space_state
    var q := PhysicsRayQueryParameters3D.create(from, to, 1)
    q.exclude = [self]
    var hit := space.intersect_ray(q)
    return not hit.is_empty()


func _try_step_up() -> void:
    # Only step-up while grounded with horizontal intent. Jumping or
    # falling over a ledge uses the normal physics and shouldn't be
    # magnetized to nearby platforms.
    if not is_on_floor():
        return
    # Read the INTENDED velocity, not the post-slide velocity. When
    # move_and_slide is blocked by a wall it zeroes that component, so
    # the post-slide vector points nowhere — meaning the loop below
    # would never find a wall-opposing direction. Using the intended
    # velocity recovers the original direction of travel.
    var h_vel := _intended_h_vel
    if h_vel.length() < 0.8:
        return
    var move_dir := h_vel.normalized()
    # Did we actually hit something blocking us? If slide count is
    # zero (no obstacles), skip the raycasts — nothing to step over.
    var hit_wall: bool = false
    for i in range(get_slide_collision_count()):
        var c := get_slide_collision(i)
        if c == null:
            continue
        var n := c.get_normal()
        if abs(n.y) > 0.3:
            continue              # floor/ceiling, not a wall
        if n.dot(move_dir) > -0.2:
            continue              # wall isn't in our way
        hit_wall = true
        break
    if not hit_wall:
        return
    _probe_step_up(move_dir)


func _probe_step_up(move_dir: Vector3) -> bool:
    # Ask the physics world: if I were STEP_UP_MAX higher and one
    # Mario-radius forward, would I be unblocked AND above a floor?
    # If both, lift Mario onto that floor. Two ray casts — cheap.
    var step_up := Vector3(0, STEP_UP_MAX, 0)
    var forward_reach: float = 0.45
    var from := global_position + step_up
    var to := from + move_dir * forward_reach
    var space := get_world_3d().direct_space_state

    var q_forward := PhysicsRayQueryParameters3D.create(from, to, 1)
    q_forward.exclude = [self]
    if not space.intersect_ray(q_forward).is_empty():
        return false   # still blocked at step height — obstacle is taller than STEP_UP_MAX

    var q_down := PhysicsRayQueryParameters3D.create(
        to, to + Vector3(0, -(STEP_UP_MAX + 0.15), 0), 1)
    q_down.exclude = [self]
    var hit_down := space.intersect_ray(q_down)
    if hit_down.is_empty():
        return false   # no floor at step height — just a gap, not a step

    var floor_y: float = (hit_down["position"] as Vector3).y
    var lift: float = floor_y - global_position.y + 0.02
    if lift <= 0.0 or lift > STEP_UP_MAX:
        return false
    global_position.y += lift
    return true


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
    # Trigger a sound on specific action transitions. Each jump variant
    # gets an appropriately-iconic voice clip instead of sharing one bank
    # (wall kick gets "uh", triple jump gets "yahoo", dive gets "yah").
    var a: int = _state.action
    if a == _prev_action_for_sfx:
        return
    _prev_action_for_sfx = a
    match a:
        MarioStateScript.ACT_JUMP, MarioStateScript.ACT_SIDE_FLIP:
            _play_sfx("jump")
        MarioStateScript.ACT_DOUBLE_JUMP:
            _play_sfx("double_jump")
        MarioStateScript.ACT_TRIPLE_JUMP:
            _play_sfx("triple_jump")
        MarioStateScript.ACT_LONG_JUMP:
            _play_sfx("long_jump")
        MarioStateScript.ACT_BACKFLIP:
            _play_sfx("backflip")
        MarioStateScript.ACT_WALL_KICK_AIR:
            _play_sfx("wall_kick")
        MarioStateScript.ACT_DIVE:
            _play_sfx("dive")
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
            _break_nearby_blocks()
        MarioStateScript.ACT_PUNCHING:
            _play_sfx("punch")


func _break_nearby_blocks() -> void:
    # Ground-pound smashes any breakable block within 2m. Each block is
    # registered in the 'breakable' group by level_manager when it
    # finds meta('breakable'=true) in the level scene. On break, we
    # optionally spawn the reward listed in meta('reward_kind').
    for node in get_tree().get_nodes_in_group("breakable"):
        if not (node is Node3D):
            continue
        var n3: Node3D = node
        if global_position.distance_to(n3.global_position) > 2.0:
            continue
        var reward: String = str(n3.get_meta("reward_kind", ""))
        var reward_pos: Vector3 = n3.global_position
        if reward != "":
            _spawn_reward_at(reward, reward_pos)
        n3.queue_free()


func _spawn_reward_at(kind: String, pos: Vector3) -> void:
    # Import the spawner on demand to avoid circular preload. Uses the
    # same PICKUP_SCENES table that normal pickups use.
    var ObjectSpawner := preload("res://scripts/object_spawner.gd")
    var p: Node3D = ObjectSpawner._make_pickup(kind)
    get_tree().current_scene.add_child(p)
    p.global_position = pos


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
            _play_sfx("star_yahoo")
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
        "key_bronze", "key_silver", "key_gold":
            var color: String = kind.substr(4)  # strip "key_"
            if not has_key(color):  # don't stack duplicates
                keys.append(color)
            _play_sfx("cap")
    other.queue_free()


func _camera_yaw() -> float:
    if _camera_node == null:
        return 0.0
    # Yaw is the rotation of camera forward around Y. atan2(-fwd.x, -fwd.z)
    # gives 0 when the camera looks along -Z (Godot forward).
    var fwd := -_camera_node.global_transform.basis.z
    return atan2(-fwd.x, -fwd.z)
