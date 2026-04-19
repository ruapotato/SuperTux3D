extends Node3D

# Tiny animation for coin/star/cap pickups — they spin on Y and bob
# vertically so the world feels alive even without the decomp's full
# pickup behavior code. The pickup_kind meta tag on the Area3D parent
# is untouched so Mario's sensor still finds us on touch.

@export var spin_speed: float = 3.5      # radians/sec
@export var bob_amplitude: float = 0.12  # world units
@export var bob_speed: float = 2.2       # cycles/sec (in radians)

var _time: float = randf() * TAU
var _base_y: float = 0.0


func _ready() -> void:
    _base_y = position.y


func _process(delta: float) -> void:
    _time += delta
    rotation.y += spin_speed * delta
    position.y = _base_y + sin(_time * bob_speed) * bob_amplitude
