extends Control
class_name BlueprintCanvas

# Top-down 2D canvas for the blueprint editor. Responsibilities:
#   - Draw a world-space grid and axis hints
#   - Draw every room on the current floor as a filled rectangle with a
#     darker outline, walls thicker where openings carve gaps out of them
#   - Draw extras (stairs/elevators/pillars/etc.), pickups, spawn marker
#   - Forward mouse input (screen → world meters) to the main editor,
#     which decides what to place/select/drag
#
# The canvas does NOT mutate the blueprint itself — it just turns pixels
# into meters and hands intent back to the editor.

signal canvas_click(world: Vector2, button: int, shift: bool, ctrl: bool)
signal canvas_drag(world: Vector2, delta_world: Vector2)
signal canvas_release(world: Vector2, button: int)
signal canvas_hover(world: Vector2)

# Reference to the editor; set by the editor after instantiation. Needed
# for read-only access to blueprint data + selection state during _draw.
var editor: Node = null

var pixels_per_meter: float = 18.0
var pan: Vector2 = Vector2(480, 200)   # canvas-space offset of world (0,0)
var _dragging_pan: bool = false
var _dragging_item: bool = false
var _drag_start_world: Vector2 = Vector2.ZERO
var _last_world: Vector2 = Vector2.ZERO

const GRID_COLOR := Color(0.2, 0.22, 0.28)
const GRID_COLOR_MAJOR := Color(0.28, 0.30, 0.36)
const BG_COLOR := Color(0.10, 0.11, 0.14)
const AXIS_X := Color(0.65, 0.30, 0.30)
const AXIS_Z := Color(0.30, 0.45, 0.70)
const ROOM_FILL := Color(0.38, 0.42, 0.52, 0.55)
const ROOM_OUTLINE := Color(0.82, 0.88, 0.98)
const ROOM_SELECTED := Color(1.0, 0.85, 0.35)
const GHOST_FILL := Color(0.38, 0.42, 0.52, 0.12)
const GHOST_OUTLINE := Color(0.55, 0.60, 0.70, 0.35)
const OPENING_DOOR := Color(0.95, 0.75, 0.35)
const OPENING_WIN := Color(0.45, 0.85, 1.0)
const EXTRA_COLORS := {
	"stair": Color(0.75, 0.75, 0.45),
	"spiral_stair": Color(0.85, 0.55, 0.85),
	"elevator": Color(0.55, 0.85, 0.55),
	"pillar": Color(0.70, 0.50, 0.30),
	"platform": Color(0.90, 0.60, 0.40),
}
const BLOCK_COLOR := Color(0.80, 0.55, 0.30)
const KEY_COLOR := Color(0.95, 0.85, 0.35)
const SPAWN_COLOR := Color(0.35, 1.0, 0.55)
const LOCK_COLOR := Color(0.85, 0.35, 0.85)


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP


func world_to_canvas(p: Vector2) -> Vector2:
	return p * pixels_per_meter + pan


func canvas_to_world(p: Vector2) -> Vector2:
	return (p - pan) / pixels_per_meter


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		var world := canvas_to_world(mb.position)
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			if mb.pressed:
				_zoom_at(mb.position, 1.15)
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if mb.pressed:
				_zoom_at(mb.position, 1.0 / 1.15)
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging_pan = mb.pressed
			_last_world = world
			return
		if mb.button_index == MOUSE_BUTTON_LEFT or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_dragging_item = true
				_drag_start_world = world
				_last_world = world
				canvas_click.emit(world, mb.button_index, mb.shift_pressed, mb.ctrl_pressed)
			else:
				if _dragging_item:
					_dragging_item = false
					canvas_release.emit(world, mb.button_index)
			accept_event()
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		var world := canvas_to_world(mm.position)
		if _dragging_pan:
			# Pan should NOT change the world position under the cursor —
			# just shift the canvas-space pan by the pixel delta.
			pan += mm.relative
			queue_redraw()
		elif _dragging_item:
			var dw := world - _last_world
			_last_world = world
			canvas_drag.emit(world, dw)
		else:
			canvas_hover.emit(world)
		return


