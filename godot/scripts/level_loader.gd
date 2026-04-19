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


static func load_actor(mesh_json_path: String, parent: Node3D,
                       animation_mode: String = "mario",
                       anim_data: Variant = null,
                       actor_scale_override: float = -1.0,
                       skip_alpha_geo: bool = false,
                       debug_actor_name: String = "") -> Dictionary:
    """Load an articulated actor into `parent`. Returns a dictionary with
    `bone_root` (the Node3D that owns the whole rig), `bones` (array of
    Node3D indexed by bone index, matching the decomp's traversal order
    used by animation data), and `mesh_instances` (array of MeshInstance3D
    parallel to bones, or null for bones without geometry).

    The skeleton is placed so the rest-pose feet sit at parent.y = 0. The
    bone_root's basis encodes the actor→Godot axis remap and the 0.25×
    actor scale; inside that basis, bones live in decomp units so the
    animation data (which operates in decomp units and s16 angles) can be
    applied directly at runtime."""
    _ensure_texture_map()
    var model: Variant = _read_json(mesh_json_path)
    if not (model is Dictionary):
        return {}
    return _build_articulated_actor(
        model, parent, animation_mode, anim_data,
        actor_scale_override, skip_alpha_geo, debug_actor_name,
    )


static func _build_articulated_actor(
    model: Dictionary, parent: Node3D,
    animation_mode: String = "mario",
    anim_data: Variant = null,
    actor_scale_override: float = -1.0,
    skip_alpha_geo: bool = false,
    debug_actor_name: String = ""
) -> Dictionary:
    var bones_data: Array = model.bones
    var bones: Array = []
    var mesh_instances: Array = []
    bones.resize(bones_data.size())
    mesh_instances.resize(bones_data.size())

    var base_scale: float = ACTOR_SCALE if actor_scale_override <= 0.0 else actor_scale_override
    var s: float = base_scale * WORLD_SCALE
    # Base rigid axis remap — directly maps decomp mesh convention into
    # Godot (+X mesh-up → Godot +Y, +Y mesh-forward → -Z, +Z mesh-left → -X).
    var rigid := Basis(
        Vector3(0, 1, 0),
        Vector3(0, 0, -1),
        Vector3(-1, 0, 0),
    )
    # Compensation: when an animation plays it applies a rotation chain
    # whose frame-0 composed rotation would otherwise tip the mesh away
    # from upright (Mario uses Ry(+90°)+Rz(+90°); Goomba's is similar;
    # Koopa carries Rz(+148°) so the tip angle differs). We pre-multiply
    # the rigid remap by the INVERSE of that composed rotation so the
    # animation's rotations cancel out the pose and leave us upright.
    # Decide compensation depth from bone hierarchy: if the actor has any
    # geometry-carrying bone whose ancestor chain passes through bone 1,
    # then bone 1's rotation is part of the body chain — compensate bones
    # 0+1. Otherwise (goomba/chain_chomp: bone 1 is a sibling-only
    # billboard bone), only compensate bone 0 so bone 1's irrelevant
    # rotation doesn't leak Rz(-90°) into the sibling body bones.
    var comp_depth: int = _auto_comp_depth(bones_data)
    var comp := _anim_axis_compensation(anim_data, comp_depth)
    var axis_remap: Basis = (rigid * comp).scaled(Vector3(s, s, s))
    # Legacy "rigid" mode = skip comp (used when no animation will play).
    if animation_mode == "rigid" or anim_data == null:
        axis_remap = rigid.scaled(Vector3(s, s, s))
    # "world" mode: the animation already rotates mesh vertices into game
    # world coords (e.g. Bobomb's bone 1 Rz(~+180°) flips the body up),
    # so we need NEITHER rigid NOR compensation — pure identity (plus
    # scale) lets the anim speak directly into Godot's frame.
    elif animation_mode == "world":
        axis_remap = Basis.IDENTITY.scaled(Vector3(s, s, s))

    var bone_root := Node3D.new()
    bone_root.name = "BoneRoot"
    bone_root.transform = Transform3D(axis_remap, Vector3.ZERO)
    parent.add_child(bone_root)

    # Build bones in hierarchy order (parent before child, which is already
    # guaranteed by the converter's DFS emission order).
    var textured := 0
    var untextured := 0
    for bd in bones_data:
        var bi: int = bd.index
        var node := Node3D.new()
        node.name = "Bone_%d_%s" % [bi, bd.name]
        # Position: raw decomp translation (bone_root's scale applies
        # externally).
        var t: Array = bd.translation
        node.position = Vector3(t[0], t[1], t[2])
        # Rest rotation: s16 Euler. EULER_ORDER_ZYX matches the decomp's
        # mtxf_rotate_xyz_and_translate composition (Rz*Ry*Rx).
        var r: Array = bd.rest_rotation
        if r[0] != 0 or r[1] != 0 or r[2] != 0:
            var to_rad := TAU / 65536.0
            node.basis = Basis.from_euler(
                Vector3(r[0] * to_rad, r[1] * to_rad, r[2] * to_rad),
                EULER_ORDER_ZYX,
            )
        bones[bi] = node

        var parent_node: Node3D
        if bd.parent >= 0:
            parent_node = bones[bd.parent]
        else:
            parent_node = bone_root
        parent_node.add_child(node)

        # Attach a MeshInstance3D if the bone has any sub_meshes.
        if bd.sub_meshes.size() > 0:
            var mi := _build_bone_mesh_instance(bd.sub_meshes, skip_alpha_geo)
            node.add_child(mi)
            mesh_instances[bi] = mi
            for sm in bd.sub_meshes:
                if _texture_map.has(sm.texture):
                    textured += 1
                else:
                    untextured += 1
        else:
            mesh_instances[bi] = null

    # Compute the lowest vertex in PARENT-LOCAL coords so the shift
    # ignores where this actor sits in the world. Using global_transform
    # is unsafe for enemies — they're positioned by object_spawner BEFORE
    # their mesh is loaded, so the global_y already reflects the spawn
    # height and the shift would teleport the mesh to world y=0 instead
    # of lining it up with the character's own origin.
    var min_y: float = INF
    if bone_root.is_inside_tree():
        var parent_inv: Transform3D = parent.global_transform.affine_inverse()
        min_y = _compute_min_local_y(bones, mesh_instances, parent_inv)
        if min_y != INF:
            bone_root.position.y = -min_y

    print("[level_loader] articulated actor [%s]: %d bones, %d textured, %d untextured, min_y=%.3f" % [
        animation_mode, bones_data.size(), textured, untextured, min_y,
    ])
    if debug_actor_name != "":
        _dump_actor_bones(debug_actor_name, bones, mesh_instances, bones_data, parent)
    return {
        "bone_root": bone_root,
        "bones": bones,
        "mesh_instances": mesh_instances,
    }


