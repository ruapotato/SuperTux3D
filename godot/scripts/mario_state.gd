extends RefCounted

# GDScript scaffolding of the decomp `struct MarioState` + action dispatch.
#
# Each tick, `update()` reads the latest input, runs the action handler loop
# (which may transition through multiple actions in one frame — that's how the
# decomp handles e.g. "land into walk", where act_jump_land immediately sets
# ACT_WALKING if the stick is held and re-enters the loop), and writes back a
# velocity + pose the owning CharacterBody3D applies to physics.
#
# The current action handlers are placeholders that reproduce the old capsule
# stub's behavior. They'll be replaced one-by-one with faithful ports of the
# decomp's mario_actions_*.c functions. The structure around them — the dispatch
# loop, action flags, prev_action tracking — already matches the decomp so
# ports are drop-in.

# ---- Action IDs (copied from sm64.h) -------------------------------------
# 9-bit action number + flags, layout matches decomp so bitwise checks port.
const ACT_FLAG_STATIONARY := 1 << 9
const ACT_FLAG_MOVING     := 1 << 10
const ACT_FLAG_AIR        := 1 << 11

const ACT_UNINITIALIZED := 0x00000000
const ACT_IDLE          := 0x0C400201
const ACT_WALKING       := 0x04000440
const ACT_JUMP          := 0x03000880
const ACT_FREEFALL      := 0x0100088C
const ACT_JUMP_LAND     := 0x04000470
const ACT_FREEFALL_LAND := 0x04000471
# TODO: populate more from sm64.h as we port corresponding action handlers.

# ---- Controller input (mirrors decomp's struct Controller / input flags) -
# For now a trivial shape — a 2D stick and a jump-this-frame flag. Real decomp
# has BUTTON_A_PRESSED, NONZERO_ANALOG, etc.; we'll grow into it.
var input_stick: Vector2 = Vector2.ZERO  # x: left/right, y: forward(-)/back(+)
var input_jump_pressed: bool = false
var input_camera_yaw: float = 0.0        # world yaw of camera forward, for stick→world

# ---- Mario state (subset of struct MarioState) ---------------------------
var action: int = ACT_UNINITIALIZED
var prev_action: int = ACT_UNINITIALIZED
var action_timer: int = 0                # frames since current action began
var action_arg: int = 0                  # per-action scratch (matches decomp)

var pos: Vector3 = Vector3.ZERO          # Godot world units
var vel: Vector3 = Vector3.ZERO          # Godot world units/sec
var forward_vel: float = 0.0             # horizontal speed; decomp uses this
var face_yaw: float = 0.0                # world yaw Mario is facing (radians)

var is_on_floor: bool = false            # populated by the caller each tick

# ---- Physics tuning (Godot units; will absorb decomp constants later) ----
const WALK_SPEED := 16.0
const JUMP_SPEED := 24.0
const GRAVITY := 70.0


func set_action(new_action: int, arg: int = 0) -> bool:
    # Decomp semantic: returns TRUE so callers can `return set_mario_action(...)`
    # and drop out of their handler, letting the dispatch loop re-enter with the
    # new action on the same frame.
    prev_action = action
    action = new_action
    action_timer = 0
    action_arg = arg
    return true


func step(delta: float) -> void:
    # Reset per-frame integration state and run the action dispatch loop.
    # The loop re-enters when an action handler calls set_action() + returns
    # TRUE, exactly like execute_mario_action() in mario.c. Capped to avoid
    # pathological transitions.
    if action == ACT_UNINITIALIZED:
        set_action(ACT_IDLE)

    var safety := 8
    while safety > 0:
        var changed := false
        match action:
            ACT_IDLE:
                changed = _act_idle(delta)
            ACT_WALKING:
                changed = _act_walking(delta)
            ACT_JUMP:
                changed = _act_jump(delta)
            ACT_FREEFALL:
                changed = _act_freefall(delta)
            ACT_JUMP_LAND, ACT_FREEFALL_LAND:
                # Simplified: instant return to idle/walking based on stick.
                if input_stick.length() > 0.1:
                    set_action(ACT_WALKING)
                    changed = true
                else:
                    set_action(ACT_IDLE)
                    changed = true
            _:
                # Unknown action — fall back to idle so we don't stall.
                set_action(ACT_IDLE)
                changed = true
        if not changed:
            break
        safety -= 1
    action_timer += 1


# ---- Action handlers (stub implementations) ------------------------------
# Each returns TRUE if the action changed (re-enter dispatch), FALSE otherwise.
# TODO: replace each body with a port of the decomp's equivalent function.

func _act_idle(delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() > 0.1:
        return set_action(ACT_WALKING)
    vel.x = 0.0
    vel.z = 0.0
    vel.y = -1.0  # small snap pull onto the floor
    return false


func _act_walking(delta: float) -> bool:
    if not is_on_floor:
        return set_action(ACT_FREEFALL)
    if input_jump_pressed:
        return set_action(ACT_JUMP)
    if input_stick.length() <= 0.1:
        return set_action(ACT_IDLE)
    var dir := _stick_to_world_dir()
    if dir.length() > 0.001:
        # face_yaw is applied as a rotation around Y to the ActorAnchor. The
        # mesh's "forward" (after the loader's axis remap) points at Godot -Z
        # at yaw=0, so to face direction `dir` we need the rotation that
        # takes -Z to dir — that's atan2(-dir.x, -dir.z).
        face_yaw = atan2(-dir.x, -dir.z)
    vel.x = dir.x * WALK_SPEED
    vel.z = dir.z * WALK_SPEED
    vel.y = -1.0
    return false


func _act_jump(delta: float) -> bool:
    if action_timer == 0:
        vel.y = JUMP_SPEED
    var dir := _stick_to_world_dir()
    # Airborne momentum: stick nudges horizontal velocity, doesn't set it.
    vel.x = dir.x * WALK_SPEED
    vel.z = dir.z * WALK_SPEED
    vel.y -= GRAVITY * delta
    if vel.y <= 0.0:
        return set_action(ACT_FREEFALL)
    return false


func _act_freefall(delta: float) -> bool:
    var dir := _stick_to_world_dir()
    vel.x = dir.x * WALK_SPEED
    vel.z = dir.z * WALK_SPEED
    vel.y -= GRAVITY * delta
    if is_on_floor:
        # Convert to moving-land if the stick is held, else stationary-land.
        if input_stick.length() > 0.1:
            return set_action(ACT_FREEFALL_LAND)
        return set_action(ACT_FREEFALL_LAND)
    return false


# ---- Helpers -------------------------------------------------------------

func _stick_to_world_dir() -> Vector3:
    # Camera-relative stick → world direction.
    # - input_camera_yaw is the yaw of camera-forward; yaw=0 means camera
    #   looks along world -Z (Godot forward).
    #   camera forward = (-sin(yaw), 0, -cos(yaw))
    #   camera right   = ( cos(yaw), 0, -sin(yaw))
    # - Input sign: stick.y < 0 means the player pressed "forward" (WASD
    #   move_back - move_forward). We want press-forward to move along
    #   camera forward, so we scale forward by (-stick.y).
    if input_stick.length() < 0.001:
        return Vector3.ZERO
    var cy := cos(input_camera_yaw)
    var sy := sin(input_camera_yaw)
    var forward := Vector3(-sy, 0.0, -cy)
    var right := Vector3(cy, 0.0, -sy)
    var world := right * input_stick.x + forward * (-input_stick.y)
    return world.normalized()
