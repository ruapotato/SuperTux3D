extends CharacterBody3D

# Lightweight generic enemy node. The bhv name (from the decomp level
# script) determines visual and behavior parameters.

const GRAVITY := 30.0
const LevelLoader := preload("res://scripts/level_loader.gd")
const MarioAnimator := preload("res://scripts/mario_animator.gd")

# bhv name → (actor mesh subdir, approximate world-scale factor). Actors
# use the same actor-space axes as Mario, so the same loader applies.
const ACTOR_MESHES := {
    "bhvGoomba":               "goomba",
    "bhvGoombaTripletSpawner": "goomba",
    "bhvKoopa":                "koopa",
    "bhvKoopaShellUnderwater": "koopa_shell",
    "bhvBobomb":               "bobomb",
    "bhvBobombBuddy":          "bobomb_buddy",
    "bhvChuckya":              "bobomb",
    "bhvPiranhaPlant":         "piranha_plant",
    "bhvSmallPenguin":         "penguin",
    "bhvRacingPenguin":        "penguin",
}

@export var bhv_name: String = "bhvGoomba"
@export var patrol_radius: float = 3.0
@export var speed: float = 2.0

var _center: Vector3
var _time: float = 0.0
var life: int = 1
var _squished: bool = false
var _hurt_area: Area3D
var _mesh: Node3D   # MeshInstance3D or loaded actor root
var _mode: String = "patrol"     # patrol / chase / static / bomb / pop
var _fuse: float = 0.0
var _exploded: bool = false
var _animator: RefCounted


func _ready() -> void:
    _center = global_position
    _mode = _mode_for_bhv(bhv_name)
    _randomize_motion()
    _build_visual()
    _build_hurt_area()
    collision_layer = 2
    collision_mask = 1

    # Per-mode tuning tweaks.
    match _mode:
        "chase":  speed = 3.0
        "bomb":   speed = 3.5
        "static": speed = 0.0
        "pop":    speed = 0.0


static func _mode_for_bhv(bhv: String) -> String:
    match bhv:
        "bhvBobomb":        return "bomb"
        # Chuckya grabs Mario in the decomp; we don't have the grab
        # animation ported so approximate with an aggressive chase.
        "bhvChuckya":       return "chase"
        # Koopas walk patrols in SM64 and only attack if bumped into —
        # use a calm patrol, not chase.
        "bhvKoopa":         return "patrol"
        "bhvPiranhaPlant":  return "pop"
        "bhvMrBlizzard", "bhvMrBlizzardHidden": return "static"
        "bhvSnufit", "bhvFlyGuy":               return "static"
        _:                  return "patrol"


func _randomize_motion() -> void:
    # Slight per-instance variance so identical goombas don't march in sync.
    _time = randf() * 2.0 * PI


func _build_visual() -> void:
    # Prefer a real decomp actor mesh if we have one extracted for this bhv.
    var actor_sub: String = ACTOR_MESHES.get(bhv_name, "")
    if actor_sub != "":
        var mesh_path := "res://extracted/actors/%s/mesh.json" % actor_sub
        if FileAccess.file_exists(mesh_path):
            var actor_anchor := Node3D.new()
            actor_anchor.name = "ActorAnchor"
            add_child(actor_anchor)
            # Decide axis mode: decomp anim data carries bone 0 =
            # Ry(+90°) + bone 1 = Rz(+90°) across every actor (not just
            # Mario), so if we're going to play an animation we must
            # use "mario" mode so those rotations compensate out into
            # upright/face-forward. Without an animation the mesh's
            # natural frame needs "rigid".
            var anim_data := _find_walk_animation(actor_sub)
            var mode := "mario" if not anim_data.is_empty() else "rigid"
            var actor: Dictionary = LevelLoader.load_actor(
                mesh_path, actor_anchor, mode,
                anim_data if not anim_data.is_empty() else null,
            )
            _mesh = actor_anchor
            if not anim_data.is_empty():
                _start_animation(actor, anim_data)
        else:
            _build_placeholder_mesh()
    else:
        _build_placeholder_mesh()


