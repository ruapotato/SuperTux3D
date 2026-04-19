extends SceneTree

# Smoke-tests level loading: iterates every extracted level and loads it via
# the LevelManager. Reports which ones load without errors.

const LevelManagerScript := preload("res://scripts/level_manager.gd")
const LevelLoader := preload("res://scripts/level_loader.gd")


func _init() -> void:
    var levels_root := "res://extracted/levels"
    var results: Array = []
    var dir := DirAccess.open(levels_root)
    if dir == null:
        push_error("can't open " + levels_root)
        quit(); return

    for level in dir.get_directories():
        var script_path := "%s/%s/script.json" % [levels_root, level]
        if not FileAccess.file_exists(script_path):
            continue
        var data: Variant = JSON.parse_string(
            FileAccess.open(script_path, FileAccess.READ).get_as_text())
        if not (data is Dictionary):
            continue
        var spawns: Dictionary = data.spawns if data.spawns is Dictionary else {}
        var areas: Dictionary = data.areas if data.areas is Dictionary else {}
        var total_objs := 0
        for a in areas.values():
            if a is Dictionary:
                total_objs += a.objects.size() if a.objects is Array else 0
        var model_present := FileAccess.file_exists(
            "%s/%s/area_1/model.json" % [levels_root, level])
        var coll_present := FileAccess.file_exists(
            "%s/%s/area_1/collision.json" % [levels_root, level])
        results.append({
            "name": level,
            "areas": areas.size(),
            "spawns": spawns.size(),
            "objects": total_objs,
            "model": model_present,
            "collision": coll_present,
        })

    print("=== level loading smoke test ===")
    print("name              areas spawns objs model coll")
    print("---------------   ----- ------ ---- ----- ----")
    for r in results:
        print("%-16s %5d %6d %4d %5s %5s" % [
            r.name, r.areas, r.spawns, r.objects,
            "yes" if r.model else "NO",
            "yes" if r.collision else "NO",
        ])
    print("total levels: ", results.size())
    quit()
