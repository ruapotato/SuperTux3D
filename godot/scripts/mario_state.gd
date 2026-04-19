extends RefCounted

# Decomp-style Mario state machine. Mirrors the `struct MarioState` + action
# dispatch in mario.c and ports a core subset of the mario_actions_*.c files:
#   stationary: ACT_IDLE (3-anim head cycle), ACT_JUMP_LAND_STOP, ACT_FREEFALL_LAND_STOP
#   moving:     ACT_WALKING (forward_vel accum), ACT_BRAKING (skid),
#               ACT_JUMP_LAND, ACT_FREEFALL_LAND
#   airborne:   ACT_JUMP, ACT_FREEFALL
#
# Physics constants live in Godot units (see LevelLoader.WORLD_SCALE = 0.01)
# but were derived from the decomp's per-frame values at 30 fps. Keeping
# these as explicit numbers with a short comment beats hardcoding magic.
#
# Animations are addressed by decomp ID (MARIO_ANIM_*). The owning
# CharacterBody3D is responsible for resolving them via the animator.
# Each action sets `requested_anim` + `requested_anim_speed` and the
# outer driver loads/plays that animation.

# ---- Action IDs (from include/sm64.h) -----------------------------------
const ACT_FLAG_STATIONARY := 1 << 9
const ACT_FLAG_MOVING     := 1 << 10
const ACT_FLAG_AIR        := 1 << 11

const ACT_UNINITIALIZED        := 0x00000000
const ACT_IDLE                 := 0x0C400201
const ACT_JUMP_LAND_STOP       := 0x0C000230
const ACT_FREEFALL_LAND_STOP   := 0x0C000232
const ACT_WALKING              := 0x04000440
const ACT_BRAKING              := 0x04000445
const ACT_JUMP_LAND            := 0x04000470
const ACT_FREEFALL_LAND        := 0x04000471
const ACT_TURNING_AROUND       := 0x00000443
const ACT_JUMP                 := 0x03000880
const ACT_FREEFALL             := 0x0100088C

# ---- Animation IDs (from include/mario_animation_ids.h) -----------------
const MARIO_ANIM_A_POSE                  := 0x0E
const MARIO_ANIM_SKID_ON_GROUND          := 0x0F
const MARIO_ANIM_STOP_SKID               := 0x10
const MARIO_ANIM_WALKING                 := 0x48
const MARIO_ANIM_SINGLE_JUMP             := 0x4D
const MARIO_ANIM_LAND_FROM_SINGLE_JUMP   := 0x4E
const MARIO_ANIM_GENERAL_FALL            := 0x56
const MARIO_ANIM_GENERAL_LAND            := 0x57
const MARIO_ANIM_RUNNING                 := 0x72
const MARIO_ANIM_IDLE_HEAD_LEFT          := 0xC3
const MARIO_ANIM_IDLE_HEAD_RIGHT         := 0xC4
const MARIO_ANIM_IDLE_HEAD_CENTER        := 0xC5

# ---- Physics tuning (Godot units, derived from decomp per-frame values) -
# Decomp numbers were in units/frame at 30 fps; converted to Godot units/sec
# via * 30 * WORLD_SCALE (WORLD_SCALE = 0.01). Values commented inline.
const GRAVITY         := 36.0   # decomp -4/frame² → 4 * 30² * 0.01
const TERMINAL_VEL    := -22.5  # decomp -75/frame → -75 * 30 * 0.01
const WALK_MAX_VEL    := 9.6    # decomp 32/frame
const RUN_MAX_VEL     := 14.4   # decomp 48/frame
const WALK_ACCEL      := 18.0   # ~1 decomp unit/frame/frame
const BRAKE_DECEL     := 45.0   # skid deceleration
const IDLE_FRICTION   := 30.0   # stops Mario on no input
const AIR_STEERING    := 6.0    # how much air momentum input can shift per sec
const JUMP_IMPULSE    := 12.6   # decomp 42/frame * 30 * 0.01
const TURN_RATE       := 12.0   # rad/sec horizontal turning while walking

# Walking vs running threshold: if forward_vel exceeds this, use RUNNING anim.
const RUN_ANIM_THRESHOLD := 8.0

