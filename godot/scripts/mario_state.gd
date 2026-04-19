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

const ACT_UNINITIALIZED          := 0x00000000
const ACT_IDLE                   := 0x0C400201
const ACT_CROUCHING              := 0x0C008220
const ACT_JUMP_LAND_STOP         := 0x0C000230
const ACT_DOUBLE_JUMP_LAND_STOP  := 0x0C000231
const ACT_FREEFALL_LAND_STOP     := 0x0C000232
const ACT_SIDE_FLIP_LAND_STOP    := 0x0C000233
const ACT_BACKFLIP_LAND_STOP     := 0x0800022F
const ACT_TRIPLE_JUMP_LAND_STOP  := 0x0800023A
const ACT_LONG_JUMP_LAND_STOP    := 0x0800023B
const ACT_GROUND_POUND_LAND      := 0x0080023C
const ACT_BRAKING_STOP           := 0x0C00023D
const ACT_WALKING                := 0x04000440
const ACT_BRAKING                := 0x04000445
const ACT_TURNING_AROUND         := 0x00000443
const ACT_DIVE_SLIDE             := 0x00880456
const ACT_CROUCH_SLIDE           := 0x04808459
const ACT_JUMP_LAND              := 0x04000470
const ACT_FREEFALL_LAND          := 0x04000471
const ACT_DOUBLE_JUMP_LAND       := 0x04000472
const ACT_SIDE_FLIP_LAND         := 0x04000473
const ACT_TRIPLE_JUMP_LAND       := 0x04000478
const ACT_LONG_JUMP_LAND         := 0x00000479
const ACT_BACKFLIP_LAND          := 0x0400047A
const ACT_JUMP                   := 0x03000880
const ACT_DOUBLE_JUMP            := 0x03000881
const ACT_TRIPLE_JUMP            := 0x01000882
const ACT_BACKFLIP               := 0x01000883
const ACT_WALL_KICK_AIR          := 0x03000886
const ACT_SIDE_FLIP              := 0x01000887
const ACT_LONG_JUMP              := 0x03000888
const ACT_DIVE                   := 0x0188088A
const ACT_FREEFALL               := 0x0100088C
const ACT_GROUND_POUND           := 0x008008A9
const ACT_PUNCHING               := 0x00800380

# ---- Animation IDs (from include/mario_animation_ids.h) -----------------
const MARIO_ANIM_BACKFLIP                    := 0x04
const MARIO_ANIM_A_POSE                      := 0x0E
const MARIO_ANIM_SKID_ON_GROUND              := 0x0F
const MARIO_ANIM_STOP_SKID                   := 0x10
const MARIO_ANIM_CROUCH_FROM_FAST_LONGJUMP   := 0x11
const MARIO_ANIM_FAST_LONGJUMP               := 0x13
const MARIO_ANIM_SLOW_LONGJUMP               := 0x14
const MARIO_ANIM_GROUND_POUND_LANDING        := 0x3A
const MARIO_ANIM_GROUND_POUND                := 0x3D
const MARIO_ANIM_WALKING                     := 0x48
const MARIO_ANIM_SINGLE_JUMP                 := 0x4D
const MARIO_ANIM_LAND_FROM_SINGLE_JUMP       := 0x4E
const MARIO_ANIM_AIR_KICK                    := 0x4F
const MARIO_ANIM_DOUBLE_JUMP_RISE            := 0x50
const MARIO_ANIM_DOUBLE_JUMP_FALL            := 0x4C
const MARIO_ANIM_LAND_FROM_DOUBLE_JUMP       := 0x4B
const MARIO_ANIM_GENERAL_FALL                := 0x56
const MARIO_ANIM_GENERAL_LAND                := 0x57
const MARIO_ANIM_FIRST_PUNCH                 := 0x67
const MARIO_ANIM_SECOND_PUNCH                := 0x68
const MARIO_ANIM_RUNNING                     := 0x72
const MARIO_ANIM_SIDESTEP_LEFT               := 0x7F
const MARIO_ANIM_SIDESTEP_RIGHT              := 0x80
const MARIO_ANIM_DIVE                        := 0x88
const MARIO_ANIM_SLIDE_KICK                  := 0x8C
const MARIO_ANIM_CROUCHING                   := 0x98
const MARIO_ANIM_TRIPLE_JUMP                 := 0xC1
const MARIO_ANIM_TRIPLE_JUMP_LAND            := 0xC0
const MARIO_ANIM_IDLE_HEAD_LEFT              := 0xC3
const MARIO_ANIM_IDLE_HEAD_RIGHT             := 0xC4
const MARIO_ANIM_IDLE_HEAD_CENTER            := 0xC5

