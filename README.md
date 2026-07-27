# NewUI

Ashita v4 addon. Draws a styled HP/MP/TP unit-frame panel that tracks your
character in 3D space, anchored below the feet.

## V2

A rounded, bordered panel with three stacked bars, each showing its raw
current value as text:

| Bar | Source | Label | Default color |
|---|---|---|---|
| HP | `party:GetMemberHPPercent(i)` | current HP | light red |
| MP | `party:GetMemberMPPercent(i)` | current MP | light yellow |
| TP | `party:GetMemberTP(i)`, drawn as 3 separate bars (1000 TP each) | current TP (0-3000) | light blue |

The TP row is three individual bars side by side rather than one bar with
dividers, spaced by the same `gap` used between rows. The label is centered
across the whole row, so it prints over the middle bar.

Each bar has one color; opacity comes from a shared fill state instead of
separate colors: `full` (1.0, alpha) for a fully-filled bar or a TP segment
past its threshold, `incomplete` (0.5) for a TP segment still charging, and
`empty` (0.2) for the background track behind any bar. So a TP segment that
hits 1000/2000/3000 visibly "locks in" brighter than the one still charging,
without needing a separate color.

One panel per party member (all 6 slots), each anchored to that member. Turn
off with **Show Party Members** in the config window to go back to self only.
A slot is skipped when it is empty, out of zone, or off screen; the whole UI
hides while zoning or logged out.

The server only sends raw HP/MP for *you* — for everyone else those read 0, so
their labels fall back to the percent it does send. TP is raw for everyone.
Party members' MP bar follows their own job, and is dropped until their job is
known.

Three visibility gates, all off by default. They are **additive**: with none on
the panel always shows, and with any on it shows whenever at least one enabled
gate passes. Several on is a union, so being engaged is enough on its own even
when the battle-target check disagrees.

| Setting | Shows when | Notes |
|---|---|---|
| **Show In Combat** | you have a battle target (`<bt>`, via `SeekBattleActor`) | Signature scan, unverified on this client — see below. Prefer **Show While Engaged** |
| **Show While Engaged** | your entity status is `Engaged` (1) | Flips back to Idle the moment you disengage |
| **Show While Idle** | your entity status is `Idle` (0) | Standing around, not fighting |

Dead (2/3), Zoning (4) and Resting (33) match none of these, so with any gate
on the panel is hidden in those states.

### On the battle-target gate

`SeekBattleActor` is reached through a byte-signature scan lifted from Ashita's
`targets.lua`. Signatures are client-version specific, and FFXiMain.dll ships
packed (`.text` has zero raw size on disk; the code is unpacked into memory at
load), so whether this one resolves on CatsEyeXI can only be answered at
runtime — hence `/newui bt`.

The gate fails **closed**: if the scan misses, it reports "not in combat" and
prints a warning at load. It previously failed *open*, which under additive
gates meant the panel was permanently visible whenever the setting was ticked.

**Show While Engaged** tests essentially the same condition through a supported
Ashita API with no signature involved, so prefer it. The battle-target gate is
kept for the case where you want "has a target" specifically.

Every visual property (panel size/rounding/colors, bar heights/colors, border,
text color) is configurable via `/newui config` and persists across sessions.

## Commands

| Command | Effect |
|---|---|
| `/newui` | Toggle on/off |
| `/newui height <n>` | Vertical world offset. Positive is below feet. Default `0.3` |
| `/newui config` | Toggle the settings window |
| `/newui bt` | Print what the battle-target gate sees (scan address, actor, entity index, status) |

The default height is a guess — model heights vary by race and mount, so nudge it in-game.

## Files

- `NewUI.lua` — projection, ImGui rendering, config window, commands
- `stats.lua` — HP/MP/TP normalization + TP segment math (no Ashita dependencies)
- `config.lua` — settings defaults, load/save, derived layout math (no Ashita dependencies except load/save)
- `test.lua` — self-check for `stats.lua` and `config.lua`; run with `lua test.lua`
- `docs/` — research notes this was built from (gitignored)

## Notes

Bars are drawn directly with Ashita's bundled ImGui background draw list
(`AddRectFilled`, `AddRect`, `AddText`) rather than the `primitives` library,
since `primitives` can't render text or rounded corners. Settings are
persisted with Ashita's `settings` library, one shared file for all
characters.