# ---- Controller input ----------------------------------------------------
var input_stick: Vector2 = Vector2.ZERO
var input_jump_pressed: bool = false
var input_camera_yaw: float = 0.0

# ---- Mario state (subset of struct MarioState) --------------------------
var action: int = ACT_UNINITIALIZED
var prev_action: int = ACT_UNINITIALIZED
var action_state: int = 0           # sub-state within an action (decomp's actionState)
var action_timer: int = 0           # frames elapsed in current action
var action_arg: int = 0

var pos: Vector3 = Vector3.ZERO
var vel: Vector3 = Vector3.ZERO
var forward_vel: float = 0.0        # horizontal speed along face_yaw
var face_yaw: float = 0.0           # world yaw Mario is facing (radians)

var is_on_floor: bool = false
var anim_at_end: bool = false       # fed in from animator each tick

# ---- Animation request (outer driver consumes these each tick) -----------
# requested_anim = -1 means "don't change"; otherwise it's a decomp ID.
var requested_anim: int = -1
var requested_anim_speed: float = 1.0
var requested_anim_reset: bool = false  # true → rewind even if ID unchanged
var _last_requested_anim: int = -1


func set_action(new_action: int, arg: int = 0) -> bool:
    prev_action = action
    action = new_action
    action_state = 0
    action_timer = 0
    action_arg = arg
    return true


func step(delta: float) -> void:
    if action == ACT_UNINITIALIZED:
        set_action(ACT_IDLE)
    requested_anim = -1
    requested_anim_reset = false

    # Decomp-style dispatch loop: actions can transition on the same tick by
    # returning true from set_action. Capped to avoid infinite loops.
    var safety := 8
    while safety > 0:
        var changed := false
        match action:
            ACT_IDLE:                changed = _act_idle(delta)
            ACT_WALKING:             changed = _act_walking(delta)
            ACT_BRAKING:             changed = _act_braking(delta)
            ACT_JUMP:                changed = _act_jump(delta)
            ACT_FREEFALL:            changed = _act_freefall(delta)
            ACT_JUMP_LAND:           changed = _act_jump_land(delta)
            ACT_FREEFALL_LAND:       changed = _act_freefall_land(delta)
            ACT_JUMP_LAND_STOP:      changed = _act_jump_land_stop(delta)
            ACT_FREEFALL_LAND_STOP:  changed = _act_freefall_land_stop(delta)
            _:                       changed = set_action(ACT_IDLE)
        if not changed:
            break
        safety -= 1
    action_timer += 1


# ---- Actions ------------------------------------------------------------

