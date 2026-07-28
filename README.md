# NewUI

Ashita v4 addon. Draws a styled HP/MP/TP unit-frame panel that tracks your
character in 3D space, anchored to the nameplate.

## V2

A rounded panel over a dark scrim with three stacked bars, each able to show its
raw current value as text:

| Bar | Source | Label | Default color | Label on by default |
|---|---|---|---|---|
| HP | `party:GetMemberHPPercent(i)` | current HP | light red | yes |
| MP | `party:GetMemberMPPercent(i)` | current MP | light yellow | no |
| TP | `party:GetMemberTP(i)`, drawn as 3 separate bars (1000 TP each) | current TP (0-3000) | light blue | no |

Only HP prints its number by default — it is the one being read — while the
shorter MP and TP bars stay clean. **Show MP / TP Text** turns theirs back on.

The TP row is three individual bars side by side rather than one bar with
dividers, spaced by the same `gap` used between rows. The label is centered
across the whole row, so it prints over the middle bar.

**Percent labels are marked with a `%`.** Raw HP/MP only arrives for yourself;
for anyone else — and for every target panel — the client sends a percent and no
amount, so the label falls back to that percent. It prints as `42%`, not `42`,
because the two are the same integer and reading a mob at "42" as 42 HP left is
the obvious way to misread it. TP is always raw, so it never carries a sign.

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

## Panel sizes

Size is the one setting that is **not** shared between the three panel kinds.
Self, party and target each own a width and a height per bar, under `sizes` in
the settings file and in their own block in `/newui config`:

| Panel | Settings | Defaults |
|---|---|---|
| Self | Width, HP / MP / TP Height | 200 — 18 / 10 / 16 |
| Party | Width, HP / MP / TP Height | 150 — 14 / 7 / 10 |
| Target | Width, HP Height | 300 — 20 |

The defaults size by how closely each is read: the target panel is the widest,
then your own, then the five party panels that are on screen all at once.

Target lists one height because it draws one bar — see below. Every other visual
property (padding, rounding, bar colors, fill alphas, borders, text color) stays
common to all three, so a retint is still a single edit.

Panel geometry is still derived, not stored: bar width is `width - 2*offset`
(minus the slot box, when that is on — see **Party slot indicator**) and
panel height is the sum of the heights that panel's bars actually use, plus the
gaps between them and the padding. A job with no MP pool therefore gets a
shorter panel at whatever heights that kind is set to.

> Upgrading from a version before this split: the old shared `panel.width` and
> `bars.*.height` keys are ignored, so those two settings return to the defaults
> above once and need setting again per panel. Everything else in your settings
> file carries over.

## Party slot indicator

**Party Slot Indicator** (on) draws that member's party slot — `P1` through `P5`,
the same slots `<p1>`..`<p5>` address — in a box on the left of the panel, and
shifts the bars right to make room.

**Your own panel never gets one.** The panel over your own head is the one you
never need told apart from the others, and it reserves no box either, so your
bars keep the full width rather than sitting beside a blank space.

The box takes its space **out of the bars, not out of the panel**: `width` stays
what you set it to, so the bars shift right and shorten by the box plus one gap.
Growing the frame instead would resize every panel the moment the box was ticked.
At the default `21`px text and `1` gap that is 32px of the party panel's 150.

It is separated from the bars by the same **Bar Gap** the bars are separated from
each other by, and sits inside the same panel padding, so the left edge lines up
with nothing new. The box spans the full content height — all bars, not just the
top one — with the text centered in it, so it reads as one tag against the whole
stack.

**Slot Text Size** is the tag's height in pixels, the one piece of text with a
size of its own (bar labels take theirs from their bar — see **Label size**). The
box's width is derived from it at a fixed 1.5:1, which fits `P1` with room either
side at every size in both Ashita's font and ImGui's built-in one. Below **Min
Text Size**, including once the distance scale has shrunk it there, the tag drops
out the same way a bar label does; the reserved space stays, so the bars don't
jump as you walk away.

Target panels never get one either — an arbitrary entity has no party slot — so
that panel also reserves no space and keeps its full bar width.

## Distance scaling

