extends Node3D

const CleanCharacterAnim := preload("res://scripts/clean_character_anim.gd")
const LevelManagerScript := preload("res://scripts/level_manager.gd")
const SoundBankScript := preload("res://scripts/sound_bank.gd")
const SaveDataScript := preload("res://scripts/save_data.gd")
const LevelSelectScript := preload("res://scripts/level_select.gd")
const PLAYER_SCENE := preload("res://assets/characters/player.tscn")
const BOOT_LEVEL := "grass_hub"
const BOOT_AREA := 1

# Level-switcher keyboard shortcuts. Each key jumps to one of the
# procedural clean-room worlds. Key 9 jumps to the blueprint demo
# (locked door + breakable block + key pickup), useful for testing
# the new systems without needing to find them inside a big level.
const LEVEL_SHORTCUTS := {
    KEY_1: ["grass_hub", 1],
    KEY_2: ["mountain",  1],
    KEY_3: ["snow",      1],
    KEY_4: ["water",     1],
    KEY_5: ["lava",      1],
    KEY_6: ["sand",      1],
    KEY_7: ["sky",       1],
    KEY_8: ["bowser",    1],
    KEY_9: ["demo_full", 1],
    KEY_0: ["test_multistory", 1],
}

# Q / E step through the worlds in order.
const CYCLE_ORDER := [
    "grass_hub", "mountain", "snow", "water",
    "lava", "sand", "sky", "bowser",
]
var _cycle_idx: int = 0


# Orbit camera settings (Godot world scale ~= meters).
# Lakitu-ish defaults: ~7 units behind Mario, pitched slightly down.
const CAM_DISTANCE_DEFAULT := 7.0
const CAM_DISTANCE_MIN := 2.0
const CAM_DISTANCE_MAX := 20.0
const MOUSE_SENSITIVITY := 0.005
# Focus point offset from Mario's feet (~chest height).
const FOCUS_OFFSET := Vector3(0, 1.0, 0)
var _cam_distance: float = CAM_DISTANCE_DEFAULT

@onready var world: Node3D = $World
@onready var camera: Camera3D = $CameraRig/Camera3D
@onready var camera_rig: Node3D = $CameraRig
@onready var mario: CharacterBody3D = $Mario
@onready var hud_label: Label = $UI/HUD
# Title/menu lives in scenes/main_menu.tscn now — this scene is game-only.

var _animator: RefCounted
var _level_manager: Node
var _sound_bank: Node
var _save: Node
var _death_pending: bool = false
# Animation cache keyed by decomp ID (MARIO_ANIM_* integer). Loaded lazily
# the first time a state requests it.
var _anim_cache: Dictionary = {}

# Yaw: rotation about world Y. Pitch: angle above horizontal (+ = camera above).
var _cam_yaw := 0.0
var _cam_pitch := 0.25
# Smoothed focus point so Mario's animation bob doesn't shake the camera.
var _focus_smooth: Vector3 = Vector3.ZERO


func _ready() -> void:
    var anchor: Node3D = mario.get_node("ActorAnchor")
    var rig: Node3D = PLAYER_SCENE.instantiate()
    anchor.add_child(rig)
    _setup_animator(rig)

    _sound_bank = SoundBankScript.new()
    _sound_bank.name = "SoundBank"
    add_child(_sound_bank)
    _sound_bank.setup(8, mario)
    if mario.has_method("bind_sound_bank"):
        mario.bind_sound_bank(_sound_bank)

    _save = SaveDataScript.new()
    _save.name = "Save"
    add_child(_save)
    _save.load_file()
    mario.lives = _save.lives
    mario.coin_count = _save.coins
    mario.star_count = _save.stars

    _level_manager = LevelManagerScript.new()
    _level_manager.name = "LevelManager"
    add_child(_level_manager)
    _level_manager.setup(world, mario)
    _level_manager.sound_bank = _sound_bank
    _level_manager.save_data = _save
    # If the user picked a specific level from the level-select menu,
    # that choice wins over whatever save_data remembers. Consumed once
    # so re-entering main.tscn from a different path falls back to the
    # saved last-played level.
    var boot_level: String = _save.last_level
    var boot_area: int = _save.last_area
    if LevelSelectScript.pending_level != "":
        boot_level = LevelSelectScript.pending_level
        boot_area = 1
        LevelSelectScript.pending_level = ""
    _level_manager.load_level(boot_level, boot_area)
    # Temp-spawn override from the editor's Play button: drop Mario at
    # the editor-picked position instead of the level's SpawnArea. One
    # shot — cleared after use so subsequent respawns use the level's
    # real spawn.
    if LevelSelectScript.pending_temp_spawn.size() == 3:
        var ts: Array = LevelSelectScript.pending_temp_spawn
        mario.global_position = Vector3(float(ts[0]), float(ts[1]), float(ts[2]))
        mario.velocity = Vector3.ZERO
        LevelSelectScript.pending_temp_spawn = []

    mario.set_camera(camera)
    # Game starts immediately — the landing menu already decided we're
    # playing. Capture the mouse so the orbit camera reads deltas.
    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
    get_tree().debug_collisions_hint = false


