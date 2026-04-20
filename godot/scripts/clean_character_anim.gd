extends RefCounted

# Procedural animator for the clean-room character rig. Computes bone
# rotations per-frame from the current "action" and a time accumulator.
# Matches the mario_stub.gd/state-machine contract (play/set_speed/
# is_at_end/current_anim_id).
#
# The rig is a 7-bone skeleton exposed as Node3D children of a root
# anchor:
#   pelvis (root, bobs)
#     torso        — spine lean/twist
#       head       — nods and side-tilts
#       arm_l      — shoulder pivot
#       arm_r
#     leg_l        — hip pivot
#     leg_r
#
# Each "animation" is a GDScript function that reads the time cursor
# and returns per-bone Vector3 euler offsets. Applied on top of the
# rig's rest pose.

# The decomp animation IDs we honored in mario_state.gd — we map each
# to one of our procedural motion tags so we don't have to rewrite
# the state machine. Anything unmapped just plays "idle".
const ACTION_FOR_ANIM_ID := {
    # idle variants
    0xC3: "idle", 0xC4: "idle", 0xC5: "idle", 0x0E: "idle",
    # walking / running
    0x48: "walk", 0x72: "run",
    # skids
    0x0F: "skid", 0x10: "skid_stop",
    # jumps — ascending / descending / landing
    0x4D: "jump_rise", 0x4E: "jump_land",
    0x50: "double_jump_rise", 0x4C: "double_jump_fall", 0x4B: "double_jump_land",
    0xC1: "triple_jump", 0xC0: "triple_jump_land",
    # flips
    0x04: "backflip",
    0x13: "long_jump", 0x14: "long_jump", 0x11: "long_jump_crouch",
    # general air/land
    0x56: "freefall", 0x57: "freefall_land",
    # attacks (kept for dive + slide kick + air kick; punches resolve to a swing)
    0x4F: "air_kick", 0x67: "punch", 0x68: "punch",
    # side step
    0x7F: "sidestep", 0x80: "sidestep",
    # dive / slide
    0x88: "dive", 0x8C: "slide_kick",
    # crouch + ground pound
    0x98: "crouch", 0x3D: "ground_pound", 0x3A: "ground_pound_land",
    # swim
    0xAA: "swim", 0xAB: "swim", 0xAC: "flutterkick",
    # pole
    0x0D: "pole_idle", 0x05: "pole_climb", 0x06: "pole_grab",
}

# Actions whose motion ends and should NOT loop. The state machine
# watches is_at_end() to chain into the next action.
const ONE_SHOT_ACTIONS := {
    "jump_land": true, "double_jump_land": true, "triple_jump_land": true,
    "freefall_land": true, "skid_stop": true,
    "backflip": true, "long_jump": true, "long_jump_crouch": true,
    "air_kick": true, "punch": true, "dive": true, "slide_kick": true,
    "ground_pound": true, "ground_pound_land": true, "pole_grab": true,
}

# Rough frame budget per one-shot so is_at_end fires at a natural time.
const ONE_SHOT_DURATION := {
    "jump_land": 0.25, "double_jump_land": 0.30, "triple_jump_land": 0.40,
    "freefall_land": 0.25, "skid_stop": 0.35,
    "backflip": 1.0, "long_jump": 1.1, "long_jump_crouch": 0.3,
    "air_kick": 0.35, "punch": 0.30, "dive": 0.80, "slide_kick": 0.50,
    "ground_pound": 0.40, "ground_pound_land": 0.35, "pole_grab": 0.30,
}

var bones: Dictionary = {}       # name → Node3D
var rest_rotations: Dictionary = {}  # name → Vector3 (rest Euler)
var current_action: String = "idle"
var current_anim_id: int = -1     # echoes the ID mario_stub passed; -1 = none
var speed_multiplier: float = 1.0
var _time: float = 0.0
var _looped_this_tick: bool = false


func setup(bone_nodes: Dictionary) -> void:
    bones = bone_nodes
    for key in bones.keys():
        var n: Node3D = bones[key]
        if n != null:
            rest_rotations[key] = n.rotation


func play(anim_data: Variant, speed: float = 1.0, anim_id: int = -1) -> void:
    # anim_data is ignored (we don't replay decomp tracks). The ID
    # selects which procedural motion to run — tied to the MARIO_ANIM_*
    # constants that mario_state.gd emits.
    var action: String = ACTION_FOR_ANIM_ID.get(anim_id, "idle")
    if action != current_action:
        current_action = action
        _time = 0.0
        _looped_this_tick = false
    current_anim_id = anim_id
    speed_multiplier = speed


func set_speed(speed: float) -> void:
    speed_multiplier = speed


func is_at_end() -> bool:
    return _looped_this_tick


func stop() -> void:
    current_action = "idle"
    current_anim_id = -1


func debug_state() -> String:
    return "%s t=%.2f speed=%.2f" % [current_action, _time, speed_multiplier]


