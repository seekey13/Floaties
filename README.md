# Floaties

Ashita v4 addon. Draws a styled HP/MP/TP unit-frame panel that tracks your
character in 3D space, anchored to the nameplate.

## V2

A rounded panel over a dark scrim with three stacked bars, each able to show its
raw current value as text:

| Bar | Source | Label | Default color | Label on by default |
|---|---|---|---|---|
| HP | `party:GetMemberHPPercent(i)` | current HP | light red | no |
| MP | `party:GetMemberMPPercent(i)` | current MP | light yellow | no |
| TP | `party:GetMemberTP(i)`, drawn as 3 separate bars (1000 TP each) | current TP (0-3000) | light blue | no |

No bar prints its number by default: at the heights the panels ship at a digit
is most of the bar it sits in, and the fill is already the read. **Show HP / MP /
TP Text** turns each back on — HP first, if you want one, since its number is the
one being read.

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

## Pet panels

Pets get a panel of their own, drawn with the **party** panel's width, bar
heights and height offset. A pet is a party-member-shaped thing, and giving it a
third set of size sliders would mean keeping two sets in step by hand for no
gain — so there is no Pet Panel block in the config window, and its two switches
live under **Party Panel** instead:

| Setting | Default | What it draws |
|---|---|---|
| **Show My Pet** | on | Your own avatar / automaton / wyvern / jug pet / luopan |
| **Show Party Pets** | on | Every other party member's pet |
| **Share Pet Info** | on | Swaps pet MP/TP with the other Floaties sessions on this PC |

Two switches, not one, because the two cost very different amounts of screen:
your own pet is one extra panel and is the one you actually manage, while a
party of summoners is six. **Show My Pet** is also independent of **Show Party
Members** — it is your pet, not the party's, so switching the party's panels off
does not take it with them.

Pets have no party slot, so they are reached through their owner's target index
(`GetPetTargetIndex`) rather than by scanning; the same 0..5 walk the party
panels use covers them.

**Only your own pet shows more than HP** — unless the owner is another Floaties
session on this PC, see **Shared pet info** below. The client publishes pet MP and
TP through the player block, which has room for exactly one pet — yours. Everyone
else's pet is just another entity, so it draws the single HP bar a target panel
does, percent-labelled like any other entity read.

Your pet's MP bar follows the **owner's job**, not a live MP reading: SMN and PUP
draw HP/MP/TP, every other pet job draws HP/TP. Testing the percent instead would
make an avatar's bar disappear the moment it spent its last MP and reappear on
the next tick, and a wyvern would still need excluding by hand. A charmed pet
draws no MP bar.

Pet panels carry **no slot tag**: a `P3` box over slot 3's pet would read as slot
3's own panel rather than as its pet.

They do print a **name line**, on the same terms a party member's panel does — it
appears only in place of a plate this addon took away, so it comes and goes with
**Hide Party Nameplates**, which covers pets (see below). Your own pet prints its
name there too, unlike your own panel: the mask takes your pet's plate but not
yours, so leaving the line off slot 0's pet would remove a name and put nothing
back.

A pet at 0% is skipped, the same corpse rule the target and enemy-list panels
follow.

### Shared pet info

Multiboxing on one PC, the second box's avatar drew one bar where its own session
drew three — the MP and TP are on that session's screen, they just have no way
across. With **Share Pet Info** on, every Floaties session writes its own pet's
numbers to `config/addons/floaties/pet_<CharName>.txt` and reads the file
belonging to each party member it draws a pet for, so both boxes show the full
bar set. Nothing to set up beyond running the addon on both. (Sidekick shares a
party roster through the same directory the same way.)

The published line is `<pet server id> <mp percent> <raw tp> <unix seconds>`,
rewritten twice a second while a pet is out:

- **HP is not in it.** The entity table already carries a live HP percent for
  anybody's pet, so sharing it would only add a way for the two to disagree.
- **Lookup is by character name**, not by scanning the directory: the only pets
  drawn hang off party slots 0..5, and those owners' names are already in hand. A
  session whose character isn't in your party publishes a file nobody reads.
- **The server id is checked against the pet actually being drawn.** A member who
  swaps avatars leaves the old id in the file until the next write, and MP
  belonging to the wrong pet is worse than no MP bar.
- **Staleness retires the data, not a teardown path.** A line older than 5s is
  ignored, which covers the publisher dismissing its pet, zoning, logging out,
  unloading the addon or crashing — all of which just stop the writes.
- **Publishing runs ahead of the visibility gates and ignores Show My Pet**, since
  what it writes is for somebody else's screen. Which bars *draw* still follows
  the owner's job, exactly as for your own pet: a shared jug pet gets HP/TP.
- **One switch covers both halves**, publish and read: a session that won't
  publish has no business reading, and the exchange is worthless unless both ends
  are in it.

## Panel sizes

Size is the one setting that is **not** shared between the three panel kinds.
Self, party and target each own a width and a height per bar, under `sizes` in
the settings file and in their own block in `/floaties config`. Pets are not a
fourth kind — they draw with the party's (see **Pet panels**):

| Panel | Settings | Defaults |
|---|---|---|
| Self | Width, HP / MP / TP Height | 200 — 8 / 6 / 10 |
| Party | Width, HP / MP / TP Height | 150 — 8 / 6 / 10 |
| Target | Width, HP Height | 300 — 23 |