func _zoom_at(screen_point: Vector2, factor: float) -> void:
	var world_before := canvas_to_world(screen_point)
	pixels_per_meter = clamp(pixels_per_meter * factor, 2.0, 280.0)
	var world_after := canvas_to_world(screen_point)
	pan += (world_after - world_before) * pixels_per_meter
	queue_redraw()


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, BG_COLOR, true)
	_draw_grid()
	_draw_axes()
	if editor == null:
		return
	var bp: Dictionary = editor.blueprint
	if bp.is_empty():
		return
	_draw_ghost_floors(bp)
	_draw_current_floor(bp)
	_draw_spawn(bp)
	_draw_tool_preview()


func _draw_grid() -> void:
	# Draw meters as minor lines, every 5m as major. Compute visible
	# world extents so we don't spam draw calls offscreen.
	var tl := canvas_to_world(Vector2.ZERO)
	var br := canvas_to_world(size)
	var x0 := int(floor(tl.x)) - 1
	var x1 := int(ceil(br.x)) + 1
	var z0 := int(floor(tl.y)) - 1
	var z1 := int(ceil(br.y)) + 1
	for x in range(x0, x1 + 1):
		var p0 := world_to_canvas(Vector2(x, tl.y))
		var p1 := world_to_canvas(Vector2(x, br.y))
		var c: Color = GRID_COLOR_MAJOR if (x % 5 == 0) else GRID_COLOR
		draw_line(p0, p1, c, 1.0)
	for z in range(z0, z1 + 1):
		var q0 := world_to_canvas(Vector2(tl.x, z))
		var q1 := world_to_canvas(Vector2(br.x, z))
		var c2: Color = GRID_COLOR_MAJOR if (z % 5 == 0) else GRID_COLOR
		draw_line(q0, q1, c2, 1.0)


func _draw_axes() -> void:
	var origin := world_to_canvas(Vector2.ZERO)
	var x_tip := world_to_canvas(Vector2(3.0, 0.0))
	var z_tip := world_to_canvas(Vector2(0.0, 3.0))
	draw_line(origin, x_tip, AXIS_X, 2.0)
	draw_line(origin, z_tip, AXIS_Z, 2.0)
	var font := ThemeDB.fallback_font
	draw_string(font, x_tip + Vector2(4, 4), "+x", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AXIS_X)
	draw_string(font, z_tip + Vector2(4, 14), "+z", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, AXIS_Z)


func _draw_ghost_floors(bp: Dictionary) -> void:
	# Faint outline of rooms on other floors so the user has spatial
	# context when authoring (e.g. tower stands over gallery).
	var current_y: float = editor.current_floor_y
	for room in bp.get("rooms", []):
		var oy: float = float(room["origin"][1])
		var sy: float = float(room["size"][1])
		if current_y >= oy and current_y < oy + sy:
			continue  # this room is on the current floor
		_draw_room(room, true)


func _draw_current_floor(bp: Dictionary) -> void:
	var current_y: float = editor.current_floor_y
	# Terrain patches first, so rooms and extras render on top of them.
	var patches: Array = bp.get("terrain_patches", [])
	for i in range(patches.size()):
		_draw_terrain_patch(patches[i], _is_selected("terrain_patches", i))
	var rooms: Array = bp.get("rooms", [])
	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var oy: float = float(room["origin"][1])
		var sy: float = float(room["size"][1])
		if current_y < oy or current_y >= oy + sy:
			continue
		_draw_room(room, false, _is_selected("rooms", i), i)
	for i in range(bp.get("extras", []).size()):
		var ex: Dictionary = bp["extras"][i]
		if not _extra_on_floor(ex, current_y):
			continue
		_draw_extra(ex, _is_selected("extras", i))
	for i in range(bp.get("blocks", []).size()):
		var blk: Dictionary = bp["blocks"][i]
		if not _block_on_floor(blk, current_y):
			continue
		_draw_block(blk, _is_selected("blocks", i))
	for i in range(bp.get("keys", []).size()):
		var k: Dictionary = bp["keys"][i]
		if not _pos_on_floor(k.get("pos", [0, 0, 0]), current_y, 0.5):
			continue
		_draw_key(k, _is_selected("keys", i))
	for i in range(bp.get("locks", []).size()):
		var lk: Dictionary = bp["locks"][i]
		if not _lock_on_floor(lk, current_y):
			continue
		_draw_lock(lk, _is_selected("locks", i))
	for i in range(bp.get("volumes", []).size()):
		_draw_volume(bp["volumes"][i], _is_selected("volumes", i))
	for i in range(bp.get("warps", []).size()):
		_draw_warp(bp["warps"][i], _is_selected("warps", i))
	for i in range(bp.get("enemies", []).size()):
		_draw_enemy(bp["enemies"][i], _is_selected("enemies", i))
	for i in range(bp.get("pickups", []).size()):
		_draw_pickup(bp["pickups"][i], _is_selected("pickups", i))


