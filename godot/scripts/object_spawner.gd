extends Node

# Spawns the OBJECT() macros parsed from a level's script.c into the world.
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


static func spawn_area_objects(
    objects: Array, parent: Node3D, _manager: Node
) -> void:
    var spawned := 0
    for obj in objects:
        var bhv: String = obj.get("bhv", "")
        var kind: String = BHV_IMPLEMENTATIONS.get(bhv, "")
        var node: Node3D = null
        if kind != "":
            node = _make_pickup(kind)
        # We always spawn something so the level is populated visibly even
        # before all behaviors are ported. Unrecognized objects get a small
        # debug marker; they'll be replaced as we port their behaviors.
        if node == null:
            node = _make_debug_marker(bhv)
        var p: Array = obj.pos
        node.position = Vector3(p[0], p[1], p[2]) * LevelLoader.WORLD_SCALE
        var a: Array = obj.angle
        var to_rad := TAU / 65536.0 if abs(a[1]) > 360 else PI / 180.0
        # SM64 angles can be either s16 (65536=360°) or plain degrees
        # depending on the macro. Most OBJECT() args are degrees; pick the
        # heuristic by magnitude.
        node.rotation.y = a[1] * to_rad
        parent.add_child(node)
        spawned += 1
    print("[object_spawner] spawned %d objects" % spawned)


static func _make_pickup(kind: String) -> Node3D:
    # A small floating sphere with a color hint. Mario's pickup collision
    # is handled in mario_stub.gd via an Area3D check later.
    var body := Area3D.new()
    body.name = "Pickup_" + kind
    body.set_meta("pickup_kind", kind)

    var shape := CollisionShape3D.new()
    var sphere := SphereShape3D.new()
    sphere.radius = 0.3
    shape.shape = sphere
    body.add_child(shape)

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
