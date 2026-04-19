extends Node

# Spawns the OBJECT() macros parsed from a level's script.c into the world.

const EnemyScript := preload("res://scripts/enemy.gd")
const PickupBobScript := preload("res://scripts/pickup_bob.gd")

# Warp-like behaviors. Enter the matching Area3D → warp to the level/area
# the bhv_param WARP_NODE points at.
const WARP_BEHAVIORS := [
    "bhvDoorWarp", "bhvWarp", "bhvInstantActiveWarp",
    "bhvStarDoor",
    "bhvPaintingStarCollectWarp",
    "bhvLaunchStarCollectWarp", "bhvAirborneStarCollectWarp",
]
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
    objects: Array, parent: Node3D, manager: Node, warps: Array = []
) -> void:
    var spawned := 0
    var enemies := 0
    var pickups := 0
    var warp_triggers := 0
    # Build a lookup from WARP_NODE_id → (level, area).
    var warp_lookup := {}
    for w in warps:
        warp_lookup[str(w.id)] = w
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
        elif bhv in WARP_BEHAVIORS:
            node = _make_warp_trigger(bhv, obj, warp_lookup, manager)
            if node != null:
                warp_triggers += 1
        if node == null:
            node = _make_debug_marker(bhv)
        var p: Array = obj.pos
        node.position = Vector3(p[0], p[1], p[2]) * LevelLoader.WORLD_SCALE
        var a: Array = obj.angle
        var to_rad: float = (TAU / 65536.0) if abs(a[1]) > 360 else (PI / 180.0)
        node.rotation.y = a[1] * to_rad
        parent.add_child(node)
        spawned += 1
    print("[object_spawner] spawned %d objects (%d pickups, %d enemies, %d warps)"
          % [spawned, pickups, enemies, warp_triggers])


static func _make_warp_trigger(
    bhv: String, obj: Dictionary, warp_lookup: Dictionary, manager: Node
) -> Node3D:
    # bhv_param looks like "BPARAM2(WARP_NODE_00)"; pull the WARP_NODE_ identifier.
    var param: String = obj.get("bhv_param", "")
    var target := ""
    for token in ["WARP_NODE_TOTWC", "WARP_NODE_VCUTM", "WARP_NODE_COTMC"]:
        if param.find(token) >= 0:
            target = token
            break
    if target == "":
        # Generic WARP_NODE_XX pattern.
        for i in range(param.length() - 10):
            if param.substr(i, 10) == "WARP_NODE_":
                var j := i + 10
                while j < param.length() and (
                    param[j].to_upper() != param[j].to_lower()
                    or param[j].is_valid_int()
                ):
                    j += 1
                target = param.substr(i, j - i)
                break
    var warp: Variant = warp_lookup.get(target)
    if not (warp is Dictionary):
        return null
    var dest_level: String = _level_const_to_name(warp.level)
    if dest_level == "":
        return null
    var dest_area: int = 1
    if warp.area is int:
        dest_area = warp.area
    elif warp.area is String and warp.area.is_valid_int():
        dest_area = warp.area.to_int()

    var a := Area3D.new()
    a.name = "Warp_%s" % target
    a.set_meta("warp_target_level", dest_level)
    a.set_meta("warp_target_area", dest_area)
    a.set_meta("warp_source_bhv", bhv)
    var cs := CollisionShape3D.new()
    var box := BoxShape3D.new()
    # Doors are taller and narrower, paintings are wall-aligned. Use a
    # generous box that catches either.
    box.size = Vector3(2.5, 3.0, 2.5)
    cs.shape = box
    cs.position = Vector3(0, 1.5, 0)
    a.add_child(cs)
    # Faint glowing marker so the portal is visible.
    var m := MeshInstance3D.new()
    var bm := BoxMesh.new()
    bm.size = Vector3(1.2, 2.4, 0.3)
    m.mesh = bm
    var mat := StandardMaterial3D.new()
    mat.albedo_color = Color(0.4, 0.7, 1.0, 0.4)
    mat.emission_enabled = true
    mat.emission = Color(0.3, 0.6, 1.0)
    mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
    m.material_override = mat
    m.position = Vector3(0, 1.2, 0)
    a.add_child(m)
    # Connect: on body entered, ask the manager to switch levels.
    a.body_entered.connect(
        func(body: Node) -> void:
            if body is CharacterBody3D and manager != null:
                print("[warp] %s triggered → %s area %d" % [a.name, dest_level, dest_area])
                manager.load_level(dest_level, dest_area)
    )
    return a


static func _level_const_to_name(level_const: String) -> String:
    # LEVEL_BOB → "bob", LEVEL_CASTLE_INSIDE → "castle_inside", …
    if not level_const.begins_with("LEVEL_"):
        return ""
    var short := level_const.substr(6).to_lower()
    # Handle a few special-case mappings where our directory name differs
    # from the decomp's LEVEL_ macro suffix.
    match short:
        "castle": return "castle_inside"
        "ending": return ""     # unsupported for now
        "unknown_1", "unknown_2", "unknown_3": return ""
    return short


static func _make_enemy(bhv: String) -> Node3D:
    # Use `.set()` rather than `.bhv_name =` so we go through the property
    # system; direct field access after set_script() sometimes races with
    # script attachment in Godot 4.
    var e := CharacterBody3D.new()
    e.set_script(EnemyScript)
    e.set("bhv_name", bhv)
    e.name = "Enemy_" + bhv
    return e


# pickup_kind → extracted actor mesh subdir, when we have one.
const PICKUP_ACTORS := {
    "coin_yellow": "coin_yellow",
    "coin_blue":   "coin_blue",
    "coin_red":    "coin_yellow",
    "star":        "star",
    "oneup":       "oneup",
    "cap_wing":    "cap_wing",
    "cap_metal":   "cap_metal",
    "cap_vanish":  "cap_normal",
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

    # Prefer a real actor mesh where we have one extracted. The anchor node
    # carries a small spin + bob animation so collectibles read clearly.
    var actor_sub: String = PICKUP_ACTORS.get(kind, "")
    if actor_sub != "":
        var mesh_path := "res://extracted/actors/%s/mesh.json" % actor_sub
        if FileAccess.file_exists(mesh_path):
            var anchor := Node3D.new()
            anchor.name = "ActorAnchor"
            anchor.set_script(PickupBobScript)
            body.add_child(anchor)
            LevelLoader.load_actor(mesh_path, anchor, "rigid")
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