The defaults size by how closely each is read: the target panel is the widest
and by far the tallest — it is the thing being read at a glance — then your own,
then the five party panels that are on screen all at once. Self and party ship
the same bar heights and differ only in width; the split is still per kind, so
raising one does not raise the other.

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

**Party Slot Indicator** (off) draws that member's party slot — `P1` through `P5`,
the same slots `<p1>`..`<p5>` address — in a box on the left of the panel, and
shifts the bars right to make room.

**Your own panel never gets one.** The panel over your own head is the one you
never need told apart from the others, and it reserves no box either, so your
bars keep the full width rather than sitting beside a blank space.

The box takes its space **out of the bars, not out of the panel**: `width` stays
what you set it to, so the bars shift right and shorten by the box plus one gap.
Growing the frame instead would resize every panel the moment the box was ticked.
At the default `21`px text and `0` gap that is 31px of the party panel's 150.
It ships off: a party panel already sits over the member it belongs to, so `P3`
repeats what the panel's own position says, at the bars' expense.

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

**Target panels get a tag box too, but a different one.** Instead of a party
slot it holds the target's level — a range (`14-17`) or a fixed number (`50`,
also what a checked mob's exact level shows as — see **The check tier**), no
`Lv.` prefix and no job — gated by **Show Level & Job** (`cfg.mob.level`)
rather than by this setting, since an arbitrary entity has no party slot to
gate on. It reserves space out of the bar the same way, through the same
`M.slot_width` — the box just holds different text depending on which panel
kind is drawing it.

## Hiding nameplates

Two settings, one mechanism: **Hide Party Nameplates** covers the party and its
pets, **Hide Target Nameplates** covers the mobs a target or enemy-list panel is
drawing over. Everything from **How it works** down applies to both.

### Party members and pets

**Hide Party Nameplates** (on) switches the client's own name off over party
members `P1`..`P5` **and over every party member's pet, yours included**, leaving
their panel as the only thing above their head. The plate otherwise repeats what
the panel already says, in the space the panel wants.

**The panel then prints the name itself**, one line above its frame — where the
plate was. It is the same deal the mob reference lines get under a target panel:
outside the frame, so it costs the panel no height and the panel is the same
shape with a name as without; and it shrinks with the panel but bottoms out at
**Min Text Size**, because a name you can't read at range isn't standing in for a
nameplate. A name wider than the panel overhangs both sides evenly instead of
being dropped.

**Party Name Size** (`25`) sets its text height. It follows the same rule as
**Info Text Size** but is a knob of its own: a name line and a target's reference
rows are the same *shape* of line, and sizing one to taste shouldn't resize the
other. Targets have their own **Target Name Size** for the same reason (see **The
name above the panel**).

There is no separate switch for the name itself. The name is only there to replace a plate
this addon took away, so it comes and goes with the plate — with it off, the
plate says the name and the panel says the bars, which is the split the game
already had.

### Targets and the enemy list

**Hide Target Nameplates** (on) switches the client's own name off over every mob
a target panel or an enemy-list panel is currently drawing over — the mob you
have selected, and every mob you have personally hit. That panel already prints
the mob's name above its frame, with the check tier prefixed and the job suffixed
(see **The name above the panel**), so the plate is the same name twice in the
same space.

**On by default, like the party one**: both plates duplicate a name the panel
under them already prints, and the mob's is the duplication this addon created —
a mob panel puts a name up there whether or not you asked for a second one.

**It follows the panels, not the target.** A plate is hidden because a panel
actually drew a name over that mob this frame — so a mob off screen, one capped
out by **Enemy List Max**, or one whose panel is switched off entirely keeps the
only name it has left. There is no case where both names are gone. The cost is
one frame of lag at each end: the plate survives the frame a panel first draws,
and stays hidden for the frame after it stops.

**Your own name is not touched here either**, for the same reason — targeting
yourself draws a panel like anything else, but that plate is `noname`'s.

### How it works

It works by setting bit `0x08` of each entity's `Render.Flags2` — the
client's own "name hidden" mask, the same one Ashita's `noname` addon sets on
the local player. Nothing is drawn over or around the plate: the game is told
not to draw it.

**Your own name is never touched, by either setting.** That is `noname`'s job,
and two addons writing one flag on one entity would just fight over it — clearing
the bit back off your entity when you untarget yourself would undo *its* hiding.
**Your pet's is**, though — your
pet is not you, nothing else is hiding its plate, and it is standing in exactly
the space your own panel wants. So the sweep runs over slots `0`..`5` and skips
only the *member* half of slot 0.

It is **independent of Show Party Members**, **Show My Pet** and **Show Party
Pets**, not nested under them: hiding plates without drawing panels is a
legitimate combination, and tying them together would un-hide names the moment
panels were switched off. The flip side is that a pet whose panel is switched off
loses its plate and gets no name line back — the panel is what prints the name.

Consequences of it being a live edit to the client rather than something
Floaties draws:

- **The bit is re-set every frame**, because the client rebuilds an entity's
  render flags wholesale on spawn and on zone.
- **Names come back the moment you switch it (or the addon) off**, because the
  bit is cleared explicitly rather than left for the client's next rebuild to
  drop. A member leaving the party gets theirs back the same frame, as does a mob
  whose panel stopped drawing.
- **Unloading restores every plate still hidden**, from either setting. Leaving
  the bit set would strand entities nameless with nothing running to explain it
  and no way back short of zoning.

### Why it also patches one byte of the client

