#!/usr/bin/env python3
"""Parse an SM64 decomp `levels/<name>/script.c` into a level-summary JSON
that our Godot LevelManager can load.

We care about a handful of LevelScript macros:
  MARIO_POS(area, yaw, x, y, z)
      Mario's spawn position/angle for the given area index.
  AREA(index, geo)
      Starts an area definition; subsequent OBJECT/WARP entries belong
      to this area until END_AREA.
  END_AREA()
  OBJECT(model, x, y, z, rx, ry, rz, bhvParam, bhv)
      Static object placement.
  OBJECT_WITH_ACTS(..., acts)
      Same with an act mask.
  WARP_NODE(id, dest_level, dest_area, dest_node, warp_op)
      Warp connection (paintings → levels, doors, etc.).

Output:
{
  "name": "ccm",
  "spawns": {1: {"yaw": 0, "pos": [2660, -3435, 1040]}, ...},
  "areas": {
    "1": {
      "geo": "ccm_geo",
      "objects": [{"model": "...", "pos": [...], "angle": [...],
                   "bhv": "...", "bhv_param": "...", "acts": 0}, ...],
      "warps": [{"id": 10, "level": "LEVEL_CASTLE", "area": 1,
                 "node": 10, "op": "WARP_NO_CHECKPOINT"}, ...]
    }
  }
}

We don't evaluate #ifdefs or expand macros — we just scan the text with
regex-level parsing, which is sufficient for the canonical decomp format.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


OBJECT_RE = re.compile(
    r"\bOBJECT(?:_WITH_ACTS)?\s*\((?P<args>[^()]*(?:\([^()]*\)[^()]*)*)\)",
    re.DOTALL,
)
MARIO_POS_RE = re.compile(
    r"\bMARIO_POS\s*\((?P<args>[^)]*)\)",
    re.DOTALL,
)
WARP_NODE_RE = re.compile(
    r"\b(?:WARP_NODE|PAINTING_WARP_NODE)\s*\((?P<args>[^)]*)\)",
    re.DOTALL,
)
AREA_RE = re.compile(r"\bAREA\s*\((?P<args>[^)]*)\)", re.DOTALL)
END_AREA_RE = re.compile(r"\bEND_AREA\s*\(\s*\)")

# Macro-object entries inside areas/N/macro.inc.c. Compressed spawns that
# reference a preset table from include/macro_presets.inc.c. Most of each
# level's enemies (goombas, bob-ombs, chain chomp, koopas of certain
# variants, etc.) live here — NOT in script.c. Easy to miss and I did
# for a while.
MACRO_OBJECT_RE = re.compile(
    r"\bMACRO_OBJECT(?:_WITH_BHV_PARAM)?\s*\((?P<args>[^()]*(?:\([^()]*\)[^()]*)*)\)",
    re.DOTALL,
)

# Preset entry inside macro_presets.inc.c. The comment before each entry
# is the preset's identifier (matching what shows up in levels/*/areas/N/
# macro.inc.c). We need the mapping to resolve macro preset → bhv/model/
# bhvParam. Example line:
#   /* macro_goomba            */ { bhvGoomba, MODEL_GOOMBA, 0 },
MACRO_PRESET_RE = re.compile(
    r"/\*\s*(?P<name>macro_\w+)\s*\*/\s*\{"
    r"\s*(?P<bhv>\w+)\s*,"
    r"\s*(?P<model>\w+)\s*,"
    r"\s*(?P<param>[^}]+?)\s*\}",
    re.DOTALL,
)

BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.DOTALL)
LINE_COMMENT_RE = re.compile(r"//[^\n]*")


def split_args(arg_text: str) -> list[str]:
    out: list[str] = []
    depth = 0
    cur: list[str] = []
    for ch in arg_text:
        if ch == "(":
            depth += 1
            cur.append(ch)
        elif ch == ")":
            depth -= 1
            cur.append(ch)
        elif ch == "," and depth == 0:
            out.append("".join(cur).strip())
            cur = []
        else:
            cur.append(ch)
    if cur:
        out.append("".join(cur).strip())
    return out


def parse_macro_presets(text: str) -> dict[str, dict]:
    """Build preset_name → {bhv, model, param} dict from macro_presets.inc.c
    content. The param field is kept as a raw string so we can preserve
    expressions like `GOOMBA_TRIPLET_SPAWNER_BP_EXTRA_GOOMBAS(0) | GOOMBA_SIZE_REGULAR`."""
    out: dict[str, dict] = {}
    for m in MACRO_PRESET_RE.finditer(text):
        out[m.group("name")] = {
            "bhv": m.group("bhv").strip(),
            "model": m.group("model").strip(),
            "param": m.group("param").strip(),
        }
    return out


def parse_int_safe(s: str) -> int | None:
    s = s.strip().rstrip(",").strip()
    if not s:
        return None
    # Strip trailing 'f' or 'F'.
    if s.endswith(("f", "F")):
        s = s[:-1]
    try:
        if s.lower().startswith("0x"):
            return int(s, 16)
        return int(s)
    except ValueError:
        return None


def parse_macro_file(macro_text: str, presets: dict[str, dict]) -> list[dict]:
    """Parse a single areas/N/macro.inc.c text, returning a list of
    object dicts in the same shape our OBJECT parser emits."""
    text = BLOCK_COMMENT_RE.sub("", macro_text)
    text = LINE_COMMENT_RE.sub("", text)
    objects: list[dict] = []
    for m in MACRO_OBJECT_RE.finditer(text):
        args = split_args(m.group("args"))
        if len(args) < 5:
            continue
        preset_name = args[0].strip()
        preset = presets.get(preset_name)
        if preset is None:
            # Unknown preset — still emit a stub with the raw name so
            # the spawner can log it.
            preset = {"bhv": preset_name, "model": "MODEL_NONE", "param": "0"}
        yaw = parse_int_safe(args[1])
        pos = [parse_int_safe(args[i]) for i in (2, 3, 4)]
        if yaw is None or None in pos:
            continue
        # MACRO_OBJECT_WITH_BHV_PARAM supplies its own bhvParam; otherwise
        # use the preset's default param.
        bhv_param = args[5].strip() if len(args) >= 6 else preset["param"]
        objects.append({
            "model": preset["model"],
            "pos": pos,
            "angle": [0, yaw, 0],
            "bhv_param": bhv_param,
            "bhv": preset["bhv"],
            "acts": None,
        })
    return objects


def parse(script_text: str) -> dict:
    text = BLOCK_COMMENT_RE.sub("", script_text)
    text = LINE_COMMENT_RE.sub("", text)

    # Find all AREA/END_AREA markers with their text offsets so we can
    # attribute subsequent OBJECT/WARP entries to the right area.
    markers: list[tuple[str, int, dict]] = []
    for m in AREA_RE.finditer(text):
        args = split_args(m.group("args"))
        if args:
            idx = parse_int_safe(args[0])
            geo = args[1].strip() if len(args) > 1 else ""
            if idx is not None:
                markers.append(("AREA", m.start(), {"index": idx, "geo": geo}))
    for m in END_AREA_RE.finditer(text):
        markers.append(("END_AREA", m.start(), {}))
    markers.sort(key=lambda x: x[1])

    def area_at(offset: int) -> int | None:
        # Return the area index that covers `offset` in source. Most scripts
        # define a single area (AREA … END_AREA) or nest MARIO_POS outside
        # any area; default to 1 in the latter case for convenience.
        current: int | None = None
        for kind, pos, data in markers:
            if pos >= offset:
                break
            if kind == "AREA":
                current = data["index"]
            elif kind == "END_AREA":
                current = None
        return current

    areas_init: dict[str, dict] = {}
    for kind, _, data in markers:
        if kind == "AREA":
            areas_init[str(data["index"])] = {
                "geo": data["geo"],
                "objects": [],
                "warps": [],
            }

    out: dict = {
        "spawns": {},
        "areas": areas_init,
    }

    def ensure_area(area_idx: int | None) -> dict:
        key = str(area_idx) if area_idx is not None else "1"
        if key not in out["areas"]:
            out["areas"][key] = {"geo": "", "objects": [], "warps": []}
        return out["areas"][key]

    # MARIO_POS entries
    for m in MARIO_POS_RE.finditer(text):
        args = split_args(m.group("args"))
        if len(args) >= 5:
            area = parse_int_safe(args[0])
            yaw = parse_int_safe(args[1])
            x = parse_int_safe(args[2])
            y = parse_int_safe(args[3])
            z = parse_int_safe(args[4])
            if area is not None and None not in (yaw, x, y, z):
                out["spawns"][str(area)] = {
                    "yaw": yaw,
                    "pos": [x, y, z],
                }

    # OBJECT entries
    for m in OBJECT_RE.finditer(text):
        args = split_args(m.group("args"))
        if len(args) < 9:
            continue
        model = args[0]
        pos = [parse_int_safe(args[i]) for i in (1, 2, 3)]
        angle = [parse_int_safe(args[i]) for i in (4, 5, 6)]
        bhv_param = args[7]
        bhv = args[8]
        acts: int | None = None
        if len(args) >= 10:
            acts = parse_int_safe(args[9])
        if None in pos or None in angle:
            continue
        area = ensure_area(area_at(m.start()))
        area["objects"].append({
            "model": model,
            "pos": pos,
            "angle": angle,
            "bhv_param": bhv_param,
            "bhv": bhv,
            "acts": acts,
        })

    # WARP_NODE entries — the IDs are usually enum constants (WARP_NODE_XX)
    # so we keep them as raw strings and let the runtime resolve matching
    # node ids to warp locations.
    for m in WARP_NODE_RE.finditer(text):
        args = split_args(m.group("args"))
        if len(args) < 5:
            continue
        node_id_raw = args[0].strip()
        # Try numeric first, fall back to the original token.
        node_id_int = parse_int_safe(node_id_raw)
        node_id: object = node_id_raw if node_id_int is None else node_id_int
        level = args[1].strip()
        dest_area = parse_int_safe(args[2])
        dest_area_val: object = args[2].strip() if dest_area is None else dest_area
        dest_node = parse_int_safe(args[3])
        dest_node_val: object = args[3].strip() if dest_node is None else dest_node
        op = args[4].strip()
        area = ensure_area(area_at(m.start()))
        area["warps"].append({
            "id": node_id,
            "level": level,
            "area": dest_area_val,
            "node": dest_node_val,
            "op": op,
        })

    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("level_dir", type=Path,
                    help="e.g. reference/sm64/levels/ccm")
    ap.add_argument("output", type=Path,
                    help="where to write the level summary JSON")
    args = ap.parse_args()

    script = args.level_dir / "script.c"
    if not script.exists():
        print(f"missing {script}", file=sys.stderr)
        return 1

    data = parse(script.read_text(errors="ignore"))
    data["name"] = args.level_dir.name

    # Load macro presets from the sm64 repo (levels/<name> → ../../include).
    presets_path = args.level_dir.parent.parent / "include" / "macro_presets.inc.c"
    presets: dict[str, dict] = {}
    if presets_path.exists():
        presets = parse_macro_presets(presets_path.read_text(errors="ignore"))

    # Each area may have areas/<idx>/macro.inc.c with additional enemy
    # spawns. Merge them into the matching area's object list.
    macro_added = 0
    if presets:
        for area_dir in sorted((args.level_dir / "areas").glob("*/")):
            try:
                area_idx = int(area_dir.name)
            except ValueError:
                continue
            macro_file = area_dir / "macro.inc.c"
            if not macro_file.exists():
                continue
            macro_objects = parse_macro_file(
                macro_file.read_text(errors="ignore"), presets
            )
            key = str(area_idx)
            if key not in data["areas"]:
                data["areas"][key] = {"geo": "", "objects": [], "warps": []}
            data["areas"][key]["objects"].extend(macro_objects)
            macro_added += len(macro_objects)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(data, indent=2))

    obj_total = sum(len(a["objects"]) for a in data["areas"].values())
    warp_total = sum(len(a["warps"]) for a in data["areas"].values())
    print(f"wrote {args.output}: {len(data['areas'])} areas, "
          f"{len(data['spawns'])} spawns, {obj_total} objects "
          f"({macro_added} from macro.inc.c), {warp_total} warps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