func _is_selected(kind: String, index: int) -> bool:
	return editor != null and editor.selected_kind == kind and editor.selected_index == index


func _extra_on_floor(ex: Dictionary, floor_y: float) -> bool:
	var t: String = ex.get("type", "")
	var pos: Array = ex.get("pos", [0, 0, 0])
	var py: float = float(pos[1])
	match t:
		"stair":
			var steps: float = float(ex.get("steps", 0))
			var rise: float = float(ex.get("rise", 0))
			var h: float = max(steps * rise, 0.4)
			return floor_y >= py - 0.6 and floor_y < py + h + 0.6
		"spiral_stair":
			var h2: float = float(ex.get("steps", 0)) * float(ex.get("rise", 0))
			return floor_y >= py - 0.6 and floor_y < py + h2 + 0.6
		"elevator":
			var lo: float = float(ex.get("low_y", py))
			var hi: float = float(ex.get("high_y", py + 4))
			return floor_y >= lo - 0.6 and floor_y < hi + 0.6
		"pillar":
			var ph: float = float(ex.get("height", 1.0))
			return floor_y >= py - 0.1 and floor_y < py + ph + 0.1
		"platform":
			var size: Array = ex.get("size", [1, 0.4, 1])
			return floor_y >= py - 0.6 and floor_y < py + float(size[1]) + 0.6
	return _pos_on_floor(pos, floor_y, 0.6)


func _block_on_floor(blk: Dictionary, floor_y: float) -> bool:
	var pos: Array = blk.get("pos", [0, 0, 0])
	var size: Array = blk.get("size", [1, 1, 1])
	var py: float = float(pos[1])
	var sy: float = float(size[1])
	return floor_y >= py - 0.4 and floor_y < py + sy + 0.4


func _lock_on_floor(lk: Dictionary, floor_y: float) -> bool:
	var pos: Array = lk.get("pos", [0, 0, 0])
	var py: float = float(pos[1])
	var h: float = float(lk.get("height", 4))
	return floor_y >= py - 0.4 and floor_y < py + h + 0.4


func _pos_on_floor(pos: Array, floor_y: float, tol: float) -> bool:
	var py: float = float(pos[1])
	return abs(py - floor_y) <= tol + 0.5 or (py >= floor_y - tol and py < floor_y + 2.0 + tol)


func _draw_room(room: Dictionary, ghost: bool, selected: bool = false, room_index: int = -1) -> void:
	var o: Array = room["origin"]
	var s: Array = room["size"]
	var ox: float = float(o[0])
	var oz: float = float(o[2])
	var sx: float = float(s[0])
	var sz: float = float(s[2])
	var tl := world_to_canvas(Vector2(ox, oz))
	var br := world_to_canvas(Vector2(ox + sx, oz + sz))
	var rect := Rect2(tl, br - tl)
	if ghost:
		draw_rect(rect, GHOST_FILL, true)
		draw_rect(rect, GHOST_OUTLINE, false, 1.0)
	else:
		draw_rect(rect, ROOM_FILL, true)
		var outline: Color = ROOM_SELECTED if selected else ROOM_OUTLINE
		var thick: float = 3.0 if selected else 2.0
		draw_rect(rect, outline, false, thick)
		_draw_openings(room, room_index)
		var name: String = String(room.get("name", ""))
		if name != "":
			var font := ThemeDB.fallback_font
			draw_string(font, tl + Vector2(6, 16), name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, outline)