func tick(delta: float) -> void:
    _looped_this_tick = false
    var dt: float = delta * speed_multiplier
    # Clamp one-shots so they don't keep ticking once "done"; the state
    # machine usually transitions away on is_at_end anyway.
    var duration: float = ONE_SHOT_DURATION.get(current_action, 0.0)
    if ONE_SHOT_ACTIONS.get(current_action, false) and duration > 0.0:
        if _time < duration:
            _time += dt
            if _time >= duration:
                _looped_this_tick = true
    else:
        _time += dt
    _apply(current_action, _time)


# -- pose evaluation ---------------------------------------------------

func _apply(action: String, t: float) -> void:
    # Reset all bones to rest first; each action only sets the bones it
    # drives, avoiding leftover poses from the previous action.
    for key in bones.keys():
        var n: Node3D = bones[key]
        if n != null:
            n.rotation = rest_rotations.get(key, Vector3.ZERO)
    match action:
        "walk":        _pose_walk(t, 1.0)
        "run":         _pose_walk(t, 1.6)
        "skid":        _pose_skid(t)
        "skid_stop":   _pose_skid(t)
        "jump_rise":   _pose_jump_rise(t)
        "jump_land":   _pose_crouch(t * 2.0)
        "double_jump_rise": _pose_jump_rise(t, 0.15)
        "double_jump_fall": _pose_freefall(t)
        "double_jump_land": _pose_crouch(t * 2.0)
        "triple_jump":      _pose_flip(t, 1.4)
        "triple_jump_land": _pose_crouch(t * 2.0)
        "backflip":    _pose_flip(t, -1.6)
        "long_jump":   _pose_long_jump(t)
        "long_jump_crouch": _pose_crouch(t * 2.5)
        "freefall":    _pose_freefall(t)
        "freefall_land": _pose_crouch(t * 2.0)
        "air_kick":    _pose_air_kick(t)
        "punch":       _pose_punch(t)
        "dive":        _pose_dive(t)
        "slide_kick":  _pose_slide(t)
        "crouch", "ground_pound_land": _pose_crouch(t)
        "ground_pound": _pose_flip(t, 2.5)
        "sidestep":    _pose_walk(t, 0.6)
        "swim", "flutterkick": _pose_swim(t)
        "pole_idle":   _pose_pole(t, 0.0)
        "pole_climb":  _pose_pole(t, 1.0)
        "pole_grab":   _pose_pole(t, 0.0)
        _:             _pose_idle(t)


# Tiny breathing wobble in the idle pose so the character isn't frozen.
func _pose_idle(t: float) -> void:
    _rot(bones.get("torso"), Vector3(sin(t * 1.5) * 0.01, 0, 0))
    _rot(bones.get("head"),  Vector3(0, sin(t * 0.7) * 0.08, 0))


# Alternating legs + counter-swinging arms. Amplitude controlled so a
# walk vs run only differ in frequency + stride magnitude.
func _pose_walk(t: float, intensity: float) -> void:
    var freq: float = 6.0 * intensity
    var amp_leg: float = 0.55 * clamp(intensity, 0.5, 1.8)
    var amp_arm: float = 0.45 * clamp(intensity, 0.5, 1.8)
    var phase: float = sin(t * freq)
    var phase_b: float = sin(t * freq + PI)
    _rot(bones.get("leg_l"), Vector3(phase * amp_leg, 0, 0))
    _rot(bones.get("leg_r"), Vector3(phase_b * amp_leg, 0, 0))
    _rot(bones.get("arm_l"), Vector3(phase_b * amp_arm, 0, 0))
    _rot(bones.get("arm_r"), Vector3(phase * amp_arm, 0, 0))
    _rot(bones.get("torso"), Vector3(0, phase * 0.08, 0))
    _rot(bones.get("pelvis"), Vector3(0, 0, phase * 0.05))


func _pose_skid(t: float) -> void:
    # Lean back, arms out for balance.
    _rot(bones.get("torso"), Vector3(0.4, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.3, 0, -1.1))
    _rot(bones.get("arm_r"), Vector3(-0.3, 0, 1.1))
    _rot(bones.get("leg_l"), Vector3(-0.5, 0, 0))
    _rot(bones.get("leg_r"), Vector3(0.2, 0, 0))


func _pose_jump_rise(t: float, lean: float = 0.0) -> void:
    _rot(bones.get("arm_l"), Vector3(-2.0, 0, -0.4))
    _rot(bones.get("arm_r"), Vector3(-2.0, 0, 0.4))
    _rot(bones.get("leg_l"), Vector3(-0.4, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.7, 0, 0))
    _rot(bones.get("torso"), Vector3(-0.2 + lean, 0, 0))


func _pose_freefall(t: float) -> void:
    var sway: float = sin(t * 4.0) * 0.1
    _rot(bones.get("arm_l"), Vector3(-1.2 + sway, 0, -0.6))
    _rot(bones.get("arm_r"), Vector3(-1.2 - sway, 0, 0.6))
    _rot(bones.get("leg_l"), Vector3(-0.2 - sway, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.4 + sway, 0, 0))
    _rot(bones.get("torso"), Vector3(0.1, 0, 0))


