extends Node3D

# Runtime-built heightfield terrain. The converter emits one of these
# per `terrain_patches` entry in a blueprint; the node stores its
# parameters as metadata and _ready() turns them into:
#
#   - a MeshInstance3D with an ArrayMesh (triangle grid, per-vertex
#     normals from finite differences of neighbouring heights,
#     per-vertex slope-blended colours modulated by surface painting)
#   - one StaticBody3D per UNIQUE painted surface kind found in
#     `surface_grid` (plus a "default" body for un-painted cells).
#     Each body carries its own CollisionShape3D (trimesh of its
#     cells' triangles) and metadata/surface_kind, which mario_state
#     reads off get_slide_collision().get_collider(). That's how one
#     painted terrain can have ice, lava, and grass all coexisting.
#
# Origin is the south-west corner of the patch at base_y=origin.y.
# Each vertex world-space Y = origin.y + heights[i*res + j]. resolution
# is the vertex count per side, so a patch with resolution=8 has 64
# vertices / 49 quad cells / 98 triangles — cheap.
#
# Authored in the blueprint editor's terrain tool + paint sub-mode;
# the converter re-serialises heights + surface_grid on every Build.

const SURFACE_TINTS := {
	"water":             Color(0.25, 0.55, 0.95),
	"burning":           Color(1.00, 0.35, 0.08),
	"ice":               Color(0.70, 0.90, 1.00),
	"slippery":          Color(0.75, 0.85, 0.95),
	"very_slippery":     Color(0.80, 0.95, 1.00),
	"snow":              Color(0.95, 0.97, 1.00),
	"sand":              Color(0.90, 0.80, 0.45),
	"shallow_quicksand": Color(0.78, 0.65, 0.30),
	"deep_quicksand":    Color(0.55, 0.40, 0.18),
}

const DEFAULT_TINT_STRENGTH := 0.65


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
	var flat_color: Color = _color_meta("terrain_flat_color", Color(0.35, 0.55, 0.22))
	var slope_color: Color = _color_meta("terrain_slope_color", Color(0.45, 0.32, 0.18))
	var slope_threshold: float = float(get_meta("terrain_slope_threshold", 0.72))
	var slope_softness: float = float(get_meta("terrain_slope_softness", 0.15))
	# Per-cell surface kinds. Absent / wrong length → all default ("").
	var sg_raw: Variant = get_meta("terrain_surface_grid", null)
	var cell_count: int = (res - 1) * (res - 1)
	var surface_grid: Array = []
	if sg_raw is Array:
		for s in sg_raw:
			surface_grid.append(str(s))
	if surface_grid.size() != cell_count:
		surface_grid = []
		for _i in range(cell_count):
			surface_grid.append("")

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
			var base: Color = slope_color.lerp(flat_color, t)
			# Surface-kind tint: average the tints of the (up to 4)
			# cells surrounding this vertex. Cells with kind "" don't
			# contribute so edges feather smoothly into default.
			var tint_sum := Color(0, 0, 0, 0)
			var tint_weight: float = 0.0
			for di in [-1, 0]:
				for dj in [-1, 0]:
					var ci: int = i + di
					var cj: int = j + dj
					if ci < 0 or cj < 0 or ci >= res - 1 or cj >= res - 1:
						continue
					var kind: String = String(surface_grid[ci * (res - 1) + cj])
					if kind == "":
						continue
					var tint: Color = SURFACE_TINTS.get(kind, Color(0, 0, 0))
					tint_sum += Color(tint.r, tint.g, tint.b, 1.0)
					tint_weight += 1.0
			if tint_weight > 0.0:
				var avg := Color(tint_sum.r / tint_weight, tint_sum.g / tint_weight, tint_sum.b / tint_weight, 1.0)
				# Four of four cells painted → full tint; fewer corners
				# lerp back toward the base so the boundary fades.
				var tint_mix: float = DEFAULT_TINT_STRENGTH * (tint_weight / 4.0)
				colors[idx] = base.lerp(avg, tint_mix)
			else:
				colors[idx] = base

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

	# Collision split by surface kind: one StaticBody3D per unique kind
	# found in the grid, each with a trimesh of ITS cells only. Un-
	# painted ("") cells go to a default body without a surface_kind
	# meta so mario_state's floor_surface falls back to "default".
	var kind_to_cells: Dictionary = {}
	for ci in range(res - 1):
		for cj in range(res - 1):
			var kind: String = String(surface_grid[ci * (res - 1) + cj])
			if not kind_to_cells.has(kind):
				kind_to_cells[kind] = []
			kind_to_cells[kind].append(Vector2i(ci, cj))
	for kind in kind_to_cells.keys():
		var cells: Array = kind_to_cells[kind]
		var tri_verts := PackedVector3Array()
		for cell in cells:
			var ci2: int = (cell as Vector2i).x
			var cj2: int = (cell as Vector2i).y
			var a2: int = ci2 * res + cj2
			var b2: int = (ci2 + 1) * res + cj2
			var c2: int = (ci2 + 1) * res + (cj2 + 1)
			var d2: int = ci2 * res + (cj2 + 1)
			tri_verts.append_array([verts[a2], verts[b2], verts[c2]])
			tri_verts.append_array([verts[a2], verts[c2], verts[d2]])
		if tri_verts.is_empty():
			continue
		var body := StaticBody3D.new()
		body.name = "Col_" + (str(kind) if kind != "" else "default")
		body.collision_layer = 1
		body.collision_mask = 1
		if kind != "":
			body.set_meta("surface_kind", kind)
		var shape := ConcavePolygonShape3D.new()
		shape.data = tri_verts
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
		add_child(body)


func _color_meta(key: String, default_c: Color) -> Color:
	var raw: Variant = get_meta(key, null)
	if raw == null:
		return default_c
	if raw is Color:
		return raw
	if raw is Array and raw.size() >= 3:
		return Color(float(raw[0]), float(raw[1]), float(raw[2]))
	return default_c