func _draw_openings(room: Dictionary, room_index: int = -1) -> void:
	# Render each wall opening as a colored slot on the corresponding
	# edge. When an opening is the current editor selection, drawn
	# thicker + in the selection colour so it's obviously pickable.
	var o: Array = room["origin"]
	var s: Array = room["size"]
	var ox: float = float(o[0])
	var oz: float = float(o[2])
	var sx: float = float(s[0])
	var sz: float = float(s[2])
	var walls: Dictionary = room.get("walls", {})
	for side in ["north", "south", "east", "west"]:
		if not walls.has(side):
			continue
		var openings: Array = walls[side].get("openings", [])
		for oi in range(openings.size()):
			var op: Dictionary = openings[oi]
			var t: String = op.get("type", "window")
			var ox2: float = float(op.get("x", 0))
			var w: float = float(op.get("width", 1))
			var col: Color = OPENING_DOOR if t == "door" else OPENING_WIN
			var a := Vector2.ZERO
			var b := Vector2.ZERO
			match side:
				"south":
					a = Vector2(ox + ox2, oz)
					b = Vector2(ox + ox2 + w, oz)
				"north":
					a = Vector2(ox + ox2, oz + sz)
					b = Vector2(ox + ox2 + w, oz + sz)
				"west":
					a = Vector2(ox, oz + ox2)
					b = Vector2(ox, oz + ox2 + w)
				"east":
					a = Vector2(ox + sx, oz + ox2)
					b = Vector2(ox + sx, oz + ox2 + w)
			var selected: bool = (editor != null
				and editor.selected_kind == "opening"
				and editor._sel_op_room == room_index
				and editor._sel_op_side == side
				and editor._sel_op_idx == oi)
			var final_col: Color = ROOM_SELECTED if selected else col
			var thick: float = 7.0 if selected else 4.0
			draw_line(world_to_canvas(a), world_to_canvas(b), final_col, thick)


