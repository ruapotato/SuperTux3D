extends AnimatableBody3D

# Elevator platform. Reads its configuration from meta values set by
# the blueprint converter:
#   elevator_low_y  — bottom y-position (meters)
#   elevator_high_y — top y-position
#   elevator_speed  — meters/second of travel
#   elevator_mode   — "loop" (bobs up/down forever), "toggle"
#                     (each player touch flips direction), "call"
#                     (returns to low when empty; rises to high while
#                     player stands on it).
#
# AnimatableBody3D is the correct base: it's a solid collider that
# CharacterBody3D picks up as a moving floor. move_and_slide()'s
# built-in platform follow handles the player riding it — no need
# to reparent or transfer velocity manually.

var _low: float = 0.0
var _high: float = 0.0
var _speed: float = 2.0
var _mode: String = "toggle"
var _direction: int = 1   # +1 going up, -1 going down
var _active: bool = true
var _player_on_board: bool = false

# A small Area3D on top of the platform detects when the player
# stands on it. Used by "call" and "toggle" modes.
var _sensor: Area3D


func _ready() -> void:
    _low = float(get_meta("elevator_low_y", position.y))
    _high = float(get_meta("elevator_high_y", position.y + 4.0))
    _speed = float(get_meta("elevator_speed", 2.0))
    _mode = str(get_meta("elevator_mode", "toggle"))
    # Clamp starting Y into the range so we don't drift.
    position.y = clamp(position.y, _low, _high)
    # "call" mode starts at low and rises when called.
    if _mode == "call":
        position.y = _low
        _direction = 1

    # Build a slim Area3D that sits on top of the platform to detect
    # the player standing on us.
    _sensor = Area3D.new()
    _sensor.name = "StandSensor"
    _sensor.collision_mask = 1
    _sensor.collision_layer = 0
    var cs := CollisionShape3D.new()
    var box := BoxShape3D.new()
    var me := $Col as CollisionShape3D
    if me != null and me.shape is BoxShape3D:
        var s: Vector3 = (me.shape as BoxShape3D).size
        box.size = Vector3(s.x * 0.9, 0.4, s.z * 0.9)
        cs.position = Vector3(0, s.y * 0.5 + 0.2, 0)
    else:
        box.size = Vector3(2.0, 0.4, 2.0)
    cs.shape = box
    _sensor.add_child(cs)
    add_child(_sensor)
    _sensor.body_entered.connect(_on_stand)
    _sensor.body_exited.connect(_on_leave)


func _on_stand(body: Node) -> void:
    if body is CharacterBody3D and body.get_script() != null:
        _player_on_board = true
        if _mode == "toggle":
            _direction *= -1


func _on_leave(body: Node) -> void:
    if body is CharacterBody3D:
        _player_on_board = false


func _physics_process(delta: float) -> void:
    if not _active:
        return
    var target_y: float = position.y
    match _mode:
        "loop":
            target_y += _direction * _speed * delta
            if target_y >= _high:
                target_y = _high
                _direction = -1
            elif target_y <= _low:
                target_y = _low
                _direction = 1
        "toggle":
            target_y += _direction * _speed * delta
            target_y = clamp(target_y, _low, _high)
        "call":
            # Go up while player stands on us, return down when empty.
            if _player_on_board and position.y < _high:
                target_y = min(position.y + _speed * delta, _high)
            elif not _player_on_board and position.y > _low:
                target_y = max(position.y - _speed * delta, _low)
    var new_pos := position
    new_pos.y = target_y
    # AnimatableBody3D uses sync_to_physics by default — just assign
    # position and the physics server syncs the body on the next tick.
    position = new_pos
