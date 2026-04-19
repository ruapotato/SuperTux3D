extends Node

# Loads a converted level (model.json + collision.json) into the scene tree.
# Everything is built procedurally at runtime for now — later we'll move to
# import-time conversion (.tres resources).

# Decomp world units are N64 units (Mario is ~160 tall). We scale into Godot
# meters at load time because Godot's physics engine is tuned for ~1-unit =
# 1-meter scale: its internal collision margins and swept-shape tests assume
# velocities of order single-digit units/sec. At N64 scale Mario tunnels
# through thin floor triangles every frame. All decomp positions/velocities
# get multiplied by WORLD_SCALE at the engine boundary.
const WORLD_SCALE := 0.01
const UV_FIXED_POINT_SHIFT := 32.0  # Q10.5 -> texels
const TEXTURE_MAP_JSON := "res://extracted/textures/texture_map.json"
const TEXTURE_ROOT := "res://extracted/textures"

# Per-run cache so repeated loads don't re-decode the same PNG.
static var _texture_map: Dictionary = {}
static var _texture_cache: Dictionary = {}
static var _texture_map_loaded := false


static func load_level(model_json_path: String, collision_json_path: String,
                        parent: Node3D) -> Dictionary:
    _ensure_texture_map()
    var result := {"mesh_instance": null, "collision_body": null}
    var model: Variant = _read_json(model_json_path)
    var coll: Variant = _read_json(collision_json_path)
    if model != null:
        var mi := _build_mesh_instance(model)
        parent.add_child(mi)
        result.mesh_instance = mi
    if coll != null:
        var body := _build_static_body(coll)
        parent.add_child(body)
        result.collision_body = body
    return result