func _act_idle(_delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        forward_vel = 0.0
        return set_action(ACT_WALKING)
    # Cycle through HEAD_LEFT → HEAD_RIGHT → HEAD_CENTER like the decomp.
    match action_state:
        0: _request_anim(MARIO_ANIM_IDLE_HEAD_LEFT, 1.0)
        1: _request_anim(MARIO_ANIM_IDLE_HEAD_RIGHT, 1.0)
        _: _request_anim(MARIO_ANIM_IDLE_HEAD_CENTER, 1.0)
    if anim_at_end:
        action_state = (action_state + 1) % 3
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0  # slope-snap pull
    forward_vel = 0.0
    return false


func _act_walking(delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    var stick_mag: float = input_stick.length()
    if stick_mag <= 0.1:
        if forward_vel > RUN_ANIM_THRESHOLD * 0.5:
            return set_action(ACT_BRAKING)
        return set_action(ACT_IDLE)

    # Decomp-style: compute desired world direction from stick, face angle
    # turns toward it, forward_vel accelerates toward stick-scaled target.
    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.001:
        var target_yaw := atan2(-stick_dir.x, -stick_dir.z)
        face_yaw = _approach_angle(face_yaw, target_yaw, TURN_RATE * delta)
    var target_vel: float = stick_mag * WALK_MAX_VEL
    # Let the player push past WALK_MAX toward RUN_MAX by holding at full.
    # Actual decomp uses a different curve; this is an approximation that
    # still crosses into running territory.
    if stick_mag > 0.95:
        target_vel = RUN_MAX_VEL
    if forward_vel < target_vel:
        forward_vel = min(forward_vel + WALK_ACCEL * delta, target_vel)
    else:
        forward_vel = max(forward_vel - WALK_ACCEL * delta, target_vel)

    # Apply horizontal velocity along face_yaw.
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    vel.y = -1.0

    if forward_vel >= RUN_ANIM_THRESHOLD:
        _request_anim(MARIO_ANIM_RUNNING, _speed_scale(forward_vel, RUN_MAX_VEL))
    else:
        _request_anim(MARIO_ANIM_WALKING, _speed_scale(forward_vel, WALK_MAX_VEL))
    return false


func _act_braking(delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    _request_anim(MARIO_ANIM_SKID_ON_GROUND, 1.0)
    forward_vel = max(forward_vel - BRAKE_DECEL * delta, 0.0)
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    vel.y = -1.0
    if forward_vel <= 0.1:
        return set_action(ACT_IDLE)
    # If the player pushes stick in a new direction hard, let them redirect.
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    return false


func _act_jump(delta: float) -> bool:
    if action_timer == 0:
        vel.y = JUMP_IMPULSE
    _request_anim(MARIO_ANIM_SINGLE_JUMP, 1.0)
    _apply_air_motion(delta)
    if vel.y <= 0.0:
        return set_action(ACT_FREEFALL)
    if is_on_floor and action_timer > 2:
        return set_action(ACT_JUMP_LAND)
    return false


func _act_freefall(delta: float) -> bool:
    _request_anim(MARIO_ANIM_GENERAL_FALL, 1.0)
    _apply_air_motion(delta)
    if is_on_floor:
        return set_action(ACT_FREEFALL_LAND)
    return false


func _act_jump_land(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_LAND_FROM_SINGLE_JUMP, 1.2)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    forward_vel = 0.0
    if anim_at_end or action_timer > 10:
        return set_action(ACT_JUMP_LAND_STOP)
    return false


func _act_freefall_land(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_GENERAL_LAND, 1.2)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    forward_vel = 0.0
    if anim_at_end or action_timer > 10:
        return set_action(ACT_FREEFALL_LAND_STOP)
    return false


func _act_jump_land_stop(_delta: float) -> bool:
    # "Stopped" landed state — behave like idle but hold the landing anim
    # through its end frame (matches decomp where Mario doesn't immediately
    # head-look after landing).
    _request_anim(MARIO_ANIM_LAND_FROM_SINGLE_JUMP, 1.0)
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    if action_timer > 6:
        return set_action(ACT_IDLE)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    return false


func _act_freefall_land_stop(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_GENERAL_LAND, 1.0)
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    if action_timer > 6:
        return set_action(ACT_IDLE)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    return false


# ---- Helpers ------------------------------------------------------------

func _apply_air_motion(delta: float) -> void:
    var stick_dir := _stick_to_world_dir()
    if stick_dir.length() > 0.01:
        vel.x = move_toward(vel.x, stick_dir.x * WALK_MAX_VEL, AIR_STEERING * delta)
        vel.z = move_toward(vel.z, stick_dir.z * WALK_MAX_VEL, AIR_STEERING * delta)
    vel.y -= GRAVITY * delta
    if vel.y < TERMINAL_VEL:
        vel.y = TERMINAL_VEL


func _stick_to_world_dir() -> Vector3:
    if input_stick.length() < 0.001:
        return Vector3.ZERO
    var cy := cos(input_camera_yaw)
    var sy := sin(input_camera_yaw)
    var forward := Vector3(-sy, 0.0, -cy)
    var right := Vector3(cy, 0.0, -sy)
    return (right * input_stick.x + forward * (-input_stick.y)).normalized()


func _speed_scale(current_speed: float, max_speed: float) -> float:
    # Map forward_vel → animation playback scale. At full speed, 1×; slow,
    # down to 0.5× so the feet don't look like they're running on ice.
    return clamp(0.5 + (current_speed / max_speed) * 0.7, 0.5, 1.8)


func _approach_angle(current: float, target: float, max_step: float) -> float:
    var diff := wrapf(target - current, -PI, PI)
    if abs(diff) <= max_step:
        return target
    return current + sign(diff) * max_step


func _request_anim(id: int, speed: float) -> void:
    requested_anim = id
    requested_anim_speed = speed
    requested_anim_reset = (id != _last_requested_anim)
    _last_requested_anim = id
