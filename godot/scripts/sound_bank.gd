extends Node

# Simple sound bank — loads WAVs from extracted/sounds/ and plays them on
# demand via a pool of AudioStreamPlayer3D voices parented to a node of
# your choice. Placeholder tones for now; the real decomp audio engine
# is a future port.

const SOUNDS_DIR := "res://extracted/sounds"
const SOUND_NAMES := [
    "coin", "death", "jump", "land", "star", "punch",
    "ground_pound", "cap", "oneup",
]

var _streams: Dictionary = {}   # name → AudioStreamWAV
var _players: Array[AudioStreamPlayer3D] = []
var _pool_idx: int = 0


func setup(voice_count: int, mount: Node3D) -> void:
    for name in SOUND_NAMES:
        var path := "%s/%s.wav" % [SOUNDS_DIR, name]
        var stream := AudioStreamWAV.new()
        if not FileAccess.file_exists(path):
            continue
        var bytes := FileAccess.get_file_as_bytes(path)
        # Our WAV writer produces 22050 Hz 16-bit mono PCM with a 44-byte
        # header. Strip the header for AudioStreamWAV's raw PCM buffer.
        if bytes.size() > 44:
            stream.format = AudioStreamWAV.FORMAT_16_BITS
            stream.mix_rate = 22050
            stream.stereo = false
            stream.data = bytes.slice(44)
            _streams[name] = stream
    for _i in range(voice_count):
        var p := AudioStreamPlayer3D.new()
        p.unit_size = 6.0
        mount.add_child(p)
        _players.append(p)


func play(name: String) -> void:
    var s: Variant = _streams.get(name)
    if s == null:
        return
    if _players.is_empty():
        return
    var p := _players[_pool_idx % _players.size()]
    _pool_idx += 1
    p.stream = s
    p.pitch_scale = 1.0
    p.play()