static func _read_json(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        push_error("LevelLoader: missing file %s" % path)
        return null
    var f := FileAccess.open(path, FileAccess.READ)
    var text := f.get_as_text()
    var parsed: Variant = JSON.parse_string(text)
    if parsed == null:
        push_error("LevelLoader: failed to parse JSON %s" % path)
    return parsed


static func _ensure_texture_map() -> void:
    if _texture_map_loaded:
        return
    _texture_map_loaded = true
    var parsed: Variant = _read_json(TEXTURE_MAP_JSON)
    if parsed is Dictionary:
        _texture_map = parsed


static func _load_texture(symbol: String) -> Texture2D:
    if _texture_cache.has(symbol):
        return _texture_cache[symbol]
    var info: Variant = _texture_map.get(symbol)
    if info == null:
        _texture_cache[symbol] = null
        return null
    var rel_path: String = info.png
    var full_path: String = TEXTURE_ROOT + "/" + rel_path
    # Use Image.load so we don't depend on Godot's editor-time import pipeline
    # (there's no .import sidecar for our extracted PNGs).
    var img := Image.new()
    var err := img.load(full_path)
    if err != OK:
        push_error("LevelLoader: failed to load texture %s -> %s (err %d)"
            % [symbol, full_path, err])
        _texture_cache[symbol] = null
        return null
    var tex := ImageTexture.create_from_image(img)
    _texture_cache[symbol] = tex
    return tex


static func _build_mesh_instance(model: Dictionary) -> MeshInstance3D:
    var mesh := ArrayMesh.new()
    for sm in model.sub_meshes:
        var positions: PackedVector3Array = PackedVector3Array()
        var normals: PackedVector3Array = PackedVector3Array()
        var uvs: PackedVector2Array = PackedVector2Array()
        var colors: PackedColorArray = PackedColorArray()
        for p in sm.positions:
            positions.append(Vector3(p[0], p[1], p[2]) * WORLD_SCALE)
        for n in sm.normals:
            normals.append(Vector3(n[0], n[1], n[2]))
        var tex_info: Variant = _texture_map.get(sm.texture)
        var tex_w: float = 32.0
        var tex_h: float = 32.0
        if tex_info is Dictionary:
            tex_w = float(tex_info.width)
            tex_h = float(tex_info.height)
        for u in sm.uvs:
            # Raw UVs are Q10.5 texel coordinates; divide by 32 to get texels,
            # then by the texture's size in pixels to get [0,1].
            uvs.append(Vector2(u[0] / UV_FIXED_POINT_SHIFT / tex_w,
                               u[1] / UV_FIXED_POINT_SHIFT / tex_h))
        for c in sm.colors:
            colors.append(Color(c[0], c[1], c[2], c[3]))
        var indices: PackedInt32Array = PackedInt32Array()
        for idx in sm.indices:
            indices.append(idx)
        if positions.is_empty() or indices.is_empty():
            continue

        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = positions
        arrays[Mesh.ARRAY_NORMAL] = normals
        arrays[Mesh.ARRAY_TEX_UV] = uvs
        # Colors left out for now — they're not useful when the bytes are
        # normals rather than vertex colors. The converter provides both;
        # we'll wire in a per-material "use_vertex_colors" flag later.
        arrays[Mesh.ARRAY_INDEX] = indices

        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var surf_idx := mesh.get_surface_count() - 1
        var mat := StandardMaterial3D.new()
        mat.resource_name = sm.key
        # N64 triangles have been winding-flipped in collision but the visual
        # mesh still matches the original decomp winding, so we disable culling
        # for now. Will revisit once we flip winding for the visual mesh too.
        mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
        var tex := _load_texture(sm.texture)
        if tex != null:
            mat.albedo_texture = tex
            mat.albedo_color = Color(1, 1, 1, 1)
        else:
            mat.albedo_color = _color_for_layer(sm.layer)
        if sm.layer == "LAYER_ALPHA":
            mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
        elif sm.layer == "LAYER_TRANSPARENT_DECAL":
            mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
        mesh.surface_set_material(surf_idx, mat)

    var mi := MeshInstance3D.new()
    mi.name = "LevelMesh"
    mi.mesh = mesh
    return mi


static func _color_for_layer(layer: String) -> Color:
    # Temporary: distinguish draw layers by color so we can see the structure.
    match layer:
        "LAYER_OPAQUE": return Color(0.85, 0.85, 0.85)
        "LAYER_ALPHA": return Color(0.6, 0.9, 0.6, 0.7)
        "LAYER_TRANSPARENT_DECAL": return Color(0.9, 0.6, 0.6, 0.8)
        _: return Color(0.7, 0.7, 0.9)


static func _build_static_body(coll: Dictionary) -> StaticBody3D:
    var body := StaticBody3D.new()
    body.name = "LevelCollision"

    var verts: Array = coll.vertices
    # Flatten per-group triangles into one triangle soup for ConcavePolygonShape3D.
    # Surface types get preserved by mapping triangle index → surface_id in a
    # side array stored as metadata, so gameplay can query it later.
    var tri_points: PackedVector3Array = PackedVector3Array()
    var surface_ids: PackedInt32Array = PackedInt32Array()
    for group in coll.triangle_groups:
        var sid: int = group.surface_id
        for tri in group.triangles:
            # Flip winding: decomp triangles are wound such that the cross
            # product of (V1-V0) x (V2-V0) points into the surface (N64/F3D
            # left-handed convention). Godot's ConcavePolygonShape3D is
            # one-sided and expects CCW-front (right-handed), so swapping
            # the 2nd and 3rd vertices inverts the effective normal and makes
            # floor triangles catch a ray coming down from above.
            var v0: Array = verts[tri[0]]
            var v1: Array = verts[tri[1]]
            var v2: Array = verts[tri[2]]
            tri_points.append(Vector3(v0[0], v0[1], v0[2]) * WORLD_SCALE)
            tri_points.append(Vector3(v2[0], v2[1], v2[2]) * WORLD_SCALE)
            tri_points.append(Vector3(v1[0], v1[1], v1[2]) * WORLD_SCALE)
            surface_ids.append(sid)

    var shape := ConcavePolygonShape3D.new()
    shape.set_faces(tri_points)

    var cs := CollisionShape3D.new()
    cs.shape = shape
    cs.name = "LevelShape"
    body.add_child(cs)
    body.set_meta("surface_ids", surface_ids)
    body.set_meta("triangle_count", tri_points.size() / 3)
    # Explicit collision layer + mask in case project defaults differ.
    body.collision_layer = 1
    body.collision_mask = 1
    print("[level_loader] built StaticBody3D '%s' with %d collision tris (layer=%d mask=%d)"
        % [body.name, tri_points.size() / 3, body.collision_layer, body.collision_mask])
    return body
