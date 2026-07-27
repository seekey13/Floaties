# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Ashita v4 addon (Lua) for Final Fantasy XI. It draws HP/MP/TP unit-frame
panels in 3D space over the player, party members, and the current target,
anchored to the game's nameplate position. `README.md` is the behavior spec —
it documents *why* each rule exists, and is expected to be updated in the same
commit as any behavior change.

The repo root **is** the addon directory: it must be installed as
`Ashita/addons/NewUI/`, and Ashita loads `NewUI.lua` because the file matches
the folder name.

## Commands

There is no build step. Lua is installed but off PATH:

```sh
LUA="$LOCALAPPDATA/Programs/Lua/bin/lua.exe"     # lua 5.4
LUAC="$LOCALAPPDATA/Programs/Lua/bin/luac.exe"

"$LUA" test.lua                        # run the whole self-check (from the repo root)
"$LUAC" -p NewUI.lua lib/targets.lua   # syntax-check the files test.lua cannot load
```

`test.lua` is a flat list of `assert`s, not a framework — there is no way to run
a single case; delete/comment lines locally if you need to isolate one. It exits
non-zero on the first failure and prints `<file>.lua ok` per module otherwise.

Only in-game verification covers rendering, projection, and the memory reads in
`lib/targets.lua`; `/newui config` shows live gate/target state for that.

## Architecture

### The headless boundary

The single most important constraint: **`NewUI.lua` is the only file that may
touch Ashita globals** (`AshitaCore`, `ashita.*`, `imgui`, `ffi`, `d3d8`,
`GetEntity`, `require('common')`). Everything else stays loadable under plain
Lua so `test.lua` can exercise it headless. Consequences to preserve:

- `stats.lua` — pure. Takes the party/entity objects as arguments, never fetches
  them. Uses a modulo `hasFlag` helper instead of `bit.band`, because `bit` is a
  LuaJIT global that plain Lua 5.4 does not have.
- `config.lua` — pure except `M.load`/`M.save`, which `require('settings')`
  *inside the function body*, never at file scope, for the same reason.
- `nameplate.lua` — takes the memory reader (`mem`) as an injected argument
  (`ashita.memory` in the addon, a fake table in tests), so the pointer walk is
  testable.
- `lib/targets.lua` — Ashita's own target library, **vendored unmodified**. Do
  not edit it; it is diffable against upstream/Sidekick's `lib/core/targets.lua`.
  It hard-`error`s at load when its byte signatures miss, so it is `require`d
  inside a `pcall` and a miss degrades one gate instead of killing the addon.

New logic with a decision in it belongs in `stats.lua` or `config.lua` with
asserts in `test.lua`; `NewUI.lua` should stay glue, drawing, and Ashita I/O.

### Per-frame flow (`d3d_present`)

1. `updateGateState` runs **before every early return**, so the config window's
   status line keeps reporting truthfully while the addon is disabled or the
   panel is hidden. It also resolves `target_index` next to the diagnostic
   string describing it, so the two can never disagree.
2. `config.visible(cfg, gate_state)` decides. Gates are **purely enabling**:
   the panel shows if any *enabled* gate's condition is true, hidden otherwise.
   Several enabled is a union, not an intersection, and none enabled means never
   visible (there is no "always show" fallback — that made a single ticked gate
   look broken).
3. `drawMember` for slots `0..5`, then `drawTarget`, both funnelling into
   `drawAt` → `worldToScreen` → `drawPanel` → `drawBar`/`drawLabel`.

Gate-state keys match `config.gates` exactly so the table can be passed straight
to `config.visible`; adding a gate is a string in that list, a default, a
checkbox, and a condition in `updateGateState`.

### Coordinates and anchoring

FFXI position structs are stored **X, Z, Y** — the game's Z is the D3D up-axis,
and the height axis is **down-positive** (so the top of a model is the *smallest*
Z, and a positive height offset moves a panel *down*). `worldToScreen` returns
view depth (`p.w`) as a fourth value because that is exactly what distance
scaling needs, for free.

Panels hang from `nameplate.top()` — the highest bone in the actor's skeleton —
not from the entity's feet, so the gap under the nameplate holds across races,
mounts, sitting and jumping. Any unreadable pointer in the chain returns `nil`
and the caller falls back to feet position for that frame; never let that walk
throw.

### Layout and settings

Geometry is derived, never stored: `config.bar_width`, `config.panel_height` and
`config.label_size` are pure functions of the settings table, so distance
scaling multiplies their *results* in `drawPanel` rather than threading a scale
factor through them.

`sizes.self` / `sizes.party` / `sizes.target` are the only per-panel-kind
settings (width + per-bar heights); everything else — padding, rounding, colors,
alphas, borders, text — is shared, so a retint stays one edit. `sizes.target`
carries `hp` only, because the client is told nothing but an HP percent about an
arbitrary entity.

Adding a setting = a key in `config.defaults` + a widget in `drawConfigWindow`.
Every widget writes through and calls `config.save()` immediately; there is no
apply button. Settings persist via Ashita's `settings` library into one shared
file for all characters, and `M.load` wraps defaults in `T(...)` for its
`copy`/`merge` metatable.

Bars are drawn straight onto ImGui's background draw list
(`AddRectFilled`/`AddRect`/`AddText`) rather than Ashita's `primitives` library,
which cannot do text or rounded corners. Label sizing uses the two-argument
`AddText` overload (font + size); ImGui takes a font, not a weight, so "bold" is
the fill stamped a second time one pixel right.

## Conventions

- Comments explain *why*, at length where the reason is non-obvious (a rejected
  alternative, a client quirk, a failure mode). Match that density — the
  existing files are the style guide.
- `--[[ * ... * @param ... * @return ... --]]` doc blocks on non-trivial
  functions, Ashita house style: semicolons, parenthesized `if (...) then`.
- A deliberate shortcut with a known ceiling is marked `-- ponytail: <what and
  when to upgrade>`.
- `docs/` holds research notes and is **gitignored** — never assume its contents
  are available to a reader of the repo, and don't reference it as if committed.
