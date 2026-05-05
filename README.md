# SuperTux3D

An open-source 3D platformer starring Tux the penguin, inspired by classic
collect-a-thon platformers like Super Mario 64. Built in Godot 4 with a
JSON-driven level format and a built-in 2D top-down editor for authoring
new worlds.

This project is a clean-room reimplementation — no proprietary assets are
used or required.

## Features

- **3D platformer movement** — running, walking, jumping (single / double /
  triple), backflip, side-flip, long jump, wall kick, dive, ground pound,
  swimming, pole climbing.
- **Surface-aware physics** — ice, slippery, snow, sand, quicksand, lava
  bounce-off, water swim. Per-cell on terrain.
- **Built-in level editor** (`scenes/blueprint_editor.tscn`) — sculpt
  terrain, paint surface kinds (water, lava, ice, snow…), place enemies,
  pickups, warps, doors, stairs, elevators. Round-trips through human-
  readable JSON.
- **Blueprint format** — levels live as `blueprints/*.json`; a Python
  converter at `tools/build_from_blueprint.py` builds them into Godot
  `.tscn` scenes. Edits round-trip cleanly; both files are version-control
  friendly.
- **Auto-derived geometry** — stairs auto-snap their rise to land flush
  with the upper floor; auto-punch holes through ceilings; door openings
  mirror across shared walls; pool walls extrude to block under-water
  shortcuts.

## Getting started

You need Godot 4.5+. Either drop a Godot binary into the project root
(it's gitignored) or install one system-wide via your package manager.

```sh
./start.sh
```

`start.sh` finds a bundled `Godot_v*` binary if one's in the project
root, falls back to whatever `godot` is on `PATH` otherwise, and forwards
any extra args (`./start.sh --headless` etc.).

Boot lands on the main menu. From there:

- **Play** → level select → pick any built level.
- **Level Editor** → load or create a blueprint, sculpt + paint, hit
  ▶ Play to drop straight in.

### Authoring a level

1. Editor → New (Ctrl+N) or Open an existing blueprint.
2. **R** to draw a room (drag a rectangle), **D** to place doors,
   **W** windows, **S** stairs, **T** terrain (drag), **N** enemies,
   **C** pickups, **X** warps. Full shortcut list is in the tool palette.
3. Select a terrain patch → use **Sculpt** (raise / flatten / average) or
   **Paint** (water / lava / ice / snow / sand / quicksand). Brush radius +
   strength in the inspector.
4. Save (Ctrl+S) — the converter rebuilds the `.tscn` automatically.
5. ▶ Play to test in-place. Use the **Temp Spawn** tool (M) to drop in
   somewhere other than the level's spawn point.

### Levels live in JSON

Open `blueprints/test_multistory.json` for a worked example with rooms,
stairs, an elevator, pickups, and pillars. Anything you can do in the
editor lives in there as plain text — easy to diff, easy to hand-edit if
you'd rather not click.

## Project layout

```
blueprints/         JSON levels (the source of truth)
godot/              Godot 4 project
  scenes/           main_menu, main, level_select, blueprint_editor
  scripts/          game logic, blueprint editor, runtime systems
  assets/           characters, enemies, pickups, materials, sounds
tools/
  build_from_blueprint.py    JSON → .tscn converter
```

## Inspiration

Super Mario 64's physics, jump combos, surface-kind handling, and overall
"vibey 3D playground" feel were the design reference. None of Nintendo's
code, art, audio, or level data is used. Tux the penguin (Linux mascot)
is the protagonist; the visual style is original clean-room work plus a
small amount of original audio.

## License

GPL v3. See `LICENSE` for the full text.

Contributions welcome — open a PR or an issue.
