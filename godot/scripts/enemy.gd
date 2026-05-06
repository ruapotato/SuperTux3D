extends CharacterBody3D

# Lightweight generic enemy node. The bhv name (from the level layout)
# determines visual scene and behavior parameters.

const GRAVITY := 30.0

# bhv name → path to the enemy visual scene. Multiple bhvs can share a
# scene (Chuckya uses the bomb visual; GoombaTripletSpawner uses the
# goomba visual as a placeholder).
const ENEMY_SCENES := {
    "bhvGoomba":                   "res://assets/enemies/goomba.tscn",
    "bhvGoombaTripletSpawner":     "res://assets/enemies/goomba.tscn",
    "bhvKoopa":                    "res://assets/enemies/koopa.tscn",
    "bhvKoopaShellUnderwater":     "res://assets/enemies/koopa.tscn",
    "bhvBobomb":                   "res://assets/enemies/bobomb.tscn",
    "bhvBobombBuddy":              "res://assets/enemies/bobomb_buddy.tscn",
    "bhvBobombBuddyOpensCannon":   "res://assets/enemies/bobomb_buddy.tscn",
    "bhvChuckya":                  "res://assets/enemies/bobomb.tscn",
    "bhvPiranhaPlant":             "res://assets/enemies/piranha_plant.tscn",
    "bhvChainChomp":               "res://assets/enemies/chain_chomp.tscn",
    # Original aerial predator — glides toward the player at height.
    "bhvCuttlefish":               "res://assets/enemies/cuttlefish.tscn",
}

@export var bhv_name: String = "bhvGoomba"
@export var patrol_radius: float = 3.0
@export var speed: float = 2.0

var _center: Vector3
var _time: float = 0.0
var life: int = 1
var _squished: bool = false
var _hurt_area: Area3D
var _mesh: Node3D   # the instantiated enemy visual scene
var _mode: String = "patrol"     # patrol / chase / static / bomb / pop
var _fuse: float = 0.0
var _exploded: bool = false
# Snapshot of where the cuttlefish committed to dive at the end of
# its telegraph phase. Reset every cycle. Storing this means the
# dive trajectory is FIXED — Mario who runs sideways during the
# dive itself escapes; Mario who stands still gets hit.
var _dive_target: Vector3 = Vector3.ZERO


func _ready() -> void:
    _center = global_position
    _mode = _mode_for_bhv(bhv_name)
    _randomize_motion()
    _build_visual()
    # Tag aerial predators so they can query each other for flocking
    # separation in _physics_process.
    if bhv_name == "bhvCuttlefish":
        add_to_group("cuttlefish")
    # Friendly NPCs (BobombBuddy) don't have a hurt area — Mario bumps
    # past them harmlessly. Everything else gets the squish/hurt zone.
    if _mode != "friendly":
        _build_hurt_area()
    collision_layer = 2
    collision_mask = 1

    # Per-mode tuning tweaks.
    match _mode:
        "chase":    speed = 3.0
        "bomb":     speed = 3.5
        "static":   speed = 0.0
        "pop":      speed = 0.0
        "friendly": speed = 0.0
        "glide":    speed = 3.2  # aerial predator — slow enough that Mario can outrun
        "chomp":    speed = 5.5  # bursts forward when lunging


static func _mode_for_bhv(bhv: String) -> String:
    match bhv:
        "bhvBobomb":        return "bomb"
        # Chuckya grabs you in the decomp; we don't have that anim so
        # approximate with an aggressive chase.
        "bhvChuckya":       return "chase"
        # Shelled critter walks patrols and doesn't actively attack.
        "bhvKoopa":         return "patrol"
        "bhvPiranhaPlant":  return "pop"
        "bhvMrBlizzard", "bhvMrBlizzardHidden": return "static"
        "bhvSnufit", "bhvFlyGuy":               return "static"
        # Aerial glider: hovers, drifts toward the player, periodically
        # swoops. Separate mode because it needs to bypass gravity.
        "bhvCuttlefish":    return "glide"
        # Chain chomp sits at its spawn (tethered) and lunges toward
        # the player when they wander within leash range.
        "bhvChainChomp":    return "chomp"
        # The mossy-stone NPC is friendly — stand still, no hurt area.
        "bhvBobombBuddy", "bhvBobombBuddyOpensCannon": return "friendly"
        _:                  return "patrol"


func _randomize_motion() -> void:
    # Slight per-instance variance so identical goombas don't march in sync.
    _time = randf() * 2.0 * PI


