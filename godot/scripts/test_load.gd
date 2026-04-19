extends SceneTree

# Smoke-tests the level loader headlessly. Run via:
#   Godot --headless --path godot --script res://scripts/test_load.gd

const LevelLoader := preload("res://scripts/level_loader.gd")
const MODEL := "res://extracted/levels/bob/area_1/model.json"
const COLL := "res://extracted/levels/bob/area_1/collision.json"


func _init() -> void:
    print("=== smoke test: level loader ===")
    print("model exists: ", FileAccess.file_exists(MODEL))
    print("collision exists: ", FileAccess.file_exists(COLL))

    var root := Node3D.new()
    root.name = "Root"

    var parent := Node3D.new()
    parent.name = "World"
    root.add_child(parent)

    var result: Dictionary = LevelLoader.load_level(MODEL, COLL, parent)
    var mi: MeshInstance3D = result.mesh_instance
    if mi != null:
        var mesh := mi.mesh as ArrayMesh
        print("mesh surfaces: ", mesh.get_surface_count())
        var total_verts := 0
        var total_tris := 0
        for i in range(mesh.get_surface_count()):
            var arrays := mesh.surface_get_arrays(i)
            var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
            total_verts += verts.size()
            total_tris += indices.size() / 3
        print("total verts: ", total_verts, "  total tris: ", total_tris)
    else:
        print("ERROR: no mesh loaded")

    var body: StaticBody3D = result.collision_body
    if body != null:
        var cs: CollisionShape3D = body.get_child(0)
        var shape: ConcavePolygonShape3D = cs.shape
        var faces: PackedVector3Array = shape.get_faces()
        print("collision tri verts: ", faces.size(), "  (", faces.size() / 3, " triangles)")
    else:
        print("ERROR: no collision loaded")

    # Count how many sub-meshes got an actual texture applied.
    var textured := 0
    var untextured := 0
    if mi != null:
        var mesh2 := mi.mesh as ArrayMesh
        for i in range(mesh2.get_surface_count()):
            var mat := mesh2.surface_get_material(i) as StandardMaterial3D
            if mat != null and mat.albedo_texture != null:
                textured += 1
            else:
                untextured += 1
    print("materials: ", textured, " textured, ", untextured, " untextured")
    print("=== done ===")
    quit()
