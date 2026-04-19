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

# Actor meshes (Mario, etc.) live in the decomp's local coordinate frame where
# +X is up, +Y is forward, +Z is left. Godot uses +Y up, -Z forward. The
# remap below puts actor +X to Godot +Y (up), actor +Y to Godot -Z (forward),
# and actor +Z to Godot -X (left). With this remap, face_yaw=0 makes Mario
# look along Godot -Z, matching the camera-default forward direction.
# We also apply 0.25× scale because we enter the walker at mario_geo_body,
# which skips the top-level mario_geo's GEO_SCALE(0, 16384) = 0.25.
const ACTOR_SCALE := 0.25


static func _remap_actor_point(p: Array) -> Vector3:
    return Vector3(-p[2], p[0], -p[1])

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


static func load_actor(mesh_json_path: String, parent: Node3D) -> MeshInstance3D:
    """Load a converted actor mesh (from tools/convert_actor.py) as a
    MeshInstance3D under `parent`. Applies the actor→Godot axis remap and
    the 0.25× scale we skip by entering at `mario_geo_body` instead of the
    top-level `mario_geo` (which carries its own GEO_SCALE)."""
    _ensure_texture_map()
    var model: Variant = _read_json(mesh_json_path)
    if not (model is Dictionary):
        return null
    var mi := _build_actor_mesh_instance(model)
    parent.add_child(mi)
    return mi


static func _build_actor_mesh_instance(model: Dictionary) -> MeshInstance3D:
    var mesh := ArrayMesh.new()
    var textured := 0
    var untextured := 0
    # Actor bones are centered on the butt, so by default Mario's feet sit
    # well below the CharacterBody3D origin (and therefore below the capsule
    # bottom, which is what the physics engine treats as the ground contact).
    # Find the lowest Godot-Y vertex as we build, then offset the whole mesh
    # up by that amount so the feet land at y=0 in the node's local space.
    var min_y: float = INF
    for sm in model.sub_meshes:
        # Skip the cap-wings on non-wing-cap Mario. The decomp controls wing
        # visibility via an ASM callback (`geo_mario_rotate_wing_cap_wings`)
        # we don't emulate; walking the geo tree blindly always emits them,
        # and they sit right in front of Mario's face as an opaque overlay.
        # Dropping LAYER_ALPHA sub-meshes until we model wing visibility.
        if sm.layer == "LAYER_ALPHA":
            continue
        var positions := PackedVector3Array()
        var normals := PackedVector3Array()
        var uvs := PackedVector2Array()
        var colors := PackedColorArray()
        var tex_info: Variant = _texture_map.get(sm.texture)
        var tw: float = 32.0
        var th: float = 32.0
        if tex_info is Dictionary:
            tw = float(tex_info.width)
            th = float(tex_info.height)
        for p in sm.positions:
            var v: Vector3 = _remap_actor_point(p) * ACTOR_SCALE * WORLD_SCALE
            if v.y < min_y:
                min_y = v.y
            positions.append(v)
        for n in sm.normals:
            normals.append(_remap_actor_point(n))
        for u in sm.uvs:
            uvs.append(Vector2(u[0] / UV_FIXED_POINT_SHIFT / tw,
                               u[1] / UV_FIXED_POINT_SHIFT / th))
        # Deliberately do NOT emit ARRAY_COLOR. For Mario, the Vtx "color"
        # bytes are actually normals (G_LIGHTING is enabled on every body
        # part). Emitting them as vertex colors gives random RGB with alpha=0
        # and Godot's material interacts with them badly (renders black /
        # fully transparent). Normals we DO need for lighting; they come
        # through ARRAY_NORMAL above.
        var indices := PackedInt32Array()
        for idx in sm.indices:
            indices.append(idx)
        if positions.is_empty() or indices.is_empty():
            continue

        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = positions
        arrays[Mesh.ARRAY_NORMAL] = normals
        arrays[Mesh.ARRAY_TEX_UV] = uvs
        arrays[Mesh.ARRAY_INDEX] = indices
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var surf_idx := mesh.get_surface_count() - 1
        var mat := StandardMaterial3D.new()
        mat.resource_name = sm.key
        mat.cull_mode = BaseMaterial3D.CULL_DISABLED
        # Plain NEAREST: our runtime ImageTextures don't have mipmaps.
        mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
        # UNSHADED so Mario's face/mustache/etc. render at full brightness
        # instead of potentially going dark when a lit triangle's normal
        # points away from the scene's DirectionalLight3D. N64 Mario was
        # pseudo-lit via gsSPLight per-DL groups; until we port those, flat
        # albedo looks closer to the original.
        mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
        var tex := _load_texture(sm.texture)
        if tex != null:
            mat.albedo_texture = tex
            mat.albedo_color = Color(1, 1, 1, 1)
            textured += 1
        else:
            # Untextured sub-mesh: use the decomp's gsSPLight color (blue
            # overalls, red shirt/cap, beige face skin, white gloves, brown
            # shoes, brown2 hair). Falls back to a neutral gray only when
            # we couldn't determine a light group.
            mat.albedo_color = _actor_shade_color(sm)
            untextured += 1
        mesh.surface_set_material(surf_idx, mat)

    var mi := MeshInstance3D.new()
    mi.name = "ActorMesh"
    mi.mesh = mesh
    # Shift the mesh up so the lowest vertex (feet) lands at local y=0, the
    # same height as the CharacterBody3D's capsule bottom. Without this
    # Mario's legs clip through the floor because his bone origin is at his
    # butt, not his feet.
    if min_y != INF:
        mi.position.y = -min_y
    print("[level_loader] actor mesh: ", mesh.get_surface_count(),
          " surfaces, ", textured, " textured, ", untextured, " untextured, ",
          "min_y=", min_y, " -> shifted up ", -min_y)
    return mi