func _build_visual() -> void:
    var scene_path: String = ENEMY_SCENES.get(bhv_name, "")
    if scene_path != "" and ResourceLoader.exists(scene_path):
        var scene: PackedScene = load(scene_path)
        var visual: Node3D = scene.instantiate()
        visual.name = "Visual"
        # Enemy scenes were authored facing +Z (looking "back" in Godot
        # convention). Flip the visual 180° around Y so the eyes and
        # fronts end up at -Z, matching the movement direction.
        visual.rotate_y(PI)
        add_child(visual)
        _mesh = visual
        # Add a collision capsule so the enemy stands on the floor.
        var cs := CollisionShape3D.new()
        var caps := CapsuleShape3D.new()
        caps.radius = 0.3
        caps.height = 0.8
        cs.shape = caps
        cs.position.y = 0.4
        add_child(cs)
    else:
        _build_placeholder_mesh()


func _build_placeholder_mesh() -> void:
    _mesh = MeshInstance3D.new()
    var sph := SphereMesh.new()
    sph.radius = 0.35
    sph.height = 0.7
    _mesh.mesh = sph
    var mat := StandardMaterial3D.new()
    mat.albedo_color = _visual_color_for(bhv_name)
    mat.emission_enabled = true
    mat.emission = mat.albedo_color * 0.3
    _mesh.material_override = mat
    _mesh.position.y = 0.4
    add_child(_mesh)


func _build_hurt_area() -> void:
    # Per-bhv hurt volume. Most enemies are sphere-ish around hip
    # height; piranha plant is a tall capsule because its head is at
    # +1m; chain chomp is big and spherical.
    _hurt_area = Area3D.new()
    _hurt_area.name = "HurtArea"
    var cs := CollisionShape3D.new()
    match bhv_name:
        "bhvPiranhaPlant":
            var cap := CapsuleShape3D.new()
            cap.radius = 0.45
            cap.height = 1.4
            cs.shape = cap
            cs.position.y = 0.75
        "bhvChainChomp":
            var sph := SphereShape3D.new()
            sph.radius = 0.8
            cs.shape = sph
            cs.position.y = 0.8
        "bhvKoopa", "bhvKoopaShellUnderwater":
            var cap := CapsuleShape3D.new()
            cap.radius = 0.4
            cap.height = 0.9
            cs.shape = cap
            cs.position.y = 0.5
        "bhvCuttlefish":
            # Reach DOWN from the enemy origin so a well-timed jump
            # reliably catches the cuttlefish — the mantle center is
            # ~2m up when hovering, and Tux maxes out at ~1.5m tall
            # even on a triple jump from below. Extending the hurt
            # capsule down gives real overlap.
            var cap := CapsuleShape3D.new()
            cap.radius = 0.65
            cap.height = 2.2
            cs.shape = cap
            cs.position.y = -0.7
        _:
            var sph := SphereShape3D.new()
            sph.radius = 0.55
            cs.shape = sph
            cs.position.y = 0.45
    _hurt_area.add_child(cs)
    # Layer 4 (arbitrary), mask 1 so Mario's body triggers us. Without
    # this the hurt area uses default layer/mask and won't collide with
    # Mario's CharacterBody3D in some project settings.
    _hurt_area.collision_layer = 0
    _hurt_area.collision_mask = 1
    add_child(_hurt_area)
    _hurt_area.body_entered.connect(_on_body_entered)


static func _visual_color_for(bhv: String) -> Color:
    # Color-coded stand-ins until we port the real actor models.
    match bhv:
        "bhvGoomba", "bhvGoombaTripletSpawner": return Color(0.55, 0.30, 0.15)
        "bhvKoopa", "bhvKoopaShellUnderwater":   return Color(0.25, 0.65, 0.30)
        "bhvBobomb", "bhvBobombBuddy":           return Color(0.15, 0.15, 0.15)
        "bhvChuckya":                            return Color(0.25, 0.4, 0.7)
        "bhvPiranhaPlant":                       return Color(0.85, 0.15, 0.25)
        "bhvMrBlizzard", "bhvMrBlizzardHidden":  return Color(0.95, 0.95, 1.0)
        "bhvSmallPenguin", "bhvRacingPenguin":   return Color(0.1, 0.1, 0.3)
        _:                                       return Color(0.6, 0.35, 0.35)