func _setup_animator(rig: Node3D) -> void:
    # Build the name→Node3D bone dict that clean_character_anim expects
    # from the instantiated player rig. Keys match the animator's
    # _pose_* functions and the node names in player.tscn.
    _animator = CleanCharacterAnim.new()
    var bones := {
        "pelvis": rig.get_node_or_null("pelvis"),
        "torso":  rig.get_node_or_null("pelvis/torso"),
        "head":   rig.get_node_or_null("pelvis/torso/head"),
        "arm_l":  rig.get_node_or_null("pelvis/torso/arm_l"),
        "arm_r":  rig.get_node_or_null("pelvis/torso/arm_r"),
        "leg_l":  rig.get_node_or_null("pelvis/leg_l"),
        "leg_r":  rig.get_node_or_null("pelvis/leg_r"),
    }
    _animator.setup(bones)
    if mario.has_method("bind_animator"):
        mario.bind_animator(_animator, self)
    # Wire star collection → brief delay → return to castle hub.
    if mario.has_signal("star_collected"):
        mario.star_collected.connect(_on_star_collected)
    # Wire death → short delay → reload current area, restoring HP.
    if mario.has_signal("died"):
        mario.died.connect(_on_mario_died)


func _on_mario_died() -> void:
    if _death_pending:
        return
    _death_pending = true
    mario.lives -= 1
    if mario.lives <= 0:
        # Game over: reset lives, return to the hub with full HP.
        mario.lives = 4
        mario.coin_count = 0
        mario._play_sfx("death")
        _go_to_hub()
        _respawn_after(2.0)
    else:
        _respawn_after(1.5)


func _on_star_collected() -> void:
    if _save != null:
        _save.record_star(_level_manager.current_level)
    _respawn_after(2.5)
    # After a short star fanfare, warp back to the grass hub so each
    # level trip feels like a round-trip from a home base.
    var t := Timer.new()
    t.wait_time = 2.4
    t.one_shot = true
    add_child(t)
    t.timeout.connect(_go_to_hub)
    t.start()


func _go_to_hub() -> void:
    if _level_manager != null:
        _level_manager.current_level = BOOT_LEVEL
        _level_manager.current_area = 1


func _save_progress() -> void:
    if _save == null or _level_manager == null:
        return
    _save.stars = mario.star_count
    _save.coins = mario.coin_count
    _save.lives = mario.lives
    _save.record_level(_level_manager.current_level, _level_manager.current_area)
    _save.save_file()


func _cycle_level(direction: int) -> void:
    _cycle_idx = (_cycle_idx + direction + CYCLE_ORDER.size()) % CYCLE_ORDER.size()
    _level_manager.load_level(CYCLE_ORDER[_cycle_idx], 1)


func get_anim(anim_id: int) -> Dictionary:
    # The procedural clean-room animator doesn't replay recorded tracks —
    # it picks a motion tag from the anim_id directly in play(). We still
    # return a non-empty marker dict because mario_stub treats empty as
    # "no animation available" and suppresses the call.
    return {"id": anim_id}


func _input(event: InputEvent) -> void:
    if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
        _cam_yaw -= event.relative.x * MOUSE_SENSITIVITY
        # Mouse up → look up (camera pitches lower so it looks upward).
        _cam_pitch = clamp(_cam_pitch + event.relative.y * MOUSE_SENSITIVITY,
                           -0.4, 1.2)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
        # ESC pauses the game (which also releases the cursor). The pause
        # overlay handles its own unpause input.
        var pause := get_node_or_null("PauseMenu")
        if pause != null:
            pause.toggle()
    elif event is InputEventKey and event.pressed and event.keycode == KEY_R:
        _respawn()
    elif event is InputEventKey and event.pressed and event.keycode == KEY_F1:
        get_tree().debug_collisions_hint = not get_tree().debug_collisions_hint
        _reload_debug_shapes()
    elif event is InputEventKey and event.pressed and event.keycode == KEY_F4:
        _open_in_editor()
    elif event is InputEventKey and event.pressed and LEVEL_SHORTCUTS.has(event.keycode):
        var spec: Array = LEVEL_SHORTCUTS[event.keycode]
        _level_manager.load_level(spec[0], spec[1])
    elif event is InputEventKey and event.pressed and event.keycode == KEY_Q:
        _cycle_level(-1)
    elif event is InputEventKey and event.pressed and event.keycode == KEY_E:
        _cycle_level(1)
    elif event is InputEventMouseButton and event.pressed:
        if event.button_index == MOUSE_BUTTON_WHEEL_UP:
            _cam_distance = max(_cam_distance - 0.7, CAM_DISTANCE_MIN)
        elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
            _cam_distance = min(_cam_distance + 0.7, CAM_DISTANCE_MAX)


