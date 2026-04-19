extends CanvasLayer

# Pause menu overlay — ESC (when cursor is captured) or P toggles pause.
# While paused the physics world and processes freeze. We keep the camera
# and HUD animating so the menu overlay can be read but the simulation
# sits frozen until resumed.

@onready var _panel: Control = $PauseRoot


func _ready() -> void:
    # We want to keep running input (to accept the unpause keys) even while
    # the rest of the tree is paused.
    process_mode = Node.PROCESS_MODE_ALWAYS
    _panel.visible = false


func toggle() -> void:
    set_paused(not is_paused())


func is_paused() -> bool:
    return get_tree().paused


func set_paused(paused: bool) -> void:
    get_tree().paused = paused
    _panel.visible = paused
    if paused:
        Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    else:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and event.keycode == KEY_P:
        toggle()