static func _dump_actor_bones(
    tag: String, bones: Array, mesh_instances: Array,
    bones_data: Variant, parent: Node3D
) -> void:
    # Print per-bone global position + per-submesh vertex Y range, so we
    # can see exactly where each bone actually lands after the axis_remap
    # + anim rotation chain runs. Useful for diagnosing cases like the
    # bob-omb body floating far above the feet: if bone 11's vertex Y
    # range is >> the foot bones', the anim's authored rotation genuinely
    # places the body up there, not our math. If it's at a reasonable
    # position but the mesh just isn't visible, the bug is elsewhere.
    var parent_inv: Transform3D = parent.global_transform.affine_inverse()
    for i in range(bones.size()):
        var n: Node3D = bones[i]
        if n == null:
            continue
        var pos_local: Vector3 = parent_inv * n.global_transform.origin
        var info := ""
        var mi: MeshInstance3D = mesh_instances[i]
        if mi != null and mi.mesh != null:
            var mesh := mi.mesh as ArrayMesh
            var min_vy: float = INF
            var max_vy: float = -INF
            var vcount: int = 0
            for s in range(mesh.get_surface_count()):
                var arrays := mesh.surface_get_arrays(s)
                var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
                var local_t: Transform3D = parent_inv * mi.global_transform
                for v in verts:
                    var y: float = (local_t * v).y
                    if y < min_vy: min_vy = y
                    if y > max_vy: max_vy = y
                    vcount += 1
            if vcount > 0:
                info = " verts=%d y=[%.3f, %.3f]" % [vcount, min_vy, max_vy]
        var par_idx: int = -1
        if bones_data is Array and i < bones_data.size():
            par_idx = int(bones_data[i].parent)
        print("  [%s] bone %2d (parent=%2d) local_pos=(%.3f, %.3f, %.3f)%s" % [
            tag, i, par_idx,
            pos_local.x, pos_local.y, pos_local.z, info,
        ])


