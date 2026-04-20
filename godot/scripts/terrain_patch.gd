extends Node3D

# Runtime-built heightfield terrain. The converter emits one of these
# per `terrain_patches` entry in a blueprint; the node stores its
# parameters as metadata and _ready() turns them into three ArrayMeshes:
#
#   1. Default mesh — opaque, per-vertex slope-blended Mario-style
#      grass/dirt with a small deterministic jitter so the surface
#      isn't a flat colour. Holds all cells that aren't water or lava,
#      including painted ice / snow / sand / slippery tints.
#
#   2. Water mesh — transparent blue, NO collision. Painted-water cells
#      become a see-through surface that Mario can walk off the edge of
#      and fall into. The converter auto-seeds water_level_y from the
#      max water-cell surface Y so mario_state's swim-state trigger
#      fires as soon as his feet drop below the surface.
#
#   3. Lava mesh — emissive orange, StaticBody3D with
#      metadata/surface_kind="burning" so mario_state's existing lava
#      kick fires on contact. Stays solid so you can be bounced off it.
#
# Collision for all other kinds is split into one StaticBody3D per
# unique kind (each with metadata/surface_kind), so a single painted
# terrain can host grass + ice + quicksand + lava simultaneously and
# every patch of ground feels right under Mario's feet.
#
# Authored in the blueprint editor's terrain tool. Sculpt + Paint +
# Flatten + Average brushes all write back to `heights` / `surface_grid`
# arrays that the converter re-serialises on save.