Setting the bit once a frame is not enough on its own. The client's entity
update runs `and ecx, 0FFFFFFF7h` / `mov [eax+128h], ecx` — `+0x128` is
`Render.Flags2`, `0xF7` is `~0x08` — so every entity update packet (`0x00D` /
`0x00E`) strips the mask straight back off. The plate then draws for the frame
between that clear and the next per-frame write: **a one-frame flash of the
name**, every update, which is what this looked like before the patch.

So the immediate is patched from `0xF7` to `0xF8`, which leaves bit `0x08`
alone — the same byte, and the same value, `noname` writes for the local
player. The per-frame write stays: the patch stops the client clearing the mask,
it does not set it in the first place, and it does not cover the wholesale
rebuild on spawn or zone.

Because it is a write into the client's code rather than into an entity:

- **It is applied only while one of the two settings is on**, and restored the
  moment both go off or the addon unloads. Off means the client is untouched. One
  patch serves both — it stops the client clearing the bit, and neither setting
  cares which one asked for that.
- **It defers to `noname`.** If that byte already reads `0xF8`, Floaties takes
  the benefit and claims no ownership, so unloading Floaties cannot rip
  `noname`'s patch out from under it.
- **If the signature is not found** (`FFXiMain.dll` is packed on disk, so this
  can only be resolved at runtime) it says so once in the log, and hiding still
  works — with the one-frame flash back.

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
percent — and nothing else, so there is no MP or TP to draw. **The bar's label is
that percent**, the same as every other bar on every other panel; the target's
name — prefixed with its `/check` tier and suffixed with its job when mobdb has
an entry — draws one row *above* the frame, where a nameplate goes (see **The
name above the panel**).
The panel shrinks to fit the one bar and stays that shape: every piece of mob
reference is drawn *around* it, never inside, so none of it changes the panel's
geometry.

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

**Ungated.** The target panel does *not* obey the visibility gates below; the
self and party panels do. Having something targeted is already the answer to
"should this draw", and running that through gates keyed on *your own* status
meant a mob you had just clicked drew nothing until you engaged it — the moment
the panel is most for. It answers to **Show Target** and a resolved target and
nothing else, so it appears the frame a valid target is picked and goes the frame
it is cleared, in any status, including while resting or dead.

That leaves two independent decisions per frame instead of one, which is why the
config window reports them on two lines (see **Reading the gate state**).

## Visibility gates

Three visibility gates, covering the **self, party and pet panels**. Each one only
ever **enables**: those panels show when at least one *enabled* gate's condition
is true, and are hidden otherwise. Several on is a union, so being engaged is
enough on its own even when the battle-target check disagrees.

All three off therefore means they never draw — all three are on by default,
which shows them in normal play and still hides them while dead, zoning or
resting, since those match no gate. (Earlier versions fell back to "always show"
with no gate enabled, which made a single ticked gate look broken: it could never
hide anything until you ticked a second one.)

| Setting | Shows when | Notes |
|---|---|---|
| **Show In Combat** | your battle target (`<bt>`, via `SeekBattleActor`) resolves to a living mob | Signature scan, unverified on this client — see below |
| **Show While Engaged** | your entity status is `Engaged` (1) | Flips back to Idle the moment you disengage |
| **Show While Idle** | your entity status is `Idle` (0) | Standing around, not fighting |

Dead (2/3), Zoning (4) and Resting (33) match none of these, so with any gate on
the self and party panels are hidden in those states. A target panel still draws
in them, because it is not gated.

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
disabled or the panel is gated off. The **Debug** collapsing section at the
bottom of `/floaties config` shows it live — **In Combat / Engaged / Idle** in
green when true, red when false, followed by the raw entity status and what
`<bt>` currently resolves to:

```
In Combat: true  Engaged: true  Idle: false  | status=1
bt: Mandragora hp=63% status=1 flags=0x10
target: Mandragora hp=63% status=1 flags=0x10
Self/party panels: shown
Target panel: shown
```

`Self/party panels:` is the resulting decision — **`Enabled` and the gates
together**, not the gates alone — so a gate reading false while a panel is on
screen is visible as a contradiction rather than something to infer. With no gate
enabled it reads `hidden -- no gate enabled, so nothing can enable it`; with the
addon switched off it reads `hidden -- addon switched off; tick Enabled above`.

`Target panel:` is the second decision, and it is deliberately a second line: the
gates do not reach it, so folding both into one `Panel:` verdict would have it
read `hidden` while a target panel was plainly on screen. It is `shown` when
`Enabled` and **Show Target** are both on and the current target survived the
filters above — which is exactly the `target:` line reading anything but `none`
or ` REJECTED`.

`Enabled` is the master switch, a checkbox at the top of **Debug** and
persisted. It lives there, not among the regular settings above it, because the
question "is the addon even on?" is exactly the one Debug's other lines answer
— and leaving it out of the same section that reports "hidden" is what let it
be off and invisible at the same time: the line meant to answer "is this a gate
problem?" said `shown` over an empty screen for as long as the setting stayed
off.

**Either line reading `shown` with nothing on screen means the drawing threw**,
not that a gate is wrong — and a `draw error:` line under it says what. The panels are
drawn inside a `pcall` for exactly this: the config window is drawn *first* in
the frame, so an uncaught throw below it takes every panel with it and leaves
the window truthfully reporting `shown` over an empty screen, with the reason
only in Ashita's own log. Trapped, one bad frame costs the panels and prints
why. The line clears itself on the first frame that draws cleanly.

