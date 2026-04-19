extends CharacterBody3D

# Lightweight generic enemy node. The bhv name (from the decomp level
# script) determines visual and behavior parameters. Enough to populate
# levels with moving hazards — not a line-by-line decomp port of each
# behavior's state machine, which is future work.
#
# Mario interacts with enemies via body_entered on the enemy's Area3D:
# - Mario above + falling / ground-pounding → enemy squished (dies)
# - Mario on ground level → Mario takes a hit (brief invulnerability)

const GRAVITY := 30.0

@export var bhv_name: String = "bhvGoomba"
@export var patrol_radius: float = 3.0
@export var speed: float = 2.0

var _center: Vector3
var _time: float = 0.0
var life: int = 1
var _squished: bool = false
var _hurt_area: Area3D
var _mesh: MeshInstance3D


func _ready() -> void:
    _center = global_position
    _randomize_motion()
    _build_visual()
    _build_hurt_area()


func _randomize_motion() -> void:
    # Slight per-instance variance so identical goombas don't march in sync.
    _time = randf() * 2.0 * PI


func _build_visual() -> void:
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

    # Collision capsule so the enemy can stand on the floor.
    var cs := CollisionShape3D.new()
    var caps := CapsuleShape3D.new()
    caps.radius = 0.3
    caps.height = 0.8
    cs.shape = caps
    cs.position.y = 0.4
    add_child(cs)


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
    if _squished:
        return
    _time += delta
    # Drive a simple sinusoidal patrol around the spawn center.
    var angle := _time * (speed / max(patrol_radius, 0.5))
    var target := _center + Vector3(
        sin(angle) * patrol_radius, 0, cos(angle) * patrol_radius
    )
    var dir := target - global_position
    dir.y = 0.0
    if dir.length() > 0.01:
        dir = dir.normalized()
        rotation.y = atan2(-dir.x, -dir.z)
    velocity.x = dir.x * speed
    velocity.z = dir.z * speed
    velocity.y -= GRAVITY * delta
    move_and_slide()


func _on_body_entered(body: Node) -> void:
    if _squished:
        return
    if body is CharacterBody3D and body.has_method("take_damage"):
        # If Mario is clearly above (falling, ground-pounding), squish.
        var mario_y := body.global_position.y
        if mario_y > global_position.y + 0.6 and body.velocity.y <= 0.0:
            _squish()
            if body.has_method("on_enemy_squished"):
                body.on_enemy_squished()
        else:
            body.take_damage(1, bhv_name)


func _squish() -> void:
    _squished = true
    # Flatten the enemy to the floor, then remove after a brief moment so
    # the squish is visible.
    if _mesh != null:
        _mesh.scale = Vector3(1.4, 0.2, 1.4)
        _mesh.position.y = 0.06
    if _hurt_area != null:
        _hurt_area.queue_free()
    var t := Timer.new()
    t.wait_time = 0.35
    t.one_shot = true
    add_child(t)
    t.timeout.connect(queue_free)
    t.start()
