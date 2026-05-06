extends Node

# Tiny persistent save — stored as JSON in Godot's user:// filesystem
# (platform-dependent, e.g. ~/.local/share/godot/app_userdata/SM64_Godot/
# on Linux). Tracks the minimum progression state SM64 cares about.

const SAVE_PATH := "user://save.json"

var stars: int = 0
var coins: int = 0       # lifetime coin count (SM64 tracks per-course, we keep one number)
var lives: int = 4
var last_level: String = "grass_hub"
var last_area: int = 1
# Per-level set of collected star markers. Keys are level stems
# ("mountain"), values are arrays of star marker names ("MountainPeak").
# Looked up by level_manager when spawning to render previously-
# collected stars as ghost markers (visible-but-uncollectible) so
# the player sees their progress and can't farm the same star.
var collected_stars: Dictionary = {}

# A level is valid if the runtime can actually load its .tscn. This
# auto-accepts any level the user authors in the editor (no hardcoded
# list to maintain) and still falls back to the hub when an old save
# points at a deleted level.
func _level_exists(name: String) -> bool:
    return ResourceLoader.exists("res://assets/levels/%s.tscn" % name)


func load_file() -> void:
    if not FileAccess.file_exists(SAVE_PATH):
        return
    var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
    if f == null:
        return
    var parsed: Variant = JSON.parse_string(f.get_as_text())
    if not (parsed is Dictionary):
        return
    stars = int(parsed.get("stars", stars))
    coins = int(parsed.get("coins", coins))
    lives = int(parsed.get("lives", lives))
    last_level = String(parsed.get("last_level", last_level))
    last_area = int(parsed.get("last_area", last_area))
    var raw_collected: Variant = parsed.get("collected_stars", {})
    if raw_collected is Dictionary:
        collected_stars = {}
        for k in raw_collected.keys():
            var arr: Variant = raw_collected[k]
            if arr is Array:
                var clean: Array = []
                for n in arr:
                    clean.append(String(n))
                collected_stars[String(k)] = clean
    if not _level_exists(last_level):
        last_level = "grass_hub"
        last_area = 1


func save_file() -> void:
    var d := {
        "stars": stars,
        "coins": coins,
        "lives": lives,
        "last_level": last_level,
        "last_area": last_area,
        "collected_stars": collected_stars,
    }
    var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if f != null:
        f.store_string(JSON.stringify(d, "\t"))


func is_star_collected(level: String, star_name: String) -> bool:
    if star_name == "" or not collected_stars.has(level):
        return false
    return star_name in collected_stars[level]


func collect_star(level: String, star_name: String) -> bool:
    """Record a star as collected. Returns true if this was a NEW
    pickup (advancing the global counter), false if it was already
    in the set (no-op + no double counting)."""
    if star_name == "":
        return false
    var arr: Array = collected_stars.get(level, [])
    if star_name in arr:
        return false
    arr.append(star_name)
    collected_stars[level] = arr
    stars += 1
    last_level = level
    save_file()
    return true


func record_level(level: String, area: int) -> void:
    last_level = level
    last_area = area