`status=` before the pipe is *your* entity status; the one inside `bt:` is the
battle target's, so a corpse still being handed back by `get_bt` is visible as
`status=2`/`3` or `hp=0%`, and the trust case as `REJECTED` on a party member's
name. `bt: none` means `get_bt` returned nothing.

`target:` is the same treatment for the target panel, so an NPC you have clicked
reads as ` REJECTED` with `flags=0x2` rather than looking identical to targeting
nothing at all. `/floaties bt` prints all of it to the log.

**Show While Engaged** tests a similar condition through a supported Ashita API
with no signature involved. The battle-target gate is the one that stays true
while a claimed mob is alive but you are disengaged.

Every visual property is configurable via `/floaties config` and persists across
sessions — per-panel widths and bar heights (see **Panel sizes**), and shared
padding/rounding/colors/border/text color.

The default panel is black at `125/255` alpha, edged by a black **Panel Border
Color** at `100/255`: enough scrim to hold the bars off the world behind them,
with a soft edge so the frame still reads as its own shape against a bright zone.
The bar border shares that `100/255`. Both borders draw unconditionally — there
is no visibility checkbox for either — so a transparent alpha is what hides one:
drop **Panel Border Color** to `0` for the borderless look, and raise it again
rather than looking for a separate toggle; the same goes for **Panel Rounding** and **Bar
Rounding**, which turn their rounding off at `0` instead of a checkbox next to
them.

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
(`1`). It is decided per bar, not per panel: a short TP row can go quiet while
the HP row above it still prints. Raise **Min Text Size** to drop labels sooner,
lower it to keep them further out.

Too *narrow* a bar is handled the other way: the label shrinks until it fits,
rather than being dropped. Height and width are different failures — no legible
glyph at all versus a long string in a bar that is tall enough for it — and only
the first is worth going quiet over. See **The level on the bar**, which is what
made the distinction matter.

**The floor ships at `1`, which is the floor switched off** — nothing this addon
ships with prints a number inside a bar (see the label column above), so a floor
tall enough to keep one crisp would only be dropping the slot tag and clipping the
mob reference rows at range, which are the two other things it gates.

Raise it back toward `12` if you switch a bar label on. That is the useful value
because ImGui rasterizes its font at 13px and scales down from there: a label that
prints at 12 or above is drawn at about the size the atlas actually holds, while
below it the digits lose enough pixels to read as texture rather than numbers and
the 1px outline underneath ends up wider than the strokes it is outlining. At the
shipped bar heights, which are short, a label left on with the floor at `1` prints
exactly that mush rather than going quiet.

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
are not. **All three ship off** — at the shipped bar heights a digit is most of
the bar it sits in, and the fill is already the read. They are independent of the
size rules above — a bar hides its label if either the toggle is off or the bar is
too short for it — so switching one on at those heights wants **Min Text Size**
raised with it (see **Label size**).

Sizing the text uses `ImDrawList`'s second `AddText`, the one taking a font and
a size.

## Target reference lines

Mob reference data drawn **around** the target panel — none of it inside the
frame — reading left to right as one sentence: what it does to you, what it is,
what it sees you with.

```
                 EP-DC Tough Mist Lizard WAR/MNK
            14-17
<Passive> <Link> [═════════  71%  ═════════] <Sight> <Sound> <Scent>
                   <Fire>+25% <Ice>-50% <Dark>-50%
```

Four toggles in `/floaties config` feed it:

| Setting | Contributes | Drawn as |
|---|---|---|
| **Show Detection** | the icon groups flanking the bar | left of it: aggro/passive, then Link. Right of it: TrueSight, Sight, Sound, Scent, Magic, JA, Blood |
| **Show Level & Job** | the tag box, and a suffix on the name line | `14-17` in the box; ` WAR/MNK` appended to the name |
| **Show Check** | a prefix on the name line, and the bar's own fill color | the `/check` tier jammed into one string: `EP-DC `, drawn in the name's own color like the name beside it; the bar fills in the tier's color, or a left-to-right low-to-high gradient when the range straddles two tiers |
| **Show Weakness/Resist** | a row under the panel | an icon and a percentage each: `<Fire>+25% <Ice>-50%` |

The target's **name always draws**, whatever mobdb knows about it or doesn't —
it is the entity's own display name, not mobdb data, so a player or an
unrecognized mob still gets a label instead of a blank bar. **Show Check** and
**Show Level & Job**'s job suffix are the only pieces of the label that need a
mobdb entry; the tag box needs one too.

**Show Detection** owns both icon groups because they answer the same question
from two sides — Link sits with the aggro flag rather than with the senses,
since it is not one, and the two of them together are the pull decision. Each
toggle still owns exactly what it names: **Show Detection** alone draws the
icons and leaves the label alone, **Show Level & Job** alone adds the tag box
and the job suffix (no check prefix), and **Show Check** alone prefixes the
label (no tag box, no job).

Resistances stay on their own row under the panel. That list has no fixed
length, so flanking with it would shove the bar off-center by however many
damage types the mob happens to have.

**Three of the four ship on; Show Level & Job ships off.** mobdb's level range
is an estimate wide enough (`14-17`) to be worth less than the space its box takes
out of the bars, and **Show Check** already puts the relative-difficulty read on
the panel. Switch it on to see the exact level a captured `/check` reports — that
one is not an estimate (see **The check tier**). All four draw on the target panel
only — party members are not mobs, and a PC you have targeted has no entry either.