func _find_walk_animation(actor_sub: String) -> Dictionary:
    # Pick the first JSON in the actor's anims/ dir. For Koopa that's
    # its walking cycle; for Goomba it's the only anim they have. We
    # don't try to match anim-by-name — the first one is always fine
    # as the default-pose walk cycle in the decomp's layout.
    var anims_dir := "res://extracted/actors/%s/anims" % actor_sub
    var d := DirAccess.open(anims_dir)
    if d == null:
        return {}
    for f in d.get_files():
        if not f.ends_with(".json"):
            continue
        var file := FileAccess.open("%s/%s" % [anims_dir, f], FileAccess.READ)
        if file == null:
            continue
        var parsed: Variant = JSON.parse_string(file.get_as_text())
        if parsed is Dictionary:
            return parsed
    return {}


func _start_animation(actor: Dictionary, anim_data: Dictionary) -> void:
    if actor.is_empty() or anim_data.is_empty():
        return
    # Verify bone counts match so anim tracks address valid bones.
    if int(anim_data.bone_count) != actor.bones.size():
        # Mismatched skeleton; skip rather than crash at runtime.
        return
    _animator = MarioAnimator.new()
    var rest_rots: Array = []
    for b in actor.bones.size():
        var bone_node: Node3D = actor.bones[b]
        if bone_node != null:
            rest_rots.append(bone_node.rotation)
        else:
            rest_rots.append(Vector3.ZERO)
    _animator.setup(actor.bones, rest_rots)
    _animator.frames_per_second = 30.0
    _animator.play(anim_data, 1.0, 0)

    # Collision capsule so the enemy can stand on the floor.
    var cs := CollisionShape3D.new()
    var caps := CapsuleShape3D.new()
    caps.radius = 0.3
    caps.height = 0.8
    cs.shape = caps
    cs.position.y = 0.4
    add_child(cs)


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
    _hurt_area = Area3D.new()
    _hurt_area.name = "HurtArea"
    var cs := CollisionShape3D.new()
    var sph := SphereShape3D.new()
    sph.radius = 0.55
    cs.shape = sph
    cs.position.y = 0.4
    _hurt_area.add_child(cs)
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
    if _animator != null:
        _animator.tick(delta)
    var mario := _find_mario()
    var dir := Vector3.ZERO

    match _mode:
        "patrol":
            var angle: float = _time * (speed / max(patrol_radius, 0.5))
            var target := _center + Vector3(
                sin(angle) * patrol_radius, 0, cos(angle) * patrol_radius)
            dir = target - global_position
        "chase":
            if mario != null and global_position.distance_to(mario.global_position) < 12.0:
                dir = mario.global_position - global_position
            else:
                var angle2: float = _time * (speed / max(patrol_radius, 0.5))
                dir = _center + Vector3(
                    sin(angle2) * patrol_radius, 0, cos(angle2) * patrol_radius
                ) - global_position
        "bomb":
            if mario != null and global_position.distance_to(mario.global_position) < 6.0:
                dir = mario.global_position - global_position
                _fuse += delta
                # Pulse scale as the fuse ticks (visual warning).
                if _mesh != null:
                    var puls: float = 1.0 + sin(_time * 12.0) * (_fuse * 0.25)
                    _mesh.scale = Vector3(puls, puls, puls)
                if _fuse > 3.0 or global_position.distance_to(mario.global_position) < 1.0:
                    _explode(mario)
                    return
            else:
                _fuse = max(_fuse - delta * 0.5, 0.0)
        "pop", "static":
            pass  # no movement; hurt area still active

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
        # If Mario is clearly above (falling, ground-pounding), squish.
        var mario_y: float = body.global_position.y
        if mario_y > global_position.y + 0.6 and body.velocity.y <= 0.0:
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
