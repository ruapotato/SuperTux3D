extends StaticBody3D

# Runtime-built heightfield terrain. The converter emits one of these
# per `terrain_patches` entry in a blueprint; the node stores its
# parameters as metadata and _ready() turns them into:
#
#   - a MeshInstance3D with an ArrayMesh (triangle grid, per-vertex
#     normals from finite differences of neighbouring heights)
#   - a CollisionShape3D with a ConcavePolygonShape3D (trimesh) built
#     from the same vertex set so collision follows the sculpt exactly
#
# Origin is the south-west corner of the patch at base_y=origin.y.
# Each vertex world-space Y = origin.y + heights[i*res + j]. resolution
# is the vertex count per side, so a patch with resolution=8 has 64
# vertices / 49 quad cells / 98 triangles — cheap.
#
# Editable in the blueprint editor's terrain tool; the converter
# re-serialises the heights on every Build so sculpt changes round-trip
# without ever touching the .tscn by hand.

func _ready() -> void:
	var raw: Variant = get_meta("terrain_heights", PackedFloat32Array())
	var heights: PackedFloat32Array
	if raw is PackedFloat32Array:
		heights = raw
	elif raw is Array:
		heights = PackedFloat32Array()
		for v in raw:
			heights.append(float(v))
	else:
		return
	var size_x: float = float(get_meta("terrain_size_x", 10.0))
	var size_z: float = float(get_meta("terrain_size_z", 10.0))
	var res: int = int(get_meta("terrain_resolution", 8))
	var mat_path: String = str(get_meta("terrain_material", ""))
	# Slope-aware colouring. Flat cells pick up flat_color (grass green
	# by default), sloped cells pick up slope_color (dirt brown). The
	# blend uses each vertex's normal.y and a smoothstep between
	# (threshold - softness) and (threshold + softness), baked into
	# ARRAY_COLOR so we don't need a custom shader.
	var flat_color: Color = _color_meta("terrain_flat_color", Color(0.35, 0.55, 0.22))
	var slope_color: Color = _color_meta("terrain_slope_color", Color(0.45, 0.32, 0.18))
	var slope_threshold: float = float(get_meta("terrain_slope_threshold", 0.72))
	var slope_softness: float = float(get_meta("terrain_slope_softness", 0.15))
	if res < 2 or heights.size() != res * res or size_x <= 0.0 or size_z <= 0.0:
		return

	var cell_x: float = size_x / float(res - 1)
	var cell_z: float = size_z / float(res - 1)

	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var colors := PackedColorArray()
	verts.resize(res * res)
	normals.resize(res * res)
	uvs.resize(res * res)
	colors.resize(res * res)
	for i in range(res):
		for j in range(res):
			var idx: int = i * res + j
			verts[idx] = Vector3(float(i) * cell_x, heights[idx], float(j) * cell_z)
			uvs[idx] = Vector2(float(i) / float(res - 1), float(j) / float(res - 1))

	# Per-vertex normals via central difference — good enough for shaded
	# rolling terrain without full face-normal averaging. Each vertex
	# gets a slope-blended colour baked in at the same time.
	var lo: float = slope_threshold - slope_softness
	var hi: float = slope_threshold + slope_softness
	for i in range(res):
		for j in range(res):
			var idx: int = i * res + j
			var left: int = max(i - 1, 0)
			var right: int = min(i + 1, res - 1)
			var back: int = max(j - 1, 0)
			var fwd: int = min(j + 1, res - 1)
			var dx: float = verts[right * res + j].y - verts[left * res + j].y
			var dz: float = verts[i * res + fwd].y - verts[i * res + back].y
			var n := Vector3(-dx, 2.0 * cell_x, -dz).normalized()
			normals[idx] = n
			var up: float = clamp(n.y, 0.0, 1.0)
			var t: float = smoothstep(lo, hi, up)
			colors[idx] = slope_color.lerp(flat_color, t)

	var indices := PackedInt32Array()
	for i in range(res - 1):
		for j in range(res - 1):
			var a: int = i * res + j
			var b: int = (i + 1) * res + j
			var c: int = (i + 1) * res + (j + 1)
			var d: int = i * res + (j + 1)
			indices.append_array([a, b, c, a, c, d])

	var mesh := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# Material resolution: if the blueprint names a material, honour it
	# (lets themed worlds override with a lava/ice shader). Otherwise
	# fall back to a StandardMaterial3D that renders the per-vertex
	# slope colours — no shader required.
	if mat_path != "" and ResourceLoader.exists(mat_path):
		var mat: Resource = load(mat_path)
		if mat is Material:
			mesh.surface_set_material(0, mat)
	else:
		var default_mat := StandardMaterial3D.new()
		default_mat.vertex_color_use_as_albedo = true
		default_mat.roughness = 0.88
		mesh.surface_set_material(0, default_mat)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.name = "Mesh"
	add_child(mi)

	# Trimesh collision: feed triangle vertices flat (3 verts per tri).
	var tri_verts := PackedVector3Array()
	tri_verts.resize(indices.size())
	for k in range(indices.size()):
		tri_verts[k] = verts[indices[k]]
	var shape := ConcavePolygonShape3D.new()
	shape.data = tri_verts
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.name = "Col"
	add_child(cs)
	# The converter may attach a surface_kind meta ("snow" / "ice" /
	# "sand" etc.) so mario_state's floor_surface check picks up the
	# right friction when Mario stands on a themed terrain. Mario reads
	# set_meta("surface_kind") on the collider; we already have it on
	# this node thanks to the converter, no-op if absent.


func _color_meta(key: String, default_c: Color) -> Color:
	var raw: Variant = get_meta(key, null)
	if raw == null:
		return default_c
	if raw is Color:
		return raw
	if raw is Array and raw.size() >= 3:
		return Color(float(raw[0]), float(raw[1]), float(raw[2]))
	return default_c