### The name above the panel

**The name is the target's, with the check tier prefixed and the job suffixed
when mobdb has an entry, and it draws one row above the frame** — the same row a
party member's stand-in nameplate uses, outside the frame, so it costs the panel
no height and the panel is the same shape with it as without. **The bar keeps the
plain HP percent.**

That line used to live *inside* the HP bar, and the bar paid for it twice.
`EP-DC Tough Mist Lizard WAR/MNK` is as long as the tier, the name, and the job
pairing make it, so it only ever fit by shrinking toward mush against a bar sized
for a two-digit number — and the percent had to be suppressed at full health to
make room for it at all. Above the frame there is nothing to overflow: a long
name simply overhangs both sides evenly, holds at a legible size, and the percent
is back on the bar unconditionally.

**The name is not mobdb data.** It is the entity's own display name, always
known, so a player you have targeted or a mob mobdb has never heard of still gets
a name line — just without the check prefix or job suffix, which do need an
entry.

**It shrinks with the panel but bottoms out at Min Text Size**, the same rule a
party member's stand-in nameplate follows.

**Target Name Size** (`34`) sets its text height, separately from **Party Name
Size** (`25`). The two are the same *shape* of line but not the same length — a
target's carries the check tier and the job pairing on top of the name — and it is
the one you read from a distance you are not standing at, which is why it ships
larger rather than equal.

#### Aggressive mobs get a different color

**An aggressive mob's name line draws in Aggro Name Color** (`#FFBABA`) instead
of **Text Color** — a paler take on the HP bar's own red, because the line is
saying the thing the bar under it is already colored for: this one walks over to
you. Paler than the bar itself, because a whole name line at the bar's saturation
reads as an error message rather than a warning.

**The whole line takes the tint**, check tier and job suffix included. Those two
are drawn in the name's color on purpose so the three read as one string (see
**The check tier**); coloring a third of it would split that string back in two,
which is the exact thing the tier's own color was moved onto the bar to avoid.

**It needs mobdb.** `Aggro` is a mobdb flag, so a mob mobdb has never heard of —
and a player — keeps the plain color. Same "no entry, no data" rule the detection
icons follow.

**It is not gated by Show Detection**, or by any of the other three. Those switch
the reference *lines* on and off; this is a tint on a line that draws whatever
they are set to. There is no separate toggle either — set **Aggro Name Color** to
match **Text Color** and it stops saying anything.

### The check tier

**Show Check** prefixes the name line with the `/check` tier, and fills the
bar itself in that tier's color — your main job level against the mob's level
from mobdb, so it is the one piece of the panel that is about *you* rather
than about the mob.

| | Abbreviation | Level difference at 1 | at 75 |
|---|---|---|---|
| Too Weak to be Worthwhile | `TW` | 7+ below | 20+ below |
| Easy Prey | `EP` | 3–6 below | 8–19 below |
| Decent Challenge | `DC` | 1–2 below | 1–7 below |
| Even Match | `EM` | same level | same level |
| Tough | `T` | 1–4 above | 1–3 above |
| Very Tough | `VT` | 5 above | 4–7 above |
| Incredibly Tough | `IT` | 6+ above | 8+ above |
| Impossible to Gauge | `???` | any notorious monster | |

It leads the label — before the name — because it is read first: whether to
engage at all is answered before anything else on the panel matters.

**The prefix draws in the name line's own color, same as the name and job around
it** (**Text Color**, or **Aggro Name Color** when the whole line is tinted) — it
used to be tinted with its tier, which made the line read as a colored word glued
to a white one at every size. The tier's color is not lost: it fills the whole HP bar underneath, where
it says the same thing at a glance without breaking the line of text into two.

**The bands are interpolated between the two published endpoints**, not looked
up. The server derives the tier from the experience the kill would award and
that curve flattens with level, which is why Too Weak is 7 levels down at 1 and
20 down at 75. A straight line between the two reproduces it within a level
across the whole range for one line of arithmetic instead of a 75×75 table.
Above 75 the boundaries hold at their level-75 values rather than running off the
end of the curve.

**A level *range* that straddles a boundary is jammed into one string** —
`EP-DC` for a Lv.14-17 mob at level 20 — instead of printing each end in its own
color the way it used to when this sat on its own line above the bar. mobdb
gives most mobs a range, and naming one end and not the other would be wrong
about half the spawn; the text says both, and the bar under it colors both.

**The bar itself fills in a gradient for a straddling range** — low tier's color
on the left, high tier's on the right — instead of picking one end the way the
label has to. The gradient spans the whole bar width and holds still as HP
drains; the fill just reveals less of it, the same way the flat fill for a
single-tier mob always did. A mob that does not straddle a boundary still fills
flat, in that one tier's color, same as ever.

**A notorious monster reads `???` whatever its level says.** `/check` refuses to
gauge an NM, and printing the tier mobdb's range implies would be inventing an
answer the game withholds.