**Scale With Distance** (on) shrinks panels as their entity moves away and grows
them as it comes closer, so a panel keeps its proportion to the nameplate above
it instead of staying a fixed pixel size at every range. Turn it off for a fixed
pixel size at every range.

The curve is the perspective divide itself — the same one the game applies to
the nameplate — so the two track each other for free rather than being tuned to
match:

```
scale = clamp(Scale Reference Depth / view depth, 0.35, 1.5)
```

*View depth* is distance along the camera's forward axis, not the straight-line
distance to the entity. That is the quantity the projection already divides by,
so it costs nothing to read and needs no camera position out of memory.

**Scale Reference Depth** (`6.0`) is the depth at which a panel draws at its
configured size, and the only knob — the `0.35`/`1.5` clamps are fixed, so a
distant panel stays a readable smudge and a near one does not fill the screen.

The reference defaults to `6.0` because that is roughly where the third-person
camera sits: your own panel lands near 1:1 and everything else scales away from
it. A much larger reference pegs self at the ceiling permanently, at which point
the slider stops doing anything you can see.

Scale is taken at the anchor point, so the panel's top edge stays pinned under
the nameplate and the panel grows or shrinks downward from there. Padding and
corner rounding scale with everything else — otherwise a shrunk panel keeps a
full-size border that swallows its own bars.

The numbers scale with everything else, because their size is not a setting: a
label is drawn at its own bar's height (see **Label size**), and that height
already carries the scale.

## Target panel

A panel over whatever you currently have targeted, on top of the self and party
ones. **Show Target** in the config window turns it off; it has its own
**Target Height Offset**.

**One bar, HP only.** Party panels can show MP and TP because the party packets
carry them. For an arbitrary entity the client is told a single number — an HP
percent — and nothing else, so there is no MP or TP to draw. The label is that
percent, via the same `hp_raw == 0` fallback party members' labels already use,
and prints with a trailing `%` for exactly that reason. The panel shrinks to fit
the one bar — and grows again for the reference lines under it, if those are on
(see **Target reference lines**).

**Which target.** The cursor target (`<t>`) first; when nothing is selected, the
battle target (`<bt>`) instead, so clearing your target mid-fight doesn't blank
the panel. With a sub-target open (the green cursor, picking a cure recipient)
the live selection is target slot 1, which is what gets drawn — the same way
`lib/targets.lua` resolves `<t>`.

The cursor read goes through Ashita's target manager, not `lib/targets.lua`, so
it still works when the signature scans miss. Only the `<bt>` fallback carries
that dependency, which the in-combat gate already did.

**What draws.** Mobs (`SpawnFlags & 0x10`) and players (`& 0x01`). NPCs (`&
0x02`) don't — you target them constantly just to talk, and a health bar over a
shopkeeper is noise. Corpses don't (`HPPercent == 0`, or status `2`/`3`).
Neither do you or your party members in slots `0..5`, since those already have a
panel and a second one would stack on it.

That party check is `0..5`, deliberately narrower than the in-combat gate's
`0..17`. The gate scans the full alliance to reject *trusts and pets* as combat
evidence; here a trust or pet you've targeted is a perfectly good thing to draw
a panel over. Alliance members outside your own party get one too. Two small
predicates, two different questions.

**Gating.** The target panel obeys the same three visibility gates as everything
else — one decision per frame, everything shows and hides together.

Three visibility gates. Each one only ever **enables**: the panel shows when at
least one *enabled* gate's condition is true, and is hidden otherwise. Several
on is a union, so being engaged is enough on its own even when the battle-target
check disagrees.

