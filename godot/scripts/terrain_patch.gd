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

	# Water mesh — transparent blue, no collision, rendered as ONE FLAT
	# surface at `water_level_y` (passed from the converter). The cells'
	# sculpted heights aren't used for the water render — authors often
	# paint water over slightly uneven ground and expect a pond that
	# looks like a pond, not a rippled sheet.
	#
	# Pool walls: for every NON-water cell that borders a water cell,
	# we extrude a vertical skirt from the shared edge downward to
	# water_level_y - SKIRT_DEPTH. These walls live in the default
	# mesh + default collision body so they render with grass/dirt
	# colouring and stop Mario from falling through the seam.
	var water_level_y: float = float(get_meta(
		"terrain_water_level_y", -1e9))
	var have_water: bool = water_indices.size() > 0
	if have_water and water_level_y > -1e8:
		var wvert_positions := PackedVector3Array()
		var wvert_normals := PackedVector3Array()
		var wvert_uvs := PackedVector2Array()
		var windices := PackedInt32Array()
		# Local-space water Y (we translate from each cell's world
		# position relative to the patch origin, which is the node
		# origin — converter sank the transform by 2cm already, so add
		# it back). `origin_y_local` is 0 (local); world water_y minus
		# node world y gives local water y.
		var local_water_y: float = water_level_y - self.global_position.y
		for ci in range(res - 1):
			for cj in range(res - 1):
				var kind: String = String(surface_grid[ci * (res - 1) + cj])
				if kind != "water":
					continue
				var ax: float = float(ci) * cell_x
				var bx: float = float(ci + 1) * cell_x
				var az: float = float(cj) * cell_z
				var bz: float = float(cj + 1) * cell_z
				var base: int = wvert_positions.size()
				wvert_positions.append(Vector3(ax, local_water_y, az))
				wvert_positions.append(Vector3(bx, local_water_y, az))
				wvert_positions.append(Vector3(bx, local_water_y, bz))
				wvert_positions.append(Vector3(ax, local_water_y, bz))
				for _k in range(4):
					wvert_normals.append(Vector3.UP)
					wvert_uvs.append(Vector2.ZERO)
				windices.append_array([base, base + 1, base + 2,
					base, base + 2, base + 3])
		# For each painted water cell, also drop an Area3D over its
		# xz footprint so mario_stub's foot sensor can tell whether
		# the player is horizontally OVER water. The state needs this
		# in addition to the global water_level_y check — without it,
		# walking off a pool onto grass that happens to sit at the
		# same y keeps Mario in swim state (no Y condition flips).
		for ci in range(res - 1):
			for cj in range(res - 1):
				if String(surface_grid[ci * (res - 1) + cj]) != "water":
					continue
				var ax2: float = float(ci) * cell_x
				var bx2: float = float(ci + 1) * cell_x
				var az2: float = float(cj) * cell_z
				var bz2: float = float(cj + 1) * cell_z
				var area := Area3D.new()
				area.name = "WaterArea_%d_%d" % [ci, cj]
				# Layer 1 matches pickups / other gameplay triggers;
				# Mario's sensor filters by meta tag below. We set
				# monitorable so Mario's sensor sees us, but disable
				# monitoring since the area itself doesn't need to
				# detect anything.
				area.collision_layer = 1
				area.collision_mask = 0
				area.monitorable = true
				area.monitoring = false
				area.set_meta("water_area", true)
				var cs_area := CollisionShape3D.new()
				var box := BoxShape3D.new()
				# Tall + matches cell xz footprint. 200m y so any
				# Mario height inside the water column counts.
				box.size = Vector3(cell_x, 200.0, cell_z)
				cs_area.shape = box
				area.add_child(cs_area)
				area.position = Vector3(
					(ax2 + bx2) * 0.5,
					local_water_y - 95.0,
					(az2 + bz2) * 0.5)
				add_child(area)
		if windices.size() > 0:
			var wmesh := ArrayMesh.new()
			var warrays: Array = []
			warrays.resize(Mesh.ARRAY_MAX)
			warrays[Mesh.ARRAY_VERTEX] = wvert_positions
			warrays[Mesh.ARRAY_NORMAL] = wvert_normals
			warrays[Mesh.ARRAY_TEX_UV] = wvert_uvs
			warrays[Mesh.ARRAY_INDEX] = windices
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

	# Pool walls (skirt). Built as extra triangles tacked onto the
	# default mesh so they render + collide with the usual grass/dirt
	# material. Only emitted when we have water cells AND a known
	# water_level_y to act as the bottom reference.
	var skirt_verts := PackedVector3Array()
	var skirt_normals := PackedVector3Array()
	var skirt_uvs := PackedVector2Array()
	var skirt_colors := PackedColorArray()
	var skirt_indices := PackedInt32Array()
	# Box-shape wall definitions for collision — each entry is a tuple
	# (center: Vector3, size: Vector3). The visual skirt is a thin
	# trimesh (looks like extruded earth); the box collision on top
	# has some thickness (0.25m) and slight overhang past the shared
	# edge so corners don't leave tunnelable gaps between adjacent
	# walls. Thin trimesh alone was letting the swim capsule squeeze
	# through corners when the player hit the wall at an angle.
	var wall_boxes: Array = []  # Array of [Vector3 center, Vector3 size]
	var SKIRT_DEPTH := 8.0
	var WALL_THICK := 0.25
	var WALL_OVERHANG := 0.15   # slight overlap past the cell edge at each end
	if have_water and water_level_y > -1e8:
		var skirt_bottom_local: float = water_level_y - self.global_position.y - SKIRT_DEPTH
		var dirt: Color = slope_color.lerp(Color.BLACK, 0.25)
		# Directions: (di, dj, v0a, v0b) — for cell (ci, cj), the
		# neighbour at (ci+di, cj+dj) is water → emit a wall along the
		# shared edge. v0a/v0b are the two corner vertex indices
		# (relative to the cell's four corners TL=a BL=b BR=c TR=d).
		var NEIGHBOURS := [
			# Water to the +x side (neighbour ci+1) → wall on this cell's +x edge.
			[ 1,  0, "b", "c"],
			# Water to the -x side → wall on -x edge.
			[-1,  0, "a", "d"],
			# Water to +z side → wall on +z edge.
			[ 0,  1, "d", "c"],
			# Water to -z side → wall on -z edge.
			[ 0, -1, "a", "b"],
		]
		for ci in range(res - 1):
			for cj in range(res - 1):
				var own_kind: String = String(surface_grid[ci * (res - 1) + cj])
				if own_kind == "water":
					continue
				for nb in NEIGHBOURS:
					var di: int = int(nb[0])
					var dj: int = int(nb[1])
					var ni: int = ci + di
					var nj: int = cj + dj
					if ni < 0 or nj < 0 or ni >= res - 1 or nj >= res - 1:
						continue
					if String(surface_grid[ni * (res - 1) + nj]) != "water":
						continue
					# Shared edge between cell (ci,cj) and (ni,nj).
					# Cell corner indices: a = (ci, cj), b = (ci+1, cj),
					# c = (ci+1, cj+1), d = (ci, cj+1).
					var a_idx: int = ci * res + cj
					var b_idx: int = (ci + 1) * res + cj
					var c_idx: int = (ci + 1) * res + (cj + 1)
					var d_idx: int = ci * res + (cj + 1)
					var corners: Dictionary = {"a": a_idx, "b": b_idx, "c": c_idx, "d": d_idx}
					var top_left: int = corners[String(nb[2])]
					var top_right: int = corners[String(nb[3])]
					var vt_tl: Vector3 = verts[top_left]
					var vt_tr: Vector3 = verts[top_right]
					var vb_tl := Vector3(vt_tl.x, skirt_bottom_local, vt_tl.z)
					var vb_tr := Vector3(vt_tr.x, skirt_bottom_local, vt_tr.z)
					# Normal points outward (toward water, i.e. in the
					# (di, dj) direction).
					var nwall := Vector3(float(di), 0.0, float(dj)).normalized()
					var base_idx: int = skirt_verts.size()
					skirt_verts.append(vt_tl)
					skirt_verts.append(vt_tr)
					skirt_verts.append(vb_tr)
					skirt_verts.append(vb_tl)
					for _k in range(4):
						skirt_normals.append(nwall)
						skirt_uvs.append(Vector2.ZERO)
						skirt_colors.append(dirt)
					skirt_indices.append_array([
						base_idx, base_idx + 1, base_idx + 2,
						base_idx, base_idx + 2, base_idx + 3,
					])
					# Axis-aligned box collision for this wall. Use the
					# MAX of the two top heights so the box always
					# reaches the terrain surface; slight overhang at
					# both ends means adjacent walls at a corner share
					# a tiny overlap instead of leaving a seam.
					var edge_len_x: float = abs(vt_tr.x - vt_tl.x)
					var edge_len_z: float = abs(vt_tr.z - vt_tl.z)
					var edge_mid_x: float = (vt_tl.x + vt_tr.x) * 0.5
					var edge_mid_z: float = (vt_tl.z + vt_tr.z) * 0.5
					var top_y_max: float = max(vt_tl.y, vt_tr.y)
					var box_h: float = top_y_max - skirt_bottom_local
					var box_cy: float = (top_y_max + skirt_bottom_local) * 0.5
					var box_size: Vector3
					if abs(di) > 0:
						# Wall normal in ±x → box is thin in x, wide in z.
						box_size = Vector3(WALL_THICK,
							box_h,
							edge_len_z + WALL_OVERHANG * 2.0)
					else:
						# Wall normal in ±z → box is thin in z, wide in x.
						box_size = Vector3(edge_len_x + WALL_OVERHANG * 2.0,
							box_h,
							WALL_THICK)
					wall_boxes.append([
						Vector3(edge_mid_x, box_cy, edge_mid_z),
						box_size,
					])
	if skirt_indices.size() > 0:
		var smesh := ArrayMesh.new()
		var sarrays: Array = []
		sarrays.resize(Mesh.ARRAY_MAX)
		sarrays[Mesh.ARRAY_VERTEX] = skirt_verts
		sarrays[Mesh.ARRAY_NORMAL] = skirt_normals
		sarrays[Mesh.ARRAY_TEX_UV] = skirt_uvs
		sarrays[Mesh.ARRAY_COLOR] = skirt_colors
		sarrays[Mesh.ARRAY_INDEX] = skirt_indices
		smesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sarrays)
		var smat := StandardMaterial3D.new()
		smat.vertex_color_use_as_albedo = true
		smat.roughness = 0.92
		smat.cull_mode = BaseMaterial3D.CULL_DISABLED
		smesh.surface_set_material(0, smat)
		var smi := MeshInstance3D.new()
		smi.mesh = smesh
		smi.name = "Skirt"
		add_child(smi)
	# Box colliders for each pool wall — thin flat trimeshes let
	# swim-capsule penetration at angled approaches and corners.
	# Each wall is its own StaticBody3D with a BoxShape3D, thick
	# enough to be robust and overlapping slightly at the edges so
	# corners join cleanly.
	if wall_boxes.size() > 0:
		var sbody := StaticBody3D.new()
		sbody.name = "SkirtCol"
		sbody.collision_layer = 1
		sbody.collision_mask = 1
		for entry in wall_boxes:
			var centre: Vector3 = entry[0]
			var size: Vector3 = entry[1]
			var box_shape := BoxShape3D.new()
			box_shape.size = size
			var cs_wall := CollisionShape3D.new()
			cs_wall.shape = box_shape
			cs_wall.position = centre
			sbody.add_child(cs_wall)
		add_child(sbody)

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
