# NewUI

Ashita v4 addon. Draws a styled HP/MP/TP unit-frame panel that tracks your
character in 3D space, anchored to the nameplate.

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

Three visibility gates. Each one only ever **enables**: the panel shows when at
least one *enabled* gate's condition is true, and is hidden otherwise. Several
on is a union, so being engaged is enough on its own even when the battle-target
check disagrees.

All three off therefore means the panel never draws — **Show While Engaged** and
**Show While Idle** are on by default. (Earlier versions fell back to "always
show" with no gate enabled, which made a single ticked gate look broken: it
could never hide anything until you ticked a second one.)

| Setting | Shows when | Notes |
|---|---|---|
| **Show In Combat** | your battle target (`<bt>`, via `SeekBattleActor`) resolves to a living mob | Signature scan, unverified on this client — see below |
| **Show While Engaged** | your entity status is `Engaged` (1) | Flips back to Idle the moment you disengage |
| **Show While Idle** | your entity status is `Idle` (0) | Standing around, not fighting |

Dead (2/3), Zoning (4) and Resting (33) match none of these, so with any gate
on the panel is hidden in those states.

### On the battle-target gate

`<bt>` comes from `lib/targets.lua` — Ashita's own `targets.lua`, dropped in
**unmodified**, the same file Sidekick carries at `lib/core/targets.lua`. It is
`require`d inside a `pcall`: it hard-`error`s at load if any of its four
byte-signature scans miss, and only the `SeekBattleActor` one matters here, so a
miss disables the in-combat gate rather than taking the whole addon down.
Signatures are client-version specific and FFXiMain.dll ships packed (`.text`
has zero raw size on disk; the code is unpacked into memory at load), so whether
they resolve on CatsEyeXI can only be answered at runtime.

The gate fails **closed**: if the library does not load, it reports "not in
combat" and prints a warning at load. It previously failed *open*, which under
additive gates meant the panel was permanently visible whenever the setting was
ticked.

`get_bt() ~= nil` is **not** the gate, because it is not a combat test:
`SeekBattleActor` keeps handing back an entity after the fight ends, and that
entity is not always a mob — a trust in your own party turns up there, which
pinned the gate on. Three filters run on top of the library's answer, matching
what Sidekick's `is_combat` does:

- **Mob** — `SpawnFlags & 0x10`, same test as Sidekick. Rejects PCs, NPCs, and
  whatever stale index the pointer happened to hold.
- **Alive** — `HPPercent > 0` and status not `2`/`3`. The corpse is still handed
  back for a while after the kill.
- **Not yours** — server id absent from party slots `0..17`. Trusts and pets
  carry the mob flag (they live in the `0x700` index range), so the flag test
  alone does not exclude them; the alliance range is covered too.

A target that fails any of them is printed with ` REJECTED` on the status line
rather than dropped, so "the gate is off but `get_bt` has something" reads
differently from "`get_bt` has nothing".

### Reading the gate state

Both gate conditions are evaluated once per frame into a single state table,
*before* any of the early returns, so it keeps updating while the addon is
disabled or the panel is gated off. The top line of `/newui config` shows it
live — **In Combat / Engaged / Idle** in green when true, red when false,
followed by the raw entity status and what `<bt>` currently resolves to:

```
In Combat: true  Engaged: true  Idle: false  | status=1 | bt: Mandragora hp=63% status=1 flags=0x10
Panel: shown
```

`Panel:` is the resulting decision, so a gate reading false while the panel is
on screen is visible as a contradiction rather than something to infer. With no
gate enabled it reads `hidden -- no gate enabled, so nothing can enable it`.

`status=` before the pipe is *your* entity status; the one inside `bt:` is the
battle target's, so a corpse still being handed back by `get_bt` is visible as
`status=2`/`3` or `hp=0%`, and the trust case as `REJECTED` on a party member's
name. `bt: none` means `get_bt` returned nothing.
`/newui bt` prints the same line to the log.

**Show While Engaged** tests a similar condition through a supported Ashita API
with no signature involved. The battle-target gate is the one that stays true
while a claimed mob is alive but you are disengaged.

Every visual property (panel size/rounding/colors, bar heights/colors, border,
text color) is configurable via `/newui config` and persists across sessions.

## Commands

| Command | Effect |
|---|---|
| `/newui` | Toggle on/off |
| `/newui height <n>` | Your own vertical nudge from the nameplate anchor. Positive is downward. Default `0.0` |
| `/newui config` | Toggle the settings window |
| `/newui bt` | Print the current gate state (in combat / engaged / idle, raw status, resolved `<bt>` or why it was rejected) |

`0.0` puts the panel's top edge level with the top of the model, i.e. directly under the
nameplate; nudge from there. Self and party have separate offsets (`Self Height Offset` /
`Party Height Offset` in `/newui config`); the command only touches your own.

## Nameplate anchor

The panel hangs from the same point the game hangs a nameplate from: the top of the rendered
model, read from the actor's skeleton (highest bone, i.e. smallest Z — the height axis points
down). That makes the offset from the plate hold across races, mounts, sitting, and mid-jump,
all of which a fixed world offset from the ground gets wrong.

It is *not* a hook into the game's own draw code. FFXI computes the nameplate's screen position
inside `FFXiMain.dll` each frame and keeps it nowhere readable, so pixel-exact co-location needs
a code cave — see `docs/NAMEPLATE-HOOK-RESEARCH.md`, which prices that at 2–4 days plus live
frame-dumping to find the stack slots. This gets within a couple of pixels for the cost of a
pointer walk.

If the skeleton can't be read (zoning, model swap, an invalid index), the panel silently falls
back to the entity's feet position for that frame. `/newui config` shows which of the two is
live on the **Anchor** line — red there, not a mis-tuned offset, is why the panel would sit at
your feet.

## Files

- `NewUI.lua` — projection, ImGui rendering, gate state, config window, commands
- `nameplate.lua` — actor → skeleton → bone walk for the model-top anchor (memory reader injected, so it tests headless)
- `lib/targets.lua` — Ashita's target library, vendored unmodified (only `get_bt` is used)
- `stats.lua` — HP/MP/TP normalization + TP segment math (no Ashita dependencies)
- `config.lua` — settings defaults, load/save, derived layout math (no Ashita dependencies except load/save)
- `test.lua` — self-check for `stats.lua`, `config.lua` and `nameplate.lua`; run with `lua test.lua`
- `docs/` — research notes this was built from (gitignored)

## Notes

Bars are drawn directly with Ashita's bundled ImGui background draw list
(`AddRectFilled`, `AddRect`, `AddText`) rather than the `primitives` library,
since `primitives` can't render text or rounded corners. Settings are
persisted with Ashita's `settings` library, one shared file for all
characters.
