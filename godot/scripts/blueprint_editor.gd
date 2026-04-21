extends Control

# Blueprint editor — 2D top-down authoring tool for the JSON blueprint
# format that tools/build_from_blueprint.py consumes. Runs as a plain
# scene inside Godot (F6 to play blueprint_editor.tscn). The user:
#
#   1. Opens or creates a blueprint (File > Open / New)
#   2. Picks a floor Y using the spin box (each tier of rooms lives at a
#      specific y — 0, 5, 10 in the multistory demo)
#   3. Picks a tool from the palette (select / room / door / window /
#      stair / spiral / elevator / pillar / platform / block / key /
#      lock / spawn)
#   4. Click-drags to create rooms or places individual items at the
#      cursor. The selected item's fields appear in the inspector on the
#      left and are editable inline
#   5. Saves the JSON back to /home/david/gd_mario/blueprints/ and hits
#      "Build" to invoke the Python converter, producing a fresh .tscn
#      at godot/assets/levels/<name>.tscn that the level manager can load.

const BlueprintCanvasScript := preload("res://scripts/blueprint_canvas.gd")
const LevelSelectScript := preload("res://scripts/level_select.gd")

# Absolute filesystem paths — the FileDialog needs OS paths because the
# blueprint JSON and the converter live outside res:// (parallel to the
# godot/ folder).
const BLUEPRINTS_DIR := "/home/david/gd_mario/blueprints"
const BUILD_SCRIPT := "/home/david/gd_mario/tools/build_from_blueprint.py"
const LEVELS_DIR := "/home/david/gd_mario/godot/assets/levels"
const PY := "python3"

const MATERIAL_OPTIONS := [
	"brick", "floor", "floor2", "wood", "red",
	"metal", "gold", "silver", "bronze",
]
const KEY_COLORS := ["silver", "gold", "bronze", "red"]
const DIRECTIONS := ["+x", "-x", "+z", "-z"]
const ELEVATOR_MODES := ["call", "loop", "toggle"]

# Mouse-hittable object kinds, in z-order of preference when multiple
# overlap. Rooms are last so point-items on top take priority.
const HIT_ORDER := [
	"pickups", "enemies", "warps", "keys", "locks", "blocks",
	"extras", "volumes", "rooms", "terrain_patches",
]

var blueprint: Dictionary = {}
var current_file: String = ""
var current_floor_y: float = 0.0
var tool_mode: String = "select"
var selected_kind: String = ""
var selected_index: int = -1

# Openings (doors/windows) live inside rooms, not at a top-level array,
# so they need a compound selection path. When selected_kind ==
# "opening", these three name which opening is live.
var _sel_op_room: int = -1
var _sel_op_side: String = ""
var _sel_op_idx: int = -1

var _dirty: bool = false
var _drag_moving: bool = false  # true while user is moving a selected item

# Sculpt state — when active, clicks on the selected terrain patch
# modify its height field instead of selecting/moving it. Brush radius
# is in grid cells; strength in meters of vertical displacement per
# click. Shift-click and right-click both invert (lower instead of raise).
var _sculpt_active: bool = false
var _sculpt_radius: int = 1
var _sculpt_strength: float = 0.4
# Sculpt mode:
#   "raise"   — click raises, shift-click lowers
#   "flatten" — click sets each cell in the brush to _flatten_target;
#               Ctrl-click eyedrops the clicked cell's height as target
#   "average" — click averages heights under the brush
var _sculpt_mode: String = "raise"
var _flatten_target: float = 0.0
# Hard brush = uniform effect across radius (no smooth falloff). The
# user explicitly asked for "only selected quadrants and not its
# neighbors", and hard feels right for almost every authoring case.
var _hard_brush: bool = true

# Paint state — same pattern but writes the selected terrain patch's
# `surface_grid` cells instead of heights. Shift/right-click erases
# (sets kind back to ""). Brush radius is a CELL radius, 0 = single cell.
var _paint_active: bool = false
var _paint_kind: String = "water"
var _paint_radius: int = 1

const TERRAIN_PAINT_KINDS := [
	"", "water", "burning", "ice", "slippery", "very_slippery",
	"snow", "sand", "shallow_quicksand", "deep_quicksand",
]

# Temporary spawn override for Play-in-editor. Not saved to JSON — this
# is session-only state. Shape is [x, y, z]; an empty array means "use
# the blueprint's spawn_point normally."
var _temp_spawn: Array = []

# Undo stack of blueprint snapshots. Pushed before each discrete
# mutating action (place, delete, drag-move start, sculpt-click). A
# drag or sculpt stroke counts as ONE action thanks to
# `_action_pushed_undo` — otherwise the stack would fill with
# per-frame snapshots mid-drag and one Ctrl+Z would rewind a millimetre.
const UNDO_MAX := 80
var _undo_stack: Array = []
var _action_pushed_undo: bool = false

# Session-tracked "empty" floors — Y-levels the author created with the
# + button but hasn't placed rooms on yet. Unioned with each room's
# origin.y to populate the floor dropdown. Persisted as `_editor_floors`
# so adding "Floor 3" empty and reopening the blueprint doesn't lose it.
var _extra_floors: Array = [0.0]

var _canvas: Control
var _floor_option: OptionButton
var _new_floor_height_spin: SpinBox   # default room height
var _tool_list: ItemList
var _inspector: VBoxContainer
var _file_label: Label
var _status_label: Label
var _dialog: FileDialog
var _save_as_mode: bool = false

const TOOLS := [
	["select",       "Select / Move",          "V"],
	["room",         "Room (drag)",            "R"],
	["door",         "Door",                   "D"],
	["window",       "Window",                 "W"],
	["stair",        "Stair",                  "S"],
	["spiral_stair", "Spiral Stair",           "Y"],
	["elevator",     "Elevator",               "E"],
	["pillar",       "Pillar",                 "I"],
	["platform",     "Platform",               "F"],
	["block",        "Block",                  "B"],
	["key",          "Key",                    "K"],
	["lock",         "Lock (barrier)",         "L"],
	["terrain",      "Terrain (drag)",         "T"],
	["enemy",        "Enemy",                  "N"],
	["pickup",       "Pickup",                 "C"],
	["water",        "Water Volume (drag)",    "U"],
	["lava",         "Lava Volume (drag)",     "J"],
	["warp",         "Warp",                   "X"],
	["spawn",        "Spawn Point",            "G"],
	["temp_spawn",   "Temp Spawn (for Play)",  "M"],
]

const ENEMY_BHVS := [
	"bhvGoomba", "bhvKoopa", "bhvBobomb",
	"bhvChuckya", "bhvPiranhaPlant", "bhvMrBlizzard",
	"bhvSmallPenguin", "bhvScuttlebug",
	"bhvBobombBuddy", "bhvCuttlefish", "bhvChainChomp",
]
const PICKUP_KINDS := [
	"coin_yellow", "coin_blue", "coin_red",
	"star", "oneup",
	"cap_wing", "cap_metal", "cap_vanish",
	"key_bronze", "key_silver", "key_gold",
]
const VOLUME_SURFACE_KINDS := [
	"", "snow", "sand", "ice", "slippery", "very_slippery",
	"burning", "shallow_quicksand", "deep_quicksand",
]

# Keycode → tool_mode. Built at startup from TOOLS so we have a fast
# lookup in the _input handler.
var _tool_shortcuts: Dictionary = {}


func _ready() -> void:
	_build_ui()
	_new_blueprint()
	set_process_input(true)


func _build_ui() -> void:
	var split := HSplitContainer.new()
	split.anchors_preset = Control.PRESET_FULL_RECT
	split.anchor_right = 1.0
	split.anchor_bottom = 1.0
	split.split_offset = 280
	add_child(split)

	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(280, 0)
	split.add_child(left)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	left.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", 6)
	scroll.add_child(vb)

	# --- Back to menu -----------------------------------------------------
	var back_btn := Button.new()
	back_btn.text = "< Back to Menu"
	back_btn.pressed.connect(func() -> void:
		get_tree().change_scene_to_file("res://scenes/main_menu.tscn"))
	vb.add_child(back_btn)

	# --- File bar ---------------------------------------------------------
	var file_row := HBoxContainer.new()
	vb.add_child(file_row)
	for pair in [["New", "_on_new"], ["Open", "_on_open"], ["Save", "_on_save"], ["Save As", "_on_save_as"]]:
		var b := Button.new()
		b.text = pair[0]
		b.pressed.connect(Callable(self, pair[1]))
		file_row.add_child(b)
	var build_btn := Button.new()
	build_btn.text = "Build .tscn"
	build_btn.tooltip_text = "Saves current file, then runs tools/build_from_blueprint.py"
	build_btn.pressed.connect(_on_build)
	vb.add_child(build_btn)

	var play_row := HBoxContainer.new()
	vb.add_child(play_row)
	var play_btn := Button.new()
	play_btn.text = "▶ Play"
	play_btn.tooltip_text = "Save, build, then drop into this level. Uses the Temp Spawn if one was placed, otherwise the blueprint's spawn_point."
	play_btn.pressed.connect(_on_play)
	play_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	play_row.add_child(play_btn)
	var clear_spawn_btn := Button.new()
	clear_spawn_btn.text = "Clear Temp"
	clear_spawn_btn.tooltip_text = "Forget any Temp Spawn placement."
	clear_spawn_btn.pressed.connect(_on_clear_temp_spawn)
	play_row.add_child(clear_spawn_btn)

	_file_label = Label.new()
	_file_label.text = "(unsaved)"
	_file_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(_file_label)

	_status_label = Label.new()
	_status_label.text = ""
	_status_label.modulate = Color(0.7, 0.9, 0.7)
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(_status_label)

	vb.add_child(HSeparator.new())

	# --- Floor picker -----------------------------------------------------
	vb.add_child(_mklabel("Floor:"))
	var floor_row := HBoxContainer.new()
	vb.add_child(floor_row)
	_floor_option = OptionButton.new()
	_floor_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_floor_option.item_selected.connect(_on_floor_selected)
	floor_row.add_child(_floor_option)
	var add_fl := Button.new()
	add_fl.text = "+"
	add_fl.tooltip_text = "Add a new floor above the current one (default +5m)."
	add_fl.pressed.connect(_on_add_floor)
	floor_row.add_child(add_fl)
	var del_fl := Button.new()
	del_fl.text = "−"
	del_fl.tooltip_text = "Remove the current floor (only allowed when empty)."
	del_fl.pressed.connect(_on_remove_floor)
	floor_row.add_child(del_fl)

	var fh_row := HBoxContainer.new()
	vb.add_child(fh_row)
	fh_row.add_child(_mklabel("New-room height:"))
	_new_floor_height_spin = SpinBox.new()
	_new_floor_height_spin.min_value = 2.0
	_new_floor_height_spin.max_value = 20.0
	_new_floor_height_spin.step = 0.5
	_new_floor_height_spin.value = 5.0
	fh_row.add_child(_new_floor_height_spin)

	vb.add_child(HSeparator.new())

	# --- Tool palette -----------------------------------------------------
	vb.add_child(_mklabel("Tool:"))
	_tool_list = ItemList.new()
	_tool_list.custom_minimum_size = Vector2(0, 260)
	_tool_list.auto_height = false
	for t in TOOLS:
		_tool_list.add_item("%s  (%s)" % [t[1], t[2]])
		var keycode: int = OS.find_keycode_from_string(t[2])
		if keycode != 0:
			_tool_shortcuts[keycode] = t[0]
	_tool_list.item_selected.connect(_on_tool_selected)
	_tool_list.select(0)
	vb.add_child(_tool_list)

	vb.add_child(HSeparator.new())

	# --- Inspector --------------------------------------------------------
	vb.add_child(_mklabel("Selected:"))
	_inspector = VBoxContainer.new()
	vb.add_child(_inspector)

	# --- Canvas -----------------------------------------------------------
	_canvas = BlueprintCanvasScript.new()
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.editor = self
	_canvas.canvas_click.connect(_on_canvas_click)
	_canvas.canvas_drag.connect(_on_canvas_drag)
	_canvas.canvas_release.connect(_on_canvas_release)
	split.add_child(_canvas)

	# --- File dialog ------------------------------------------------------
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.current_dir = BLUEPRINTS_DIR
	_dialog.add_filter("*.json ; JSON blueprints")
	_dialog.file_selected.connect(_on_dialog_file_selected)
	_dialog.size = Vector2(820, 560)
	add_child(_dialog)