func _open_in_editor() -> void:
    """F4 — flip to the blueprint editor with the current level
    pre-loaded so the player can adjust geometry / paint / pickups
    in place. The editor's _ready picks up pending_level_to_edit
    and tries to open `blueprints/<stem>.json`; if that doesn't
    exist (hand-authored level with no blueprint yet), the editor
    starts blank and the user can save-as to create one."""
    var stem: String = _level_manager.current_level if _level_manager != null else ""
    LevelSelectScript.pending_level_to_edit = stem
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().change_scene_to_file("res://scenes/blueprint_editor.tscn")


func _respawn() -> void:
    if _level_manager != null:
        _level_manager.load_level(_level_manager.current_level,
                                  _level_manager.current_area)
    _death_pending = false
    mario.health = 8
    mario.invulnerable_time = 1.5


func _respawn_after(delay: float) -> void:
    var t := Timer.new()
    t.wait_time = delay
    t.one_shot = true
    add_child(t)
    t.timeout.connect(_respawn)
    t.start()


func _update_animation(delta: float) -> void:
    if _animator == null:
        return
    _animator.tick(delta)


func _reload_debug_shapes() -> void:
    # Toggling debug_collisions_hint at runtime only affects newly-added
    # collision shapes, so re-parent all CollisionShape3D nodes in `world` to
    # force them to re-register with a debug mesh attached.
    for body in world.get_children():
        for child in body.get_children():
            if child is CollisionShape3D:
                var parent := child.get_parent()
                parent.remove_child(child)
                parent.add_child(child)


func _process(delta: float) -> void:
    _update_animation(delta)
    var focus_target: Vector3 = mario.global_position + FOCUS_OFFSET
    # Smooth the focus position (not just the camera position) so vertical
    # bobbing and rapid Mario motion don't whip the camera around.
    _focus_smooth = _focus_smooth.lerp(focus_target, clamp(delta * 10.0, 0.0, 1.0))
    var offset := Vector3(
        sin(_cam_yaw) * cos(_cam_pitch),
        sin(_cam_pitch),
        cos(_cam_yaw) * cos(_cam_pitch),
    ) * _cam_distance
    var desired := _focus_smooth + offset
    # Raycast from focus to desired to keep the camera out of walls.
    var space := get_world_3d().direct_space_state
    var q := PhysicsRayQueryParameters3D.create(_focus_smooth, desired)
    q.exclude = [mario.get_rid()]
    q.collision_mask = 1
    var hit := space.intersect_ray(q)
    if hit.has("position"):
        desired = (hit.position as Vector3).lerp(_focus_smooth, 0.04)
    # Glide the rig to its new target for a softer feel.
    camera_rig.global_position = camera_rig.global_position.lerp(
        desired, clamp(delta * 14.0, 0.0, 1.0)
    )
    camera_rig.look_at(_focus_smooth, Vector3.UP)
    # Auto-respawn on fall-plane crossing. Routes through the same death
    # handler so lives decrement + game-over flow are consistent.
    if mario.global_position.y < -10.0 and not _death_pending:
        mario._play_sfx("death")
        _on_mario_died()
    var mario_stub := mario as CharacterBody3D
    var ray_down: String = mario.get("debug_ray_down_hit")
    var ray_up: String = mario.get("debug_ray_up_hit")
    var anim_state: String = "(none)"
    if _animator != null:
        anim_state = _animator.debug_state()
    var action_name: String = ""
    if mario.has_method("current_action_name"):
        action_name = mario.current_action_name()
    var stats := ""
    if mario != null:
        var cap := ""
        if mario.power_cap != "":
            cap = "  cap:%s (%.0fs)" % [mario.power_cap, mario.power_cap_time]
        stats = "HP:%d/8  coins:%d  stars:%d  lives:%d%s" % [
            mario.health, mario.coin_count, mario.star_count,
            mario.lives, cap,
        ]
    var level_info := ""
    if _level_manager != null:
        level_info = "level: %s area %d" % [
            _level_manager.current_level, _level_manager.current_area,
        ]
    hud_label.text = (
        "%s\n"
        + "%s\n"
        + "action: %s\n"
        + "%s\n"
        + "WASD move  Space jump  Ctrl crouch  Shift attack/dive\n"
        + "Wheel zoom  1-8 swap world  Q/E cycle  R respawn  F1 collision\n"
        + "F4: edit this level   Esc: pause"
    ) % [
        level_info,
        stats,
        action_name,
        "pos: (%.1f, %.1f, %.1f)" % [
            mario.global_position.x, mario.global_position.y, mario.global_position.z,
        ],
    ]
