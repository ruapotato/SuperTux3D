extends Node3D

const LevelLoader := preload("res://scripts/level_loader.gd")
const MarioAnimator := preload("res://scripts/mario_animator.gd")
const LevelManagerScript := preload("res://scripts/level_manager.gd")
const SoundBankScript := preload("res://scripts/sound_bank.gd")
const SaveDataScript := preload("res://scripts/save_data.gd")
const MARIO_MESH_JSON := "res://extracted/actors/mario/mesh.json"
const ANIMS_DIR := "res://extracted/actors/mario/anims"
const BOOT_LEVEL := "castle_inside"   # SM64-canonical boot: castle hub
const BOOT_AREA := 1

# Level-switcher keyboard shortcuts so we can bounce between levels to test
# the pipeline before the painting warps are wired up.
const LEVEL_SHORTCUTS := {
    KEY_1: ["bob", 1],
    KEY_2: ["ccm", 1],
    KEY_3: ["wf", 1],
    KEY_4: ["jrb", 1],
    KEY_5: ["hmc", 1],
    KEY_6: ["ssl", 1],
    KEY_7: ["ttm", 1],
    KEY_8: ["thi", 1],
    KEY_9: ["rr", 1],
    KEY_0: ["castle_grounds", 1],
}

# Q and E step through the full list of 30 levels in sorted order.
const CYCLE_ORDER := [
    "castle_grounds", "castle_inside", "castle_courtyard",
    "bob", "wf", "jrb", "ccm", "bbh", "hmc", "lll", "ssl",
    "ddd", "sl", "wdw", "ttm", "thi", "ttc", "rr",
    "pss", "sa", "totwc", "cotmc", "vcutm", "wmotr",
    "bitdw", "bitfs", "bits", "bowser_1", "bowser_2", "bowser_3",
]
var _cycle_idx: int = 0
# Actual spawn from decomp levels/bob/script.c: MARIO_POS(1, 135, -6558, 0, 6464).
# Scaled to Godot world scale (see LevelLoader.WORLD_SCALE). +2 Y offset for
# a small cushion so the capsule doesn't start clipped into the floor.
# Mario's spawn is read from the current level's script.json; only the
# level-manager knows the answer.


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
@onready var title_screen: ColorRect = $UI/TitleScreen

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
    # Preload Mario's idle animation so the axis-compensation pass can
    # sample its frame-0 bone 0 + bone 1 rotations. Same treatment every
    # animated actor gets — no Mario-special-case axis_remap any more.
    var mario_idle: Variant = _read_json("res://extracted/actors/mario/anims/anim_C5.json")
    # skip_alpha_geo=true hides Mario's cap wings by default — the decomp
    # uses an ASM callback to toggle them on when he wears the Wing Cap
    # powerup, which we don't model. Without this flag wings sprout from
    # the sides of his head.
    var actor: Dictionary = LevelLoader.load_actor(
        MARIO_MESH_JSON, anchor, "mario", mario_idle,
        -1.0, true,
    )
    _setup_animator(actor)

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
    _level_manager.load_level(_save.last_level, _save.last_area)

    mario.set_camera(camera)
    # Hold on the title screen; the first key press closes it and captures
    # the mouse.
    if title_screen != null:
        title_screen.visible = true
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    get_tree().debug_collisions_hint = false


func _setup_animator(actor: Dictionary) -> void:
    if actor.is_empty():
        return
    _animator = MarioAnimator.new()
    var rest_rots: Array = []
    var rest_model: Variant = _read_json(MARIO_MESH_JSON)
    if rest_model is Dictionary:
        for b in rest_model.bones:
            var r: Array = b.rest_rotation
            var to_rad: float = TAU / 65536.0
            rest_rots.append(Vector3(r[0] * to_rad, r[1] * to_rad, r[2] * to_rad))
    _animator.setup(actor.bones, rest_rots)
    # Hand the animator to Mario so MarioState can request animations by ID.
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
        # Game over: reset lives, return to castle hub with full HP.
        mario.lives = 4
        mario.coin_count = 0
        mario._play_sfx("game_over")
        _go_to_castle()
        _respawn_after(2.0)
    else:
        _respawn_after(1.5)


func _on_star_collected() -> void:
    if _save != null:
        _save.record_star(_level_manager.current_level)
    _respawn_after(2.5)
    # Override the next respawn to land in castle_grounds rather than the
    # current level's spawn. The simplest approach: change the current
    # level_manager state immediately before respawn fires.
    var t := Timer.new()
    t.wait_time = 2.4
    t.one_shot = true
    add_child(t)
    t.timeout.connect(_go_to_castle)
    t.start()


func _go_to_castle() -> void:
    if _level_manager != null:
        _level_manager.current_level = "castle_inside"
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
    # Resolve a MARIO_ANIM_* ID to the parsed animation JSON, lazily loading
    # from disk on first request and caching thereafter.
    if _anim_cache.has(anim_id):
        return _anim_cache[anim_id]
    var path := "%s/anim_%02X.json" % [ANIMS_DIR, anim_id]
    var parsed: Variant = _read_json(path)
    if parsed is Dictionary:
        _anim_cache[anim_id] = parsed
        return parsed
    push_warning("main: missing animation 0x%02X at %s" % [anim_id, path])
    _anim_cache[anim_id] = {}
    return {}


func _read_json(path: String) -> Variant:
    if not FileAccess.file_exists(path):
        return null
    var f := FileAccess.open(path, FileAccess.READ)
    return JSON.parse_string(f.get_as_text())


func _input(event: InputEvent) -> void:
    # Title screen swallows the first meaningful press.
    if title_screen != null and title_screen.visible:
        if (event is InputEventKey and event.pressed) \
                or (event is InputEventMouseButton and event.pressed):
            title_screen.visible = false
            Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
            get_viewport().set_input_as_handled()
            return
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
        + "Wheel zoom  1-9 swap level  0 castle  Q/E cycle  R respawn  F1 collision"
    ) % [
        level_info,
        stats,
        action_name,
        "pos: (%.1f, %.1f, %.1f)" % [
            mario.global_position.x, mario.global_position.y, mario.global_position.z,
        ],
    ]