# Flip: continuous rotation around the pelvis (not torso) so the legs
# go with the body. Rotating torso alone leaves the legs stuck since
# they're children of pelvis, not torso. Sign picks forward vs backward
# flip; magnitude >1 spins past a full flip.
func _pose_flip(t: float, rate: float) -> void:
    var angle: float = t * 7.0 * rate
    _rot(bones.get("pelvis"), Vector3(angle, 0, 0))
    _rot(bones.get("torso"), Vector3(0, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-2.3, 0, -0.3))
    _rot(bones.get("arm_r"), Vector3(-2.3, 0, 0.3))
    _rot(bones.get("leg_l"), Vector3(-0.6, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.6, 0, 0))


func _pose_long_jump(t: float) -> void:
    _rot(bones.get("torso"), Vector3(0.6, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-2.6, 0, -0.2))
    _rot(bones.get("arm_r"), Vector3(-2.6, 0, 0.2))
    _rot(bones.get("leg_l"), Vector3(-1.3, 0, 0))
    _rot(bones.get("leg_r"), Vector3(0.3, 0, 0))


func _pose_crouch(t: float) -> void:
    var depth: float = clamp(t, 0.0, 1.0)
    _rot(bones.get("torso"), Vector3(0.9 * depth, 0, 0))
    _rot(bones.get("pelvis"), Vector3(0, 0, 0))
    _rot(bones.get("leg_l"), Vector3(-0.9 * depth, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.9 * depth, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.3, 0, -0.4))
    _rot(bones.get("arm_r"), Vector3(-0.3, 0, 0.4))


func _pose_air_kick(t: float) -> void:
    var leg_swing: float = clamp(t * 4.0, 0.0, 1.0) * -1.6
    _rot(bones.get("leg_r"), Vector3(leg_swing, 0, 0))
    _rot(bones.get("leg_l"), Vector3(-0.4, 0, 0))
    _rot(bones.get("torso"), Vector3(0.3, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-0.6, 0, -1.2))
    _rot(bones.get("arm_r"), Vector3(-0.6, 0, 1.2))


func _pose_punch(t: float) -> void:
    var swing: float = sin(clamp(t / 0.3, 0, 1) * PI)
    _rot(bones.get("arm_r"), Vector3(-1.2 - swing * 1.0, 0, 0.1))
    _rot(bones.get("arm_l"), Vector3(-0.3, 0, -0.5))
    _rot(bones.get("torso"), Vector3(0, -swing * 0.4, 0))


func _pose_dive(t: float) -> void:
    _rot(bones.get("torso"), Vector3(1.3, 0, 0))
    _rot(bones.get("arm_l"), Vector3(-2.9, 0, -0.1))
    _rot(bones.get("arm_r"), Vector3(-2.9, 0, 0.1))
    _rot(bones.get("leg_l"), Vector3(0.2, 0, 0))
    _rot(bones.get("leg_r"), Vector3(0.2, 0, 0))


func _pose_slide(t: float) -> void:
    _rot(bones.get("torso"), Vector3(0.2, 0, -0.8))
    _rot(bones.get("arm_l"), Vector3(-1.4, 0, -0.5))
    _rot(bones.get("arm_r"), Vector3(-1.4, 0, 0.5))
    _rot(bones.get("leg_l"), Vector3(-0.9, 0, 0))
    _rot(bones.get("leg_r"), Vector3(0.1, 0, 0))


# Frog-kick swim: arms sweep back in opposition to legs kicking.
func _pose_swim(t: float) -> void:
    var phase: float = sin(t * 4.0)
    _rot(bones.get("torso"), Vector3(1.0, 0, phase * 0.15))
    _rot(bones.get("arm_l"), Vector3(-1.9, 0, -0.6 + phase * 0.4))
    _rot(bones.get("arm_r"), Vector3(-1.9, 0, 0.6 - phase * 0.4))
    _rot(bones.get("leg_l"), Vector3(-0.3 - phase * 0.4, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.3 + phase * 0.4, 0, 0))


func _pose_pole(t: float, climb: float) -> void:
    var shimmy: float = sin(t * 6.0) * climb * 0.3
    _rot(bones.get("arm_l"), Vector3(-2.7 + shimmy, 0, -0.15))
    _rot(bones.get("arm_r"), Vector3(-2.7 - shimmy, 0, 0.15))
    _rot(bones.get("leg_l"), Vector3(-0.25 + shimmy, 0, 0))
    _rot(bones.get("leg_r"), Vector3(-0.25 - shimmy, 0, 0))
    _rot(bones.get("torso"), Vector3(0.1, 0, 0))


static func _rot(node: Node3D, euler: Vector3) -> void:
    if node != null:
        node.rotation = euler
