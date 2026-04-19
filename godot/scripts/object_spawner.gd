extends Node

# Spawns the OBJECT() macros parsed from a level's script.c into the world.

const EnemyScript := preload("res://scripts/enemy.gd")
# The decomp maps a (MODEL_*, bhv*) pair to a specific actor + behavior at
# runtime; we stub most of those with placeholder nodes while the per-object
# behaviors get ported incrementally. Coins and stars are the first real
# implementations because they're the gameplay core of SM64.

const LevelLoader := preload("res://scripts/level_loader.gd")


# Behaviors we implement fully. Everything else spawns a debug marker.
const BHV_IMPLEMENTATIONS := {
    # Coins
    "bhvYellowCoin": "coin_yellow",
    "bhvSingleCoinGetsSpawned": "coin_yellow",
    "bhvMovingYellowCoin": "coin_yellow",
    "bhvBlueCoinSliding": "coin_blue",
    "bhvBlueCoin": "coin_blue",
    "bhvRedCoin": "coin_red",
    # Stars
    "bhvStar": "star",
    "bhvStarSpawnCoordinates": "star",
    "bhvHiddenStar": "star",
    # One-ups
    "bhv1Up": "oneup",
    "bhv1UpWalking": "oneup",
    # Caps
    "bhvWingCap": "cap_wing",
    "bhvMetalCap": "cap_metal",
    "bhvVanishCap": "cap_vanish",
}


# Behaviors that spawn as walking enemies.
const ENEMY_BEHAVIORS := [
    "bhvGoomba", "bhvGoombaTripletSpawner",
    "bhvKoopa",
    "bhvBobomb", "bhvBobombBuddy",
    "bhvChuckya",
    "bhvPiranhaPlant",
    "bhvMrBlizzard", "bhvMrBlizzardHidden",
    "bhvSmallPenguin",
    "bhvScuttlebug",
    "bhvMoneybag", "bhvMoneybagHidden",
    "bhvSpindrift",
    "bhvFlyGuy",
    "bhvSnufit",
]


static func spawn_area_objects(
    objects: Array, parent: Node3D, _manager: Node
) -> void:
    var spawned := 0
    var enemies := 0
    var pickups := 0
    for obj in objects:
        var bhv: String = obj.get("bhv", "")
        var kind: String = BHV_IMPLEMENTATIONS.get(bhv, "")
        var node: Node3D = null
        if kind != "":
            node = _make_pickup(kind)
            pickups += 1
        elif bhv in ENEMY_BEHAVIORS:
            node = _make_enemy(bhv)
            enemies += 1
        if node == null:
            node = _make_debug_marker(bhv)
        var p: Array = obj.pos
        node.position = Vector3(p[0], p[1], p[2]) * LevelLoader.WORLD_SCALE
        var a: Array = obj.angle
        var to_rad := (TAU / 65536.0) if abs(a[1]) > 360 else (PI / 180.0)
        node.rotation.y = a[1] * to_rad
        parent.add_child(node)
        spawned += 1
    print("[object_spawner] spawned %d objects (%d pickups, %d enemies)"
          % [spawned, pickups, enemies])


static func _make_enemy(bhv: String) -> Node3D:
    var e := CharacterBody3D.new()
    e.set_script(EnemyScript)
    e.bhv_name = bhv
    e.name = "Enemy_" + bhv
    return e


# pickup_kind → extracted actor mesh subdir, when we have one.
const PICKUP_ACTORS := {
    "coin_yellow": "coin_yellow",
    "coin_blue":   "coin_blue",
    "coin_red":    "coin_yellow",
    "star":        "star",
    "oneup":       "oneup",
}


static func _make_pickup(kind: String) -> Node3D:
    var body := Area3D.new()
    body.name = "Pickup_" + kind
    body.set_meta("pickup_kind", kind)

    var shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = 0.35
    shape.shape = sphere
    body.add_child(shape)

    # Prefer a real actor mesh where we have one extracted; fall back to
    # the glowing sphere for caps (no cap actor yet) and any unknown kind.
    var actor_sub: String = PICKUP_ACTORS.get(kind, "")
    if actor_sub != "":
        var mesh_path := "res://extracted/actors/%s/mesh.json" % actor_sub
        if FileAccess.file_exists(mesh_path):
            var anchor := Node3D.new()
            anchor.name = "ActorAnchor"
            body.add_child(anchor)
            LevelLoader.load_actor(mesh_path, anchor)
            return body

    var mesh_inst := MeshInstance3D.new()
    var sphere_mesh := SphereMesh.new()
    sphere_mesh.radius = 0.3
    sphere_mesh.height = 0.6
    mesh_inst.mesh = sphere_mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = _pickup_color(kind)
    mat.emission_enabled = true
    mat.emission = mat.albedo_color * 0.5
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mesh_inst.material_override = mat
    body.add_child(mesh_inst)
    return body


static func _pickup_color(kind: String) -> Color:
    match kind:
        "coin_yellow": return Color(1.0, 0.85, 0.1)
        "coin_blue":   return Color(0.2, 0.5, 1.0)
        "coin_red":    return Color(1.0, 0.2, 0.2)
        "star":        return Color(1.0, 1.0, 0.3)
        "oneup":       return Color(0.4, 1.0, 0.4)
        "cap_wing":    return Color(1.0, 1.0, 0.9)
        "cap_metal":   return Color(0.7, 0.7, 0.8)
        "cap_vanish":  return Color(0.8, 0.4, 1.0)
        _:             return Color(1, 1, 1)


static func _make_debug_marker(bhv: String) -> Node3D:
    # A faint gray capsule so you can see object placement without every
    # object having a real model yet.
    var n := MeshInstance3D.new()
    n.name = "ObjStub_" + bhv
    var mesh := CapsuleMesh.new()
    mesh.radius = 0.15
    mesh.height = 0.5
    n.mesh = mesh
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.35, 0.35, 0.42, 0.7)
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    n.material_override = mat
    return n