# ---- Physics tuning (Godot units, derived from decomp per-frame values) -
# Decomp numbers were in units/frame at 30 fps; converted to Godot units/sec
# via * 30 * WORLD_SCALE (WORLD_SCALE = 0.01). Values commented inline.
const GRAVITY              := 36.0
const TERMINAL_VEL         := -22.5
const WALK_MAX_VEL         := 9.6
const RUN_MAX_VEL          := 14.4
const WALK_ACCEL           := 18.0
const BRAKE_DECEL          := 45.0
const IDLE_FRICTION        := 30.0
const AIR_STEERING         := 6.0
const JUMP_IMPULSE         := 12.6    # single jump (decomp 42/frame)
const DOUBLE_JUMP_IMPULSE  := 15.6    # decomp 52/frame
const TRIPLE_JUMP_IMPULSE  := 20.7    # decomp 69/frame
const BACKFLIP_IMPULSE     := 18.6    # decomp 62/frame
const LONG_JUMP_IMPULSE    := 8.4     # decomp 28/frame (flatter arc)
const LONG_JUMP_FORWARD    := 16.8    # long-jump preserved horizontal
const SIDE_FLIP_IMPULSE    := 18.0
const WALL_KICK_IMPULSE    := 18.0
const DIVE_IMPULSE_Y       := 4.8     # small up-kick on dive
const DIVE_IMPULSE_FWD     := 14.4
const GROUND_POUND_SPEED   := -22.5   # snap terminal on pound
const TURN_RATE            := 12.0

# Walking vs running threshold: if forward_vel exceeds this, use RUNNING anim.
const RUN_ANIM_THRESHOLD := 8.0

