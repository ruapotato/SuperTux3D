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
    }
    var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
    if f != null:
        f.store_string(JSON.stringify(d, "\t"))


func record_star(level: String) -> void:
    stars += 1
    last_level = level
    save_file()


func record_level(level: String, area: int) -> void:
    last_level = level
    last_area = area
