extends Control

# Landing scene. Does nothing except pick which full scene to run next.
# Kept intentionally tiny so boot time is instant and the cursor is
# free — users land on this before the game captures the mouse, before
# the editor grabs the viewport. Swapping to another scene discards
# this one entirely (no overlay, no physics ticking).

const GAME_SCENE := "res://scenes/main.tscn"
const EDITOR_SCENE := "res://scenes/blueprint_editor.tscn"
const HUB_LEVEL := "grass_hub"
const LevelSelectScript := preload("res://scripts/level_select.gd")


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	$Buttons/PlayBtn.pressed.connect(_play)
	$Buttons/EditorBtn.pressed.connect(_editor)
	$Buttons/QuitBtn.pressed.connect(_quit)
	$Buttons/PlayBtn.grab_focus()


func _play() -> void:
	# Mario-64-style: drop straight into the hub world. From there
	# the player walks to one of the painting/door warps to enter
	# a themed level. The old level-list select is still reachable
	# from the editor but isn't the default play path anymore.
	LevelSelectScript.pending_level = HUB_LEVEL
	get_tree().change_scene_to_file(GAME_SCENE)


func _editor() -> void:
	get_tree().change_scene_to_file(EDITOR_SCENE)


func _quit() -> void:
	get_tree().quit()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ENTER, KEY_SPACE:
				_play()
				get_viewport().set_input_as_handled()
			KEY_ESCAPE:
				_quit()
				get_viewport().set_input_as_handled()