# ---- Controller input ----------------------------------------------------
var input_stick: Vector2 = Vector2.ZERO
var input_jump_pressed: bool = false
var input_crouch: bool = false           # held
var input_crouch_pressed: bool = false   # this frame
var input_attack_pressed: bool = false   # this frame (dive/punch)
var input_camera_yaw: float = 0.0
# Double/triple jump chain — we count consecutive landings that happen
# while still holding forward momentum. Reset on long pause or stop.
var jump_combo: int = 0
var jump_combo_timer: float = 0.0
# Signal from the owning CharacterBody3D: did we bump a wall this frame?
var is_on_wall: bool = false
var wall_normal: Vector3 = Vector3.ZERO
# Active power cap (from owner): "wing" gives reduced gravity + extra air
# time, "metal" makes Mario impervious and slightly slower, "vanish"
# currently cosmetic only.
var power_cap: String = ""

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
    if jump_combo_timer > 0.0:
        jump_combo_timer = max(jump_combo_timer - delta, 0.0)
        if jump_combo_timer == 0.0:
            jump_combo = 0

    var safety := 8
    while safety > 0:
        var changed := false
        match action:
            ACT_IDLE:                     changed = _act_idle(delta)
            ACT_WALKING:                  changed = _act_walking(delta)
            ACT_BRAKING:                  changed = _act_braking(delta)
            ACT_CROUCHING:                changed = _act_crouching(delta)
            ACT_CROUCH_SLIDE:             changed = _act_crouch_slide(delta)
            ACT_PUNCHING:                 changed = _act_punching(delta)
            ACT_JUMP:                     changed = _act_jump(delta)
            ACT_DOUBLE_JUMP:              changed = _act_double_jump(delta)
            ACT_TRIPLE_JUMP:              changed = _act_triple_jump(delta)
            ACT_BACKFLIP:                 changed = _act_backflip(delta)
            ACT_SIDE_FLIP:                changed = _act_side_flip(delta)
            ACT_LONG_JUMP:                changed = _act_long_jump(delta)
            ACT_WALL_KICK_AIR:            changed = _act_wall_kick(delta)
            ACT_DIVE:                     changed = _act_dive(delta)
            ACT_DIVE_SLIDE:               changed = _act_dive_slide(delta)
            ACT_GROUND_POUND:             changed = _act_ground_pound(delta)
            ACT_GROUND_POUND_LAND:        changed = _act_ground_pound_land(delta)
            ACT_FREEFALL:                 changed = _act_freefall(delta)
            ACT_JUMP_LAND:                changed = _act_jump_land(delta)
            ACT_DOUBLE_JUMP_LAND:         changed = _act_jump_land(delta)
            ACT_TRIPLE_JUMP_LAND:         changed = _act_jump_land(delta)
            ACT_LONG_JUMP_LAND:           changed = _act_jump_land(delta)
            ACT_BACKFLIP_LAND:            changed = _act_jump_land(delta)
            ACT_SIDE_FLIP_LAND:           changed = _act_jump_land(delta)
            ACT_FREEFALL_LAND:            changed = _act_freefall_land(delta)
            ACT_JUMP_LAND_STOP:           changed = _act_jump_land_stop(delta)
            ACT_DOUBLE_JUMP_LAND_STOP:    changed = _act_jump_land_stop(delta)
            ACT_TRIPLE_JUMP_LAND_STOP:    changed = _act_jump_land_stop(delta)
            ACT_LONG_JUMP_LAND_STOP:      changed = _act_jump_land_stop(delta)
            ACT_BACKFLIP_LAND_STOP:       changed = _act_jump_land_stop(delta)
            ACT_SIDE_FLIP_LAND_STOP:      changed = _act_jump_land_stop(delta)
            ACT_BRAKING_STOP:             changed = _act_jump_land_stop(delta)
            ACT_FREEFALL_LAND_STOP:       changed = _act_freefall_land_stop(delta)
            _:                            changed = set_action(ACT_IDLE)
        if not changed:
            break
        safety -= 1
    action_timer += 1


# ---- Actions ------------------------------------------------------------

func _act_idle(_delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        # Standing jump: backflip if crouching held, else single jump.
        if input_crouch:
            return _begin_backflip()
        return _begin_single_jump()
    if input_crouch_pressed:
        return set_action(ACT_CROUCHING)
    if input_attack_pressed:
        return set_action(ACT_PUNCHING)
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
        # Long jump: crouch while moving + jump. Otherwise the jump
        # variant depends on the ongoing jump_combo counter.
        if input_crouch:
            return _begin_long_jump()
        if jump_combo >= 2 and forward_vel > RUN_ANIM_THRESHOLD:
            return _begin_triple_jump()
        if jump_combo >= 1:
            return _begin_double_jump()
        return _begin_single_jump()
    if input_crouch_pressed:
        if forward_vel > 4.0:
            return set_action(ACT_CROUCH_SLIDE)
        return set_action(ACT_CROUCHING)
    if input_attack_pressed:
        if forward_vel > 8.0:
            return _begin_slide_kick()
        return set_action(ACT_PUNCHING)
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
    _request_anim(MARIO_ANIM_SINGLE_JUMP, 1.0)
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_JUMP_LAND)


func _act_double_jump(delta: float) -> bool:
    if vel.y > 0:
        _request_anim(MARIO_ANIM_DOUBLE_JUMP_RISE, 1.0)
    else:
        _request_anim(MARIO_ANIM_DOUBLE_JUMP_FALL, 1.0)
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_DOUBLE_JUMP_LAND)