static func _build_bone_mesh_instance(
    sub_meshes: Array, skip_alpha_geo: bool = false
) -> MeshInstance3D:
    var mesh := ArrayMesh.new()
    for sm in sub_meshes:
        var positions := PackedVector3Array()
        var normals := PackedVector3Array()
        var uvs := PackedVector2Array()
        var tex_info: Variant = _texture_map.get(sm.texture)
        var tw: float = 32.0
        var th: float = 32.0
        if tex_info is Dictionary:
            tw = float(tex_info.width)
            th = float(tex_info.height)
        # Vertices are already in the bone's local frame (decomp units). No
        # additional transform — bone_root/bone hierarchy handles placement.
        for p in sm.positions:
            positions.append(Vector3(p[0], p[1], p[2]))
        for n in sm.normals:
            normals.append(Vector3(n[0], n[1], n[2]))
        for u in sm.uvs:
            uvs.append(Vector2(u[0] / UV_FIXED_POINT_SHIFT / tw,
                               u[1] / UV_FIXED_POINT_SHIFT / th))
        var indices := PackedInt32Array()
        for idx in sm.indices:
            indices.append(idx)
        if positions.is_empty() or indices.is_empty():
            continue
        # Skip geometry authored inside GEO_BILLBOARD (Goomba/Bob-omb eye
        # sprites). They're meant to always face the camera; rendered
        # statically they appear as duplicated flat quads in the middle
        # of the body ("two small cores"). Until we implement real
        # billboarding, it's better to omit them.
        if sm.get("billboard", false):
            continue
        # Mario's cap wings (among other things) are authored as
        # LAYER_ALPHA geometry toggled on by an ASM callback we don't
        # implement. For Mario we skip all non-billboard alpha geometry
        # so the wings don't sprout by default. Other actors (bob-omb
        # fuse/eye panels, Koopa shell alpha decals) keep it.
        if skip_alpha_geo and sm.layer == "LAYER_ALPHA":
            continue

        var arrays := []
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX] = positions
        arrays[Mesh.ARRAY_NORMAL] = normals
        arrays[Mesh.ARRAY_TEX_UV] = uvs
        arrays[Mesh.ARRAY_INDEX] = indices
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
        var surf_idx := mesh.get_surface_count() - 1

        var tex := _load_texture(sm.texture)
        var mat: Material
        if tex != null:
            # Use a ShaderMaterial with a repeat_disable sampler so textured
            # actor surfaces CLAMP instead of WRAPPING. The decomp sets
            # G_TX_CLAMP on most actor textures (goomba face, koopa eyes,
            # etc.); without this, UVs authored outside [0,1] tile the
            # face texture across the whole body and eyes appear on the
            # back. Alpha layers use alpha-scissor for cutout transparency.
            mat = _build_clamped_actor_material(
                tex, sm.key, sm.layer == "LAYER_ALPHA"
            )
        else:
            var smat := StandardMaterial3D.new()
            smat.resource_name = sm.key
            smat.cull_mode = BaseMaterial3D.CULL_DISABLED
            smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
            smat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
            smat.albedo_color = _actor_shade_color(sm)
            if sm.layer == "LAYER_ALPHA":
                smat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
            mat = smat
        mesh.surface_set_material(surf_idx, mat)

    var mi := MeshInstance3D.new()
    mi.name = "Mesh"
    mi.mesh = mesh
    return mi