func _draw_extra(ex: Dictionary, selected: bool) -> void:
	var t: String = ex.get("type", "")
	var pos: Array = ex.get("pos", [0, 0, 0])
	var px: float = float(pos[0])
	var pz: float = float(pos[2])
	var center := world_to_canvas(Vector2(px, pz))
	var col: Color = EXTRA_COLORS.get(t, Color(0.9, 0.9, 0.9))
	match t:
		"stair":
			var steps: int = int(ex.get("steps", 1))
			var run_m: float = float(ex.get("run", 0.5))
			var width: float = float(ex.get("width", 1.0))
			var dir: String = ex.get("direction", "+x")
			var length: float = steps * run_m
			var rect_w: float = length
			var rect_d: float = width
			var off := Vector2.ZERO
			match dir:
				"+x": off = Vector2(rect_w, rect_d); _draw_stair_rect(Vector2(px, pz), off, col, steps, selected, dir)
				"-x": off = Vector2(rect_w, rect_d); _draw_stair_rect(Vector2(px - rect_w, pz), off, col, steps, selected, dir)
				"+z": off = Vector2(rect_d, rect_w); _draw_stair_rect(Vector2(px, pz), off, col, steps, selected, dir)
				"-z": off = Vector2(rect_d, rect_w); _draw_stair_rect(Vector2(px, pz - rect_w), off, col, steps, selected, dir)
		"spiral_stair":
			var radius: float = float(ex.get("radius", 1.6))
			var rr: float = radius * pixels_per_meter
			draw_circle(center, rr, Color(col.r, col.g, col.b, 0.35))
			draw_arc(center, rr, 0, TAU, 36, col, 2.0 if not selected else 3.0)
			draw_line(center, center + Vector2(rr, 0), col, 1.5)
		"elevator":
			var width2: float = float(ex.get("width", 2))
			var depth2: float = float(ex.get("depth", 2))
			var tl := world_to_canvas(Vector2(px - width2 * 0.5, pz - depth2 * 0.5))
			var br := world_to_canvas(Vector2(px + width2 * 0.5, pz + depth2 * 0.5))
			var rect := Rect2(tl, br - tl)
			draw_rect(rect, Color(col.r, col.g, col.b, 0.35), true)
			draw_rect(rect, col, false, 3.0 if selected else 2.0)
			var font := ThemeDB.fallback_font
			draw_string(font, tl + Vector2(4, 12), "LIFT", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, col)
		"pillar":
			var rr2: float = float(ex.get("radius", 0.3)) * pixels_per_meter
			draw_circle(center, rr2, col)
			if selected:
				draw_arc(center, rr2 + 3.0, 0, TAU, 24, ROOM_SELECTED, 2.0)
		"platform":
			var size: Array = ex.get("size", [1, 0.4, 1])
			var sx: float = float(size[0])
			var sz: float = float(size[2])
			var tl2 := world_to_canvas(Vector2(px, pz))
			var br2 := world_to_canvas(Vector2(px + sx, pz + sz))
			var rect2 := Rect2(tl2, br2 - tl2)
			draw_rect(rect2, Color(col.r, col.g, col.b, 0.45), true)
			draw_rect(rect2, col, false, 3.0 if selected else 1.5)
	# Label
	var font := ThemeDB.fallback_font
	draw_string(font, center + Vector2(8, -6), String(ex.get("name", t)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.WHITE)


func _draw_stair_rect(origin_m: Vector2, size_m: Vector2, col: Color, steps: int, selected: bool, dir: String) -> void:
	var tl := world_to_canvas(origin_m)
	var br := world_to_canvas(origin_m + size_m)
	var rect := Rect2(tl, br - tl)
	draw_rect(rect, Color(col.r, col.g, col.b, 0.35), true)
	draw_rect(rect, col, false, 3.0 if selected else 1.5)
	# Draw little step ticks along the long axis.
	var long_axis: float = size_m.x if (dir == "+x" or dir == "-x") else size_m.y
	var tick_count: int = min(steps, 10)
	for i in range(1, tick_count):
		var frac: float = float(i) / float(tick_count)
		if dir == "+x":
			var xw: float = origin_m.x + frac * long_axis
			draw_line(world_to_canvas(Vector2(xw, origin_m.y)), world_to_canvas(Vector2(xw, origin_m.y + size_m.y)), col, 1.0)
		elif dir == "-x":
			var xw2: float = origin_m.x + frac * long_axis
			draw_line(world_to_canvas(Vector2(xw2, origin_m.y)), world_to_canvas(Vector2(xw2, origin_m.y + size_m.y)), col, 1.0)
		elif dir == "+z":
			var zw: float = origin_m.y + frac * long_axis
			draw_line(world_to_canvas(Vector2(origin_m.x, zw)), world_to_canvas(Vector2(origin_m.x + size_m.x, zw)), col, 1.0)
		else:
			var zw2: float = origin_m.y + frac * long_axis
			draw_line(world_to_canvas(Vector2(origin_m.x, zw2)), world_to_canvas(Vector2(origin_m.x + size_m.x, zw2)), col, 1.0)
	# Arrow marking "up" direction.
	var cx: float = origin_m.x + size_m.x * 0.5
	var cz: float = origin_m.y + size_m.y * 0.5
	var a := Vector2.ZERO
	var b := Vector2.ZERO
	match dir:
		"+x": a = Vector2(cx - size_m.x * 0.3, cz); b = Vector2(cx + size_m.x * 0.3, cz)
		"-x": a = Vector2(cx + size_m.x * 0.3, cz); b = Vector2(cx - size_m.x * 0.3, cz)
		"+z": a = Vector2(cx, cz - size_m.y * 0.3); b = Vector2(cx, cz + size_m.y * 0.3)
		"-z": a = Vector2(cx, cz + size_m.y * 0.3); b = Vector2(cx, cz - size_m.y * 0.3)
	draw_line(world_to_canvas(a), world_to_canvas(b), Color.WHITE, 2.0)


func _draw_block(blk: Dictionary, selected: bool) -> void:
	var pos: Array = blk.get("pos", [0, 0, 0])
	var size: Array = blk.get("size", [1, 1, 1])
	var px: float = float(pos[0])
	var pz: float = float(pos[2])
	var sx: float = float(size[0])
	var sz: float = float(size[2])
	var tl := world_to_canvas(Vector2(px, pz))
	var br := world_to_canvas(Vector2(px + sx, pz + sz))
	var rect := Rect2(tl, br - tl)
	var col: Color = BLOCK_COLOR
	draw_rect(rect, Color(col.r, col.g, col.b, 0.55), true)
	draw_rect(rect, col if not selected else ROOM_SELECTED, false, 3.0 if selected else 1.5)
	if blk.get("breakable", false):
		var c := rect.get_center()
		draw_line(Vector2(rect.position.x, c.y), Vector2(rect.end.x, c.y), Color(0, 0, 0, 0.4), 1.0)
		draw_line(Vector2(c.x, rect.position.y), Vector2(c.x, rect.end.y), Color(0, 0, 0, 0.4), 1.0)


func _draw_key(k: Dictionary, selected: bool) -> void:
	var pos: Array = k.get("pos", [0, 0, 0])
	var center := world_to_canvas(Vector2(float(pos[0]), float(pos[2])))
	var r: float = 7.0
	var col: Color = KEY_COLOR
	match String(k.get("color", "silver")):
		"silver": col = Color(0.85, 0.85, 0.92)
		"gold":   col = Color(0.98, 0.85, 0.30)
		"bronze": col = Color(0.80, 0.55, 0.30)
		"red":    col = Color(0.90, 0.35, 0.30)
	draw_circle(center, r, col)
	draw_arc(center, r, 0, TAU, 16, Color.BLACK, 1.0)
	if selected:
		draw_arc(center, r + 3.0, 0, TAU, 24, ROOM_SELECTED, 2.0)


func _draw_lock(lk: Dictionary, selected: bool) -> void:
	var pos: Array = lk.get("pos", [0, 0, 0])
	var w: float = float(lk.get("width", 2.0))
	var d: float = float(lk.get("depth", 0.5))
	var tl := world_to_canvas(Vector2(float(pos[0]), float(pos[2])))
	var br := world_to_canvas(Vector2(float(pos[0]) + w, float(pos[2]) + d))
	var rect := Rect2(tl, br - tl)
	draw_rect(rect, Color(LOCK_COLOR.r, LOCK_COLOR.g, LOCK_COLOR.b, 0.55), true)
	draw_rect(rect, LOCK_COLOR if not selected else ROOM_SELECTED, false, 3.0 if selected else 1.5)


func _draw_spawn(bp: Dictionary) -> void:
	if bp.has("spawn_point"):
		var sp: Array = bp["spawn_point"]
		var center := world_to_canvas(Vector2(float(sp[0]), float(sp[2])))
		draw_circle(center, 9.0, SPAWN_COLOR)
		draw_arc(center, 9.0, 0, TAU, 24, Color.BLACK, 1.0)
		var font := ThemeDB.fallback_font
		draw_string(font, center + Vector2(12, 4), "SPAWN", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, SPAWN_COLOR)
	# Temp spawn marker — an outlined cyan diamond so it's distinct
	# from the real spawn circle. Rendered only while an override is
	# active in the editor state.
	if editor != null and editor._temp_spawn.size() == 3:
		var ts: Array = editor._temp_spawn
		var c := world_to_canvas(Vector2(float(ts[0]), float(ts[2])))
		var d := 10.0
		var diamond: PackedVector2Array = PackedVector2Array([
			c + Vector2(0, -d), c + Vector2(d, 0),
			c + Vector2(0, d),  c + Vector2(-d, 0),
		])
		var cyan := Color(0.35, 0.95, 1.0)
		draw_colored_polygon(diamond, Color(cyan.r, cyan.g, cyan.b, 0.4))
		draw_polyline(PackedVector2Array([diamond[0], diamond[1], diamond[2], diamond[3], diamond[0]]), cyan, 2.0)
		var font2 := ThemeDB.fallback_font
		draw_string(font2, c + Vector2(14, 4), "TEMP", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, cyan)


func _draw_tool_preview() -> void:
	if editor == null:
		return
	var mode: String = editor.tool_mode
	if mode not in ["room", "terrain", "water", "lava"]:
		return
	if not _dragging_item:
		return
	var a := _drag_start_world
	var b := _last_world
	var tl := Vector2(min(a.x, b.x), min(a.y, b.y))
	var br := Vector2(max(a.x, b.x), max(a.y, b.y))
	var r_tl := world_to_canvas(tl)
	var r_br := world_to_canvas(br)
	var rect := Rect2(r_tl, r_br - r_tl)
	var tint: Color = Color(1, 1, 1, 0.15)
	var edge: Color = Color(1, 1, 1, 0.8)
	match mode:
		"terrain": tint = Color(0.45, 0.85, 0.45, 0.18); edge = Color(0.55, 1.0, 0.55, 0.9)
		"water":   tint = Color(0.25, 0.55, 0.95, 0.22); edge = Color(0.35, 0.7, 1.0, 0.9)
		"lava":    tint = Color(1.0, 0.35, 0.10, 0.22);  edge = Color(1.0, 0.55, 0.15, 0.95)
	draw_rect(rect, tint, true)
	draw_rect(rect, edge, false, 2.0)


const VOLUME_COLOR := {
	"water":     Color(0.25, 0.55, 0.95),
	"lava":      Color(1.0, 0.35, 0.10),
	"ice":       Color(0.70, 0.90, 1.00),
	"quicksand": Color(0.78, 0.65, 0.30),
}

const PICKUP_COLOR := {
	"coin_yellow": Color(1.0, 0.85, 0.10),
	"coin_blue":   Color(0.20, 0.50, 1.0),
	"coin_red":    Color(1.0, 0.25, 0.25),
	"star":        Color(1.0, 1.0, 0.30),
	"oneup":       Color(0.35, 1.0, 0.40),
	"cap_wing":    Color(1.0, 1.0, 0.88),
	"cap_metal":   Color(0.75, 0.75, 0.85),
	"cap_vanish":  Color(0.85, 0.45, 1.0),
	"key_bronze":  Color(0.80, 0.55, 0.30),
	"key_silver":  Color(0.88, 0.88, 0.92),
	"key_gold":    Color(0.98, 0.85, 0.35),
}


func _draw_volume(vol: Dictionary, selected: bool) -> void:
	var o: Array = vol.get("origin", [0, 0, 0])
	var s: Array = vol.get("size", [4, 1, 4])
	var tl := world_to_canvas(Vector2(float(o[0]), float(o[2])))
	var br := world_to_canvas(Vector2(float(o[0]) + float(s[0]), float(o[2]) + float(s[2])))
	var rect := Rect2(tl, br - tl)
	var col: Color = VOLUME_COLOR.get(String(vol.get("kind", "water")), Color.GRAY)
	draw_rect(rect, Color(col.r, col.g, col.b, 0.28), true)
	draw_rect(rect, col if not selected else ROOM_SELECTED, false, 3.0 if selected else 1.5)
	var font := ThemeDB.fallback_font
	draw_string(font, tl + Vector2(6, 14),
		String(vol.get("name", vol.get("kind", "vol"))).to_upper(),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, col)


func _draw_warp(warp: Dictionary, selected: bool) -> void:
	var p: Array = warp.get("pos", [0, 0, 0])
	var sz: Array = warp.get("size", [2.5, 3, 0.4])
	var w: float = float(sz[0]); var d: float = float(sz[2])
	var cx: float = float(p[0]); var cz: float = float(p[2])
	var tl := world_to_canvas(Vector2(cx - w * 0.5, cz - d * 0.5))
	var br := world_to_canvas(Vector2(cx + w * 0.5, cz + d * 0.5))
	var rect := Rect2(tl, br - tl)
	var col := Color(0.6, 0.4, 1.0)
	draw_rect(rect, Color(col.r, col.g, col.b, 0.4), true)
	draw_rect(rect, col if not selected else ROOM_SELECTED, false, 3.0 if selected else 2.0)
	var font := ThemeDB.fallback_font
	draw_string(font, tl + Vector2(4, 14),
		"→ " + String(warp.get("target_level", "?")),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.9, 0.8, 1.0))