static func _actor_shade_color(sm: Dictionary) -> Color:
    # The converter attaches a `shade_color` RGB triple from the decomp's
    # gsSPLight group. If it's missing (old converter output or a DL that
    # doesn't set a light), fall back to neutral gray.
    var shade: Variant = sm.get("shade_color")
    if shade is Array and shade.size() >= 3:
        return Color(shade[0], shade[1], shade[2], 1.0)
    return Color(0.75, 0.75, 0.78)


static func _ensure_texture_map() -> void:
    if _texture_map_loaded:
        return
    _texture_map_loaded = true
    var parsed: Variant = _read_json(TEXTURE_MAP_JSON)
    if parsed is Dictionary:
        _texture_map = parsed


# Mario decal textures have alpha=0 rgb=0 over large regions. The N64 renders
# those regions as the current light color (G_CC_BLENDRGBFADEA combine mode),
# but Godot's alpha modes either discard them (leaving holes in the head
# geometry) or render them as opaque black. We preprocess each decal image:
# alpha=0 pixels get the appropriate light color baked in as their RGB with
# alpha=1, so the decal becomes fully opaque and its "transparent" regions
# display the skin/cap color the decomp originally computed via shade.
const MARIO_BEIGE := Color(0xFE / 255.0, 0xC1 / 255.0, 0x79 / 255.0)
const MARIO_RED   := Color(0xFF / 255.0, 0x00 / 255.0, 0x00 / 255.0)
const _ACTOR_DECAL_BACKGROUND := {
    # Cap-front decals sit on the red cap.
    "mario_texture_m_logo": MARIO_RED,
    # Face decals sit on the beige face skin.
    "mario_texture_eyes_front": MARIO_BEIGE,
    "mario_texture_eyes_half_closed": MARIO_BEIGE,
    "mario_texture_eyes_closed": MARIO_BEIGE,
    "mario_texture_eyes_right": MARIO_BEIGE,
    "mario_texture_eyes_left": MARIO_BEIGE,
    "mario_texture_eyes_up": MARIO_BEIGE,
    "mario_texture_eyes_down": MARIO_BEIGE,
    "mario_texture_eyes_dead": MARIO_BEIGE,
    "mario_texture_mustache": MARIO_BEIGE,
    "mario_texture_hair_sideburn": MARIO_BEIGE,
}


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
    if _ACTOR_DECAL_BACKGROUND.has(symbol):
        _fill_transparent_background(img, _ACTOR_DECAL_BACKGROUND[symbol])
    var tex := ImageTexture.create_from_image(img)
    _texture_cache[symbol] = tex
    return tex


static func _fill_transparent_background(img: Image, bg: Color) -> void:
    # Walk every pixel; where alpha < 0.5, overwrite with the backdrop color
    # and set alpha to 1. The result is a fully opaque texture with the
    # decal on top of a solid "skin-tone" background.
    if img.get_format() != Image.FORMAT_RGBA8:
        img.convert(Image.FORMAT_RGBA8)
    var w := img.get_width()
    var h := img.get_height()
    var bg_opaque := Color(bg.r, bg.g, bg.b, 1.0)
    for y in range(h):
        for x in range(w):
            var c := img.get_pixel(x, y)
            if c.a < 0.5:
                img.set_pixel(x, y, bg_opaque)


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