func _act_triple_jump(delta: float) -> bool:
    _request_anim(MARIO_ANIM_TRIPLE_JUMP, 1.0)
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_TRIPLE_JUMP_LAND)


func _act_backflip(delta: float) -> bool:
    _request_anim(MARIO_ANIM_BACKFLIP, 1.0)
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_BACKFLIP_LAND)


func _act_side_flip(delta: float) -> bool:
    _request_anim(MARIO_ANIM_TRIPLE_JUMP, 1.3)  # reuse triple flip anim
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_SIDE_FLIP_LAND)


func _act_long_jump(delta: float) -> bool:
    _request_anim(MARIO_ANIM_FAST_LONGJUMP, 1.0)
    _apply_air_motion(delta, false)   # long jump preserves horizontal momentum
    return _common_air_transitions(ACT_LONG_JUMP_LAND)


func _act_wall_kick(delta: float) -> bool:
    _request_anim(MARIO_ANIM_SINGLE_JUMP, 1.0)
    _apply_air_motion(delta)
    return _common_air_transitions(ACT_JUMP_LAND)


func _act_dive(delta: float) -> bool:
    _request_anim(MARIO_ANIM_DIVE, 1.2)
    _apply_air_motion(delta, false)
    if is_on_floor:
        return set_action(ACT_DIVE_SLIDE)
    return false


func _act_dive_slide(delta: float) -> bool:
    _request_anim(MARIO_ANIM_SLIDE_KICK, 0.6)
    forward_vel = max(forward_vel - BRAKE_DECEL * delta, 0.0)
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    vel.y = -1.0
    if forward_vel <= 0.1:
        return set_action(ACT_IDLE)
    return false


func _act_ground_pound(delta: float) -> bool:
    _request_anim(MARIO_ANIM_GROUND_POUND, 1.0)
    if action_timer < 10:
        vel.y = 0.0   # brief spin in place
        vel.x = 0.0
        vel.z = 0.0
    else:
        vel.y = GROUND_POUND_SPEED
        vel.x = 0.0
        vel.z = 0.0
    if is_on_floor and action_timer > 10:
        return set_action(ACT_GROUND_POUND_LAND)
    return false


func _act_ground_pound_land(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_GROUND_POUND_LANDING, 1.0)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    if input_jump_pressed:
        return _begin_single_jump()
    if anim_at_end or action_timer > 12:
        return set_action(ACT_IDLE)
    return false


func _act_punching(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_FIRST_PUNCH, 1.5)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    forward_vel = 0.0
    if anim_at_end or action_timer > 8:
        return set_action(ACT_IDLE)
    return false


func _act_crouching(_delta: float) -> bool:
    _request_anim(MARIO_ANIM_CROUCHING, 1.0)
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return _begin_backflip()
    if not input_crouch:
        return set_action(ACT_IDLE)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0
    forward_vel = 0.0
    return false


func _act_crouch_slide(delta: float) -> bool:
    _request_anim(MARIO_ANIM_CROUCHING, 1.0)
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return _begin_long_jump()
    forward_vel = max(forward_vel - BRAKE_DECEL * 0.5 * delta, 0.0)
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    vel.y = -1.0
    if forward_vel <= 0.5:
        if input_crouch:
            return set_action(ACT_CROUCHING)
        return set_action(ACT_IDLE)
    return false


func _act_freefall(delta: float) -> bool:
    _request_anim(MARIO_ANIM_GENERAL_FALL, 1.0)
    _apply_air_motion(delta)
    if input_crouch_pressed:
        return set_action(ACT_GROUND_POUND)
    if input_attack_pressed:
        return _begin_dive()
    if is_on_wall and input_jump_pressed:
        return _begin_wall_kick()
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