**A mob you have actually /checked overrides all of the above with the real answer.** Everything
this section describes — the interpolated bands, the straddling range, the gradient fill — is an
*estimate* from mobdb's level data; once `checkinfo`'s captured list (see **Check capture**) holds
an entry for the target, its exact tier and level win instead. The label prefix collapses to that
one tier (never `EP-DC` — a check answers with exactly one tier, so the bar fills flat in its color,
never a gradient) and the tag box snaps from a range to the single level `/check` reported, once it
gave a usable one — the server sends `0` in place of a level for an NM's response, so that box keeps
mobdb's range in that case instead of showing nothing. Both hold **even for a mob mobdb has no entry
for at all**: `/check` needs no mobdb data to work, so an unrecognized mob you have checked still
gets an exact tier and level, just no job suffix or detection/resistance rows — those really do come
only from mobdb, and `/check` has nothing to say about them. Re-checking a mob replaces the captured
entry with the fresh answer, same as it replaces everything else `checkinfo` keeps for that server id.

**A captured check's tier also carries a `+`/`++` suffix for High Evasion and High Defense** —
`IT+` for one, `IT++` for both — since retail's condition ("High Evasion, High Defense", etc.) is
independent of the difficulty message and applies to whichever tier a mob names, not just `IT`. Low
Evasion and Low Defense never draw anything: a mob checking *worse* than expected is not worth
flagging the way one checking better is, and the plain tier already says how the fight reads
overall. The suffix is text only, trailing the tier in the label — it never changes the bar's color,
and mobdb's estimate never carries one at all, since it has no condition data to draw one from.

The bar colors are this project's own reference palette — gray, green, blue, white,
gold, orange, dark red, purple — rather than `/check`'s own chat colors: the
tier fills the whole bar, not a couple of letters next to other text,
so every tier needs a shade that reads as its own threat level on sight, and no
two tiers share one. `IT` alone stands in for three shades of "incredibly
tough" the reference chart draws separately — mobdb's own estimate has no
condition data at all, so there is no way for it to tell which of the three a
given mob is, and `IT` takes the darkest of the three rather than inventing a
split the estimate can't support. A captured check can and does tell them
apart — see the `+`/`++` suffix above — but reuses `IT`'s one color for all
three rather than needing a shade of its own for each. They are not settings: this is one fixed
chart, not a palette to retint. Opacity comes from the bar's own fill state
(`full`/`incomplete`/`empty`), like every other bar color.

### Where the icons sit

Flanking the bar, one **Bar Gap** clear of each edge and centered on the panel's
height, growing outward: the left group leftward, the right group rightward.
Neither shifts the other, the bar between them, or the panel.

They are outside the frame because they cannot fit inside it. Seven sense icons
at the default size are wider than the whole target panel, so a mob that happens
to notice everything would squeeze the bar they were meant to annotate down to
nothing.

Everything but the level is **mobdb's own icons** (see *Where the data comes
from*) — a row of glyphs reads at a glance where `Aggro Sight Magic` has to be
parsed. The level stays text because mobdb ships no icon for a level range or a
job, and it is the only text on that row.

Notorious is not an icon of its own. mobdb has HQ variants of the aggro and
passive icons — the same glyph in a gold frame — so an NM is one icon, not two.

**A ticked box does not guarantee content.** Anything with nothing to say is
skipped rather than drawn blank: a mob with no job prints its level range alone,
a mob that senses nothing contributes no icons to the right of it, and a mob
that takes every damage type normally has no resistance row at all. The
aggro/passive icon is the one thing that always draws when **Show Detection** is
on, because "detects nothing" and "does not aggro" are different facts and a
vanished icon would read as missing data rather than as a safe mob.

