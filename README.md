# NewUI

Ashita v4 addon. Draws HP, MP and TP bars above your character's head in 3D space.

## V1

Three stacked rectangles that track your character as you move and rotate the camera:

| Bar | Colour | Source |
|---|---|---|
| HP | red | `party:GetMemberHPPercent(0)` |
| MP | blue | `party:GetMemberMPPercent(0)` |
| TP | yellow | `party:GetMemberTP(0)` / 3000 |

Self only. Hidden while zoning, logged out, or when the anchor point is off screen.

## Commands

| Command | Effect |
|---|---|
| `/newui` | Toggle on/off |
| `/newui height <n>` | Vertical world offset. Negative is up. Default `-2.4` |

The default height is a guess — model heights vary by race and mount, so nudge it in-game.

## Files

- `NewUI.lua` — projection, rendering, commands
- `stats.lua` — HP/MP/TP normalization (no Ashita dependencies)
- `test.lua` — self-check for `stats.lua`; run with `lua test.lua`
- `docs/` — research notes this was built from (gitignored)

## Notes

Bars are drawn with Ashita's `primitives` library rather than raw D3D8 vertex buffers.
Solid-colour rectangles need no texture, so the vertex format, texture stage states and
render state block described in `docs/ENTITY-POSITION-RESEARCH.md` section 5 are not
needed. Only the world-to-screen projection (section 4) was carried over.