func _apply_air_motion(delta: float, allow_steering: bool = true) -> void:
    if allow_steering:
        var stick_dir := _stick_to_world_dir()
        if stick_dir.length() > 0.01:
            vel.x = move_toward(vel.x, stick_dir.x * WALK_MAX_VEL, AIR_STEERING * delta)
            vel.z = move_toward(vel.z, stick_dir.z * WALK_MAX_VEL, AIR_STEERING * delta)
    var g := GRAVITY
    if power_cap == "wing":
        # Wing cap: lets you float — roughly quarter gravity and a more
        # generous terminal velocity, matching SM64's wing-cap feel.
        g *= 0.25
        if input_jump_pressed and vel.y < 6.0:
            vel.y = min(vel.y + 8.0, 10.0)  # re-press to flap higher
    elif power_cap == "metal":
        g *= 1.15   # metal Mario falls a bit faster
    vel.y -= g * delta
    var term := TERMINAL_VEL
    if power_cap == "wing":
        term = -6.0
    if vel.y < term:
        vel.y = term


# ---- Airborne transition helpers ---------------------------------------

func _common_air_transitions(default_land: int) -> bool:
    if input_crouch_pressed:
        return set_action(ACT_GROUND_POUND)
    if input_attack_pressed:
        return _begin_dive()
    if is_on_wall and input_jump_pressed:
        return _begin_wall_kick()
    # Only promote to FREEFALL once we're clearly past the peak AND a few
    # frames have elapsed. Too tight a threshold makes the jump anim snap
    # to the fall anim mid-rise because vel.y ticks through zero briefly.
    if vel.y < -2.0 and action != ACT_FREEFALL and action_timer > 6:
        return set_action(ACT_FREEFALL)
    # Only register a landing when we're clearly airborne before touching
    # down — without the grace window a just-launched jump would read
    # as a land on the spawn frame (is_on_floor is true before the first
    # move_and_slide applies the upward velocity).
    if is_on_floor and action_timer > 4 and vel.y <= 0.0:
        return set_action(default_land)
    return false


# ---- Jump initiators ---------------------------------------------------

func _begin_single_jump() -> bool:
    set_action(ACT_JUMP)
    vel.y = JUMP_IMPULSE
    # Starting a new jump continues the combo if we were on the ground
    # briefly (the "you have a window" feel of SM64 chain-jumps).
    jump_combo = 1
    jump_combo_timer = 0.5
    return true


func _begin_double_jump() -> bool:
    set_action(ACT_DOUBLE_JUMP)
    vel.y = DOUBLE_JUMP_IMPULSE
    jump_combo = 2
    jump_combo_timer = 0.5
    return true


func _begin_triple_jump() -> bool:
    set_action(ACT_TRIPLE_JUMP)
    vel.y = TRIPLE_JUMP_IMPULSE
    jump_combo = 0
    jump_combo_timer = 0.0
    return true


func _begin_backflip() -> bool:
    set_action(ACT_BACKFLIP)
    vel.y = BACKFLIP_IMPULSE
    # Kick backward relative to current facing.
    forward_vel = -6.0
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    jump_combo = 0
    return true


func _begin_long_jump() -> bool:
    set_action(ACT_LONG_JUMP)
    vel.y = LONG_JUMP_IMPULSE
    forward_vel = LONG_JUMP_FORWARD
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    jump_combo = 0
    return true


func _begin_wall_kick() -> bool:
    set_action(ACT_WALL_KICK_AIR)
    vel.y = WALL_KICK_IMPULSE
    # Push off the wall in the opposite direction of its normal.
    if wall_normal.length() > 0.01:
        var off := wall_normal.normalized()
        vel.x = off.x * RUN_MAX_VEL * 0.8
        vel.z = off.z * RUN_MAX_VEL * 0.8
        face_yaw = atan2(-off.x, -off.z)
    return true


func _begin_dive() -> bool:
    set_action(ACT_DIVE)
    vel.y = DIVE_IMPULSE_Y
    forward_vel = DIVE_IMPULSE_FWD
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    return true


func _begin_slide_kick() -> bool:
    set_action(ACT_DIVE_SLIDE)
    forward_vel = max(forward_vel, 12.0)
    vel.x = -sin(face_yaw) * forward_vel
    vel.z = -cos(face_yaw) * forward_vel
    vel.y = 2.0  # small hop
    return true


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