func _physics_process(delta: float) -> void:
    if _squished or _exploded:
        return
    _time += delta
    var mario := _find_mario()
    var dir := Vector3.ZERO

    match _mode:
        "patrol":
            var angle: float = _time * (speed / max(patrol_radius, 0.5))
            var target := _center + Vector3(
                sin(angle) * patrol_radius, 0, cos(angle) * patrol_radius)
            dir = target - global_position
            # Ledge check: cast a short ray forward+down from ~0.4m
            # ahead. If there's no floor there, reverse direction by
            # shifting _time so the sine orbit flips phase. Prevents the
            # goomba from marching off the edge of a platform.
            if dir.length() > 0.01:
                var ahead: Vector3 = dir.normalized() * 0.8
                var ray_from: Vector3 = global_position + ahead + Vector3(0, 0.3, 0)
                var ray_to: Vector3 = ray_from + Vector3(0, -1.5, 0)
                var space := get_world_3d().direct_space_state
                var params := PhysicsRayQueryParameters3D.create(
                    ray_from, ray_to, 1)
                params.exclude = [self]
                var hit := space.intersect_ray(params)
                if hit.is_empty():
                    _time += PI  # flip orbit phase → walk back
                    dir = -dir
        "chase":
            if mario != null and global_position.distance_to(mario.global_position) < 12.0:
                dir = mario.global_position - global_position
            else:
                var angle2: float = _time * (speed / max(patrol_radius, 0.5))
                dir = _center + Vector3(
                    sin(angle2) * patrol_radius, 0, cos(angle2) * patrol_radius
                ) - global_position
        "bomb":
            # Bombs detonate on fuse-timer expiry only — proximity
            # contact alone used to insta-explode the moment Mario
            # got close, leaving him no time to react. Now the bomb
            # ignites when in range, chases, and pulses faster as the
            # 3-second fuse runs down. Player can outrun it, stomp it,
            # or just stay outside its 6m engagement radius until it
            # cools off.
            if mario != null and global_position.distance_to(mario.global_position) < 6.0:
                dir = mario.global_position - global_position
                _fuse += delta
                if _mesh != null:
                    var flash_hz: float = clamp(3.0 + _fuse * 12.0, 3.0, 30.0)
                    var puls: float = 1.0 + sin(_time * flash_hz) * (_fuse * 0.28)
                    _mesh.scale = Vector3(puls, puls, puls)
                if _fuse > 3.0:
                    _explode(mario)
                    return
            else:
                _fuse = max(_fuse - delta * 0.5, 0.0)
        "pop", "static", "friendly":
            pass  # no movement; hurt area still active (except friendly)
        "chomp":
            # Chained guardian: stays near _center within a leash of
            # ~6m. Lunges toward the player when they enter the leash;
            # returns to anchor when player is out of range or after
            # a brief recovery. Tether is enforced hard — if lunging
            # would exceed the leash, the chomp snaps back.
            var leash: float = 6.0
            var to_anchor: Vector3 = _center - global_position
            to_anchor.y = 0.0
            if mario != null:
                var to_mario: Vector3 = mario.global_position - global_position
                to_mario.y = 0.0
                var player_dist: float = to_mario.length()
                var from_anchor: float = (global_position - _center).length()
                if player_dist < leash + 2.0 and from_anchor < leash:
                    # Player is in range — lunge.
                    dir = to_mario
                elif from_anchor > leash:
                    # Leash snapped — pull back to anchor.
                    dir = to_anchor
                else:
                    # Idle shimmy at the tether end.
                    dir = to_anchor * 0.2
            else:
                dir = to_anchor
            # Visual anger pulse: short scale pump when within lunge
            # range of the player.
            if _mesh != null and mario != null:
                var dclose: float = global_position.distance_to(mario.global_position)
                var pump: float = 1.0
                if dclose < leash:
                    pump = 1.0 + sin(_time * 14.0) * 0.08
                _mesh.scale = _mesh.scale.lerp(Vector3(pump, pump, pump), 0.2)
        "glide":
            # Aerial predator with separation + telegraphed swoop. The
            # 9-second cycle gives the player a clear window to dodge:
            #   0..3s    Idle orbit around spawn point
            #   3..5s    Approach: drift to a position above the player
            #   5..5.5s  TELEGRAPH: hover in place, tilt forward,
            #            snapshot the player's CURRENT position as the
            #            dive target. Visible cue.
            #   5.5..6.4s DIVE: hard-target the snapshotted point at
            #            constant speed. Mario who moved during the
            #            telegraph escapes; standing still gets hit.
            #   6.4..9s  Retreat: climb back to hover altitude, body
            #            level out.
            var hover_y: float = _center.y + 2.2
            var target: Vector3 = _center
            target.y = hover_y + sin(_time * 1.6) * 0.35
            var idle_angle: float = _time * 0.6
            target.x = _center.x + cos(idle_angle) * 3.0
            target.z = _center.z + sin(idle_angle) * 3.0
            var aggressive: bool = false
            var diving: bool = false
            if mario != null:
                var cycle: float = fposmod(_time, 9.0)
                var dist: float = global_position.distance_to(mario.global_position)
                if cycle > 3.0 and cycle < 5.0 and dist < 14.0:
                    # Approach: hover above player at altitude.
                    target = mario.global_position
                    target.y = hover_y
                elif cycle >= 5.0 and cycle < 5.5 and dist < 14.0:
                    # Telegraph: hold position, tilt down, lock target.
                    target = global_position
                    if _mesh != null:
                        _mesh.rotation.x = lerp(_mesh.rotation.x, -1.1, 0.25)
                    _dive_target = mario.global_position + Vector3(0, 0.3, 0)
                elif cycle >= 5.5 and cycle < 6.4:
                    # Commit dive — fixed target, constant speed.
                    target = _dive_target
                    aggressive = true
                    diving = true
                else:
                    # Idle / approach / retreat — body level.
                    if _mesh != null:
                        _mesh.rotation.x = lerp(_mesh.rotation.x, 0.0, 0.10)
            var separation: Vector3 = Vector3.ZERO
            for node in get_tree().get_nodes_in_group("cuttlefish"):
                if node == self:
                    continue
                if node is Node3D:
                    var diff: Vector3 = global_position - node.global_position
                    var d: float = diff.length()
                    if d < 3.0 and d > 0.01:
                        separation += diff.normalized() * (3.0 - d)
            var to_target: Vector3 = target - global_position
            var move_dir: Vector3 = to_target.normalized() + separation * 0.6
            if move_dir.length() > 0.01:
                move_dir = move_dir.normalized()
            # Dive multiplier kept moderate so Mario can outrun the
            # cuttlefish horizontally even mid-dive — gameplay relies
            # on dodging the FIXED dive trajectory, not winning a
            # speed race.
            var dive_speed: float = speed * (1.6 if diving else 1.0)
            var move_step: float = dive_speed * delta
            global_position += move_dir * move_step
            if to_target.length() > 0.01:
                rotation.y = atan2(-to_target.x, -to_target.z)
            return  # skip the ground-walker pipeline below

    dir.y = 0.0
    if dir.length() > 0.01:
        dir = dir.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    velocity.x = dir.x * speed
    velocity.z = dir.z * speed
    velocity.y -= GRAVITY * delta
    move_and_slide()