const SURFACE_TINTS := {
	"ice":               Color(0.70, 0.90, 1.00),
	"slippery":          Color(0.75, 0.85, 0.95),
	"very_slippery":     Color(0.80, 0.95, 1.00),
	"snow":              Color(0.95, 0.97, 1.00),
	"sand":              Color(0.92, 0.80, 0.45),
	"shallow_quicksand": Color(0.78, 0.65, 0.30),
	"deep_quicksand":    Color(0.55, 0.40, 0.18),
}


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
	var flat_color: Color = _color_meta("terrain_flat_color", Color(0.30, 0.62, 0.22))
	var slope_color: Color = _color_meta("terrain_slope_color", Color(0.45, 0.32, 0.18))
	var slope_threshold: float = float(get_meta("terrain_slope_threshold", 0.72))
	var slope_softness: float = float(get_meta("terrain_slope_softness", 0.15))
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
	verts.resize(res * res)
	normals.resize(res * res)
	uvs.resize(res * res)
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
			normals[idx] = Vector3(-dx, 2.0 * cell_x, -dz).normalized()

	# Default-mesh vertex colours: slope blend + stable jitter + tint
	# from surrounding painted cells (water/burning cells don't
	# contribute — those get their own meshes and don't share the
	# default albedo).
	var default_colors := PackedColorArray()
	default_colors.resize(res * res)
	for i in range(res):
		for j in range(res):
			var idx: int = i * res + j
			var up: float = clamp(normals[idx].y, 0.0, 1.0)
			var t: float = smoothstep(lo, hi, up)
			var base: Color = slope_color.lerp(flat_color, t)
			# Deterministic hash-based jitter keeps colours stable
			# across edits (no flicker when re-sculpting) but still
			# gives variety. Slope side jitters on all 3 channels
			# (earthy browns); flat side jitters mostly in green.
			var jitter: Vector3 = _vertex_jitter(i, j)
			if t > 0.5:
				# More-flat ≈ grass; vary green dominantly.
				base.r = clamp(base.r + jitter.x * 0.05, 0.0, 1.0)
				base.g = clamp(base.g + jitter.y * 0.12, 0.0, 1.0)
				base.b = clamp(base.b + jitter.z * 0.05, 0.0, 1.0)
			else:
				# More-slope ≈ dirt; vary all channels for a rough look.
				base.r = clamp(base.r + jitter.x * 0.08, 0.0, 1.0)
				base.g = clamp(base.g + jitter.y * 0.08, 0.0, 1.0)
				base.b = clamp(base.b + jitter.z * 0.05, 0.0, 1.0)
			var tint_sum := Color(0, 0, 0, 0)
			var tint_weight: float = 0.0
			for di in [-1, 0]:
				for dj in [-1, 0]:
					var ci: int = i + di
					var cj: int = j + dj
					if ci < 0 or cj < 0 or ci >= res - 1 or cj >= res - 1:
						continue
					var kind: String = String(surface_grid[ci * (res - 1) + cj])
					if kind == "" or kind == "water" or kind == "burning":
						continue
					if not SURFACE_TINTS.has(kind):
						continue
					var tint: Color = SURFACE_TINTS[kind]
					tint_sum += Color(tint.r, tint.g, tint.b, 1.0)
					tint_weight += 1.0
			if tint_weight > 0.0:
				var avg := Color(tint_sum.r / tint_weight,
								  tint_sum.g / tint_weight,
								  tint_sum.b / tint_weight, 1.0)
				var tint_mix: float = 0.65 * (tint_weight / 4.0)
				base = base.lerp(avg, tint_mix)
			default_colors[idx] = base

	# Partition cells into three visual buckets. Collision is grouped
	# by kind separately (below) and water drops out of collision
	# entirely.
	var default_indices := PackedInt32Array()
	var water_indices := PackedInt32Array()
	var lava_indices := PackedInt32Array()
	var kind_to_cells: Dictionary = {}
	for ci in range(res - 1):
		for cj in range(res - 1):
			var kind: String = String(surface_grid[ci * (res - 1) + cj])
			var a: int = ci * res + cj
			var b: int = (ci + 1) * res + cj
			var c: int = (ci + 1) * res + (cj + 1)
			var d: int = ci * res + (cj + 1)
			if kind == "water":
				water_indices.append_array([a, b, c, a, c, d])
			elif kind == "burning":
				lava_indices.append_array([a, b, c, a, c, d])
				if not kind_to_cells.has("burning"):
					kind_to_cells["burning"] = []
				kind_to_cells["burning"].append(Vector2i(ci, cj))
			else:
				default_indices.append_array([a, b, c, a, c, d])
				if not kind_to_cells.has(kind):
					kind_to_cells[kind] = []
				kind_to_cells[kind].append(Vector2i(ci, cj))

	# Default mesh — every non-water, non-lava cell.
	if default_indices.size() > 0:
		var mesh := ArrayMesh.new()
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = normals
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_COLOR] = default_colors
		arrays[Mesh.ARRAY_INDEX] = default_indices
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

	# Water mesh — transparent blue, no collision. Mario walks onto it
	# and falls through; below water_level_y his swim state fires. The
	# mesh sits a hair below the terrain top so it doesn't Z-fight with
	# the adjacent default-mesh cells at the shore.
	if water_indices.size() > 0:
		var wmesh := ArrayMesh.new()
		var warrays: Array = []
		warrays.resize(Mesh.ARRAY_MAX)
		var wverts := verts.duplicate()
		for k in range(wverts.size()):
			wverts[k] = wverts[k] - Vector3(0, 0.01, 0)
		warrays[Mesh.ARRAY_VERTEX] = wverts
		warrays[Mesh.ARRAY_NORMAL] = normals
		warrays[Mesh.ARRAY_TEX_UV] = uvs
		warrays[Mesh.ARRAY_INDEX] = water_indices
		wmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, warrays)
		var wmat := StandardMaterial3D.new()
		wmat.albedo_color = Color(0.18, 0.48, 0.80, 0.55)
		wmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		wmat.metallic = 0.4
		wmat.roughness = 0.25
		wmat.emission_enabled = true
		wmat.emission = Color(0.10, 0.25, 0.45, 1.0)
		wmat.emission_energy_multiplier = 0.35
		wmat.cull_mode = BaseMaterial3D.CULL_DISABLED
		wmesh.surface_set_material(0, wmat)
		var wmi := MeshInstance3D.new()
		wmi.mesh = wmesh
		wmi.name = "Water"
		add_child(wmi)

	# Lava mesh — emissive orange, HAS collision so the player bounces
	# off. mario_state reads surface_kind="burning" off the body and
	# applies the upward kick + damage.
	if lava_indices.size() > 0:
		var lmesh := ArrayMesh.new()
		var larrays: Array = []
		larrays.resize(Mesh.ARRAY_MAX)
		larrays[Mesh.ARRAY_VERTEX] = verts
		larrays[Mesh.ARRAY_NORMAL] = normals
		larrays[Mesh.ARRAY_TEX_UV] = uvs
		larrays[Mesh.ARRAY_INDEX] = lava_indices
		lmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, larrays)
		var lmat := StandardMaterial3D.new()
		lmat.albedo_color = Color(0.95, 0.20, 0.05)
		lmat.emission_enabled = true
		lmat.emission = Color(1.0, 0.45, 0.10, 1.0)
		lmat.emission_energy_multiplier = 2.8
		lmat.roughness = 0.4
		lmesh.surface_set_material(0, lmat)
		var lmi := MeshInstance3D.new()
		lmi.mesh = lmesh
		lmi.name = "Lava"
		add_child(lmi)

	# Collision: one StaticBody3D per unique kind (except water, which
	# has none so the player falls through into swim state).
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


# Deterministic hash → (-0.5..0.5) on each axis. Uses the same pair of
# large primes Morton-style hashes typically use so neighbouring cells
# don't get visually banded.
func _vertex_jitter(i: int, j: int) -> Vector3:
	var h: int = ((i * 73856093) ^ (j * 19349663)) & 0xFFFFFF
	var rx: float = float(h & 0xFF) / 255.0 - 0.5
	var ry: float = float((h >> 8) & 0xFF) / 255.0 - 0.5
	var rz: float = float((h >> 16) & 0xFF) / 255.0 - 0.5
	return Vector3(rx, ry, rz)


func _color_meta(key: String, default_c: Color) -> Color:
	var raw: Variant = get_meta(key, null)
	if raw == null:
		return default_c
	if raw is Color:
		return raw
	if raw is Array and raw.size() >= 3:
		return Color(float(raw[0]), float(raw[1]), float(raw[2]))
	return default_c