func _mklabel(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _new_blueprint() -> void:
	blueprint = {
		"_doc": "",
		"standalone_level": true,
		"spawn_point": [4, 1, 4],
		"materials": {
			"brick":  "res://assets/materials/brick_stone.tres",
			"floor":  "res://assets/materials/stone_grey.tres",
			"floor2": "res://assets/materials/wood_planks.tres",
			"wood":   "res://assets/materials/wood_dark.tres",
			"red":    "res://assets/materials/fabric_red.tres",
			"metal":  "res://assets/materials/metal_grey.tres",
			"gold":   "res://assets/materials/gold.tres",
		},
		"wall_thickness": 0.4,
		"rooms": [],
		"connectors": [],
		"locks": [],
		"keys": [],
		"blocks": [],
		"extras": [],
		"terrain_patches": [],
		"enemies": [],
		"pickups": [],
		"volumes": [],
		"warps": [],
	}
	current_file = ""
	_file_label.text = "(new, unsaved)"
	_dirty = false
	selected_kind = ""
	selected_index = -1
	current_floor_y = 0.0
	_extra_floors = [0.0]
	_undo_stack.clear()
	_refresh_floor_options()
	_rebuild_inspector()
	_canvas.queue_redraw()


# -------------------------------------------------------------------- IO

func _on_new() -> void:
	if _dirty and not _confirm_discard():
		return
	_new_blueprint()


func _on_open() -> void:
	_save_as_mode = false
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.title = "Open blueprint"
	_dialog.current_dir = BLUEPRINTS_DIR
	_dialog.popup_centered()


func _on_save() -> void:
	if current_file == "":
		_on_save_as()
		return
	_write_to(current_file)


func _on_save_as() -> void:
	_save_as_mode = true
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dialog.title = "Save blueprint as"
	_dialog.current_dir = BLUEPRINTS_DIR
	if current_file != "":
		_dialog.current_file = current_file.get_file()
	_dialog.popup_centered()


func _on_dialog_file_selected(path: String) -> void:
	if _save_as_mode:
		_write_to(path)
	else:
		_read_from(path)


func _read_from(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		_status("Failed to open: %s" % path, true)
		return
	var text := f.get_as_text()
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_status("Not a JSON object: %s" % path, true)
		return
	blueprint = parsed
	# Ensure the container arrays exist so inspector edits don't KeyError.
	for k in ["rooms", "connectors", "locks", "keys", "blocks", "extras", "terrain_patches",
			  "enemies", "pickups", "volumes", "warps"]:
		if not blueprint.has(k) or typeof(blueprint[k]) != TYPE_ARRAY:
			blueprint[k] = []
	current_file = path
	_file_label.text = path.get_file()
	_dirty = false
	selected_kind = ""
	selected_index = -1
	# Restore any empty floors the author added earlier (Load preserves
	# + ADD FLOOR presses so an empty floor doesn't vanish across sessions).
	var stored_floors: Variant = blueprint.get("_editor_floors", null)
	if stored_floors is Array:
		_extra_floors = []
		for floor_y in stored_floors:
			_extra_floors.append(float(floor_y))
	else:
		_extra_floors = [0.0]
	_undo_stack.clear()
	current_floor_y = _guess_default_floor()
	_refresh_floor_options()
	_rebuild_inspector()
	_canvas.queue_redraw()
	_status("Loaded %s" % path.get_file())


func _write_to(path: String) -> bool:
	"""Save the blueprint JSON and run the converter. Returns true iff
	the .tscn build succeeded — callers like the Play button need to
	know whether to proceed or bail."""
	var text := JSON.stringify(blueprint, "  ")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_status("Failed to write: %s" % path, true)
		return false
	f.store_string(text)
	# Belt-and-suspenders flush: explicit flush(), explicit close(),
	# drop the ref, sleep briefly, then verify by reading back. The
	# converter runs immediately after this returns and Godot's write
	# buffering previously let Python see a truncated file half the
	# time — the intermittent JSONDecodeError the author was hitting.
	f.flush()
	f.close()
	f = null
	# If the read-back doesn't match what we tried to write, loop a
	# few times with short delays before giving up. Hits when the OS
	# page cache is behind the Godot write.
	var retries: int = 0
	while retries < 5:
		var rf := FileAccess.open(path, FileAccess.READ)
		if rf != null:
			var on_disk := rf.get_as_text()
			rf.close()
			if on_disk.length() == text.length():
				break
		OS.delay_msec(30)
		retries += 1
	current_file = path
	_file_label.text = path.get_file()
	_dirty = false
	var build_ok: bool = _run_converter(path)
	return build_ok


func _run_converter(json_path: String) -> bool:
	"""Invoke build_from_blueprint.py for the given JSON. Returns true
	on success, false on failure. Writes the status line either way
	(build failures get the error-coloured flash + the script output
	tail so the author can see WHY it broke)."""
	var stem := json_path.get_file().get_basename()
	var out_path := "%s/%s.tscn" % [LEVELS_DIR, stem]
	var output: Array = []
	var code := OS.execute(PY, [BUILD_SCRIPT, json_path, out_path], output, true)
	if code == 0 and FileAccess.file_exists(out_path):
		_status("Saved %s — built %s" % [json_path.get_file(), out_path.get_file()])
		return true
	var tail: String = ""
	if output.size() > 0:
		tail = String(output[0]).substr(0, 400)
	var reason: String = "python exit %d" % code
	if code == 0:
		reason = "python exit 0 but .tscn missing (write permission?)"
	_status("BUILD FAILED (%s): %s" % [reason, tail], true)
	# Dump to the engine log too — the editor status line is easy to
	# miss, and a stack-trace-looking dump is hard to ignore.
	push_error("[blueprint_editor] build of %s failed: %s — output: %s" % [
		json_path.get_file(), reason, tail])
	return false


func _on_build() -> void:
	# Kept for users who want an explicit rebuild without editing — but
	# save-time already builds, so this is mostly a no-op confirmation.
	if current_file == "":
		_status("Save the blueprint first", true)
		return
	_write_to(current_file)


func _confirm_discard() -> bool:
	# Minimal: we just accept and move on — a full confirm dialog is
	# overkill for v1. The status line warns the user after the fact.
	return true


# ------------------------------------------------------------- Tool/state

func _on_tool_selected(idx: int) -> void:
	tool_mode = TOOLS[idx][0]
	_status("Tool: %s" % TOOLS[idx][1])


func _all_floor_ys() -> Array:
	"""Union of the Y values of every room's origin plus whatever empty
	floors the author explicitly added via the + button. Sorted so the
	dropdown reads bottom-up."""
	var ys: Dictionary = {}
	for f in _extra_floors:
		ys[float(f)] = true
	for room in blueprint.get("rooms", []):
		ys[float(room["origin"][1])] = true
	if ys.is_empty():
		ys[0.0] = true
	var arr: Array = ys.keys()
	arr.sort()
	return arr


func _refresh_floor_options() -> void:
	if _floor_option == null:
		return
	var ys := _all_floor_ys()
	_floor_option.clear()
	for i in range(ys.size()):
		_floor_option.add_item("F%d   y=%.1fm" % [i + 1, ys[i]], i)
	var idx: int = -1
	for i in range(ys.size()):
		if abs(ys[i] - current_floor_y) < 0.01:
			idx = i
			break
	if idx < 0:
		idx = 0
		current_floor_y = ys[0]
	_floor_option.select(idx)


func _on_floor_selected(idx: int) -> void:
	var ys := _all_floor_ys()
	if idx < 0 or idx >= ys.size():
		return
	current_floor_y = ys[idx]
	_canvas.queue_redraw()


func _on_add_floor() -> void:
	var ys := _all_floor_ys()
	var next_y: float = ys[-1] + 5.0
	_extra_floors.append(next_y)
	current_floor_y = next_y
	blueprint["_editor_floors"] = _extra_floors.duplicate()
	_mark_dirty()
	_refresh_floor_options()
	_canvas.queue_redraw()
	_status("Added floor at y=%.1fm" % next_y)


func _on_remove_floor() -> void:
	# Refuse if any room sits at the current floor — removing would
	# orphan geometry. The user should delete rooms first.
	for r in blueprint.get("rooms", []):
		if abs(float(r["origin"][1]) - current_floor_y) < 0.01:
			_status("Can't remove floor %.1f — rooms still use it" % current_floor_y, true)
			return
	_extra_floors.erase(current_floor_y)
	blueprint["_editor_floors"] = _extra_floors.duplicate()
	_mark_dirty()
	var ys := _all_floor_ys()
	current_floor_y = ys[0]
	_refresh_floor_options()
	_canvas.queue_redraw()
	_status("Removed floor")


func _guess_default_floor() -> float:
	var rooms: Array = blueprint.get("rooms", [])
	if rooms.is_empty():
		return 0.0
	return float(rooms[0]["origin"][1])


func _status(msg: String, error: bool = false) -> void:
	_status_label.text = msg
	_status_label.modulate = Color(1, 0.55, 0.55) if error else Color(0.7, 0.95, 0.7)


# ----------------------------------------------------------- Canvas events

func _on_canvas_click(world: Vector2, button: int, shift: bool, ctrl: bool) -> void:
	# Sculpt takes priority over everything: if sculpt mode is on and a
	# terrain patch is selected, both mouse buttons modify heights
	# (left/right = raise/lower; shift flips). Selection and creation
	# are suspended until the user disables sculpt mode.
	if _paint_active and selected_kind == "terrain_patches":
		_begin_action()
		var erase: bool = shift or button == MOUSE_BUTTON_RIGHT
		_paint_at(world, erase)
		_canvas.queue_redraw()
		return
	if _sculpt_active and selected_kind == "terrain_patches":
		# Ctrl-click in flatten mode is an eyedropper: don't push undo,
		# just copy the clicked cell's height into _flatten_target.
		if _sculpt_mode == "flatten" and ctrl:
			_eyedrop_height(world)
			_rebuild_inspector()
			return
		_begin_action()
		var lower: bool = shift or button == MOUSE_BUTTON_RIGHT
		_sculpt_at(world, lower)
		_canvas.queue_redraw()
		return
	if button == MOUSE_BUTTON_RIGHT:
		# Right-click always selects, no matter the current tool — handy
		# for grabbing an item without switching tools.
		_try_select(world)
		return
	match tool_mode:
		"select":
			_try_select(world)
			if selected_kind != "":
				_drag_moving = true
		"room":
			pass  # handled on release using drag rect
		"terrain":
			pass  # handled on release using drag rect
		"door":    _begin_action(); _add_opening(world, "door")
		"window":  _begin_action(); _add_opening(world, "window")
		"stair":   _begin_action(); _add_extra_stair(world)
		"spiral_stair": _begin_action(); _add_extra_spiral(world)
		"elevator": _begin_action(); _add_extra_elevator(world)
		"pillar":  _begin_action(); _add_extra_pillar(world)
		"platform": _begin_action(); _add_extra_platform(world)
		"block":   _begin_action(); _add_block(world)
		"key":     _begin_action(); _add_key(world)
		"lock":    _begin_action(); _add_lock(world)
		"enemy":   _begin_action(); _add_enemy(world)
		"pickup":  _begin_action(); _add_pickup(world)
		"water":   pass  # drag-create
		"lava":    pass  # drag-create
		"warp":    _begin_action(); _add_warp(world)
		"spawn":   _begin_action(); _set_spawn(world)
		"temp_spawn": _set_temp_spawn(world)
	_canvas.queue_redraw()


func _on_canvas_drag(world: Vector2, delta: Vector2) -> void:
	if _paint_active and selected_kind == "terrain_patches":
		_paint_at(world, Input.is_key_pressed(KEY_SHIFT))
		_canvas.queue_redraw()
		return
	if _sculpt_active and selected_kind == "terrain_patches":
		# _begin_action already snapshotted on the initial click; drag
		# continues the same stroke.
		_sculpt_at(world, Input.is_key_pressed(KEY_SHIFT))
		_canvas.queue_redraw()
		return
	if tool_mode == "select" and _drag_moving and selected_kind != "":
		_begin_action()  # coalesces the whole drag into one undo step
		_move_selected(delta)
		_canvas.queue_redraw()
	elif tool_mode == "room" or tool_mode == "terrain" or tool_mode == "water" or tool_mode == "lava":
		_canvas.queue_redraw()  # preview rect


func _on_canvas_release(world: Vector2, button: int) -> void:
	if _sculpt_active:
		_drag_moving = false
		_end_action()
		return
	if tool_mode == "room" and button == MOUSE_BUTTON_LEFT:
		_begin_action()
		_finalize_room_drag(world)
	elif tool_mode == "terrain" and button == MOUSE_BUTTON_LEFT:
		_begin_action()
		_finalize_terrain_drag(world)
	elif (tool_mode == "water" or tool_mode == "lava") and button == MOUSE_BUTTON_LEFT:
		_begin_action()
		_finalize_volume_drag(world, tool_mode)
	_drag_moving = false
	_end_action()
	_canvas.queue_redraw()


# -------------------------------------------------------- Hit testing

func _try_select(world: Vector2) -> void:
	# Openings (doors/windows) first — they sit on top of rooms visually
	# so it's intuitive to hit the wall marker rather than the room.
	var op_hit := _hit_test_opening(world)
	if not op_hit.is_empty():
		selected_kind = "opening"
		selected_index = -1
		_sel_op_room = int(op_hit["room_idx"])
		_sel_op_side = String(op_hit["side"])
		_sel_op_idx = int(op_hit["op_idx"])
		_rebuild_inspector()
		return
	# Iterate in reverse for each kind so the topmost drawn object wins
	# in overlap cases. Also respect HIT_ORDER so keys/blocks take
	# priority over rooms underneath them.
	for kind in HIT_ORDER:
		var arr: Array = blueprint.get(kind, [])
		for i in range(arr.size() - 1, -1, -1):
			if _hit_test(kind, arr[i], world):
				selected_kind = kind
				selected_index = i
				_sel_op_room = -1
				_rebuild_inspector()
				return
	# Spawn hit test.
	if blueprint.has("spawn_point"):
		var sp: Array = blueprint["spawn_point"]
		var sp_pos := Vector2(float(sp[0]), float(sp[2]))
		if sp_pos.distance_to(world) < 0.7:
			selected_kind = "spawn"
			selected_index = 0
			_sel_op_room = -1
			_rebuild_inspector()
			return
	selected_kind = ""
	selected_index = -1
	_sel_op_room = -1
	_rebuild_inspector()


func _hit_test_opening(world: Vector2) -> Dictionary:
	"""Return {room_idx, side, op_idx} of the door/window whose wall
	segment passes closest to `world` (within 0.5m), or {} if none."""
	var rooms: Array = blueprint.get("rooms", [])
	var best: Dictionary = {}
	var best_d: float = 0.5
	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var oy: float = float(room["origin"][1])
		var sy: float = float(room["size"][1])
		if current_floor_y < oy or current_floor_y >= oy + sy:
			continue
		var ox: float = float(room["origin"][0])
		var oz: float = float(room["origin"][2])
		var sx: float = float(room["size"][0])
		var sz: float = float(room["size"][2])
		var walls: Dictionary = room.get("walls", {})
		for side in ["north", "south", "east", "west"]:
			if not walls.has(side):
				continue
			var openings: Array = walls[side].get("openings", [])
			for o in range(openings.size()):
				var op: Dictionary = openings[o]
				var lx: float = float(op.get("x", 0.0))
				var lw: float = float(op.get("width", 0.0))
				var a := Vector2.ZERO
				var b := Vector2.ZERO
				match side:
					"south":
						a = Vector2(ox + lx, oz); b = Vector2(ox + lx + lw, oz)
					"north":
						a = Vector2(ox + lx, oz + sz); b = Vector2(ox + lx + lw, oz + sz)
					"west":
						a = Vector2(ox, oz + lx); b = Vector2(ox, oz + lx + lw)
					"east":
						a = Vector2(ox + sx, oz + lx); b = Vector2(ox + sx, oz + lx + lw)
				var d: float = _distance_to_segment(world, a, b)
				if d < best_d:
					best_d = d
					best = {"room_idx": i, "side": side, "op_idx": o}
	return best


func _distance_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clamp((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _hit_test(kind: String, item: Dictionary, world: Vector2) -> bool:
	match kind:
		"terrain_patches":
			var o: Array = item.get("origin", [0, 0, 0])
			var sx: float = float(item.get("size_x", 10))
			var sz: float = float(item.get("size_z", 10))
			var r := Rect2(float(o[0]), float(o[2]), sx, sz)
			return r.has_point(world)
		"enemies", "pickups":
			var p: Array = item.get("pos", [0, 0, 0])
			return Vector2(float(p[0]), float(p[2])).distance_to(world) < 0.6
		"warps":
			var p2: Array = item.get("pos", [0, 0, 0])
			var sz_w: Array = item.get("size", [2.5, 3, 0.4])
			var rect := Rect2(float(p2[0]) - float(sz_w[0]) * 0.5,
							   float(p2[2]) - float(sz_w[2]) * 0.5,
							   float(sz_w[0]), float(sz_w[2]))
			return rect.has_point(world)
		"volumes":
			var o2: Array = item.get("origin", [0, 0, 0])
			var sz_v: Array = item.get("size", [4, 1, 4])
			var rv := Rect2(float(o2[0]), float(o2[2]), float(sz_v[0]), float(sz_v[2]))
			return rv.has_point(world)
		"rooms":
			var o: Array = item["origin"]
			var s: Array = item["size"]
			var oy: float = float(o[1])
			var sy: float = float(s[1])
			if current_floor_y < oy or current_floor_y >= oy + sy:
				return false
			var rect := Rect2(float(o[0]), float(o[2]), float(s[0]), float(s[2]))
			return rect.has_point(world)
		"extras":
			return _extra_hit(item, world)
		"blocks":
			var pos: Array = item.get("pos", [0, 0, 0])
			var size: Array = item.get("size", [1, 1, 1])
			var r := Rect2(float(pos[0]), float(pos[2]), float(size[0]), float(size[2]))
			return r.has_point(world)
		"keys":
			var p: Array = item.get("pos", [0, 0, 0])
			return Vector2(float(p[0]), float(p[2])).distance_to(world) < 0.5
		"locks":
			var p2: Array = item.get("pos", [0, 0, 0])
			var w: float = float(item.get("width", 2))
			var d: float = float(item.get("depth", 0.5))
			var r2 := Rect2(float(p2[0]), float(p2[2]), w, d)
			return r2.has_point(world)
	return false


func _extra_hit(item: Dictionary, world: Vector2) -> bool:
	var t: String = item.get("type", "")
	var pos: Array = item.get("pos", [0, 0, 0])
	var px: float = float(pos[0])
	var pz: float = float(pos[2])
	match t:
		"pillar":
			var r: float = float(item.get("radius", 0.3))
			return Vector2(px, pz).distance_to(world) < max(r, 0.3)
		"spiral_stair":
			var rr: float = float(item.get("radius", 1.6))
			return Vector2(px, pz).distance_to(world) < rr
		"elevator":
			var w: float = float(item.get("width", 2))
			var d: float = float(item.get("depth", 2))
			var r2 := Rect2(px - w * 0.5, pz - d * 0.5, w, d)
			return r2.has_point(world)
		"stair":
			var steps: int = int(item.get("steps", 1))
			var run_m: float = float(item.get("run", 0.5))
			var width: float = float(item.get("width", 1.0))
			var length: float = steps * run_m
			var dir: String = item.get("direction", "+x")
			var r3 := Rect2(0, 0, 0, 0)
			match dir:
				"+x": r3 = Rect2(px, pz, length, width)
				"-x": r3 = Rect2(px - length, pz, length, width)
				"+z": r3 = Rect2(px, pz, width, length)
				"-z": r3 = Rect2(px, pz - length, width, length)
			return r3.has_point(world)
		"platform":
			var size: Array = item.get("size", [1, 0.4, 1])
			var r4 := Rect2(px, pz, float(size[0]), float(size[2]))
			return r4.has_point(world)
	return false


# ----------------------------------------------------------- Mutations

func _mark_dirty() -> void:
	_dirty = true


# World-coordinate snap used by placement, drag-create, and select-drag.
# Default step is 0.5m; holding Ctrl tightens to 1m so authors can lay
# out rooms on clean integer grid lines. Zoom level doesn't matter —
# we always snap in world units.
func _snap_v(v: float) -> float:
	var step: float = 1.0 if Input.is_key_pressed(KEY_CTRL) else 0.5
	return snappedf(v, step)


func _push_undo() -> void:
	"""Snapshot the current blueprint for Ctrl+Z. Keeps `_extra_floors`
	and temp-spawn separate — undo only rewinds blueprint content."""
	_undo_stack.append(blueprint.duplicate(true))
	if _undo_stack.size() > UNDO_MAX:
		_undo_stack.pop_front()


func _begin_action() -> void:
	"""Call before a mutating user action. Coalesces a single drag or
	sculpt stroke into one undo step instead of one per frame."""
	if _action_pushed_undo:
		return
	_push_undo()
	_action_pushed_undo = true


func _end_action() -> void:
	"""Call on mouse release to let the next action push its own
	undo snapshot."""
	_action_pushed_undo = false


func _undo() -> void:
	if _undo_stack.is_empty():
		_status("Nothing to undo")
		return
	blueprint = _undo_stack.pop_back()
	# The selection path may no longer be valid after the restore.
	selected_kind = ""
	selected_index = -1
	_sel_op_room = -1
	_sel_op_side = ""
	_sel_op_idx = -1
	_mark_dirty()
	_rebuild_inspector()
	_refresh_floor_options()
	_canvas.queue_redraw()
	_status("Undid one step (%d remaining)" % _undo_stack.size())


func _ensure_array(key: String) -> Array:
	if not blueprint.has(key) or typeof(blueprint[key]) != TYPE_ARRAY:
		blueprint[key] = []
	return blueprint[key]


func _next_name(kind: String, prefix: String) -> String:
	var arr := _ensure_array(kind)
	var taken: Dictionary = {}
	for item in arr:
		if item is Dictionary and item.has("name"):
			taken[item["name"]] = true
	var i: int = 1
	while taken.has("%s%d" % [prefix, i]):
		i += 1
	return "%s%d" % [prefix, i]


func _finalize_terrain_drag(end_world: Vector2) -> void:
	var start: Vector2 = _canvas._drag_start_world
	var a := Vector2(min(start.x, end_world.x), min(start.y, end_world.y))
	var b := Vector2(max(start.x, end_world.x), max(start.y, end_world.y))
	var size := b - a
	if size.x < 4.0 or size.y < 4.0:
		return  # too small to bother — terrain needs room to sculpt
	# 128×128 vertices by default so outdoor levels get genuinely
	# detailed shorelines and lava edges without touching the
	# Resolution slider. ~16k verts / 32k tris per patch — large but
	# still cheap on desktop GPUs, and the user can dial down for
	# smaller themed patches.
	var res: int = 128
	var heights: Array = []
	heights.resize(res * res)
	for i in range(res * res):
		heights[i] = 0.0
	# surface_grid is (res-1)² strings, default all "" (un-painted).
	# The runtime reads this to split collision into kind-specific
	# sub-bodies so painted lava / water / ice behave correctly.
	var surface_grid: Array = []
	var cell_count: int = (res - 1) * (res - 1)
	surface_grid.resize(cell_count)
	for si in range(cell_count):
		surface_grid[si] = ""
	var patch := {
		"name": _next_name("terrain_patches", "Terrain"),
		"origin": [_snap_v(a.x), current_floor_y, _snap_v(a.y)],
		"size_x": _snap_v(size.x),
		"size_z": _snap_v(size.y),
		"resolution": res,
		"heights": heights,
		"surface_grid": surface_grid,
		"material": "",
	}
	_ensure_array("terrain_patches").append(patch)
	selected_kind = "terrain_patches"
	selected_index = blueprint["terrain_patches"].size() - 1
	_mark_dirty()
	_rebuild_inspector()


func _finalize_room_drag(end_world: Vector2) -> void:
	# Use canvas's internal drag start via a trick: we draw from
	# _drag_start_world on the canvas. The canvas also exposes the
	# starting world position on the click event, so we captured it
	# in _on_canvas_click — but we didn't save it. Instead, ask the
	# canvas directly (it stored _drag_start_world).
	var start: Vector2 = _canvas._drag_start_world
	var a := Vector2(min(start.x, end_world.x), min(start.y, end_world.y))
	var b := Vector2(max(start.x, end_world.x), max(start.y, end_world.y))
	var size := b - a
	if size.x < 1.5 or size.y < 1.5:
		return  # too small — ignore so accidental clicks don't spawn rooms
	# Room height defaults to the distance to the next floor above —
	# that way stacking rooms on consecutive floors produces a
	# continuous shell with no gap between the upper room's ceiling
	# and the next floor's floor. Falls back to the spin-box value
	# when there's no higher floor yet.
	var height: float = _new_floor_height_spin.value
	var ys := _all_floor_ys()
	for fy in ys:
		if float(fy) > current_floor_y + 0.01:
			height = float(fy) - current_floor_y
			break
	var room := {
		"name": _next_name("rooms", "Room"),
		"origin": [_snap_v(a.x), current_floor_y, _snap_v(a.y)],
		"size":   [_snap_v(size.x), height, _snap_v(size.y)],
		"material": "brick",
		"floor_material": "floor",
		"walls": {"north": {"openings": []}, "south": {"openings": []}, "east": {"openings": []}, "west": {"openings": []}},
	}
	_ensure_array("rooms").append(room)
	selected_kind = "rooms"
	selected_index = blueprint["rooms"].size() - 1
	_mark_dirty()
	_rebuild_inspector()


func _add_opening(world: Vector2, kind: String) -> void:
	# Find the room on the current floor closest to the click and the
	# wall edge nearest to it. Clamp opening x so it stays inside the
	# wall; pick sensible defaults for width/height.
	var room_i := _room_under_or_nearest(world)
	if room_i < 0:
		_status("Click inside or next to a room first", true)
		return
	var room: Dictionary = blueprint["rooms"][room_i]
	var o: Array = room["origin"]
	var s: Array = room["size"]
	var ox: float = float(o[0])
	var oz: float = float(o[2])
	var sx: float = float(s[0])
	var sz: float = float(s[2])
	# Distance to each edge.
	var d_south: float = abs(world.y - oz)
	var d_north: float = abs(world.y - (oz + sz))
	var d_west:  float = abs(world.x - ox)
	var d_east:  float = abs(world.x - (ox + sx))
	var best: String = "south"
	var best_d: float = d_south
	if d_north < best_d: best = "north"; best_d = d_north
	if d_west  < best_d: best = "west";  best_d = d_west
	if d_east  < best_d: best = "east";  best_d = d_east
	var width: float = 3.0 if kind == "door" else 1.5
	var height: float = 4.0 if kind == "door" else 2.0
	var sill: float = 0.0 if kind == "door" else 1.5
	var x_along: float = 0.0
	if best == "south" or best == "north":
		x_along = clamp(world.x - ox - width * 0.5, 0.0, max(sx - width, 0.0))
	else:
		x_along = clamp(world.y - oz - width * 0.5, 0.0, max(sz - width, 0.0))
	var walls: Dictionary = room.get("walls", {})
	if not walls.has(best):
		walls[best] = {"openings": []}
	var opening := {
		"type": kind,
		"x": snappedf(x_along, 0.1),
		"width": width,
		"height": height,
	}
	if kind == "window":
		opening["sill"] = sill
	walls[best]["openings"].append(opening)
	room["walls"] = walls
	_mark_dirty()
	_status("Added %s on %s wall of %s" % [kind, best, room.get("name", "room")])


func _room_under_or_nearest(world: Vector2) -> int:
	var rooms: Array = blueprint.get("rooms", [])
	var best: int = -1
	var best_d: float = 1e9
	for i in range(rooms.size()):
		var room: Dictionary = rooms[i]
		var oy: float = float(room["origin"][1])
		var sy: float = float(room["size"][1])
		if current_floor_y < oy or current_floor_y >= oy + sy:
			continue
		var o: Array = room["origin"]
		var s: Array = room["size"]
		var rect := Rect2(float(o[0]), float(o[2]), float(s[0]), float(s[2]))
		if rect.has_point(world):
			return i
		# Nearest edge distance.
		var cx: float = clamp(world.x, rect.position.x, rect.end.x)
		var cz: float = clamp(world.y, rect.position.y, rect.end.y)
		var d: float = Vector2(cx, cz).distance_to(world)
		if d < best_d:
			best_d = d
			best = i
	return best


func _add_extra_stair(world: Vector2) -> void:
	var item := {
		"type": "stair",
		"name": _next_name("extras", "Stair"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"steps": 12,
		"rise": 0.42,
		"run": 0.55,
		"width": 3.0,
		"direction": "+x",
		"material": "floor",
	}
	_ensure_array("extras").append(item)
	_select_last("extras")
	_mark_dirty()


func _add_extra_spiral(world: Vector2) -> void:
	var item := {
		"type": "spiral_stair",
		"name": _next_name("extras", "Spiral"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"steps": 17,
		"rise": 0.3,
		"radius": 2.0,
		"width": 1.6,
		"depth": 0.6,
		"angle": 0.42,
		"material": "floor",
	}
	_ensure_array("extras").append(item)
	_select_last("extras")
	_mark_dirty()


func _add_extra_elevator(world: Vector2) -> void:
	var item := {
		"type": "elevator",
		"name": _next_name("extras", "Elevator"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"low_y": current_floor_y + 0.2,
		"high_y": current_floor_y + 5.2,
		"width": 3.0,
		"depth": 3.0,
		"thickness": 0.4,
		"speed": 2.8,
		"mode": "call",
		"material": "metal",
	}
	_ensure_array("extras").append(item)
	_select_last("extras")
	_mark_dirty()


func _add_extra_pillar(world: Vector2) -> void:
	var item := {
		"type": "pillar",
		"name": _next_name("extras", "Pillar"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"radius": 0.3,
		"height": 5.0,
		"material": "wood",
	}
	_ensure_array("extras").append(item)
	_select_last("extras")
	_mark_dirty()


func _add_extra_platform(world: Vector2) -> void:
	var item := {
		"type": "platform",
		"name": _next_name("extras", "Platform"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"size": [4.0, 0.4, 2.0],
		"material": "gold",
	}
	_ensure_array("extras").append(item)
	_select_last("extras")
	_mark_dirty()


func _add_block(world: Vector2) -> void:
	var item := {
		"name": _next_name("blocks", "Block"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"size": [1.4, 1.4, 1.4],
		"material": "wood",
		"breakable": true,
		"reward": "coin_red",
	}
	_ensure_array("blocks").append(item)
	_select_last("blocks")
	_mark_dirty()


func _add_key(world: Vector2) -> void:
	var item := {
		"name": _next_name("keys", "Key"),
		"pos": [_snap_v(world.x), current_floor_y + 1.2, _snap_v(world.y)],
		"color": "silver",
	}
	_ensure_array("keys").append(item)
	_select_last("keys")
	_mark_dirty()


func _add_lock(world: Vector2) -> void:
	var item := {
		"type": "barrier",
		"name": _next_name("locks", "Lock"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"width": 2.5,
		"height": 4.0,
		"depth": 0.5,
		"key": "silver",
		"material": "silver",
	}
	_ensure_array("locks").append(item)
	_select_last("locks")
	_mark_dirty()


func _add_enemy(world: Vector2) -> void:
	var item := {
		"name": _next_name("enemies", "Enemy"),
		"bhv": ENEMY_BHVS[0],
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"patrol_radius": 3.0,
	}
	_ensure_array("enemies").append(item)
	_select_last("enemies")
	_mark_dirty()


func _add_pickup(world: Vector2) -> void:
	var item := {
		"name": _next_name("pickups", "Pickup"),
		"kind": "coin_yellow",
		"pos": [_snap_v(world.x), current_floor_y + 1.0, _snap_v(world.y)],
	}
	_ensure_array("pickups").append(item)
	_select_last("pickups")
	_mark_dirty()


func _add_warp(world: Vector2) -> void:
	var item := {
		"name": _next_name("warps", "Warp"),
		"pos": [_snap_v(world.x), current_floor_y, _snap_v(world.y)],
		"size": [2.5, 3.0, 0.4],
		"target_level": "",
	}
	_ensure_array("warps").append(item)
	_select_last("warps")
	_mark_dirty()


func _finalize_volume_drag(end_world: Vector2, kind: String) -> void:
	var start: Vector2 = _canvas._drag_start_world
	var a := Vector2(min(start.x, end_world.x), min(start.y, end_world.y))
	var b := Vector2(max(start.x, end_world.x), max(start.y, end_world.y))
	var size := b - a
	if size.x < 1.0 or size.y < 1.0:
		return
	# Water: volume sits BELOW the current floor so the top surface
	# is AT the floor y, letting authors sculpt lakes flush. Lava: top
	# is a thin slab AT floor y (dangerous when you step on it).
	var y_origin: float = current_floor_y - 2.0 if kind == "water" else current_floor_y
	var y_size: float = 2.0 if kind == "water" else 0.3
	var item := {
		"name": _next_name("volumes", kind.capitalize()),
		"kind": kind,
		"origin": [_snap_v(a.x), y_origin, _snap_v(a.y)],
		"size": [_snap_v(size.x), y_size, _snap_v(size.y)],
	}
	_ensure_array("volumes").append(item)
	selected_kind = "volumes"
	selected_index = blueprint["volumes"].size() - 1
	_mark_dirty()
	_rebuild_inspector()


func _set_spawn(world: Vector2) -> void:
	blueprint["spawn_point"] = [_snap_v(world.x), current_floor_y + 1.0, _snap_v(world.y)]
	selected_kind = "spawn"
	selected_index = 0
	_mark_dirty()
	_rebuild_inspector()


func _set_temp_spawn(world: Vector2) -> void:
	# Session-only: doesn't touch blueprint["spawn_point"], doesn't
	# set _dirty. When the user hits Play, this position is passed
	# through to main.gd as a one-shot override for Mario's starting
	# position, so you can iterate from anywhere in the level without
	# moving the permanent spawn.
	_temp_spawn = [_snap_v(world.x), current_floor_y + 1.0, _snap_v(world.y)]
	_status("Temp spawn at (%.1f, %.1f, %.1f) — Play will drop you there" % [
		_temp_spawn[0], _temp_spawn[1], _temp_spawn[2]])
	_canvas.queue_redraw()


func _on_clear_temp_spawn() -> void:
	if _temp_spawn.is_empty():
		_status("No temp spawn set")
		return
	_temp_spawn = []
	_status("Temp spawn cleared — Play will use blueprint spawn_point")
	_canvas.queue_redraw()


func _on_play() -> void:
	if current_file == "":
		_status("Save the blueprint first so Play has a level to load", true)
		return
	# _write_to runs the converter. Abort Play when the build failed —
	# otherwise we'd swap scenes into a missing or stale .tscn and the
	# user would see the generic level-manager "missing level" error
	# with no hint of the build failure.
	if not _write_to(current_file):
		return
	var stem: String = current_file.get_file().get_basename()
	LevelSelectScript.pending_level = stem
	LevelSelectScript.pending_temp_spawn = _temp_spawn.duplicate() if _temp_spawn.size() == 3 else []
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _select_last(kind: String) -> void:
	selected_kind = kind
	selected_index = blueprint[kind].size() - 1
	_rebuild_inspector()


func _move_selected(delta_world: Vector2) -> void:
	if selected_kind == "spawn":
		var sp: Array = blueprint.get("spawn_point", [0, 1, 0])
		sp[0] = float(sp[0]) + delta_world.x
		sp[2] = float(sp[2]) + delta_world.y
		blueprint["spawn_point"] = sp
		_mark_dirty()
		_rebuild_inspector()
		return
	if selected_kind == "opening":
		_move_selected_opening(delta_world)
		return
	if selected_index < 0:
		return
	var arr: Array = blueprint.get(selected_kind, [])
	if selected_index >= arr.size():
		return
	var item: Dictionary = arr[selected_index]
	# Rooms / terrain_patches / volumes use "origin"; everything else
	# uses "pos". One key pick instead of per-kind branches.
	var key: String = "origin" if (
		selected_kind == "rooms"
		or selected_kind == "terrain_patches"
		or selected_kind == "volumes"
	) else "pos"
	if not item.has(key):
		return
	var p: Array = item[key]
	p[0] = float(p[0]) + delta_world.x
	p[2] = float(p[2]) + delta_world.y
	item[key] = p
	_mark_dirty()
	_rebuild_inspector()


func _move_selected_opening(delta_world: Vector2) -> void:
	var op: Dictionary = _current_opening()
	if op.is_empty():
		return
	var room: Dictionary = blueprint["rooms"][_sel_op_room]
	var sx: float = float(room["size"][0])
	var sz: float = float(room["size"][2])
	# The opening slides along the wall's length axis: x for N/S walls,
	# z for E/W walls. Clamp so the opening stays inside the wall.
	var delta_along: float = delta_world.x if (_sel_op_side == "north" or _sel_op_side == "south") else delta_world.y
	var wall_len: float = sx if (_sel_op_side == "north" or _sel_op_side == "south") else sz
	var lx: float = float(op.get("x", 0.0)) + delta_along
	var lw: float = float(op.get("width", 1.0))
	op["x"] = clamp(lx, 0.0, max(wall_len - lw, 0.0))
	_mark_dirty()
	_rebuild_inspector()


func _current_opening() -> Dictionary:
	if _sel_op_room < 0 or _sel_op_idx < 0:
		return {}
	var rooms: Array = blueprint.get("rooms", [])
	if _sel_op_room >= rooms.size():
		return {}
	var walls: Dictionary = rooms[_sel_op_room].get("walls", {})
	if not walls.has(_sel_op_side):
		return {}
	var ops: Array = walls[_sel_op_side].get("openings", [])
	if _sel_op_idx >= ops.size():
		return {}
	return ops[_sel_op_idx]


func _paint_at(world: Vector2, erase: bool) -> void:
	if selected_kind != "terrain_patches" or selected_index < 0:
		return
	var patch: Dictionary = blueprint["terrain_patches"][selected_index]
	var origin: Array = patch["origin"]
	var sx: float = float(patch.get("size_x", 10))
	var sz: float = float(patch.get("size_z", 10))
	var res: int = int(patch.get("resolution", 8))
	if res < 2 or sx <= 0 or sz <= 0:
		return
	var cell_count: int = (res - 1) * (res - 1)
	var grid: Array = patch.get("surface_grid", [])
	if grid.size() != cell_count:
		grid = []
		grid.resize(cell_count)
		for i in range(cell_count):
			grid[i] = ""
		patch["surface_grid"] = grid
	# World → patch-local → cell index. Cells are (res-1)×(res-1);
	# vertex spacing is size/(res-1) so cell i,j spans local
	# [i*cs .. (i+1)*cs].
	var lx: float = world.x - float(origin[0])
	var lz: float = world.y - float(origin[2])
	if lx < 0 or lz < 0 or lx > sx or lz > sz:
		return
	var cs_x: float = sx / float(res - 1)
	var cs_z: float = sz / float(res - 1)
	var ci: int = clamp(int(floor(lx / cs_x)), 0, res - 2)
	var cj: int = clamp(int(floor(lz / cs_z)), 0, res - 2)
	var value: String = "" if erase else _paint_kind
	var r: int = max(_paint_radius, 0)
	for i in range(max(ci - r, 0), min(ci + r + 1, res - 1)):
		for j in range(max(cj - r, 0), min(cj + r + 1, res - 1)):
			# Circular brush by cell distance.
			var d: float = Vector2(float(i) - float(ci), float(j) - float(cj)).length()
			if d > float(r) + 0.01:
				continue
			grid[i * (res - 1) + j] = value
	patch["surface_grid"] = grid
	_mark_dirty()


func _sculpt_at(world: Vector2, lower: bool) -> void:
	if selected_kind != "terrain_patches" or selected_index < 0:
		return
	var patch: Dictionary = blueprint["terrain_patches"][selected_index]
	var origin: Array = patch["origin"]
	var sx: float = float(patch.get("size_x", 10))
	var sz: float = float(patch.get("size_z", 10))
	var res: int = int(patch.get("resolution", 8))
	if res < 2 or sx <= 0 or sz <= 0:
		return
	var heights: Array = patch.get("heights", [])
	if heights.size() != res * res:
		return
	var lx: float = world.x - float(origin[0])
	var lz: float = world.y - float(origin[2])
	if lx < 0 or lz < 0 or lx > sx or lz > sz:
		return
	var fi: float = (lx / sx) * float(res - 1)
	var fj: float = (lz / sz) * float(res - 1)
	var ci: int = int(round(fi))
	var cj: int = int(round(fj))
	var r: int = max(_sculpt_radius, 0)
	var affected: Array = []
	for i in range(max(ci - r, 0), min(ci + r + 1, res)):
		for j in range(max(cj - r, 0), min(cj + r + 1, res)):
			var d: float = Vector2(float(i) - fi, float(j) - fj).length()
			if d > float(r) + 0.5:
				continue
			var weight: float = 1.0
			if not _hard_brush:
				weight = 1.0 - clamp(d / (float(r) + 0.5), 0.0, 1.0)
			affected.append([i * res + j, weight])
	match _sculpt_mode:
		"raise":
			var strength: float = -_sculpt_strength if lower else _sculpt_strength
			for entry in affected:
				heights[entry[0]] = float(heights[entry[0]]) + strength * float(entry[1])
		"flatten":
			# Soft brush lerps toward target; hard brush snaps exactly.
			for entry in affected:
				var idx: int = entry[0]
				var w: float = float(entry[1])
				if _hard_brush:
					heights[idx] = _flatten_target
				else:
					heights[idx] = lerp(float(heights[idx]), _flatten_target, w)
		"average":
			var total: float = 0.0
			for entry in affected:
				total += float(heights[entry[0]])
			var avg: float = total / float(max(affected.size(), 1))
			for entry in affected:
				var idx2: int = entry[0]
				var w2: float = float(entry[1])
				if _hard_brush:
					heights[idx2] = avg
				else:
					heights[idx2] = lerp(float(heights[idx2]), avg, w2)
	patch["heights"] = heights
	_mark_dirty()


func _eyedrop_height(world: Vector2) -> void:
	# Ctrl-click on a terrain cell in flatten mode captures that cell's
	# height into _flatten_target so subsequent clicks flatten the
	# brush to match. No undo push; eyedrop is a state-only action.
	if selected_kind != "terrain_patches" or selected_index < 0:
		return
	var patch: Dictionary = blueprint["terrain_patches"][selected_index]
	var origin: Array = patch["origin"]
	var sx: float = float(patch.get("size_x", 10))
	var sz: float = float(patch.get("size_z", 10))
	var res: int = int(patch.get("resolution", 8))
	var heights: Array = patch.get("heights", [])
	if res < 2 or heights.size() != res * res:
		return
	var lx: float = world.x - float(origin[0])
	var lz: float = world.y - float(origin[2])
	if lx < 0 or lz < 0 or lx > sx or lz > sz:
		return
	var ci: int = clamp(int(round((lx / sx) * float(res - 1))), 0, res - 1)
	var cj: int = clamp(int(round((lz / sz) * float(res - 1))), 0, res - 1)
	_flatten_target = float(heights[ci * res + cj])
	_status("Flatten target = %.2fm (picked from grid cell)" % _flatten_target)


# ------------------------------------------------------------ Inspector

func _rebuild_inspector() -> void:
	for c in _inspector.get_children():
		c.queue_free()
	if selected_kind == "" or (selected_kind != "opening" and selected_kind != "spawn" and selected_index < 0):
		_inspector_level_properties()
		return
	match selected_kind:
		"rooms":            _inspector_room()
		"extras":           _inspector_extra()
		"blocks":           _inspector_block()
		"keys":             _inspector_key()
		"locks":            _inspector_lock()
		"terrain_patches":  _inspector_terrain()
		"opening":          _inspector_opening()
		"enemies":          _inspector_enemy()
		"pickups":          _inspector_pickup()
		"volumes":          _inspector_volume()
		"warps":            _inspector_warp()
		"spawn":            _inspector_spawn()


func _inspector_header(title: String) -> void:
	var l := Label.new()
	l.text = title
	l.add_theme_color_override("font_color", Color(1, 0.9, 0.55))
	_inspector.add_child(l)
	var del := Button.new()
	del.text = "Delete"
	del.pressed.connect(_delete_selected)
	_inspector.add_child(del)


func _delete_selected() -> void:
	if selected_kind == "spawn":
		_status("Can't delete spawn point — drag it instead", true)
		return
	_begin_action()
	if selected_kind == "opening":
		var op: Dictionary = _current_opening()
		if op.is_empty():
			return
		blueprint["rooms"][_sel_op_room]["walls"][_sel_op_side]["openings"].remove_at(_sel_op_idx)
		selected_kind = ""
		_sel_op_room = -1
		_sel_op_side = ""
		_sel_op_idx = -1
	else:
		var arr: Array = blueprint.get(selected_kind, [])
		if selected_index < 0 or selected_index >= arr.size():
			return
		arr.remove_at(selected_index)
		selected_kind = ""
		selected_index = -1
	_mark_dirty()
	_rebuild_inspector()
	_canvas.queue_redraw()
	_end_action()


func _mkrow(label: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(90, 0)
	row.add_child(l)
	_inspector.add_child(row)
	return row


func _mkspin(row: HBoxContainer, value: float, mn: float, mx: float, step: float, on_change: Callable) -> SpinBox:
	var sb := SpinBox.new()
	sb.min_value = mn
	sb.max_value = mx
	sb.step = step
	sb.value = value
	sb.allow_greater = true
	sb.allow_lesser = true
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sb.value_changed.connect(on_change)
	row.add_child(sb)
	return sb


func _mkoption(row: HBoxContainer, options: Array, current: String, on_change: Callable) -> OptionButton:
	var ob := OptionButton.new()
	for i in range(options.size()):
		ob.add_item(String(options[i]), i)
	var idx := options.find(current)
	if idx >= 0:
		ob.select(idx)
	ob.item_selected.connect(func(i: int) -> void: on_change.call(options[i]))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(ob)
	return ob


func _mkcheck(row: HBoxContainer, value: bool, on_change: Callable) -> CheckBox:
	var cb := CheckBox.new()
	cb.button_pressed = value
	cb.toggled.connect(on_change)
	row.add_child(cb)
	return cb


func _mkcolor_row(item: Dictionary, key: String, default_c: Color) -> void:
	var stored: Variant = item.get(key)
	var c := default_c
	if stored is Array and stored.size() >= 3:
		c = Color(float(stored[0]), float(stored[1]), float(stored[2]))
	var row := HBoxContainer.new()
	var btn := ColorPickerButton.new()
	btn.color = c
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.custom_minimum_size = Vector2(0, 28)
	btn.edit_alpha = false
	btn.color_changed.connect(func(new_c: Color) -> void:
		item[key] = [new_c.r, new_c.g, new_c.b]
		_mark_dirty())
	row.add_child(btn)
	_inspector.add_child(row)


func _mkline(row: HBoxContainer, value: String, on_change: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = value
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_changed.connect(on_change)
	row.add_child(le)
	return le


func _current_item() -> Dictionary:
	var arr: Array = blueprint.get(selected_kind, [])
	if selected_index < 0 or selected_index >= arr.size():
		return {}
	return arr[selected_index]


func _inspector_room() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Room: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty(); _canvas.queue_redraw())
	_vec3_row("Origin", item, "origin")
	_vec3_row("Size", item, "size")
	_mkoption(_mkrow("Material"), MATERIAL_OPTIONS, String(item.get("material", "brick")), func(s: String) -> void:
		item["material"] = s; _mark_dirty())
	_mkoption(_mkrow("Floor mat"), MATERIAL_OPTIONS, String(item.get("floor_material", "floor")), func(s: String) -> void:
		item["floor_material"] = s; _mark_dirty())
	var ops_label := Label.new()
	ops_label.text = "Openings:"
	_inspector.add_child(ops_label)
	var walls: Dictionary = item.get("walls", {})
	for side in ["north", "south", "east", "west"]:
		var w: Dictionary = walls.get(side, {})
		var openings: Array = w.get("openings", [])
		if openings.is_empty():
			continue
		for oi in range(openings.size()):
			var op: Dictionary = openings[oi]
			var row := HBoxContainer.new()
			var lbl := Label.new()
			lbl.text = "%s %d: %s w%.1f" % [side, oi, op.get("type", ""), float(op.get("width", 0))]
			lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(lbl)
			var del := Button.new()
			del.text = "x"
			del.pressed.connect(func() -> void:
				openings.remove_at(oi)
				_mark_dirty()
				_rebuild_inspector()
				_canvas.queue_redraw())
			row.add_child(del)
			_inspector.add_child(row)


func _inspector_extra() -> void:
	var item := _current_item()
	if item.is_empty(): return
	var t: String = item.get("type", "")
	_inspector_header("%s: %s" % [t.capitalize(), item.get("name", "(unnamed)")])
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty(); _canvas.queue_redraw())
	_vec3_row("Pos", item, "pos")
	match t:
		"stair":
			_mkspin(_mkrow("Steps"), int(item.get("steps", 10)), 1, 80, 1, func(v: float) -> void:
				item["steps"] = int(v); _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Rise"), float(item.get("rise", 0.4)), 0.1, 2.0, 0.01, func(v: float) -> void:
				item["rise"] = v; _mark_dirty())
			_mkspin(_mkrow("Run"), float(item.get("run", 0.5)), 0.2, 2.0, 0.05, func(v: float) -> void:
				item["run"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Width"), float(item.get("width", 2.0)), 0.5, 10.0, 0.1, func(v: float) -> void:
				item["width"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkoption(_mkrow("Direction"), DIRECTIONS, String(item.get("direction", "+x")), func(s: String) -> void:
				item["direction"] = s; _mark_dirty(); _canvas.queue_redraw())
			_punch_through_row(item)
		"spiral_stair":
			_mkspin(_mkrow("Steps"), int(item.get("steps", 17)), 4, 80, 1, func(v: float) -> void:
				item["steps"] = int(v); _mark_dirty())
			_mkspin(_mkrow("Rise"), float(item.get("rise", 0.3)), 0.1, 2.0, 0.01, func(v: float) -> void:
				item["rise"] = v; _mark_dirty())
			_mkspin(_mkrow("Radius"), float(item.get("radius", 2.0)), 0.5, 8.0, 0.1, func(v: float) -> void:
				item["radius"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Width"), float(item.get("width", 1.6)), 0.5, 6.0, 0.1, func(v: float) -> void:
				item["width"] = v; _mark_dirty())
			_mkspin(_mkrow("Depth"), float(item.get("depth", 0.6)), 0.1, 4.0, 0.05, func(v: float) -> void:
				item["depth"] = v; _mark_dirty())
			_mkspin(_mkrow("Angle"), float(item.get("angle", 0.42)), 0.1, 1.57, 0.01, func(v: float) -> void:
				item["angle"] = v; _mark_dirty())
			_punch_through_row(item)
		"elevator":
			_mkspin(_mkrow("Low Y"), float(item.get("low_y", 0.2)), -50.0, 200.0, 0.1, func(v: float) -> void:
				item["low_y"] = v; _mark_dirty())
			_mkspin(_mkrow("High Y"), float(item.get("high_y", 5.2)), -50.0, 200.0, 0.1, func(v: float) -> void:
				item["high_y"] = v; _mark_dirty())
			_mkspin(_mkrow("Width"), float(item.get("width", 3.0)), 0.5, 12.0, 0.1, func(v: float) -> void:
				item["width"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Depth"), float(item.get("depth", 3.0)), 0.5, 12.0, 0.1, func(v: float) -> void:
				item["depth"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Speed"), float(item.get("speed", 2.8)), 0.2, 20.0, 0.1, func(v: float) -> void:
				item["speed"] = v; _mark_dirty())
			_mkoption(_mkrow("Mode"), ELEVATOR_MODES, String(item.get("mode", "call")), func(s: String) -> void:
				item["mode"] = s; _mark_dirty())
			_punch_through_row(item)
		"pillar":
			_mkspin(_mkrow("Radius"), float(item.get("radius", 0.3)), 0.05, 3.0, 0.05, func(v: float) -> void:
				item["radius"] = v; _mark_dirty(); _canvas.queue_redraw())
			_mkspin(_mkrow("Height"), float(item.get("height", 5.0)), 0.2, 30.0, 0.1, func(v: float) -> void:
				item["height"] = v; _mark_dirty())
		"platform":
			_vec3_row("Size", item, "size")
	_mkoption(_mkrow("Material"), MATERIAL_OPTIONS, String(item.get("material", "floor")), func(s: String) -> void:
		item["material"] = s; _mark_dirty())


func _punch_through_row(item: Dictionary) -> void:
	# Pick a room (by name) to punch a ceiling/floor hole through. Null
	# option keeps the value absent. Rooms list + "(none)".
	var room_names: Array = ["(none)"]
	for r in blueprint.get("rooms", []):
		room_names.append(String(r.get("name", "")))
	var current: String = String(item.get("punch_through", "(none)"))
	_mkoption(_mkrow("Punch thru"), room_names, current, func(s: String) -> void:
		if s == "(none)":
			item.erase("punch_through")
		else:
			item["punch_through"] = s
		_mark_dirty())


func _inspector_block() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Block: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_vec3_row("Pos", item, "pos")
	_vec3_row("Size", item, "size")
	_mkoption(_mkrow("Material"), MATERIAL_OPTIONS, String(item.get("material", "wood")), func(s: String) -> void:
		item["material"] = s; _mark_dirty())
	var row := _mkrow("Breakable")
	_mkcheck(row, bool(item.get("breakable", false)), func(v: bool) -> void:
		item["breakable"] = v; _mark_dirty())
	_mkline(_mkrow("Reward"), String(item.get("reward", "")), func(s: String) -> void:
		item["reward"] = s; _mark_dirty())


func _inspector_key() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Key: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_vec3_row("Pos", item, "pos")
	_mkoption(_mkrow("Color"), KEY_COLORS, String(item.get("color", "silver")), func(s: String) -> void:
		item["color"] = s; _mark_dirty(); _canvas.queue_redraw())


func _inspector_lock() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Lock: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_vec3_row("Pos", item, "pos")
	_mkspin(_mkrow("Width"), float(item.get("width", 2.5)), 0.2, 10.0, 0.1, func(v: float) -> void:
		item["width"] = v; _mark_dirty(); _canvas.queue_redraw())
	_mkspin(_mkrow("Height"), float(item.get("height", 4.0)), 0.5, 20.0, 0.1, func(v: float) -> void:
		item["height"] = v; _mark_dirty())
	_mkspin(_mkrow("Depth"), float(item.get("depth", 0.5)), 0.1, 5.0, 0.05, func(v: float) -> void:
		item["depth"] = v; _mark_dirty(); _canvas.queue_redraw())
	_mkoption(_mkrow("Key"), KEY_COLORS, String(item.get("key", "silver")), func(s: String) -> void:
		item["key"] = s; _mark_dirty())
	_mkoption(_mkrow("Material"), MATERIAL_OPTIONS, String(item.get("material", "silver")), func(s: String) -> void:
		item["material"] = s; _mark_dirty())


func _inspector_terrain() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Terrain: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_vec3_row("Origin", item, "origin")
	_mkspin(_mkrow("Size X"), float(item.get("size_x", 10.0)), 2.0, 200.0, 0.5, func(v: float) -> void:
		item["size_x"] = v; _mark_dirty(); _canvas.queue_redraw())
	_mkspin(_mkrow("Size Z"), float(item.get("size_z", 10.0)), 2.0, 200.0, 0.5, func(v: float) -> void:
		item["size_z"] = v; _mark_dirty(); _canvas.queue_redraw())
	# Resolution change reshapes the heights array. Resample bilinearly
	# so an existing sculpt survives the switch instead of flat-resetting.
	# Cap lifted to 256 vertices per side (~65k verts / 130k tris) so
	# detailed outdoor levels can sculpt + paint at centimetre
	# precision. 128×128 is the default for new patches; dial down for
	# cheap background terrain, up to 256 for hero ground.
	_mkspin(_mkrow("Resolution"), int(item.get("resolution", 16)), 4, 256, 1, func(v: float) -> void:
		_resize_terrain(item, int(v)); _mark_dirty(); _canvas.queue_redraw(); _rebuild_inspector())
	# One-click convenience: double the cell count (clamped to the cap)
	# so the author doesn't need to type into the spinner. Paints +
	# heights are resampled so their shapes carry over.
	var refine_btn := Button.new()
	refine_btn.text = "Refine ×2  (double cell count)"
	refine_btn.tooltip_text = "Resample this patch at twice the resolution. Paint and sculpted heights are preserved."
	refine_btn.pressed.connect(func() -> void:
		var old_r: int = int(item.get("resolution", 16))
		var new_r: int = min(old_r * 2, 256)
		if new_r == old_r:
			_status("Already at max resolution (256)", true)
			return
		_resize_terrain(item, new_r)
		_mark_dirty()
		_canvas.queue_redraw()
		_rebuild_inspector()
		_status("Resolution %d → %d (%d cells)" % [old_r, new_r, (new_r - 1) * (new_r - 1)]))
	_inspector.add_child(refine_btn)
	# Material is an OVERRIDE. Blank (default) uses the slope-blended
	# grass/dirt vertex colours baked by terrain_patch.gd at runtime.
	var mat_options: Array = ["(slope colors)"] + MATERIAL_OPTIONS
	var current_mat: String = String(item.get("material", ""))
	var current_display: String = current_mat if current_mat != "" else "(slope colors)"
	_mkoption(_mkrow("Material"), mat_options, current_display, func(s: String) -> void:
		item["material"] = "" if s == "(slope colors)" else s
		_mark_dirty())
	# Slope-aware colours. Flat cells pick up `flat_color`; steeper ones
	# get `slope_color`. The threshold (cos of tilt angle) and softness
	# (blend width) decide where the transition happens.
	_inspector.add_child(_mklabel("Flat color"))
	_mkcolor_row(item, "flat_color", Color(0.35, 0.55, 0.22))
	_inspector.add_child(_mklabel("Slope color"))
	_mkcolor_row(item, "slope_color", Color(0.45, 0.32, 0.18))
	_mkspin(_mkrow("Slope thr"), float(item.get("slope_threshold", 0.72)), 0.0, 1.0, 0.02, func(v: float) -> void:
		item["slope_threshold"] = v; _mark_dirty())
	_mkspin(_mkrow("Slope soft"), float(item.get("slope_softness", 0.15)), 0.0, 0.5, 0.02, func(v: float) -> void:
		item["slope_softness"] = v; _mark_dirty())

	# --- Sculpt controls ---
	var sep := HSeparator.new()
	_inspector.add_child(sep)
	var hdr := Label.new()
	hdr.text = "Sculpt"
	hdr.add_theme_color_override("font_color", Color(0.7, 1.0, 0.8))
	_inspector.add_child(hdr)
	var sculpt_row := _mkrow("Sculpt active")
	_mkcheck(sculpt_row, _sculpt_active, func(v: bool) -> void:
		_sculpt_active = v
		if v:
			_paint_active = false
		_status("Sculpt %s" % ("ON" if v else "OFF")))
	_mkoption(_mkrow("Mode"), ["raise", "flatten", "average"],
		_sculpt_mode, func(s: String) -> void:
			_sculpt_mode = s
			if s == "flatten":
				_status("Flatten — click sets target height; Ctrl-click eyedrops from cell")
			elif s == "average":
				_status("Average — click smooths heights under brush")
			else:
				_status("Raise — click raises, shift-click lowers"))
	_mkspin(_mkrow("Brush radius"), _sculpt_radius, 0, 12, 1, func(v: float) -> void:
		_sculpt_radius = int(v))
	_mkspin(_mkrow("Strength (m)"), _sculpt_strength, 0.05, 4.0, 0.05, func(v: float) -> void:
		_sculpt_strength = v)
	_mkspin(_mkrow("Flatten target"), _flatten_target, -50.0, 50.0, 0.1, func(v: float) -> void:
		_flatten_target = v)
	var hard_row := _mkrow("Hard brush")
	_mkcheck(hard_row, _hard_brush, func(v: bool) -> void:
		_hard_brush = v)
	# Quick-action buttons so the user can reset or normalise a patch
	# without hand-sculpting every cell back to zero.
	var flatten_btn := Button.new()
	flatten_btn.text = "Flatten all to 0"
	flatten_btn.pressed.connect(func() -> void:
		var res: int = int(item.get("resolution", 16))
		var h: Array = []
		h.resize(res * res)
		for i in range(res * res):
			h[i] = 0.0
		item["heights"] = h
		_mark_dirty()
		_canvas.queue_redraw())
	_inspector.add_child(flatten_btn)
	var smooth_btn := Button.new()
	smooth_btn.text = "Smooth (1 pass)"
	smooth_btn.pressed.connect(func() -> void:
		_smooth_terrain(item)
		_mark_dirty()
		_canvas.queue_redraw())
	_inspector.add_child(smooth_btn)

	# --- Paint controls ---
	var sep2 := HSeparator.new()
	_inspector.add_child(sep2)
	var hdr2 := Label.new()
	hdr2.text = "Paint Surface"
	hdr2.add_theme_color_override("font_color", Color(0.65, 0.85, 1.0))
	_inspector.add_child(hdr2)
	var paint_row := _mkrow("Paint mode")
	_mkcheck(paint_row, _paint_active, func(v: bool) -> void:
		_paint_active = v
		if v:
			_sculpt_active = false
		_status("Paint %s — click to paint, shift-click to erase" % ("ON" if v else "OFF")))
	_mkoption(_mkrow("Kind"), TERRAIN_PAINT_KINDS, _paint_kind, func(s: String) -> void:
		_paint_kind = s)
	_mkspin(_mkrow("Brush r"), _paint_radius, 0, 8, 1, func(v: float) -> void:
		_paint_radius = int(v))
	var clear_paint_btn := Button.new()
	clear_paint_btn.text = "Clear all paint"
	clear_paint_btn.pressed.connect(func() -> void:
		var r: int = int(item.get("resolution", 16))
		var cells: int = (r - 1) * (r - 1)
		var g: Array = []
		g.resize(cells)
		for i in range(cells):
			g[i] = ""
		item["surface_grid"] = g
		_mark_dirty()
		_canvas.queue_redraw())
	_inspector.add_child(clear_paint_btn)


func _resize_terrain(patch: Dictionary, new_res: int) -> void:
	var old_res: int = int(patch.get("resolution", 16))
	var old_heights: Array = patch.get("heights", [])
	# Resample surface_grid nearest-neighbour so existing paint shape
	# survives a resolution bump. Was previously wiped to "" because
	# bilinear mixing of discrete surface kinds is meaningless, but
	# nearest-neighbour keeps the pattern and just gets coarser/finer
	# at the cell boundaries — usually what the author wants.
	var new_cells: int = (new_res - 1) * (new_res - 1)
	var new_grid: Array = []
	new_grid.resize(new_cells)
	var old_grid: Array = patch.get("surface_grid", [])
	var old_cells: int = (old_res - 1) * (old_res - 1)
	if old_grid.size() == old_cells and old_res >= 2 and new_res >= 2:
		for i in range(new_res - 1):
			for j in range(new_res - 1):
				var oi: int = clamp(int(round(float(i) * (old_res - 1) / float(new_res - 1) - 0.0)), 0, old_res - 2)
				var oj: int = clamp(int(round(float(j) * (old_res - 1) / float(new_res - 1) - 0.0)), 0, old_res - 2)
				new_grid[i * (new_res - 1) + j] = old_grid[oi * (old_res - 1) + oj]
	else:
		for i in range(new_cells):
			new_grid[i] = ""
	patch["surface_grid"] = new_grid
	if old_heights.size() != old_res * old_res or new_res == old_res:
		patch["resolution"] = new_res
		var flat: Array = []
		flat.resize(new_res * new_res)
		for i in range(new_res * new_res):
			flat[i] = 0.0
		patch["heights"] = flat
		return
	# Bilinear resample from old grid to new grid.
	var new_heights: Array = []
	new_heights.resize(new_res * new_res)
	for i in range(new_res):
		for j in range(new_res):
			var fi: float = float(i) / float(new_res - 1) * float(old_res - 1)
			var fj: float = float(j) / float(new_res - 1) * float(old_res - 1)
			var i0: int = clamp(int(floor(fi)), 0, old_res - 1)
			var j0: int = clamp(int(floor(fj)), 0, old_res - 1)
			var i1: int = clamp(i0 + 1, 0, old_res - 1)
			var j1: int = clamp(j0 + 1, 0, old_res - 1)
			var u: float = fi - float(i0)
			var v: float = fj - float(j0)
			var h00: float = float(old_heights[i0 * old_res + j0])
			var h10: float = float(old_heights[i1 * old_res + j0])
			var h01: float = float(old_heights[i0 * old_res + j1])
			var h11: float = float(old_heights[i1 * old_res + j1])
			new_heights[i * new_res + j] = (
				h00 * (1 - u) * (1 - v)
				+ h10 * u * (1 - v)
				+ h01 * (1 - u) * v
				+ h11 * u * v
			)
	patch["resolution"] = new_res
	patch["heights"] = new_heights


func _smooth_terrain(patch: Dictionary) -> void:
	var res: int = int(patch.get("resolution", 16))
	var heights: Array = patch.get("heights", [])
	if heights.size() != res * res:
		return
	var out: Array = []
	out.resize(res * res)
	for i in range(res):
		for j in range(res):
			var total: float = 0.0
			var count: int = 0
			for di in range(-1, 2):
				for dj in range(-1, 2):
					var ni: int = i + di
					var nj: int = j + dj
					if ni < 0 or nj < 0 or ni >= res or nj >= res:
						continue
					total += float(heights[ni * res + nj])
					count += 1
			out[i * res + j] = total / float(max(count, 1))
	patch["heights"] = out


func _inspector_opening() -> void:
	var op: Dictionary = _current_opening()
	if op.is_empty():
		return
	var room_name: String = String(blueprint["rooms"][_sel_op_room].get("name", ""))
	_inspector_header("%s on %s wall of %s" % [
		String(op.get("type", "opening")).capitalize(), _sel_op_side, room_name])
	var sides: Array = ["north", "south", "east", "west"]
	_mkoption(_mkrow("Wall"), sides, _sel_op_side, func(s: String) -> void:
		# Side change: pop from current side, append to new side.
		var ops: Array = blueprint["rooms"][_sel_op_room]["walls"][_sel_op_side]["openings"]
		var moved: Dictionary = ops[_sel_op_idx]
		ops.remove_at(_sel_op_idx)
		var walls: Dictionary = blueprint["rooms"][_sel_op_room].get("walls", {})
		if not walls.has(s):
			walls[s] = {"openings": []}
		blueprint["rooms"][_sel_op_room]["walls"] = walls
		var new_spec: Dictionary = walls[s]
		if not new_spec.has("openings") or typeof(new_spec["openings"]) != TYPE_ARRAY:
			new_spec["openings"] = []
		var new_ops: Array = new_spec["openings"]
		new_ops.append(moved)
		_sel_op_side = s
		_sel_op_idx = new_ops.size() - 1
		_mark_dirty()
		_rebuild_inspector()
		_canvas.queue_redraw())
	_mkoption(_mkrow("Type"), ["door", "window"], String(op.get("type", "door")), func(s: String) -> void:
		op["type"] = s
		if s == "window" and not op.has("sill"):
			op["sill"] = 1.5
		_mark_dirty()
		_canvas.queue_redraw())
	_mkspin(_mkrow("X along wall"), float(op.get("x", 0.0)), 0.0, 200.0, 0.1, func(v: float) -> void:
		op["x"] = v; _mark_dirty(); _canvas.queue_redraw())
	_mkspin(_mkrow("Width"), float(op.get("width", 1.5)), 0.5, 20.0, 0.1, func(v: float) -> void:
		op["width"] = v; _mark_dirty(); _canvas.queue_redraw())
	_mkspin(_mkrow("Height"), float(op.get("height", 3.0)), 0.5, 10.0, 0.1, func(v: float) -> void:
		op["height"] = v; _mark_dirty())
	if String(op.get("type", "door")) == "window":
		_mkspin(_mkrow("Sill"), float(op.get("sill", 1.5)), 0.0, 5.0, 0.1, func(v: float) -> void:
			op["sill"] = v; _mark_dirty())


func _inspector_level_properties() -> void:
	_inspector_header("Level Properties")
	# BGM — any track name recognised by SoundBank. Blank = use the
	# default for this level name (LEVEL_BGM dict).
	var bgm_opts: Array = [
		"", "bgm_castle", "bgm_course", "bgm_water", "bgm_bowser", "bgm_sub",
	]
	_mkoption(_mkrow("BGM"), bgm_opts, String(blueprint.get("bgm", "")), func(s: String) -> void:
		if s == "":
			blueprint.erase("bgm")
		else:
			blueprint["bgm"] = s
		_mark_dirty())
	# Water level Y override — usually inferred from a `water` volume,
	# but an explicit value wins when set. Leave blank (i.e. -inf) to
	# disable swimming entirely for this level.
	var has_wl: bool = blueprint.has("water_level_y")
	var wl_row := _mkrow("Water Y")
	var wl_check := CheckBox.new()
	wl_check.button_pressed = has_wl
	wl_check.tooltip_text = "Override the auto-computed water surface Y."
	wl_row.add_child(wl_check)
	var wl_spin := SpinBox.new()
	wl_spin.min_value = -999
	wl_spin.max_value = 999
	wl_spin.step = 0.5
	wl_spin.allow_greater = true
	wl_spin.allow_lesser = true
	wl_spin.value = float(blueprint.get("water_level_y", 0.0))
	wl_spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wl_spin.editable = has_wl
	wl_row.add_child(wl_spin)
	wl_check.toggled.connect(func(on: bool) -> void:
		wl_spin.editable = on
		if on:
			blueprint["water_level_y"] = wl_spin.value
		else:
			blueprint.erase("water_level_y")
		_mark_dirty())
	wl_spin.value_changed.connect(func(v: float) -> void:
		if wl_check.button_pressed:
			blueprint["water_level_y"] = v
			_mark_dirty())
	# Sky colours — used when standalone_level is true.
	var sky_dict: Dictionary = blueprint.get("sky") if blueprint.get("sky") is Dictionary else {}
	var sep := HSeparator.new()
	_inspector.add_child(sep)
	_inspector.add_child(_mklabel("Sky"))
	_mkcolor_row(sky_dict, "horizon_color", Color(0.52, 0.75, 0.98))
	_inspector.add_child(_mklabel("Ambient light"))
	_mkcolor_row(sky_dict, "ambient_color", Color(0.8, 0.82, 0.78))
	# Stash back in case it was missing.
	blueprint["sky"] = sky_dict
	var hint := Label.new()
	hint.text = "\nClick any object to inspect.\nDrag to create Room / Terrain / Water / Lava."
	hint.modulate = Color(0.75, 0.75, 0.8)
	_inspector.add_child(hint)


func _inspector_enemy() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Enemy: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_mkoption(_mkrow("Behavior"), ENEMY_BHVS, String(item.get("bhv", ENEMY_BHVS[0])), func(s: String) -> void:
		item["bhv"] = s; _mark_dirty())
	_vec3_row("Pos", item, "pos")
	_mkspin(_mkrow("Patrol r"), float(item.get("patrol_radius", 3.0)), 0.0, 30.0, 0.5, func(v: float) -> void:
		item["patrol_radius"] = v; _mark_dirty())


func _inspector_pickup() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Pickup: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_mkoption(_mkrow("Kind"), PICKUP_KINDS, String(item.get("kind", "coin_yellow")), func(s: String) -> void:
		item["kind"] = s; _mark_dirty(); _canvas.queue_redraw())
	_vec3_row("Pos", item, "pos")


func _inspector_volume() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Volume: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_mkoption(_mkrow("Kind"), ["water", "lava", "ice", "quicksand"],
		String(item.get("kind", "water")), func(s: String) -> void:
			item["kind"] = s; _mark_dirty(); _canvas.queue_redraw())
	_vec3_row("Origin", item, "origin")
	_vec3_row("Size", item, "size")


func _inspector_warp() -> void:
	var item := _current_item()
	if item.is_empty(): return
	_inspector_header("Warp: %s" % item.get("name", "(unnamed)"))
	_mkline(_mkrow("Name"), String(item.get("name", "")), func(s: String) -> void:
		item["name"] = s; _mark_dirty())
	_mkline(_mkrow("Target level"), String(item.get("target_level", "")), func(s: String) -> void:
		item["target_level"] = s; _mark_dirty())
	_vec3_row("Pos", item, "pos")
	_vec3_row("Size (trigger)", item, "size")
	_mkspin(_mkrow("Requires stars"), int(item.get("requires_stars", 0)), 0, 120, 1, func(v: float) -> void:
		if int(v) == 0:
			item.erase("requires_stars")
		else:
			item["requires_stars"] = int(v)
		_mark_dirty())
	_mkoption(_mkrow("Requires key"), ["", "bronze", "silver", "gold"],
		String(item.get("requires_key", "")), func(s: String) -> void:
			if s == "":
				item.erase("requires_key")
			else:
				item["requires_key"] = s
			_mark_dirty())


func _inspector_spawn() -> void:
	_inspector_header("Spawn Point")
	var row_x := _mkrow("X")
	var sp: Array = blueprint.get("spawn_point", [0, 1, 0])
	_mkspin(row_x, float(sp[0]), -999, 999, 0.5, func(v: float) -> void:
		sp[0] = v; blueprint["spawn_point"] = sp; _mark_dirty(); _canvas.queue_redraw())
	_mkspin(_mkrow("Y"), float(sp[1]), -999, 999, 0.5, func(v: float) -> void:
		sp[1] = v; blueprint["spawn_point"] = sp; _mark_dirty())
	_mkspin(_mkrow("Z"), float(sp[2]), -999, 999, 0.5, func(v: float) -> void:
		sp[2] = v; blueprint["spawn_point"] = sp; _mark_dirty(); _canvas.queue_redraw())


func _vec3_row(label: String, item: Dictionary, key: String) -> void:
	var arr: Array = item.get(key, [0, 0, 0])
	while arr.size() < 3:
		arr.append(0)
	var row_label := Label.new()
	row_label.text = label
	_inspector.add_child(row_label)
	var row := HBoxContainer.new()
	_inspector.add_child(row)
	for axis in range(3):
		var sb := SpinBox.new()
		sb.min_value = -999
		sb.max_value = 999
		sb.step = 0.5
		sb.allow_greater = true
		sb.allow_lesser = true
		sb.value = float(arr[axis])
		sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var axis_idx: int = axis
		sb.value_changed.connect(func(v: float) -> void:
			arr[axis_idx] = v
			item[key] = arr
			_mark_dirty()
			_canvas.queue_redraw())
		row.add_child(sb)


# ------------------------------------------------------------ Shortcuts

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var ke := event as InputEventKey
		# Suppress single-letter tool shortcuts while the user is
		# typing into any text field so "room" names don't trip them
		# into a different tool every few keystrokes.
		var focus: Control = get_viewport().gui_get_focus_owner()
		var typing: bool = focus is LineEdit or focus is SpinBox
		if ke.ctrl_pressed and ke.keycode == KEY_Z:
			_undo()
			get_viewport().set_input_as_handled()
			return
		if ke.ctrl_pressed and ke.keycode == KEY_S:
			_on_save()
			get_viewport().set_input_as_handled()
			return
		if ke.ctrl_pressed and ke.keycode == KEY_O:
			_on_open()
			get_viewport().set_input_as_handled()
			return
		if ke.ctrl_pressed and ke.keycode == KEY_N:
			_on_new()
			get_viewport().set_input_as_handled()
			return
		if ke.ctrl_pressed and ke.keycode == KEY_B:
			_on_build()
			get_viewport().set_input_as_handled()
			return
		if ke.keycode == KEY_DELETE:
			if selected_kind != "" and selected_kind != "spawn":
				_delete_selected()
				get_viewport().set_input_as_handled()
				return
		# Tool shortcut: plain letter key, no modifiers, not while typing.
		if not typing and not ke.ctrl_pressed and not ke.alt_pressed:
			if _tool_shortcuts.has(ke.keycode):
				var want: String = _tool_shortcuts[ke.keycode]
				for i in range(TOOLS.size()):
					if TOOLS[i][0] == want:
						_tool_list.select(i)
						_on_tool_selected(i)
						break
				get_viewport().set_input_as_handled()
				return