func _draw_enemy(enemy: Dictionary, selected: bool) -> void:
	var p: Array = enemy.get("pos", [0, 0, 0])
	var center := world_to_canvas(Vector2(float(p[0]), float(p[2])))
	var col := Color(0.95, 0.30, 0.30)
	draw_circle(center, 8.0, col)
	draw_arc(center, 8.0, 0, TAU, 16, Color.BLACK, 1.0)
	if selected:
		draw_arc(center, 11.0, 0, TAU, 24, ROOM_SELECTED, 2.0)
	var font := ThemeDB.fallback_font
	var bhv: String = String(enemy.get("bhv", ""))
	draw_string(font, center + Vector2(10, 4),
		bhv.trim_prefix("bhv"), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1, 0.8, 0.8))


func _draw_pickup(pickup: Dictionary, selected: bool) -> void:
	var p: Array = pickup.get("pos", [0, 0, 0])
	var center := world_to_canvas(Vector2(float(p[0]), float(p[2])))
	var kind: String = String(pickup.get("kind", "coin_yellow"))
	var col: Color = PICKUP_COLOR.get(kind, Color.WHITE)
	# Stars draw as a 5-point star glyph so they stand out from coins.
	if kind == "star":
		var pts := PackedVector2Array()
		for k in range(10):
			var r: float = 9.0 if k % 2 == 0 else 4.0
			var ang: float = -PI * 0.5 + k * PI * 0.2
			pts.append(center + Vector2(cos(ang), sin(ang)) * r)
		draw_colored_polygon(pts, col)
	else:
		draw_circle(center, 6.0, col)
		draw_arc(center, 6.0, 0, TAU, 16, Color.BLACK, 1.0)
	if selected:
		draw_arc(center, 11.0, 0, TAU, 24, ROOM_SELECTED, 2.0)


