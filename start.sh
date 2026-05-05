#!/usr/bin/env bash
# Boot SuperTux3D. Looks for a bundled Godot binary in this directory
# first, then falls back to whatever `godot` is on PATH. Pass extra
# args through to Godot (e.g. ./start.sh --headless).

set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

godot_bin=""
shopt -s nullglob
for candidate in ./Godot_v*-stable_linux.x86_64 ./Godot_v*.x86_64 ./Godot_v*_macos*; do
    if [[ -x "$candidate" ]]; then
        godot_bin="$candidate"
        break
    fi
done
shopt -u nullglob

if [[ -z "$godot_bin" ]]; then
    if command -v godot >/dev/null 2>&1; then
        godot_bin="godot"
    else
        echo "No Godot binary found." >&2
        echo "Drop a Godot 4.5+ binary in this directory (e.g.," >&2
        echo "  Godot_v4.5.1-stable_linux.x86_64) or install godot via" >&2
        echo "your package manager. https://godotengine.org/download" >&2
        exit 1
    fi
fi

exec "$godot_bin" --path godot "$@"