Resistances are sorted by potency, weaknesses first, so what to hit it with
reads before what to avoid. Ties keep a fixed order (physical first, then the
elements in the game's own order) rather than whatever `pairs` hands back — the
line is rebuilt every frame, and an order that shuffled between frames would
flicker.

Unlike mobdb, a run of equally-potent types keeps a percentage on every one
rather than printing it once at the end of the run. mobdb lays its icons out on
a window-wide row where that grouping reads; these are a free-standing row under
a panel, where a number lining up under the wrong icon is the likelier reading.

### Placement

The rows sit one **Bar Gap** under the panel's bottom edge, each centered on the
same anchor the panel is. **None of the reference costs the panel any height or
width** — a target panel is exactly the same shape whether the mob has everything
to say or nothing. (The check tier has no placement of its own — it is a prefix
on the name line above the frame, which is outside too, so it costs nothing
beyond what that line already costs.)

That is the point of it all being outside. A resistance list has no natural
width: a mob weak and resistant to eight damage types is a long line at any
legible font size. Inside the frame it forced the panel to stretch to hold it, so
the frame changed size every time you switched targets. Outside, a long line
simply overhangs both sides evenly and nothing else moves.

Nothing clips any of it, either — icons and text are drawn straight onto the
world, not into a box, and the shared text outline is what keeps them readable
over it.

**Info Text Size** (`32`) is the row height — the text size and the icons' side
alike. It ships large because these rows are read at the range you decide whether
to pull from, not at the range you are standing at. Unlike a bar label, **the rows do not drop out at distance — they hold at
Min Text Size and stop shrinking there.** A label that goes quiet still
leaves a bar behind it that reads at any size, while these lines carry facts
nothing else shows — a mob's level and what it aggros to is exactly what you want
at the range where the panel has gone small, and blanking it there reads as
missing data rather than as distance.

The floor never rises *above* what you configured, so **Info Text Size** dragged
under **Min Text Size** is honoured rather than bumped back up to a size you did
not ask for.

The block therefore stops shrinking while the panel above it keeps going, and at
range it reads large next to a small panel. Nothing has to be reconciled for
that: it is drawn below the frame, so it can outgrow it without overlapping
anything.

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

The config window's **Debug** section carries a `mob data:` line reporting the
loaded zone and whether a file was found, so "every line ticked and still
nothing under the bar" can be told apart from "mobdb isn't installed":

```
mob data: zone 100, loaded
```

Missing icons need no line of their own: a segment whose PNG did not load draws
its word instead, so data loaded but every line reading as words already says the
icons are missing (or that `D3DXCreateTextureFromFileA` did not resolve on this
Ashita build), as against the mob being absent from mobdb.

Job abbreviations come from Ashita's own job resource, with the same
`jobs.names_abbr` → `jobs_abbr` fallback mobdb carries for older versions.

The icons are mobdb's too, read from `Ashita/addons/mobdb/icons/<name>.png` —
nothing is shipped or duplicated here, and mobdb still does not have to be
loaded. They are loaded on first use, not by scanning the directory at startup:
a target panel can only ask for about twenty of them, and a name that has no
file has to be handled anyway, since mobdb's data and its icons are separate
downloads and either can be absent.

**A missing icon falls back to the word it stood for** — `Aggro`, `Sight`,
`Fire+25%`, with `Slashing`/`Piercing`/`Impact` shortened to
`Slash`/`Pierce`/`Blunt` for the width. That is not decoration: without it a
resistance segment with no icon would print a bare `+25%` with nothing saying
which element. A failed load is remembered, so a missing file is retried never
rather than every frame.

Icons draw at the **Info Text Size**, square and untinted — they are already
colored per element and per flag, and the shared text color has no business
retinting them.

## Check capture

`/check`'s answer is captured off the wire and kept, keyed by the checked entity's server id, so
re-targeting it later does not require a re-check to know what it already said. The target panel
reads this list — see **The check tier** — and prefers it over mobdb's estimate whenever an entry
exists; see `checkinfo.lua`.

The client's Message Basic packet (`0x0029`) is what `/check` (and the `checker` addon) both read;
Floaties listens for it too, alongside the check pair `checker.lua` uses to tell a check response from
the hundreds of other messages that packet carries. A recognized response overwrites any existing
entry for that server id — a re-check is the freshest truth, not a second opinion kept alongside the
first — and records the level, the resolved difficulty (`"like a decent challenge"`, etc.) and the
resolved condition (`"High Evasion"`, etc.). A notorious monster's response carries no difficulty at
all — the server withholds it — so that entry's type is `nil` and its message reads `"Impossible to
gauge!"` instead.

Alongside that resolved text, each entry also carries a `tier` — one of mobinfo's own chart keys
(`TW`/`EP`/.../`IT`, or `ITG` for the notorious case), mapped straight from Message Basic's difficulty
code. A captured check already names one exact tier, so this is a lookup table next to the ones that
resolve the display text, not the level-difference math `mobinfo.check_tier` runs for an estimate.
Retail's message set has one code (`"like incredibly easy prey"`) this project's seven-tier chart has
no room for below `EP`; it lands on `EP` there too, the same call `checker.lua`'s own colors make (it
leaves that one code uncolored rather than giving it `EP`'s tint, but does not invent an eighth tier
for it either).

Each entry also carries `plus` (`0`-`2`): how many of "High Evasion" / "High Defense" the resolved
condition names, counted off that same resolved string rather than a second lookup keyed on the raw
message id — the one combined condition (`"High Evasion, High Defense"`) just matches twice. "Low"
never counts. The target panel trails this many `+` onto the tier abbreviation; see **The check
tier**.

**The whole list is discarded on zone** (packets `0x00A` and `0x00B`, the same pair `checker.lua`
itself clears its widescan cache on): a server id is only unique within one zone instance, so
nothing recorded under the old one can mean the same entity after a zone change.

**One entry is discarded when that entity reaches 0% hp.** This piggybacks on the target-entity read
`updateGateState` already does every frame for the gate diagnostics, rather than a separate scan —
so a checked mob that dies while it is your target is pruned for free, but one that dies off-target
lingers in the list until the next zone clears it. That gap is intentional for now: Floaties only ever
knows what it is currently looking at, and a full-entity sweep to close it is easy to add later if
the UI branch that reads this list needs it.

## Enemy list

Every mob you (or your pet, avatar, or automaton) have personally damaged or affected gets
the exact same panel the current target does -- HP bar, name line, check tier, level tag, detection
icons, resist row -- floating over it, independent of what is currently targeted. **Show Enemy
List** in `/floaties config` turns it off; **Enemy List Max** caps how many draw in one frame.