const PAINT_TINT := {
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


func _draw_terrain_patch(patch: Dictionary, selected: bool) -> void:
	var o: Array = patch.get("origin", [0, 0, 0])
	var sx: float = float(patch.get("size_x", 10))
	var sz: float = float(patch.get("size_z", 10))
	var res: int = int(patch.get("resolution", 8))
	var heights: Array = patch.get("heights", [])
	var surface_grid: Array = patch.get("surface_grid", [])
	var ox: float = float(o[0])
	var oz: float = float(o[2])
	var tl := world_to_canvas(Vector2(ox, oz))
	var br := world_to_canvas(Vector2(ox + sx, oz + sz))
	var rect := Rect2(tl, br - tl)
	draw_rect(rect, Color(0.10, 0.18, 0.14, 0.8), true)
	# Height-coloured cells, tinted by surface_grid[cell] when painted.
	# Each cell is tiled with a single colour that merges (a) the height
	# gradient (dark = low, bright = high) and (b) the painted surface
	# kind if any.
	if res >= 2 and heights.size() == res * res:
		var min_h: float = 1e9
		var max_h: float = -1e9
		for h in heights:
			var hf: float = float(h)
			if hf < min_h: min_h = hf
			if hf > max_h: max_h = hf
		var span: float = max(max_h - min_h, 0.01)
		var cw_m: float = sx / float(res - 1)
		var ch_m: float = sz / float(res - 1)
		var expected_cells: int = (res - 1) * (res - 1)
		var has_grid: bool = surface_grid.size() == expected_cells
		for i in range(res - 1):
			for j in range(res - 1):
				var avg: float = 0.25 * (
					float(heights[i * res + j])
					+ float(heights[(i + 1) * res + j])
					+ float(heights[i * res + (j + 1)])
					+ float(heights[(i + 1) * res + (j + 1)])
				)
				var t: float = clamp((avg - min_h) / span, 0.0, 1.0)
				# Flat-terrain default: a solid grass green, not a
				# noise field. Earlier the cells got hash-jitter so
				# resolution was visible on pristine patches, but it
				# read as a distracting static pattern over any
				# authored region. The cell-count readout in the
				# inspector covers the "am I at enough resolution?"
				# question instead.
				var col: Color = Color(0.30, 0.62, 0.22).lerp(
					Color(0.85, 0.80, 0.55), t)
				if has_grid:
					var kind: String = String(surface_grid[i * (res - 1) + j])
					if kind != "" and PAINT_TINT.has(kind):
						col = col.lerp(PAINT_TINT[kind], 0.6)
				var ctl := world_to_canvas(Vector2(ox + float(i) * cw_m, oz + float(j) * ch_m))
				var cbr := world_to_canvas(Vector2(ox + float(i + 1) * cw_m, oz + float(j + 1) * ch_m))
				draw_rect(Rect2(ctl, cbr - ctl), col, true)
	# Outline + label.
	var outline: Color = Color(0.3, 1.0, 0.4) if selected else Color(0.4, 0.7, 0.5)
	draw_rect(rect, outline, false, 3.0 if selected else 1.5)
	var font := ThemeDB.fallback_font
	draw_string(font, tl + Vector2(6, 16), String(patch.get("name", "Terrain")),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, outline)
