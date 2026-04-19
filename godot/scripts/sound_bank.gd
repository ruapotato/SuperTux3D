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
    # background music tracks (procedural)
    "bgm_castle", "bgm_course", "bgm_water", "bgm_bowser", "bgm_sub",
]
const SOUND_ALIASES := {
    "death":       "whoa",
    "land":        "heavy_land",
    "punch":       "ooof",
    "title":       "here_we_go",
    "star_yahoo":  "yahoo",
    "double_jump": "jump2",
    "triple_jump": "yahoo",
    "long_jump":   "yahoo",
    "backflip":    "jump2",
    "wall_kick":   "uh",
    "dive":        "yah",
    "damage":      "attacked",
}

# Weighted random banks for repeatable events. First entry = default.
# "here_we_go" is Mario's "Let's-a go!" title voice; it's explicitly
# kept OUT of the single-jump bank (previous version had it there).
const SOUND_BANKS := {
    "jump": ["jump", "jump2", "yah", "haha"],
    "land": ["heavy_land", "plop"],
}

var _streams: Dictionary = {}
var _players: Array[AudioStreamPlayer3D] = []
var _pool_idx: int = 0
var _bgm_player: AudioStreamPlayer   # 2D/global for background music
var _bgm_current: String = ""


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
    # Global BGM player, non-positional, plays looped music.
    _bgm_player = AudioStreamPlayer.new()
    _bgm_player.volume_db = -8.0
    mount.add_child(_bgm_player)


func play_bgm(track: String) -> void:
    if track == _bgm_current:
        return
    _bgm_current = track
    var s: Variant = _streams.get(track)
    if s == null:
        _bgm_player.stop()
        return
    # Enable the loop flag on the stream so AudioStreamPlayer repeats it.
    s.loop_mode = AudioStreamWAV.LOOP_FORWARD
    s.loop_begin = 0
    s.loop_end = s.data.size() / (2 if s.format == AudioStreamWAV.FORMAT_16_BITS else 1)
    _bgm_player.stream = s
    _bgm_player.play()


func stop_bgm() -> void:
    if _bgm_player != null:
        _bgm_player.stop()
        _bgm_current = ""


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
    var actual: String = name
    if SOUND_BANKS.has(name):
        var bank: Array = SOUND_BANKS[name]
        actual = bank[randi() % bank.size()]
    else:
        actual = SOUND_ALIASES.get(name, name)
    var s: Variant = _streams.get(actual)
    if s == null:
        return
    if _players.is_empty():
        return
    var p := _players[_pool_idx % _players.size()]
    _pool_idx += 1
    p.stream = s
    # Small pitch variance so repeated plays don't sound identical even
    # when the bank resolves to the same clip.
    p.pitch_scale = 0.95 + randf() * 0.1
    p.play()