All three off therefore means the panel never draws — all three are on by
default, which shows the panel in normal play and still hides it while dead,
zoning or resting, since those match no gate. (Earlier versions fell back to
"always show" with no gate enabled, which made a single ticked gate look broken:
it could never hide anything until you ticked a second one.)

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
In Combat: true  Engaged: true  Idle: false  | status=1
bt: Mandragora hp=63% status=1 flags=0x10
target: Mandragora hp=63% status=1 flags=0x10
Panel: shown
```

`Panel:` is the resulting decision, so a gate reading false while the panel is
on screen is visible as a contradiction rather than something to infer. With no
gate enabled it reads `hidden -- no gate enabled, so nothing can enable it`.

`status=` before the pipe is *your* entity status; the one inside `bt:` is the
battle target's, so a corpse still being handed back by `get_bt` is visible as
`status=2`/`3` or `hp=0%`, and the trust case as `REJECTED` on a party member's
name. `bt: none` means `get_bt` returned nothing.

`target:` is the same treatment for the target panel, so an NPC you have clicked
reads as ` REJECTED` with `flags=0x2` rather than looking identical to targeting
nothing at all. `/newui bt` prints all of it to the log.

**Show While Engaged** tests a similar condition through a supported Ashita API
with no signature involved. The battle-target gate is the one that stays true
while a claimed mob is alive but you are disengaged.

Every visual property is configurable via `/newui config` and persists across
sessions — per-panel widths and bar heights (see **Panel sizes**), and shared
padding/rounding/colors/border/text color.

The default panel is black at `100/255` alpha with a fully transparent **Panel
Border Color**: the frame reads as its own shape against the world rather than an
outlined box. **Border Visible** stays on regardless — it also controls the bar
outlines, which do use theirs (black at `150/255`). To get a panel outline back,
raise the border color's alpha rather than looking for a second toggle.

Labels carry a separate outline color from their fill: **Text Outline Color**
draws the number a second time one pixel out in each direction, underneath, so a
white digit stays readable over a light bar. Setting its alpha to `0` skips the
outline pass — there is no separate toggle.

### Label size

Bar label size is not configurable, and deliberately so: a label is drawn at the
height of the bar it sits in, so it can never be taller than that bar — at any
configured bar height and at any distance scale, since the drawn height already
carries the scale. (The slot tag is the one exception, and has its own size —
see **Party slot indicator**.)

A bar that cannot hold a legible digit drops its label instead of drawing mush.
That happens when the size the bar would give works out under **Min Text Size**
(`12`), or when the value is too wide for the bar. Both are decided per bar, not
per panel: a short TP row can go quiet while the HP row above it still prints.
Raise **Min Text Size** to drop labels sooner, lower it to keep them further
out.

The floor defaults to `12` because ImGui rasterizes its font at 13px and scales
down from there: a label that prints at 12 or above is drawn at about the size
the atlas actually holds, while below it the digits lose enough pixels to read as
texture rather than numbers and the 1px outline underneath ends up wider than the
strokes it is outlining. At the shipped bar heights it also means the labels fade
out with distance a step before the bars themselves stop being readable.

Label size and origin are both snapped to whole pixels, to stop the text
shimmering while the camera moves: a glyph asked for at a fractional size or
drawn at a fractional origin gets resampled differently every frame.

**Bold Text** (on) stamps the fill a second time one pixel right, thickening
every vertical stroke. It is not a bold face: ImGui takes a font, not a weight,
and the font atlas belongs to Ashita, which builds it before any addon loads —
so a real bold face would mean shipping and baking a second TTF. The extra pixel
is counted into the width fit check, so bolding a label can push a wide value
over its bar's width and hide it.

### Per-bar text

**Show HP / MP / TP Text** switch a bar's number off without touching its
height, for the case where the bar itself is worth keeping and the digits on it
are not. HP ships on, MP and TP off. They are independent of the size rules above
— a bar hides its label if either the toggle is off or the bar is too short for
it.

Sizing the text uses `ImDrawList`'s second `AddText`, the one taking a font and
a size.

## Target reference lines

Three lines of mob reference data under the target panel's HP bar, each with its
own toggle in `/newui config`:

| Setting | Line | Example |
|---|---|---|
| **Show Level & Job** | level range, and the job when the entry names one | `[Lv14-17 WAR/MNK]` |
| **Show Detection** | aggression, then what it notices you with | `NM Aggro TrueSight Sight Link` |
| **Show Weakness/Resist** | every damage type it does not take normally | `Fire+25% Ice-50% Dark-50%` |

All three ship on. They draw on the target panel only — party members are not
mobs, and a PC you have targeted has no entry either.

**A ticked box does not guarantee a row.** A line with nothing to say is skipped
rather than drawn blank: a mob with no job prints its level range alone, and a
mob that takes every damage type normally has no resistance line at all. Only
the detection line always prints when it is on, because "detects nothing" and
"does not aggro" are different facts and a vanished line would read as missing
data rather than as a safe mob.

Resistances are sorted by potency, weaknesses first, so what to hit it with
reads before what to avoid. Ties keep a fixed order (physical first, then the
elements in the game's own order) rather than whatever `pairs` hands back — the
line is rebuilt every frame, and an order that shuffled between frames would
flicker. `Slashing`/`Piercing`/`Impact` print as `Slash`/`Pierce`/`Blunt`.

**The panel widens to fit the longest line**, rather than the text shrinking or
being dropped. A resistance list is the one thing on the panel with no natural
width — a mob weak and resistant to eight damage types is a long line at any
font size that stays legible. The bars keep the width they were configured with
and stay centered on the anchor, so a panel that widens leaves everything that
was already on it exactly where it was. **Info Text Size** (`14`) is the line
height; below **Min Text Size**, including once the distance scale has shrunk it
there, the lines drop out the way bar labels do, and the reserved height stays so
the panel doesn't change shape as you walk away.

### Where the data comes from

[mobdb](https://ashitaxi.com/)'s zone files, read straight off disk from
`Ashita/addons/mobdb/data/<zone>.lua` — reloaded on zone-in (packet `0x00A`),
the same hook mobdb reloads its own on.

**mobdb does not have to be loaded, or even installed.** Those files are plain
`return { Names = {...}, Indices = {...} }` tables with no globals and no
`require`s in them, so `loadfile` is the whole dependency. A zone with no file,
or no mobdb at all, reads as no data and the lines simply don't draw — which is
also why the loader is testable headless along with everything else.

Entries are looked up by entity index first and by name second, matching mobdb:
dynamic spawns (the `0x700`+ range) differ per zone instance and are keyed by
index, everything else by name. Client name markers are stripped before the name
lookup.

The config window's `mob data:` line reports the loaded zone and whether a file
was found, so "every line ticked and still nothing under the bar" can be told
apart from "mobdb isn't installed":

```
mob data: zone 100, loaded
```

Job abbreviations come from Ashita's own job resource, with the same
`jobs.names_abbr` → `jobs_abbr` fallback mobdb carries for older versions.

Unlike mobdb, the lines are text only — mobdb draws the detection and
resistance flags as icons, which would mean shipping and loading a texture set
for panels that are a few dozen pixels tall.

## Commands

| Command | Effect |
|---|---|
| `/newui` | Toggle on/off |
| `/newui height <n>` | Your own vertical nudge from the nameplate anchor. Positive is downward. Default `0.228` |
| `/newui config` | Toggle the settings window |
| `/newui bt` | Print the current gate state (in combat / engaged / idle, raw status, resolved `<bt>` and target, or why either was rejected) |

`0.0` puts the panel's top edge level with the top of the model, i.e. directly under the
nameplate; nudge from there. Self, party and target have separate offsets (`Self Height
Offset` / `Party Height Offset` / `Target Height Offset` in `/newui config`); the command
only touches your own. They default to `0.228` / `0.125` / `0.125` — everything hangs a
little below the plate, your own taller panel slightly further.

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
back to the entity's feet position for that frame.

## Files

- `NewUI.lua` — projection, ImGui rendering, gate state, config window, commands
- `nameplate.lua` — actor → skeleton → bone walk for the model-top anchor (memory reader injected, so it tests headless)
- `lib/targets.lua` — Ashita's target library, vendored unmodified (only `get_bt` is used)
- `stats.lua` — HP/MP/TP normalization, TP segment math, and the target's entity read + targetability test (no Ashita dependencies)
- `config.lua` — settings defaults, load/save, derived layout math (no Ashita dependencies except load/save)
- `mobinfo.lua` — mobdb zone-data loader and the three reference lines' formatting (no Ashita dependencies)
- `test.lua` — self-check for `stats.lua`, `config.lua`, `nameplate.lua` and `mobinfo.lua`; run with `lua test.lua`
- `docs/` — research notes this was built from (gitignored)

## Notes

Bars are drawn directly with Ashita's bundled ImGui background draw list
(`AddRectFilled`, `AddRect`, `AddText`) rather than the `primitives` library,
since `primitives` can't render text or rounded corners. Settings are
persisted with Ashita's `settings` library, one shared file for all
characters.
