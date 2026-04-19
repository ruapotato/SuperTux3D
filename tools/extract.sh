#!/usr/bin/env bash
# End-to-end asset extraction pipeline for the SM64→Godot project.
#
# Usage:
#   tools/extract.sh              # auto-discovers a ROM in the project root
#   tools/extract.sh path/to/rom  # uses the supplied ROM
#
# Idempotent: skips steps already done. Safe to re-run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REF_DIR="$PROJECT_ROOT/reference"
SM64_REPO="$REF_DIR/sm64"
SM64_URL="https://github.com/n64decomp/sm64.git"
Z64_TARGET="$PROJECT_ROOT/baserom.us.z64"

log()  { printf '\033[1;34m[extract]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[extract]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[extract]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || err "missing required tool: $1"; }
need git; need python3; need make; need gcc

# 1. Locate the source ROM.
SRC_ROM="${1:-}"
if [[ -z "$SRC_ROM" ]]; then
  mapfile -t candidates < <(find "$PROJECT_ROOT" -maxdepth 1 -type f \
    \( -iname '*.v64' -o -iname '*.z64' -o -iname '*.n64' \) \
    ! -name 'baserom.*.z64' | sort)
  if [[ ${#candidates[@]} -eq 0 ]]; then
    err "no ROM found. Place a .v64/.z64/.n64 in $PROJECT_ROOT or pass its path."
  fi
  if [[ ${#candidates[@]} -gt 1 ]]; then
    warn "multiple ROM candidates; using the first: ${candidates[0]}"
  fi
  SRC_ROM="${candidates[0]}"
fi
[[ -f "$SRC_ROM" ]] || err "ROM not found: $SRC_ROM"
log "source ROM: $SRC_ROM"

# 2. Byteswap to z64 if needed (idempotent via SHA1 check).
EXPECTED_SHA1="9bef1128717f958171a4afac3ed78ee2bb4e86ce"
if [[ -f "$Z64_TARGET" ]] && \
   [[ "$(sha1sum "$Z64_TARGET" | cut -d' ' -f1)" == "$EXPECTED_SHA1" ]]; then
  log "baserom.us.z64 already present and verified — skipping byteswap"
else
  log "running byteswap → $Z64_TARGET"
  python3 "$SCRIPT_DIR/byteswap_v64_to_z64.py" "$SRC_ROM" "$Z64_TARGET"
fi

# 3. Clone n64decomp/sm64 if missing.
mkdir -p "$REF_DIR"
if [[ ! -d "$SM64_REPO/.git" ]]; then
  log "cloning $SM64_URL → $SM64_REPO"
  git clone --depth 1 "$SM64_URL" "$SM64_REPO"
else
  log "n64decomp/sm64 already present — skipping clone"
fi

# 4. Place ROM inside sm64 repo where extract_assets.py expects it.
SM64_ROM="$SM64_REPO/baserom.us.z64"
if [[ ! -f "$SM64_ROM" ]] || ! cmp -s "$Z64_TARGET" "$SM64_ROM"; then
  log "copying ROM into $SM64_REPO"
  cp "$Z64_TARGET" "$SM64_ROM"
fi

# 5. Run extraction. The script is itself idempotent: it tracks .assets-local.txt
# and returns early when nothing is missing.
log "running asset extraction (python3 extract_assets.py us)"
(cd "$SM64_REPO" && python3 extract_assets.py us)

# 6. Build the texture symbol → PNG map, copy PNGs into extracted/textures/
# so they can be loaded via res://extracted/textures/....
EXTRACTED="$PROJECT_ROOT/extracted"
log "building texture symbol map and copying PNGs"
python3 "$SCRIPT_DIR/resolve_textures.py" \
  --sm64-root "$SM64_REPO" \
  --copy-to "$EXTRACTED/textures" \
  "$EXTRACTED/textures/texture_map.json"

# 6.5 Convert actor meshes (Mario first) as articulated skeletons.
log "converting actor meshes"
python3 "$SCRIPT_DIR/convert_actor.py" \
  "$SM64_REPO/actors/mario" \
  "$EXTRACTED/actors/mario/mesh.json"

# 6.6 Convert Mario animations to JSON. All 200+ animations; tiny files.
log "converting Mario animations"
python3 "$SCRIPT_DIR/convert_animation.py" \
  "$SM64_REPO/assets/anims" \
  "$EXTRACTED/actors/mario/anims"

# 7. Convert level geometry + collision to Godot-friendly JSON.
log "converting level geometry and collision to Godot JSON"

# Build a list of levels to convert. For now hard-coded to the ones we support.
# Extend this list as new levels are wired up.
LEVELS=(bob)

for level in "${LEVELS[@]}"; do
  level_dir="$SM64_REPO/levels/$level"
  [[ -d "$level_dir/areas" ]] || { warn "no areas/ under $level_dir — skipping"; continue; }
  for area_dir in "$level_dir"/areas/*/; do
    area=$(basename "$area_dir")
    out_dir="$EXTRACTED/levels/$level/area_$area"
    mkdir -p "$out_dir"

    if [[ -f "$area_dir/collision.inc.c" ]]; then
      python3 "$SCRIPT_DIR/convert_collision.py" \
        "$area_dir/collision.inc.c" "$out_dir/collision.json" \
        --sm64-root "$SM64_REPO"
    fi

    python3 "$SCRIPT_DIR/convert_model.py" \
      "$area_dir" "$out_dir/model.json"
  done
done

# 8. Ensure the Godot project can see extracted/ via res://. Godot restricts
# res:// to its own project tree, so we link our sibling extracted/ into it.
GODOT_LINK="$PROJECT_ROOT/godot/extracted"
if [[ ! -e "$GODOT_LINK" && -d "$PROJECT_ROOT/godot" ]]; then
  log "linking extracted/ into godot/ (res://extracted)"
  ln -s ../extracted "$GODOT_LINK"
fi

# 9. Report what we got.
texture_count=$(find "$SM64_REPO/textures" "$SM64_REPO/actors" "$SM64_REPO/levels" \
  -type f -name '*.png' 2>/dev/null | wc -l)
aiff_count=$(find "$SM64_REPO/sound" -type f -name '*.aiff' 2>/dev/null | wc -l)
m64_count=$(find "$SM64_REPO/sound" -type f -name '*.m64' 2>/dev/null | wc -l)
level_count=$(find "$EXTRACTED/levels" -name 'model.json' 2>/dev/null | wc -l)
log "done."
log "  raw assets: $texture_count PNG, $aiff_count AIFF, $m64_count M64 under $SM64_REPO/{textures,actors,levels,sound}"
log "  level JSON: $level_count area(s) under $EXTRACTED/levels/"
