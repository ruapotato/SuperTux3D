extends RefCounted

# Plays SM64 decomp animations on Mario's articulated skeleton.
#
# Animation format (from tools/convert_animation.py):
#   indices: [[num_frames, values_offset], ...] — 3 root-translation tracks
#            followed by 3 rotation tracks per bone.
#   values:  s16 samples, indexed by a track's offset + min(frame, nframes-1).
#
# Per frame t (0..loop_end-1):
#   rot_bone_b_xyz = [values[o + min(t, nf-1)] for (nf, o) in
#                     indices[3 + 3*b .. 3 + 3*b + 3]]
#   angles are s16 (65536 = 360°), applied as Euler XYZ relative to the
#   bone's rest translation. The bone's rest_rotation table is NOT applied
#   on top — the animation supplies the pose in full. (Rest rotations are
#   a hand-curated substitute for the zeroth animation frame so static
#   rigs look plausible; we skip them while an animation plays.)

var bones: Array = []              # Array[Node3D], indexed by bone index
var bone_rest_rotations: Array = []  # Array[Vector3] — rest rotation (radians, XYZ) from converter
var current_anim: Dictionary = {}
var current_anim_id: int = -1
var current_frame: float = 0.0
var _prev_frame: float = 0.0
var _looped_this_tick: bool = false

# Base playback speed in animation-frames per real second. Individual
# play() calls can override this via the `speed` argument; the decomp
# varies anim speed per action (walking scales with forward velocity,
# running uses fixed fast cadence, etc.).
var frames_per_second: float = 60.0
var speed_multiplier: float = 1.0


func setup(bone_nodes: Array, rest_rotations_rad: Array) -> void:
    bones = bone_nodes
    bone_rest_rotations = rest_rotations_rad


func play(anim: Dictionary, speed: float = 1.0, anim_id: int = -1) -> void:
    current_anim = anim
    current_anim_id = anim_id
    current_frame = float(anim.start_frame)
    _prev_frame = current_frame
    speed_multiplier = speed


func set_speed(speed: float) -> void:
    speed_multiplier = speed


func is_at_end() -> bool:
    # Returns true for the single tick after the animation rolled over its
    # loop_end. Mario actions use this to chain (e.g. IDLE cycling through
    # HEAD_LEFT → HEAD_RIGHT → HEAD_CENTER on anim end).
    return _looped_this_tick


func stop() -> void:
    current_anim = {}
    # Restore bones to their rest rotations.
    for i in range(bones.size()):
        var n: Node3D = bones[i]
        if n == null:
            continue
        if i < bone_rest_rotations.size():
            var r: Vector3 = bone_rest_rotations[i]
            n.basis = Basis.from_euler(r, EULER_ORDER_ZYX)


func tick(delta: float) -> void:
    if current_anim.is_empty():
        return
    _prev_frame = current_frame
    current_frame += delta * frames_per_second * speed_multiplier
    var loop_end: int = current_anim.loop_end
    var loop_start: int = current_anim.loop_start
    _looped_this_tick = false
    var no_loop: bool = (int(current_anim.flags) & 1) != 0
    if loop_end > loop_start:
        var span: float = float(loop_end - loop_start)
        if no_loop:
            # One-shot animations (dive, punch, backflip, single jump, …)
            # clamp at the last frame instead of wrapping. State machines
            # that want to transition on anim end watch is_at_end().
            if current_frame >= float(loop_end):
                current_frame = float(loop_end) - 1.0
                _looped_this_tick = true
        else:
            while current_frame >= float(loop_end):
                current_frame -= span
                _looped_this_tick = true
    else:
        _looped_this_tick = true
    _apply_frame(int(current_frame))


func debug_state() -> String:
    if current_anim.is_empty():
        return "(no anim)"
    return "%s frame=%.1f / %d" % [
        current_anim.name, current_frame, int(current_anim.loop_end),
    ]


func _apply_frame(frame: int) -> void:
    var indices: Array = current_anim.indices
    var values: Array = current_anim.values
    # Indices 0..2 are root X/Y/Z translation. We don't drive Mario's
    # position here — the state machine owns movement — so the root-trans
    # tracks are read but ignored for now. (Later we'll feed them into
    # the state machine as additive bobbing.)

    var bone_count: int = current_anim.bone_count
    # To_rad: s16 65536 = TAU
    var to_rad: float = TAU / 65536.0

    for b in range(min(bone_count, bones.size())):
        var base: int = 3 + 3 * b
        var rx: float = _sample_track(indices, values, base + 0, frame) * to_rad
        var ry: float = _sample_track(indices, values, base + 1, frame) * to_rad
        var rz: float = _sample_track(indices, values, base + 2, frame) * to_rad
        var n: Node3D = bones[b]
        if n == null:
            continue
        # EULER_ORDER_ZYX matches the decomp's mtxf_rotate_xyz_and_translate,
        # which builds Rz*Ry*Rx. (Godot's XYZ-order name actually means
        # Rx*Ry*Rz — the axes list applies them outer-to-inner, not the
        # other way around.) The decomp composes as Z last, applied to the
        # vector innermost-first: Rx applied to the vertex, then Ry, then Rz.
        n.basis = Basis.from_euler(Vector3(rx, ry, rz), EULER_ORDER_ZYX)


static func _sample_track(indices: Array, values: Array, track_idx: int, frame: int) -> int:
    var pair: Array = indices[track_idx]
    var n_frames: int = pair[0]
    var offset: int = pair[1]
    var f: int = frame
    if f >= n_frames:
        f = n_frames - 1
    if f < 0:
        f = 0
    var v: int = values[offset + f]
    return v