static func _compute_min_local_y(
    bones: Array, mesh_instances: Array, parent_inv: Transform3D
) -> float:
    var min_y: float = INF
    for i in range(bones.size()):
        var mi: MeshInstance3D = mesh_instances[i]
        if mi == null:
            continue
        var mesh := mi.mesh as ArrayMesh
        if mesh == null:
            continue
        # mi.global_transform → parent-local → pick Y. Each vertex then
        # tells us where it sits relative to the actor's own origin,
        # regardless of where the character is in the world.
        var local_t: Transform3D = parent_inv * mi.global_transform
        for s in range(mesh.get_surface_count()):
            var arrays := mesh.surface_get_arrays(s)
            var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
            for v in verts:
                var ly: float = (local_t * v).y
                if ly < min_y:
                    min_y = ly
    return min_y


# Shared shader + material cache. Godot's StandardMaterial3D doesn't
# expose a sampler-level repeat mode (only filter), so we use a tiny
# ShaderMaterial whose sampler is hinted `repeat_disable` → hardware
# CLAMP. The shader is unshaded, nearest-filtered, double-sided.
# Opaque shader: no ALPHA output so Godot treats the material as fully
# opaque (depth write, no blending). Setting ALPHA = c.a here would mark
# the surface as transparent, which disables depth writes and lets
# back-facing triangles composite over the front — on a goomba that
# makes the face (with eyes) invisible when viewed head-on.
const _ACTOR_CLAMPED_SHADER_SRC := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D albedo_tex : source_color, filter_nearest, repeat_disable;
void fragment() {
    ALBEDO = texture(albedo_tex, UV).rgb;
}
"""

# Alpha-scissor variant: cutout transparency for things like the bob-omb
# fuse / Koopa shell decals. discard keeps depth writes correct for the
# non-discarded fragments.
const _ACTOR_CLAMPED_ALPHA_SHADER_SRC := """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform sampler2D albedo_tex : source_color, filter_nearest, repeat_disable;
void fragment() {
    vec4 c = texture(albedo_tex, UV);
    if (c.a < 0.5) discard;
    ALBEDO = c.rgb;
}
"""
static var _actor_clamped_shader: Shader = null
static var _actor_clamped_alpha_shader: Shader = null


static func _build_clamped_actor_material(
    tex: Texture2D, name: String, alpha_scissor: bool
) -> ShaderMaterial:
    var shader: Shader
    if alpha_scissor:
        if _actor_clamped_alpha_shader == null:
            _actor_clamped_alpha_shader = Shader.new()
            _actor_clamped_alpha_shader.code = _ACTOR_CLAMPED_ALPHA_SHADER_SRC
        shader = _actor_clamped_alpha_shader
    else:
        if _actor_clamped_shader == null:
            _actor_clamped_shader = Shader.new()
            _actor_clamped_shader.code = _ACTOR_CLAMPED_SHADER_SRC
        shader = _actor_clamped_shader
    var mat := ShaderMaterial.new()
    mat.resource_name = name
    mat.shader = shader
    mat.set_shader_parameter("albedo_tex", tex)
    return mat


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
    # Bucket triangles by surface-kind and emit one child StaticBody3D per
    # kind, each tagged with `surface_kind` metadata. Mario's movement
    # inspects that tag after move_and_slide() so walking/braking can pick
    # the right friction for ice / slippery / sand / default.
    var container := StaticBody3D.new()
    container.name = "LevelCollision"
    container.collision_layer = 1
    container.collision_mask = 1

    var verts: Array = coll.vertices
    var buckets: Dictionary = {}
    for group in coll.triangle_groups:
        var sid: int = group.surface_id
        var kind := _surface_id_to_kind(sid)
        if not buckets.has(kind):
            buckets[kind] = PackedVector3Array()
        var bucket: PackedVector3Array = buckets[kind]
        for tri in group.triangles:
            var v0: Array = verts[tri[0]]
            var v1: Array = verts[tri[1]]
            var v2: Array = verts[tri[2]]
            # Flipped winding — see the earlier N64→Godot CCW note.
            bucket.append(Vector3(v0[0], v0[1], v0[2]) * WORLD_SCALE)
            bucket.append(Vector3(v2[0], v2[1], v2[2]) * WORLD_SCALE)
            bucket.append(Vector3(v1[0], v1[1], v1[2]) * WORLD_SCALE)
        buckets[kind] = bucket

    var total_tris := 0
    for kind in buckets.keys():
        var tris: PackedVector3Array = buckets[kind]
        if tris.size() == 0:
            continue
        var sub := StaticBody3D.new()
        sub.name = "Collision_" + kind
        sub.collision_layer = 1
        sub.collision_mask = 1
        sub.set_meta("surface_kind", kind)
        var shape := ConcavePolygonShape3D.new()
        shape.set_faces(tris)
        var cs := CollisionShape3D.new()
        cs.shape = shape
        sub.add_child(cs)
        container.add_child(sub)
        total_tris += tris.size() / 3
    print("[level_loader] built %d surface-kind bodies with %d total tris"
          % [buckets.size(), total_tris])
    return container


static func _auto_comp_depth(bones_data: Array) -> int:
    # Return 2 if any geometry-bearing bone descends through bone 1;
    # else 1. (Mario/Koopa/Bobomb/Piranha/Penguin = 2; Goomba/Chain
    # Chomp = 1 because bone 1 is the eye-billboard sibling.)
    for bd in bones_data:
        var subs: Array = bd.sub_meshes
        if subs.is_empty():
            continue
        var idx: int = int(bd.index)
        if idx == 1:
            continue
        # Walk parents until -1, looking for bone 1.
        var cur: int = bd.parent
        while cur >= 0:
            if cur == 1:
                return 2
            cur = int(bones_data[cur].parent)
    return 1


static func _anim_axis_compensation(anim_data: Variant, depth: int = 2) -> Basis:
    # Build a rotation that undoes the animation's frame-0 bone 0 + bone 1
    # pose, so vertex_mesh_up maps cleanly through rigid_remap into world
    # +Y. Without this Mario/Goomba/Koopa all tip differently because
    # their "authored" frame-0 rotations differ. Decomp animations use
    # Rz*Ry*Rx intrinsic composition (matches our EULER_ORDER_ZYX).
    if not (anim_data is Dictionary):
        return Basis()
    var indices: Variant = anim_data.get("indices")
    var values: Variant = anim_data.get("values")
    if not (indices is Array) or not (values is Array):
        return Basis()
    # Skip the 3 root-translation tracks, then sample the first 6 rotation
    # entries (bone 0 XYZ + bone 1 XYZ) at frame 0.
    if indices.size() < 9 or values.size() < 1:
        return Basis()
    var to_rad: float = TAU / 65536.0
    var b0 := Vector3(
        float(_sample_value(indices, values, 3)) * to_rad,
        float(_sample_value(indices, values, 4)) * to_rad,
        float(_sample_value(indices, values, 5)) * to_rad,
    )
    var b1 := Vector3(
        float(_sample_value(indices, values, 6)) * to_rad,
        float(_sample_value(indices, values, 7)) * to_rad,
        float(_sample_value(indices, values, 8)) * to_rad,
    )
    var r0 := Basis.from_euler(b0, EULER_ORDER_ZYX)
    var r1 := Basis.from_euler(b1, EULER_ORDER_ZYX)
    # depth=1: compensate only bone 0 (for goomba/chain_chomp where
    # bone 1 is a sibling-only billboard bone whose rotation should NOT
    # cancel against body bones). depth=2: compensate bones 0+1 (Mario,
    # Koopa, etc. where everything descends through bone 1).
    if depth <= 1:
        return r0.transposed()
    return (r0 * r1).transposed()


static func _sample_value(indices: Array, values: Array, track_idx: int) -> int:
    if track_idx >= indices.size():
        return 0
    var pair: Array = indices[track_idx]
    var off: int = int(pair[1])
    if off < 0 or off >= values.size():
        return 0
    return int(values[off])


static func _surface_id_to_kind(sid: int) -> String:
    # Map decomp SURFACE_* ids to coarse movement categories. Full list in
    # include/surface_terrains.h; we only distinguish the buckets that
    # change the physics meaningfully.
    match sid:
        0x0001:                  return "burning"
        0x000A:                  return "death"
        0x002E:                  return "ice"
        0x0013:                  return "very_slippery"
        0x0014:                  return "slippery"
        0x0015:                  return "not_slippery"
        0x0021, 0x0024, 0x0025:  return "shallow_quicksand"
        0x0022, 0x0023, 0x0027:  return "deep_quicksand"
        0x000D, 0x000E:          return "water"
        _:                       return "default"
