# NewUI

Ashita v4 addon. Draws a styled HP/MP/TP unit-frame panel that tracks your
character in 3D space, anchored below the feet.

## V2

A rounded, bordered panel with three stacked bars, each showing its raw
current value as text:

| Bar | Source | Label | Default color |
|---|---|---|---|
| HP | `party:GetMemberHPPercent(0)` | current HP | light red |
| MP | `party:GetMemberMPPercent(0)` | current MP | light yellow |
| TP | `party:GetMemberTP(0)` / 3000, split into 3 segments (1000 TP each) | current TP (0-3000) | light blue |

Each bar has one color; opacity comes from a shared fill state instead of
separate colors: `full` (1.0, alpha) for a fully-filled bar or a TP segment
past its threshold, `incomplete` (0.5) for a TP segment still charging, and
`empty` (0.2) for the background track behind any bar. So a TP segment that
hits 1000/2000/3000 visibly "locks in" brighter than the one still charging,
without needing a separate color.

Self only. Hidden while zoning, logged out, or when the anchor point is off screen.
Every visual property (panel size/rounding/colors, bar heights/colors, border,
text color) is configurable via `/newui config` and persists across sessions.

## Commands

| Command | Effect |
|---|---|
| `/newui` | Toggle on/off |
| `/newui height <n>` | Vertical world offset. Positive is below feet. Default `0.3` |
| `/newui config` | Toggle the settings window |

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