**What counts as "yours."** Built off the Action packet (`0x0028`), the same one that carries
melee swings, weaponskills, job abilities, and spells (including each Dia/Poison tick, which
re-sends this packet with the caster as the actor) -- filtered to actions whose actor is you or your
pet/avatar/automaton. A trust's own actions are not checked separately -- a trust only ever acts
against something you are already acting against, so your own hit already covers whatever a trust's
hit would add. A party member landing a hit does not add anything either; only your own (and your
pet's) actions do. Any action counts, hit or miss -- a swing that whiffs still means you're fighting
it, so the packet's own hit/miss/parry/evade code is never read.

This is **not** a ranked hate/enmity display. The server does not send real enmity numbers to the
client during normal play (the only exact read is casting Libra), so nothing here claims to know
where you stand on a mob's hate list -- only that you've hit it.

**No double panel.** A mob that is both your current target and on this list only ever gets the
target panel -- the enemy-list loop skips whatever index `target_index` currently is, the same way
the target panel already skips party members in slots `0..5`.

Ungated, same reasoning as the target panel: having hit something already answers "should this
draw" -- gating it on your own idle/engaged/combat status would hide a mob you just pulled until
your own status caught up.

## Commands

| Command | Effect |
|---|---|
| `/floaties` or `/float` | Toggle the settings window. The **Enabled** checkbox in its **Debug** section is the on/off switch, persisted. Whether the window itself is open is also persisted, so a `/lua reload` or relog leaves it exactly as you left it |
| `/floaties height <n>` | Your own vertical nudge from the nameplate anchor. Positive is downward. Default `0.15` |
| `/floaties config` | Same as the bare command, kept as an alias |
| `/floaties bt` | Print the current gate state (in combat / engaged / idle, raw status, resolved `<bt>` and target, or why either was rejected) |

`0.0` puts the panel's top edge level with the nameplate anchor bone, i.e. directly under the
nameplate; nudge from there. Self, party and target have separate offsets (`Self Height
Offset` / `Party Height Offset` / `Target Height Offset` in `/floaties config`); the command
only touches your own. They default to `0.15` / `0.1` / `0.129` — everything hangs a
little below the plate, your own slightly further, since your model is the one the
camera is closest to and its plate has the most room under it.

## Nameplate anchor

The panel hangs from the same point the game hangs a nameplate from: **bone 2** of the actor's
skeleton, the bone index the client's own nameplate helper is called with. That makes the offset
from the plate hold across races, mounts, sitting, and mid-jump, all of which a fixed world
offset from the ground gets wrong.

All three axes come from the actor object — the panel tracks the *model*, not the feet. Two
things fall out of that. A model that leans or lunges carries its panel with its head instead of
leaving it planted over the ground it is standing on; and the panel stops shearing sideways
during movement, which it did while the height came from the actor and the horizontal position
came from the entity struct (the actor holds the rendered position, and the entity struct can lag
it by a frame).

Earlier builds scanned the whole skeleton for its highest bone and used that. It was wrong twice
over: the topmost bone is whatever the model happens to hold up — a greatsword on the back, a
raised wing, a hat — so anything not shaped like a Hume floated its panel too high, and that bone
*moves through the animation*, so the panel drifted every time the model swung something.

It is *not* a hook into the game's own draw code. FFXI computes the nameplate's screen position
inside `FFXiMain.dll` each frame and keeps it nowhere readable, so pixel-exact co-location needs
a code cave — see `docs/NAMEPLATE-HOOK-RESEARCH.md`, which prices that at 2–4 days plus live
frame-dumping to find the stack slots. This gets within a couple of pixels for the cost of a
pointer walk.

If the skeleton can't be read (zoning, model swap, an invalid index), the panel silently falls
back to the entity's feet position for that frame.

## Files

- `Floaties.lua` — projection, ImGui rendering, gate state, config window, commands
- `lib/nameplate.lua` — actor → skeleton → bone walk for the nameplate anchor bone (memory reader injected, so it tests headless)
- `lib/targets.lua` — Ashita's target library, vendored unmodified (only `get_bt` is used)
- `lib/stats.lua` — HP/MP/TP normalization, TP segment math, and the target/pet entity reads + targetability test (no Ashita dependencies)
- `lib/config.lua` — settings defaults, load/save, derived layout math (no Ashita dependencies except load/save)
- `lib/mobinfo.lua` — mobdb zone-data loader, the reference rows, and the `/check` tier math, built as icon/text segments (no Ashita dependencies — it picks the icon names and the tier colors, `Floaties.lua` loads and draws them)
- `lib/checkinfo.lua` — the `/check` capture list keyed by server id: what counts as a check response, and its zone/death cleanup (no Ashita dependencies — `Floaties.lua` unpacks the packet and resolves the entity)
- `lib/enemylist.lua` — the enemy list: which mobs you've personally hit, keyed by server id, plus server-id-to-index resolution (no Ashita dependencies — `Floaties.lua` decodes the Action packet, decides who counts as "you", and resolves indices through an injected reader)
- `lib/petshare.lua` — the pet MP/TP swapped between Floaties sessions on one PC: the line format, its staleness window, and the throttled read/write (no Ashita dependencies — `Floaties.lua` supplies the directory and the player-block reads)
- `lib/test.lua` — self-check for `lib/stats.lua`, `lib/config.lua`, `lib/nameplate.lua`, `lib/mobinfo.lua`, `lib/checkinfo.lua`, `lib/enemylist.lua` and `lib/petshare.lua`; run with `lua lib/test.lua` from the repo root
- `docs/` — research notes this was built from (gitignored)

## Notes

Bars are drawn directly with Ashita's bundled ImGui background draw list
(`AddRectFilled`, `AddRect`, `AddText`) rather than the `primitives` library,
since `primitives` can't render text or rounded corners. Settings are
persisted with Ashita's `settings` library, one shared file for all
characters.

## Credits

**atom0s** — the Ashita v4 addon framework and its bundled ImGui/settings
libraries underpin all of Floaties; two pieces of it are used directly:

- `lib/targets.lua` — Ashita's own target library, vendored here unmodified
  (see **On the battle-target gate**).
- `checker` — the `/check` capture (`checkinfo.lua`, see **Check capture**)
  listens for the same Message Basic packet (`0x0029`) and reuses the check
  pair the `checker` addon uses to tell a check response apart from the rest
  of that packet's traffic.
