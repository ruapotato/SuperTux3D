extends Control

# Lists every playable level so the user can jump straight into any of
# them without having to memorise KEY_1..KEY_0 shortcuts. Sources:
#
#   1. res://assets/levels/*.tscn — the built, ready-to-run levels
#      (includes both hand-authored and converter-built ones)
#   2. /home/david/gd_mario/blueprints/*.json — raw blueprints. If a
#      blueprint has no matching .tscn yet, it still shows up here with
#      a "(build required)" tag. Clicking it invokes the converter
#      before changing scene, so a brand-new authored level is playable
#      one click after saving it in the editor.
#
# Selection is passed to the game scene via a static var on this script;
# main.gd's _ready() consumes and clears it.

const LEVELS_DIR := "res://assets/levels"
const BLUEPRINTS_DIR := "/home/david/gd_mario/blueprints"
const LEVELS_ABS_DIR := "/home/david/gd_mario/godot/assets/levels"
const BUILD_SCRIPT := "/home/david/gd_mario/tools/build_from_blueprint.py"

# Consumed by main.gd when it loads the game scene. Empty string means
# "use whatever save_data.last_level says".
static var pending_level: String = ""
# Optional one-shot override for where Mario spawns in the loaded
# level. Set by the editor's "▶ Play" button when a Temp Spawn marker
# was placed. [x, y, z]; empty = use the level's SpawnArea as normal.
static var pending_temp_spawn: Array = []


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	$BackBtn.pressed.connect(_back)
	$RefreshBtn.pressed.connect(_populate)
	_populate()


func _back() -> void:
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


func _populate() -> void:
	var list: VBoxContainer = $Scroll/List
	for c in list.get_children():
		c.queue_free()
	var built: Dictionary = {}   # stem → true
	var da := DirAccess.open(LEVELS_DIR)
	if da != null:
		da.list_dir_begin()
		var fname: String = da.get_next()
		while fname != "":
			if not da.current_is_dir() and fname.ends_with(".tscn"):
				built[fname.get_basename()] = true
			fname = da.get_next()
		da.list_dir_end()
	var blueprints: Dictionary = {}
	var db := DirAccess.open(BLUEPRINTS_DIR)
	if db != null:
		db.list_dir_begin()
		var fname2: String = db.get_next()
		while fname2 != "":
			if not db.current_is_dir() and fname2.ends_with(".json"):
				blueprints[fname2.get_basename()] = true
			fname2 = db.get_next()
		db.list_dir_end()

	var names: Array = []
	for n in built.keys():
		names.append(n)
	for n in blueprints.keys():
		if not built.has(n):
			names.append(n)
	names.sort()

	if names.is_empty():
		var empty := Label.new()
		empty.text = "No levels found."
		list.add_child(empty)
		return

	for n in names:
		var is_blueprint: bool = blueprints.has(n)
		var needs_build: bool = (not built.has(n)) and is_blueprint
		var stale: bool = false
		if not needs_build and is_blueprint:
			stale = _is_stale(n)
		var btn := Button.new()
		var tag: String = ""
		if needs_build:
			tag = "   [build required]"
		elif stale:
			tag = "   [stale — will rebuild]"
		elif is_blueprint:
			tag = "   [blueprint]"
		btn.text = "%s%s" % [n, tag]
		btn.custom_minimum_size = Vector2(0, 42)
		btn.add_theme_font_size_override("font_size", 18)
		btn.pressed.connect(_on_pick.bind(n, needs_build or stale))
		list.add_child(btn)
	$Status.text = "%d levels — click to play. Blueprint-backed levels auto-rebuild if the JSON is newer than the .tscn." % names.size()


func _is_stale(level_name: String) -> bool:
	# Blueprint-backed: if the JSON has been modified more recently than
	# the .tscn, the built level doesn't reflect the current edits and
	# needs a rebuild. FileAccess.get_modified_time takes an OS-absolute
	# path and returns a Unix timestamp; a missing file returns 0, in
	# which case we treat it as stale to force a build.
	var json_path: String = "%s/%s.json" % [BLUEPRINTS_DIR, level_name]
	var tscn_path: String = "%s/%s.tscn" % [LEVELS_ABS_DIR, level_name]
	var json_t: int = FileAccess.get_modified_time(json_path)
	var tscn_t: int = FileAccess.get_modified_time(tscn_path)
	if json_t == 0:
		return false  # not a blueprint-backed level
	return tscn_t < json_t


func _on_pick(level_name: String, needs_build: bool) -> void:
	if needs_build:
		$Status.text = "Building %s…" % level_name
		var out: Array = []
		var args := [
			BUILD_SCRIPT,
			"%s/%s.json" % [BLUEPRINTS_DIR, level_name],
			"%s/%s.tscn" % [LEVELS_ABS_DIR, level_name],
		]
		var code := OS.execute("python3", args, out, true)
		if code != 0:
			var tail: String = String(out[0]).substr(0, 240) if out.size() > 0 else ""
			$Status.text = "Build failed (exit %d): %s" % [code, tail]
			return
	pending_level = level_name
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			_back()
			get_viewport().set_input_as_handled()
