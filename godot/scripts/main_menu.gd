extends Control

# Landing scene. Does nothing except pick which full scene to run next.
# Kept intentionally tiny so boot time is instant and the cursor is
# free — users land on this before the game captures the mouse, before
# the editor grabs the viewport. Swapping to another scene discards
# this one entirely (no overlay, no physics ticking).

const LEVEL_SELECT_SCENE := "res://scenes/level_select.tscn"
const EDITOR_SCENE := "res://scenes/blueprint_editor.tscn"


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	$Buttons/PlayBtn.pressed.connect(_play)
	$Buttons/EditorBtn.pressed.connect(_editor)
	$Buttons/QuitBtn.pressed.connect(_quit)
	$Buttons/PlayBtn.grab_focus()


func _play() -> void:
	get_tree().change_scene_to_file(LEVEL_SELECT_SCENE)


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