func _find_mario() -> Node3D:
    # Mario is a direct child of Main; walk up from our parent chain.
    var n: Node = self
    while n != null and n.name != "Main":
        n = n.get_parent()
    if n == null:
        return null
    return n.get_node_or_null("Mario")


func _explode(mario: Node) -> void:
    _exploded = true
    # Visual pop: briefly enlarge then fade.
    if _mesh != null:
        _mesh.scale = Vector3(2.0, 2.0, 2.0)
    if _hurt_area != null:
        _hurt_area.queue_free()
    if mario != null and mario.has_method("take_damage"):
        mario.take_damage(2, bhv_name)
    var t := Timer.new()
    t.wait_time = 0.3
    t.one_shot = true
    add_child(t)
    t.timeout.connect(queue_free)
    t.start()


func _on_body_entered(body: Node) -> void:
    if _squished:
        return
    if body is CharacterBody3D and body.has_method("take_damage"):
        # Stomp if the player came from above — check either a vertical
        # offset (they're above our head) OR they're falling and
        # somewhere in the top half of our volume. Was too strict before
        # — tall enemies and high-stomp impacts weren't registering.
        var player_y: float = body.global_position.y
        var enemy_y: float = global_position.y
        var from_above: bool = player_y > enemy_y + 0.3
        var falling: bool = body.velocity.y < 2.0
        if from_above and falling:
            _squish()
            if body.has_method("on_enemy_squished"):
                body.on_enemy_squished()
        else:
            body.take_damage(1, bhv_name)


func _squish() -> void:
    _squished = true
    # Flatten the enemy to the floor. scale on the actor anchor affects
    # everything beneath.
    if _mesh != null:
        _mesh.scale = Vector3(1.4, 0.2, 1.4)
    if _hurt_area != null:
        _hurt_area.queue_free()
    var t := Timer.new()
    t.wait_time = 0.35
    t.one_shot = true
    add_child(t)
    t.timeout.connect(queue_free)
    t.start()
