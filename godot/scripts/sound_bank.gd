extends Node

# Simple sound bank — loads WAVs from extracted/sounds/ and plays them on
# demand via a pool of AudioStreamPlayer3D voices parented to a node of
# your choice. Placeholder tones for now; the real decomp audio engine
# is a future port.

const SOUNDS_DIR := "res://extracted/sounds"

# Every name we want to have loadable. Some map to the decomp's real
# AIFF-derived voice (jump = Mario's "hoo", whoa = death cry, …); others
# to procedural placeholder tones we synthesize in tools/gen_sounds.py
# for events the decomp hasn't mapped yet.
const SOUND_NAMES := [
    # procedural placeholders
    "coin", "star", "cap", "oneup", "ground_pound",
    # decomp AIFF-derived
    "jump", "jump2", "yah", "haha", "yahoo", "uh", "whoa",
    "ooof", "here_we_go", "doh", "game_over", "attacked",
    "step", "step_grass", "step_stone", "step_snow",
    "plop", "heavy_land", "hand_touch",
    # name aliases that map to a preferred sound at play time
    "death", "land", "punch",
]
const SOUND_ALIASES := {
    "death": "whoa",
    "land":  "heavy_land",
    "punch": "ooof",
}

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer3D] = []
var _pool_idx: int = 0


func setup(voice_count: int, mount: Node3D) -> void:
    for name in SOUND_NAMES:
        if SOUND_ALIASES.has(name):
            continue  # alias resolved at play() time
        var path := "%s/%s.wav" % [SOUNDS_DIR, name]
        if not FileAccess.file_exists(path):
            continue
        var stream := _load_wav(path)
        if stream != null:
            _streams[name] = stream
    for _i in range(voice_count):
        var p := AudioStreamPlayer3D.new()
        p.unit_size = 6.0
        mount.add_child(p)
        _players.append(p)


func _load_wav(path: String) -> AudioStreamWAV:
    # Parse the WAV header ourselves so we handle whatever sample rate /
    # bit depth / channel count the source produced, rather than assuming
    # 22 kHz mono. Returns null on anything non-PCM or malformed.
    var bytes := FileAccess.get_file_as_bytes(path)
    if bytes.size() < 44 or bytes.slice(0, 4) != PackedByteArray([0x52,0x49,0x46,0x46]):
        return null
    if bytes.slice(8, 12) != PackedByteArray([0x57,0x41,0x56,0x45]):
        return null
    var sample_rate: int = 22050
    var bits: int = 16
    var channels: int = 1
    var data_offset: int = -1
    var data_size: int = 0
    var i: int = 12
    while i + 8 <= bytes.size():
        var chunk_id: PackedByteArray = bytes.slice(i, i + 4)
        var chunk_size: int = bytes.decode_u32(i + 4)
        if chunk_id == PackedByteArray([0x66,0x6D,0x74,0x20]):  # "fmt "
            # var fmt_tag := bytes.decode_u16(i + 8)       # 1 = PCM
            channels = bytes.decode_u16(i + 10)
            sample_rate = bytes.decode_u32(i + 12)
            bits = bytes.decode_u16(i + 22)
        elif chunk_id == PackedByteArray([0x64,0x61,0x74,0x61]):  # "data"
            data_offset = i + 8
            data_size = chunk_size
            break
        i += 8 + chunk_size
    if data_offset < 0:
        return null

    var stream := AudioStreamWAV.new()
    stream.mix_rate = sample_rate
    stream.stereo = (channels == 2)
    match bits:
        8:  stream.format = AudioStreamWAV.FORMAT_8_BITS
        16: stream.format = AudioStreamWAV.FORMAT_16_BITS
        _:  return null
    stream.data = bytes.slice(data_offset, data_offset + data_size)
    return stream


func play(name: String) -> void:
    var actual: String = SOUND_ALIASES.get(name, name)
    var s: Variant = _streams.get(actual)
    if s == null:
        return
    if _players.is_empty():
        return
    var p := _players[_pool_idx % _players.size()]
    _pool_idx += 1
    p.stream = s
    p.pitch_scale = 1.0
    p.play()
