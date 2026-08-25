--[[
* Self-check for stats.lua. Run headless from the repo root: lua lib/test.lua
--]]

local stats     = require('lib.stats');
local config    = require('lib.config');
local nameplate = require('lib.nameplate');
local mobinfo   = require('lib.mobinfo');
local checkinfo = require('lib.checkinfo');

local function fakeParty(active, hpp, mpp, tp, hp, mp)
    return {
        GetMemberIsActive    = function () return active; end,
        GetMemberHPPercent   = function () return hpp; end,
        GetMemberMPPercent   = function () return mpp; end,
        GetMemberTP          = function () return tp; end,
        GetMemberHP          = function () return hp; end,
        GetMemberMP          = function () return mp; end,
    };
end

assert(stats.read(nil) == nil, 'nil party must yield nil');
assert(stats.read(fakeParty(0, 100, 100, 3000, 1000, 100)) == nil, 'inactive slot must yield nil');

local s = stats.read(fakeParty(1, 50, 25, 1500, 750, 40));
assert(s.hp == 0.5, 'hp 50% -> 0.5, got ' .. tostring(s.hp));
assert(s.hp_raw == 750, 'hp_raw passthrough, got ' .. tostring(s.hp_raw));
assert(s.mp == 0.25, 'mp 25% -> 0.25, got ' .. tostring(s.mp));
assert(s.mp_raw == 40, 'mp_raw passthrough, got ' .. tostring(s.mp_raw));
assert(s.tp == 0.5, 'tp 1500/3000 -> 0.5, got ' .. tostring(s.tp));
assert(s.tp_raw == 1500, 'tp_raw passthrough, got ' .. tostring(s.tp_raw));

-- HPPercent is documented to exceed 100; TP must not overflow the bar either.
local o = stats.read(fakeParty(1, 137, 0, 3200, 2000, 0));
assert(o.hp == 1.0, 'hp over 100 must clamp to 1.0, got ' .. tostring(o.hp));
assert(o.mp == 0.0, 'mp 0 -> 0.0, got ' .. tostring(o.mp));
assert(o.tp == 1.0, 'tp over 3000 must clamp to 1.0, got ' .. tostring(o.tp));
assert(o.tp_raw == 3000, 'tp_raw must clamp to 3000, got ' .. tostring(o.tp_raw));

-- TP segmentation: 3 equal 1000-point segments.
assert(stats.tp_segment(0, 1) == 0.0, 'segment 1 empty at tp=0');
assert(stats.tp_segment(500, 1) == 0.5, 'segment 1 half at tp=500');
assert(stats.tp_segment(1000, 1) == 1.0, 'segment 1 full at tp=1000');
assert(stats.tp_segment(1000, 2) == 0.0, 'segment 2 empty at tp=1000');
assert(stats.tp_segment(1500, 2) == 0.5, 'segment 2 half at tp=1500');
assert(stats.tp_segment(3000, 3) == 1.0, 'segment 3 full at tp=3000');
assert(stats.tp_segment(3000, 1) == 1.0, 'earlier segments stay full past their range');

-- Party slots: read must address the slot it was asked for, not always 0.
local slots = {
    [0] = { active = 1, hpp = 100, mpp = 100, tp = 3000, hp = 1200, mp = 300 },
    [3] = { active = 1, hpp = 40,  mpp = 10,  tp = 500,  hp = 0,    mp = 0   },
    [5] = { active = 0, hpp = 0,   mpp = 0,   tp = 0,    hp = 0,    mp = 0   },
};
local partySlots = {
    GetMemberIsActive  = function (_, i) return (slots[i] or { active = 0 }).active; end,
    GetMemberHPPercent = function (_, i) return slots[i].hpp; end,
    GetMemberMPPercent = function (_, i) return slots[i].mpp; end,
    GetMemberTP        = function (_, i) return slots[i].tp; end,
    GetMemberHP        = function (_, i) return slots[i].hp; end,
    GetMemberMP        = function (_, i) return slots[i].mp; end,
};

local me = stats.read(partySlots, 0);
assert(me.hp_raw == 1200, 'slot 0 reads its own hp, got ' .. tostring(me.hp_raw));
local mate = stats.read(partySlots, 3);
assert(mate.hp == 0.4, 'slot 3 reads its own hp percent, got ' .. tostring(mate.hp));
assert(mate.tp_raw == 500, 'slot 3 reads its own tp, got ' .. tostring(mate.tp_raw));
assert(stats.read(partySlots, 5) == nil, 'inactive slot 5 must yield nil');
assert(stats.read(partySlots, 1) == nil, 'unpopulated slot must yield nil');
assert(stats.read(partySlots).hp_raw == 1200, 'omitted index must default to slot 0');

-- Labels: raw when the server sent it, percent when it only sent that.
assert(stats.label(me, 'hp') == 1200, 'self shows raw hp, got ' .. tostring(stats.label(me, 'hp')));
assert(stats.label(mate, 'hp') == 40, 'member with no raw hp falls back to percent, got ' .. tostring(stats.label(mate, 'hp')));
assert(stats.label(mate, 'mp') == 10, 'member with no raw mp falls back to percent, got ' .. tostring(stats.label(mate, 'mp')));
assert(stats.label(mate, 'tp') == 500, 'tp is always raw, got ' .. tostring(stats.label(mate, 'tp')));
assert(stats.label(stats.read(fakeParty(1, 0, 0, 0, 0, 0)), 'hp') == 0, 'dead member still labels 0');

-- Second return marks a percent, so the draw site can print a % sign. It must track the branch
-- that chose the number, not be guessed from the value: 40 HP and 40% are the same integer.
local function isPct(s, key)
    local _, pct = stats.label(s, key);
    return pct;
end

assert(not isPct(me, 'hp'), 'self has raw hp, so its label is not a percent');
assert(isPct(mate, 'hp'), 'a member with no raw hp labels a percent');
assert(isPct(mate, 'mp'), 'a member with no raw mp labels a percent');
assert(not isPct(mate, 'tp'), 'tp is always raw, never a percent');
assert(not isPct(me, 'tp'), 'self tp is raw too');

-- A dead member reads 0 raw and 0 percent; the fallback still fires, so it is a percent.
assert(isPct(stats.read(fakeParty(1, 0, 0, 0, 0, 0)), 'hp'), 'a 0 label is still a percent');

-- Entity reads: an arbitrary entity tells the client an HP percent and nothing else.
local function fakeEnt(flags, hpp, status, serverId)
    return { SpawnFlags = flags, HPPercent = hpp, Status = status or 0, ServerId = serverId or 999, Name = 'x' };
end

assert(stats.read_entity(nil) == nil, 'nil entity must yield nil');

local mob = stats.read_entity(fakeEnt(0x10, 50));
assert(mob.hp == 0.5, 'entity hp 50% -> 0.5, got ' .. tostring(mob.hp));
assert(mob.hp_raw == 0, 'entity hp_raw is 0 -- there is no raw hp to read');
assert(stats.read_entity(fakeEnt(0x10, 137)).hp == 1.0, 'entity hp over 100 must clamp to 1.0');

-- hp_raw = 0 is what makes label print the percent; that pairing is the whole labelling
-- contract for entity panels, so assert it rather than assuming it.
assert(stats.label(mob, 'hp') == 50, 'entity label falls back to percent, got ' .. tostring(stats.label(mob, 'hp')));
assert(isPct(mob, 'hp'), 'an entity label is always a percent -- there is no raw hp to read');

-- Pet reads: an entity's HP percent, plus the MP/TP the player block publishes for your own pet
-- only. The caller does that reading (it is Ashita-side), so nil for either is the shape another
-- member's pet would arrive in and must not throw.
assert(stats.read_pet(nil, 50, 1000) == nil, 'nil entity must yield nil');

local pet = stats.read_pet(fakeEnt(0x10, 50), 40, 1500);
assert(pet.hp == 0.5, 'pet hp comes from the entity, got ' .. tostring(pet.hp));
assert(pet.mp == 0.4, 'pet mp is a percent, got ' .. tostring(pet.mp));
assert(pet.tp == 0.5, 'pet tp runs 0..3000, got ' .. tostring(pet.tp));
assert(pet.tp_raw == 1500, 'pet tp_raw is kept raw for the tp segments');

-- Same labelling contract as an entity panel: pools published as percents print as percents.
assert(pet.mp_raw == 0 and isPct(pet, 'mp'), 'a pet mp label is a percent -- there is no raw mp');

local bare = stats.read_pet(fakeEnt(0x10, 100));
assert(bare.mp == 0 and bare.tp == 0, 'a pet with nothing published reads empty, not nil');

assert(stats.read_pet(fakeEnt(0x10, 100), 137, 5000).mp == 1.0, 'pet mp over 100 must clamp');
assert(stats.read_pet(fakeEnt(0x10, 100), 0, 5000).tp == 1.0, 'pet tp over 3000 must clamp');

-- Targetability. Party slots 0..5 are rejected because drawMember already draws them.
local targetParty = {
    GetMemberIsActive = function (_, i) return i <= 2 and 1 or 0; end,
    GetMemberServerId = function (_, i) return 100 + i; end,
};

assert(not stats.targetable(nil, targetParty), 'no entity is not targetable');
assert(stats.targetable(fakeEnt(0x10, 100), targetParty), 'a living mob is targetable');
assert(stats.targetable(fakeEnt(0x01, 100), targetParty), 'a non-party pc is targetable');
assert(not stats.targetable(fakeEnt(0x02, 100), targetParty), 'an npc is not targetable');
assert(not stats.targetable(fakeEnt(0x08, 100), targetParty), 'an unknown spawn type is not targetable');

-- Single-bit masks, so a mob that also carries other flag bits must still read as a mob.
assert(stats.targetable(fakeEnt(0x12, 100), targetParty), 'the mob bit counts alongside other bits');

assert(not stats.targetable(fakeEnt(0x10, 0), targetParty), 'a mob at 0% is a corpse');
assert(not stats.targetable(fakeEnt(0x10, 100, 2), targetParty), 'status 2 is dead');
assert(not stats.targetable(fakeEnt(0x10, 100, 3), targetParty), 'status 3 is dead');

assert(not stats.targetable(fakeEnt(0x01, 100, 0, 100), targetParty), 'yourself is already drawn as slot 0');
assert(not stats.targetable(fakeEnt(0x01, 100, 0, 102), targetParty), 'a party member is already drawn');
assert(stats.targetable(fakeEnt(0x01, 100, 0, 103), targetParty), 'an inactive slot does not claim a server id');
assert(stats.targetable(fakeEnt(0x10, 100), nil), 'a missing party must not throw');

print('stats.lua ok');

-- config.lua: derived layout math must match the defaults' expected geometry.
local SELF = config.defaults.sizes.self;
assert(config.bar_width(config.defaults, SELF) == 196, 'bar width = size.width - 2*offset, got ' .. tostring(config.bar_width(config.defaults, SELF)));
assert(config.panel_height(config.defaults, SELF) == 50, 'panel height = sum(bar heights) + 2*gap + 2*offset, got ' .. tostring(config.panel_height(config.defaults, SELF)));

local custom     = { panel = { offset = 10 }, gap = 5 };
local customSize = { width = 200, hp = 20, mp = 30, tp = 40 };
assert(config.bar_width(custom, customSize) == 180, 'bar width recomputes from the given size, got ' .. tostring(config.bar_width(custom, customSize)));
assert(config.panel_height(custom, customSize) == 20 + 30 + 40 + 2 * 5 + 2 * 10, 'panel height recomputes from the given size, got ' .. tostring(config.panel_height(custom, customSize)));

-- The point of the split: each kind lays out from its own size table, sharing only the padding
-- and gap. Nothing may reach back to a single global width or bar height.
local sizes = {
    self   = { width = 100, hp = 16, mp = 16, tp = 16 },
    party  = { width = 60,  hp = 8,  mp = 8,  tp = 8  },
    target = { width = 200, hp = 24 },
};
assert(config.bar_width(config.defaults, sizes.party) == 56, 'party width is its own, got ' .. tostring(config.bar_width(config.defaults, sizes.party)));
assert(config.bar_width(config.defaults, sizes.target) == 196, 'target width is its own, got ' .. tostring(config.bar_width(config.defaults, sizes.target)));
assert(config.panel_height(config.defaults, sizes.party) == 8 * 3 + 2 * 1 + 2 * 2, 'party heights are its own, got ' .. tostring(config.panel_height(config.defaults, sizes.party)));
assert(config.panel_height(config.defaults, sizes.target, { 'hp' }) == 24 + 2 * 2, 'target height is its own, got ' .. tostring(config.panel_height(config.defaults, sizes.target, { 'hp' })));

-- Every kind in size_order must actually lay out, target included -- a missing entry is a nil
-- index inside panel_height, not a readable failure.
for _, kind in ipairs(config.size_order) do
    local size = config.defaults.sizes[kind];
    assert(size ~= nil, 'size_order names a missing size table: ' .. kind);
    assert(config.panel_height(config.defaults, size, { 'hp' }) > 0, kind .. ' cannot lay out an hp bar');
end

-- Tag box (party slot, or now a target's level -- see mobinfo.panel): the box plus one bar gap
-- comes out of the bars, never out of the panel, for any panel kind whose caller decided it has
-- one. slot_width trusts that decision (has_tag) outright -- cfg.slot.enabled is the party tag's
-- own switch, checked by the caller that builds the tag string (drawMember), not re-checked here.
local slotcfg = { panel = { offset = 4 }, gap = 2, slot = { enabled = true, size = 12 } };
local offcfg  = { panel = { offset = 4 }, gap = 2, slot = { enabled = false, size = 12 } };

assert(config.slot_box(slotcfg) == 18, 'box width = floor(1.5 * text size), got ' .. tostring(config.slot_box(slotcfg)));
assert(config.slot_width(slotcfg, true) == 20, 'reserved width = box + one gap, got ' .. tostring(config.slot_width(slotcfg, true)));
assert(config.slot_width(slotcfg, false) == 0, 'a panel with no tag reserves nothing, whatever slot.enabled says');

-- The behavior change this task makes: has_tag alone decides now. slot.enabled is a real setting
-- still (drawMember reads it to decide whether to build a tag string at all), but slot_width no
-- longer re-checks it -- a caller that hands in has_tag=true gets charged for the box regardless.
assert(config.slot_width(offcfg, true) == 20, 'has_tag alone decides -- slot.enabled is not read here anymore, got ' .. tostring(config.slot_width(offcfg, true)));
assert(config.slot_width(offcfg, false) == 0, 'still nothing with no tag, whatever slot.enabled says');

-- Exactly the old width when there is no tag, not merely close to it: no tag must not nudge bars
-- by a rounding remainder.
assert(config.bar_width(slotcfg, SELF, false) == config.bar_width(slotcfg, SELF), 'no tag must match the untagged width exactly');
assert(config.bar_width(slotcfg, SELF, true) == 200 - 2 * 4 - 20, 'bars give up box + gap, got ' .. tostring(config.bar_width(slotcfg, SELF, true)));
assert(config.bar_width(slotcfg, sizes.target, false) == 192, 'the target panel keeps its full bar width when it has no tag');

-- The defaults ship with the party indicator on, so they are the case that has to lay out: box
-- floor(1.5*21)=31 plus the 1px gap, out of the bars only.
assert(config.slot_width(config.defaults, true) == 32, 'default reserved width, got ' .. tostring(config.slot_width(config.defaults, true)));
assert(config.bar_width(config.defaults, SELF, true) == 196 - 32, 'a default party panel gives up box + gap, got ' .. tostring(config.bar_width(config.defaults, SELF, true)));
assert(config.bar_width(config.defaults, config.defaults.sizes.target, false) == 296, 'the default target panel reserves nothing when it has no tag');
assert(config.label_size(config.defaults, config.defaults.slot.size) ~= nil, 'the default slot text must clear Min Text Size, or the tag never prints');

-- The panel's own footprint is untouched -- the space is taken from the bars inside it.
-- panel_height never reads cfg.slot at all, so this holds regardless of whether a tag is drawn.
local notagcfg = { panel = { offset = 4 }, gap = 2 };
assert(config.panel_height(slotcfg, SELF) == config.panel_height(notagcfg, SELF), 'a tag must not change panel height');

-- Mob reference lines hang *below* the panel, so they cost it no height at all: a target panel is
-- the same shape whether the mob has three lines or none, and panel_height counts bars only.
local TARGET = config.defaults.sizes.target;
assert(config.panel_height(config.defaults, TARGET, { 'hp' }) == 20 + 2 * 2,
    'lines must not enter the panel height, got ' .. tostring(config.panel_height(config.defaults, TARGET, { 'hp' })));

-- The row holds at Min Text Size instead of dropping out below it, the way a bar label does: a
-- label leaves a bar behind it that still reads, while a blanked reference line reads as missing
-- data at exactly the range the panel is smallest.
local MIN_INFO = config.defaults.text.min_size;
assert(config.info_row(config.defaults, 1) == 14, 'at 1:1 the row is the configured size');
assert(config.info_row(config.defaults, nil) == 14, 'no scale is 1:1');
assert(config.info_row(config.defaults, 1.5) == 21, 'scaling up is not clamped');
assert(config.info_row(config.defaults, 0.35) == MIN_INFO, 'the smallest scale holds at the floor, got ' .. tostring(config.info_row(config.defaults, 0.35)));

-- The floor is never *above* what was configured: an Info Text Size dragged below Min Text Size is
-- honoured rather than bumped up to a size nobody asked for.
local tiny = { mob = { size = 8 }, gap = 1, text = { min_size = 12 } };
assert(config.info_row(tiny, 1) == 8, 'a size under the floor still draws at that size');
assert(config.info_row(tiny, 0.35) == 8, 'and is its own floor');

-- info_row is the whole of the block's geometry, and it must not need anything a panel kind with no
-- lines lacks -- `tiny` above carries no gap-dependent state and every fixture here ships no sizes.
assert(config.info_row({ mob = { size = 40 }, text = { min_size = 12 } }, 0.35) == 14,
    'the row reads only mob.size and text.min_size, got ' .. tostring(config.info_row({ mob = { size = 40 }, text = { min_size = 12 } }, 0.35)));

-- An explicit size (the party name line) takes mob.size's place entirely -- same floor rule, so
-- the two lines shrink and bottom out alike without one resizing the other.
assert(config.info_row(config.defaults, 1, 30) == 30, 'an explicit size overrides mob.size');
assert(config.info_row(config.defaults, 0.1, 30) == MIN_INFO,
    'an explicit size still holds at the floor, got ' .. tostring(config.info_row(config.defaults, 0.1, 30)));
assert(config.info_row(config.defaults, 0.1, 8) == 8, 'and is still its own floor under it');
assert(config.info_row(config.defaults, 1, nil) == config.info_row(config.defaults, 1),
    'nil size is mob.size, so the reference rows are untouched');

-- MP bar only shows when main or sub has an MP pool.
assert(#config.bars_for(1, 2) == 2, 'WAR/MNK must drop the mp bar');
assert(config.bars_for(1, 2)[2] == 'tp', 'remaining bars stay in draw order');
assert(#config.bars_for(1, 3) == 3, 'WAR/WHM keeps the mp bar (sub has MP)');
assert(#config.bars_for(22, 1) == 3, 'RUN/WAR keeps the mp bar (main has MP)');
assert(#config.bars_for(1, 0) == 2, 'no subjob must not error');

-- A pet's MP bar follows the *owner's* job, not a live MP reading: an avatar spending its last MP
-- must not drop a bar mid-fight, and a wyvern must never draw one it can never fill.
assert(#config.pet_bars(15) == 3, 'a SMN avatar has an mp pool');
assert(#config.pet_bars(18) == 3, 'a PUP automaton has an mp pool');
assert(#config.pet_bars(9) == 2, 'a BST jug pet has no mp pool');
assert(config.pet_bars(9)[2] == 'tp', 'remaining pet bars stay in draw order');
assert(#config.pet_bars(0) == 2, 'an unknown job must not error');

-- Not config.mp_jobs: SMN and PUP are the jobs whose *pet* has MP, which is a different list from
-- the jobs that have MP themselves -- PUP has none, and every mage in mp_jobs summons nothing.
assert(config.mp_jobs[18] == nil, 'PUP itself has no mp pool');
assert(config.pet_mp_jobs[3] == nil, 'WHM summons nothing to give an mp bar to');

-- Hiding a bar shrinks the panel by that bar's height plus one gap.
assert(config.panel_height(config.defaults, SELF, { 'hp', 'tp' }) == 39,
    'two-bar panel = 18+16 + 1*1 + 2*2, got ' .. tostring(config.panel_height(config.defaults, SELF, { 'hp', 'tp' })));

-- Label size comes from the bar, never from a setting of its own, so the text can never be taller
-- than what it sits in -- at any bar height and at any distance scale.
for h = 4, 40 do
    local size = config.label_size(config.defaults, h);
    assert(size == nil or size <= h, 'a label must never be taller than its bar (h=' .. h .. ')');
end

-- Below the floor there is no legible size left, so the bar drops its label rather than drawing
-- mush -- whether it got there by being configured short or by scaling far away.
local MIN = config.defaults.text.min_size;
assert(config.label_size(config.defaults, MIN) == MIN, 'the shortest bar that fits the floor still prints it');
assert(config.label_size(config.defaults, MIN - 1) == nil, 'one pixel under the floor drops the label');
assert(config.label_size(config.defaults, 16 * 0.5) == nil, 'a 16px bar scaled to half drops its label');
assert(config.label_size(config.defaults, 16 * 1.5) ~= nil, 'a 16px bar scaled up keeps it');

-- Whole-pixel sizes: a size that drifts by fractions as the camera moves resamples the same glyph
-- every frame, which is what shimmering text is.
for _, h in ipairs({ 16.4, 16.5, 16.9, 21.0001, 39.999 }) do
    local size = config.label_size(config.defaults, h);
    assert(size == math.floor(size), 'label size must be whole pixels, got ' .. tostring(size));
    assert(size <= h, 'flooring must never round a label up past its bar');
end

-- Visibility gates only ever *enable*: show when at least one enabled gate
-- passes, hide otherwise. Never an intersection, and never a fallback to shown.
local function vis(gates, conditions)
    local cfg = {};
    for _, g in ipairs(config.gates) do
        cfg[g] = gates[g] or false;
    end
    return config.visible(cfg, conditions);
end

local COMBAT  = { show_in_combat = true };
local ENGAGED = { show_while_engaged = true };
local IDLE    = { show_while_idle = true };
local ALL     = { show_in_combat = true, show_while_engaged = true, show_while_idle = true };

-- No gate on: nothing can enable the panel, whatever the state.
for _, cond in ipairs({ {}, COMBAT, ENGAGED, IDLE, ALL }) do
    assert(not vis({}, cond), 'no gate on must never show');
end

-- The regression this replaced: one gate on and unsatisfied must hide. It used
-- to fall through to the "no gate on" case and show anyway.
assert(not vis(COMBAT, {}), 'a single enabled gate that is false must hide');

-- Defaults must be visible in normal play -- an all-off default would now mean
-- the addon draws nothing until a box is ticked.
assert(config.visible(config.defaults, IDLE), 'defaults show while idle');
assert(config.visible(config.defaults, ENGAGED), 'defaults show while engaged');
assert(config.visible(config.defaults, COMBAT), 'defaults show with a battle target');
assert(not config.visible(config.defaults, {}), 'defaults hide while resting/dead/zoning');

assert(vis(COMBAT, COMBAT), 'combat gate shows with a battle target');
assert(not vis(COMBAT, ENGAGED), 'combat gate hides without one, engaged or not');
assert(vis(ENGAGED, ENGAGED), 'engaged gate shows while engaged');
assert(not vis(ENGAGED, IDLE), 'engaged gate hides while idle');
assert(vis(IDLE, IDLE), 'idle gate shows while idle');
assert(not vis(IDLE, ENGAGED), 'idle gate hides while engaged');

-- Union, not intersection: any one enabled gate passing is enough.
assert(vis(ALL, ENGAGED), 'all gates on: engaged alone is enough even with <bt> stale');
assert(vis(ALL, COMBAT), 'all gates on: a battle target alone is enough');
assert(vis(ALL, IDLE), 'all gates on: idle alone is enough');
assert(not vis(ALL, {}), 'all gates on: dead/zoning/resting matches nothing, so hidden');

-- Idle + engaged together still hide the states that are neither (dead, zoning, resting).
local IDLE_OR_ENGAGED = { show_while_engaged = true, show_while_idle = true };
assert(vis(IDLE_OR_ENGAGED, IDLE), 'idle+engaged shows while idle');
assert(vis(IDLE_OR_ENGAGED, ENGAGED), 'idle+engaged shows while engaged');
assert(not vis(IDLE_OR_ENGAGED, {}), 'idle+engaged hides while resting');

-- Distance scaling: scale = clamp(ref/depth, min, max), and exactly 1 whenever it is off or the
-- depth is unusable. `near` is defined further down, so compare with an explicit epsilon here.
local function nearly(a, b, why)
    assert(a ~= nil and math.abs(a - b) < 1e-9, why .. ', got ' .. tostring(a));
end

local scaling = { distance_scale = true, scale_ref = 6.0 };

nearly(config.panel_scale(scaling, 6.0), 1.0, 'the reference depth draws 1:1');
nearly(config.panel_scale(scaling, 12.0), 0.5, 'twice the reference is half size');
nearly(config.panel_scale(scaling, 5.0), 1.2, 'closer than the reference grows');
nearly(config.panel_scale(scaling, 3.0), 1.5, 'growth stops at the ceiling');
nearly(config.panel_scale(scaling, 60.0), 0.35, 'shrink stops at the floor');

-- Behind the lens / degenerate projections must not produce a negative or infinite panel.
nearly(config.panel_scale(scaling, 0), 1.0, 'zero depth yields no scaling');
nearly(config.panel_scale(scaling, -5), 1.0, 'a point behind the camera yields no scaling');
nearly(config.panel_scale(scaling, nil), 1.0, 'a missing depth yields no scaling');

-- Off must be exactly 1 at every depth -- the toggle has to leave panels exactly where they were,
-- not near enough. Its own cfg: the defaults now ship with scaling on.
local unscaled = { distance_scale = false, scale_ref = 6.0 };
for _, d in ipairs({ 0.5, 6, 50, 500 }) do
    assert(config.panel_scale(unscaled, d) == 1, 'disabled scaling is exactly 1 at depth ' .. d);
end

-- The defaults have it on, so they must actually scale -- an off-by-default value left in
-- `distance_scale` would leave scale_ref doing nothing and look like a broken slider.
nearly(config.panel_scale(config.defaults, config.defaults.scale_ref), 1.0, 'the defaults draw 1:1 at their own reference');
nearly(config.panel_scale(config.defaults, config.defaults.scale_ref * 2), 0.5, 'the defaults shrink with depth');

print('config.lua ok');

-- nameplate.lua: the actor -> skeleton -> bones pointer walk, against a fake address space.
--
-- Layout built below (all offsets straight out of nameplate.lua):
--   actor 0x1000: +0x678 X 100.0, +0x67C feet height 10.0, +0x680 Y 200.0, +0x6B8 -> 0x2000
--   0x2000 +0x0C -> 0x3000 -> 0x4000 (the skeleton)
--   0x4000 +0x32 bone count, bones start at 0x30 + 0x04 + 0x1E*count + 4, stride 0x1A, X/Z/Y at +0x0E
local ACTOR = 0x1000;

local function fakeMem(u32, u16, f32)
    return {
        read_uint32 = function (a) return u32[a] or 0; end,
        read_uint16 = function (a) return u16[a] or 0; end,
        read_float  = function (a) return f32[a] or 0; end,
    };
end

-- `bones` is a list of { x, z, y } offsets, one per bone, in bone order.
local function skeleton(bones, count)
    count = count or #bones;
    local gens = 0x4000 + 0x30 + 0x04 + 0x1E * count + 4;
    local f32  = { [ACTOR + 0x678] = 100.0, [ACTOR + 0x67C] = 10.0, [ACTOR + 0x680] = 200.0 };
    for i, b in ipairs(bones) do
        local at = gens + (i - 1) * 0x1A + 0x0E;
        f32[at], f32[at + 4], f32[at + 8] = b[1], b[2], b[3];
    end
    return fakeMem(
        { [ACTOR + 0x6B8] = 0x2000, [0x2000 + 0x0C] = 0x3000, [0x3000] = 0x4000 },
        { [0x4000 + 0x32] = count },
        f32);
end

local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6; end

-- Bone 2 (the third entry) is the anchor, and its offsets are relative to the actor origin on
-- every axis. Height is down-positive, so a bone above the feet reads negative.
local POSED = { { 9, 9, 9 }, { 9, 9, 9 }, { 0.25, -1.8, -0.5 }, { 9, 9, 9 } };
local ax, ay, az = nameplate.anchor(skeleton(POSED), ACTOR);
assert(near(ax, 100.25), 'x = actor x + bone 2 x, got ' .. tostring(ax));
assert(near(ay, 199.5),  'y = actor y + bone 2 y, got ' .. tostring(ay));
assert(near(az, 8.2),    'z = feet + bone 2 z, got ' .. tostring(az));

-- Bones the model happens to hold higher than the anchor must not move it: that scan is exactly
-- what made the panel wander through an animation.
local HIGHER = { { 9, -9, 9 }, { 9, -9, 9 }, { 0.25, -1.8, -0.5 }, { 9, -9, 9 } };
local _, _, hz = nameplate.anchor(skeleton(HIGHER), ACTOR);
assert(near(hz, 8.2), 'a higher bone elsewhere in the skeleton must not become the anchor');

-- A half-written bone reads NaN on any axis; none may reach the projection.
local nan = 0 / 0;
assert(nameplate.anchor(skeleton({ {0,0,0}, {0,0,0}, { nan, -1.8, -0.5 } }), ACTOR) == nil, 'NaN x yields nil');
assert(nameplate.anchor(skeleton({ {0,0,0}, {0,0,0}, { 0.25, nan, -0.5 } }), ACTOR) == nil, 'NaN z yields nil');
assert(nameplate.anchor(skeleton({ {0,0,0}, {0,0,0}, { 0.25, -1.8, nan } }), ACTOR) == nil, 'NaN y yields nil');

-- Every pointer in the chain can read 0 during a zone or model swap. None may throw.
assert(nameplate.anchor(skeleton(POSED), nil) == nil, 'nil actor pointer yields nil');
assert(nameplate.anchor(skeleton(POSED), 0) == nil, 'null actor pointer yields nil');
assert(nameplate.anchor(fakeMem({}, {}, {}), ACTOR) == nil, 'null skeleton base yields nil');
assert(nameplate.anchor(fakeMem({ [ACTOR + 0x6B8] = 0x2000 }, {}, {}), ACTOR) == nil, 'null skeleton offset yields nil');
assert(nameplate.anchor(fakeMem({ [ACTOR + 0x6B8] = 0x2000, [0x2000 + 0x0C] = 0x3000 }, {}, {}), ACTOR) == nil,
    'null skeleton address yields nil');

-- Bone count guards: a model with no bone 2 has no anchor, and a huge count means the walk landed
-- on non-skeleton memory and must not be turned into a bone address.
assert(nameplate.anchor(skeleton({}, 0), ACTOR) == nil, 'zero bones yields nil');
assert(nameplate.anchor(skeleton({}, 2), ACTOR) == nil, 'a model without bone 2 yields nil');
assert(nameplate.anchor(skeleton({}, 257), ACTOR) == nil, 'an implausible bone count yields nil');
assert(nameplate.anchor(skeleton({}, 256), ACTOR) ~= nil, '256 bones is still walked');

print('nameplate.lua ok');

-- mobinfo.lua: the three reference lines, formatted off real mobdb rows (West Ronfaure, zone 100).
local BOMB = { Name='Bomb', Notorious=false, Aggro=true, Link=false, TrueSight=false, Job=0,
               MinLevel=8, MaxLevel=10, Sight=true, Sound=false, Blood=false, Magic=true, JA=false,
               Scent=false,
               Modifiers={ Slashing=1, Piercing=1, H2H=1, Impact=1, Fire=1.25, Ice=0.5, Wind=0.5,
                           Earth=0.5, Lightning=0.5, Water=0.5, Light=0.5, Dark=0.5 } };

local BONES = { Name='Enchanted Bones', Notorious=false, Aggro=true, Link=false, TrueSight=false,
                Job=0, MinLevel=5, MaxLevel=8, Sight=false, Sound=true, Blood=true, Magic=false,
                JA=false, Scent=false,
                Modifiers={ Slashing=0.875, Piercing=0.5, H2H=1.125, Impact=1.25, Fire=1.25,
                            Ice=0.875, Wind=1, Earth=1, Lightning=1, Water=1, Light=1.25, Dark=0.5 } };

local jobs = { [1] = 'WAR', [2] = 'MNK' };
local function jobname(id) return jobs[id]; end

-- Detection and resistance lines are segments, drawn as mobdb's icons. These two flatten a line to
-- what Floaties draws when a texture is missing (alt in the icon's place) and to the icon names it
-- asks for -- one assertion per line either way, and the fallback wording is exactly the text the
-- lines used to be, so the readings below did not have to change with the shape.
local function text(line)
    if (line == nil) then return nil; end
    local out = {};
    for i, seg in ipairs(line) do
        out[i] = (seg.alt or '') .. (seg.text or '');
    end
    return table.concat(out, ' ');
end

local function icons(line)
    local out = {};
    for i, seg in ipairs(line) do
        out[i] = seg.icon or '-';
    end
    return table.concat(out, ' ');
end

-- The bare level tag: no `Lv.` prefix, no job -- that lives in M.panel's label now, not here.
assert(mobinfo.level_text(BOMB) == '8-10', 'a range prints both ends, got ' .. tostring(mobinfo.level_text(BOMB)));
assert(mobinfo.level_text({ Level=75, MinLevel=75, MaxLevel=75 }) == '75', 'a fixed level prints once, not as a range');
assert(mobinfo.level_text({ MinLevel=1, MaxLevel=2 }) == '1-2', 'got ' .. tostring(mobinfo.level_text({ MinLevel=1, MaxLevel=2 })));
assert(mobinfo.level_text(nil) == nil, 'an unknown mob has no level tag');

-- Threat: what happens when you walk up to it. Aggro/Passive always prints -- "detects nothing" and
-- "does not aggro" are different facts, and a vanishing group would read as missing data rather
-- than as a safe mob. Link rides with it rather than with the senses: it is not one.
assert(text(mobinfo.threat(BOMB)) == 'Aggro', 'got ' .. tostring(text(mobinfo.threat(BOMB))));
assert(text(mobinfo.threat({ Aggro=false })) == 'Passive', 'a passive mob with no flags still prints');
assert(text(mobinfo.threat({ Aggro=true, Link=true })) == 'Aggro Link', 'link follows the aggro flag');
assert(text(mobinfo.threat({ Aggro=true, Notorious=true })) == 'NM Aggro', 'NM leads the group');
assert(mobinfo.threat(nil) == nil, 'an unknown mob has no threat group');

-- Senses: what it notices you with, right of the level. Link must not turn up here.
assert(text(mobinfo.senses(BOMB)) == 'Sight Magic', 'got ' .. tostring(text(mobinfo.senses(BOMB))));
assert(text(mobinfo.senses(BONES)) == 'Sound Blood', 'got ' .. tostring(text(mobinfo.senses(BONES))));
assert(text(mobinfo.senses({ Aggro=true, Link=true, TrueSight=true, Sight=true })) == 'TrueSight Sight',
    'truesight leads sight, and link is not a sense, got ' .. tostring(text(mobinfo.senses({ Aggro=true, Link=true, TrueSight=true, Sight=true }))));
assert(#mobinfo.senses({ Aggro=false }) == 0, 'a mob that senses nothing has an empty group, not a missing one');
assert(mobinfo.senses(nil) == nil, 'an unknown mob has no senses group');

-- The icons those segments ask mobdb for. Names must match the PNGs in mobdb/icons exactly, or the
-- line silently falls back to words -- which is why they are asserted rather than eyeballed.
assert(icons(mobinfo.threat(BOMB)) == 'AggroNQ', 'got ' .. icons(mobinfo.threat(BOMB)));
assert(icons(mobinfo.senses(BOMB)) == 'Sight Magic', 'got ' .. icons(mobinfo.senses(BOMB)));
assert(icons(mobinfo.threat({ Aggro=false })) == 'PassiveNQ', 'a passive mob gets the passive icon');
assert(icons(mobinfo.threat({ Aggro=true, Link=true })) == 'AggroNQ Link', 'link has an icon of its own');
-- Notorious has no icon of its own: it is the HQ variant of the aggro/passive one, so an NM is one
-- glyph, not two -- while the fallback above still spells "NM" out, having no frame to show.
assert(icons(mobinfo.threat({ Aggro=true, Notorious=true })) == 'AggroHQ', 'an NM takes the HQ frame');
assert(icons(mobinfo.threat({ Aggro=false, Notorious=true })) == 'PassiveHQ', 'a passive NM too');

-- Weakness/resistance, sorted by potency descending so what to hit it with reads first.
assert(text(mobinfo.resist(BOMB)) == 'Fire+25% Ice-50% Wind-50% Earth-50% Lightning-50% Water-50% Light-50% Dark-50%',
    'got ' .. tostring(text(mobinfo.resist(BOMB))));
assert(text(mobinfo.resist(BONES)) == 'Blunt+25% Fire+25% Light+25% H2H+12.5% Slash-12.5% Ice-12.5% Pierce-50% Dark-50%',
    'got ' .. tostring(text(mobinfo.resist(BONES))));

-- The icon is the element's own name, so only the three renamed physical types can drift apart --
-- Blunt is the icon Impact, and a segment carries both.
assert(icons(mobinfo.resist(BONES)) == 'Impact Fire Light H2H Slashing Ice Piercing Dark',
    'got ' .. icons(mobinfo.resist(BONES)));

-- Eighths are what the data is made of, so the half-percent has to survive while a whole one must
-- not print a trailing zero.
assert(text(mobinfo.resist({ Modifiers={ Fire=1.125 } })) == 'Fire+12.5%', 'got ' .. tostring(text(mobinfo.resist({ Modifiers={ Fire=1.125 } }))));
assert(text(mobinfo.resist({ Modifiers={ Fire=1.25 } })) == 'Fire+25%', 'a whole percent drops its decimal');
assert(text(mobinfo.resist({ Modifiers={ Fire=0.875 } })) == 'Fire-12.5%', 'a resistance is signed negative');

-- Every segment keeps its own percentage, unlike mobdb, which prints one for a run of equal
-- potencies: a panel is only as wide as its widest line, and a number under the wrong icon is the
-- likelier misreading there.
assert(text(mobinfo.resist({ Modifiers={ Fire=0.5, Ice=0.5 } })) == 'Fire-50% Ice-50%', 'ties are not collapsed');

-- Ties keep collection order (physical first, then the elements in game order) rather than falling
-- out of `pairs`: this is rebuilt every frame, and a shuffling order would flicker the line.
local tied = { Modifiers={ Dark=0.5, Fire=0.5, Slashing=0.5, Water=0.5 } };
assert(text(mobinfo.resist(tied)) == 'Slash-50% Fire-50% Water-50% Dark-50%', 'got ' .. tostring(text(mobinfo.resist(tied))));

assert(mobinfo.resist({ Modifiers={ Fire=1, Ice=1 } }) == nil, 'a mob that takes everything normally has no line');
assert(mobinfo.resist({}) == nil, 'a row with no modifiers has no line');
assert(mobinfo.resist(nil) == nil, 'an unknown mob has no resist line');

-- Check tiers. Both published endpoints are asserted on every boundary, in both directions -- the
-- bands are interpolated between level 1 and level 75, so a sign or an off-by-one in the
-- interpolation shows up as one side of a boundary landing in the neighbouring tier.
local function tier(level, mob) return mobinfo.check_tier(level, mob); end

-- Level 1: EM 0, T +1..+4, VT +5, IT +6. Only the upper bands are asserted here -- the lower ones
-- at level 1 sit at mob levels below 1, which no mob has.
assert(tier(1, 1) == 'EM', 'your own level is the even match, and only it');
assert(tier(1, 2) == 'T',  'one up at level 1 is tough');
assert(tier(1, 5) == 'T',  'four up is still tough at level 1, got ' .. tier(1, 5));
assert(tier(1, 6) == 'VT', 'five up is very tough at level 1, got ' .. tier(1, 6));
assert(tier(1, 7) == 'IT', 'six up is incredibly tough at level 1, got ' .. tier(1, 7));

-- Level 75: TW at -20, EP -19..-8, DC -7..-1, EM 0, T +1..+3, VT +4..+7, IT +8. The bands widen
-- downward and narrow upward, which is the whole reason this is interpolated rather than fixed.
assert(tier(75, 55) == 'TW', 'twenty down at 75 is too weak, got ' .. tier(75, 55));
assert(tier(75, 56) == 'EP', 'nineteen down is easy prey, got ' .. tier(75, 56));
assert(tier(75, 67) == 'EP', 'eight down is still easy prey, got ' .. tier(75, 67));
assert(tier(75, 68) == 'DC', 'seven down is a decent challenge at 75, got ' .. tier(75, 68));
assert(tier(75, 74) == 'DC', 'one down too');
assert(tier(75, 75) == 'EM', 'even match is exact at every level');
assert(tier(75, 76) == 'T',  'one up is tough');
assert(tier(75, 78) == 'T',  'three up is still tough, got ' .. tier(75, 78));
assert(tier(75, 79) == 'VT', 'four up is very tough at 75 and merely tough at 1, got ' .. tier(75, 79));
assert(tier(75, 82) == 'VT', 'seven up is still very tough, got ' .. tier(75, 82));
assert(tier(75, 83) == 'IT', 'eight up is incredibly tough, got ' .. tier(75, 83));

-- Level 20, where every boundary is interpolated rather than an endpoint: TW at -10, EP -9..-4,
-- DC -3..-1, T +1..+4, VT +5..+6, IT +7. A sign error in the interpolation lands these in the
-- neighbouring tier while both endpoints above still pass.
assert(tier(20, 10) == 'TW', 'ten down at 20 is too weak, got ' .. tier(20, 10));
assert(tier(20, 11) == 'EP', 'nine down is easy prey, got ' .. tier(20, 11));
assert(tier(20, 16) == 'EP', 'four down is still easy prey, got ' .. tier(20, 16));
assert(tier(20, 17) == 'DC', 'three down is a decent challenge, got ' .. tier(20, 17));
assert(tier(20, 24) == 'T',  'four up is tough, got ' .. tier(20, 24));
assert(tier(20, 26) == 'VT', 'six up is very tough, got ' .. tier(20, 26));
assert(tier(20, 27) == 'IT', 'seven up is incredibly tough, got ' .. tier(20, 27));

-- Past the cap the boundaries hold at their level-75 values rather than running off the curve.
assert(tier(99, 79) == 'TW' and tier(99, 80) == 'EP', 'above 75 the bands stop widening');

-- The line itself. mobdb gives a range, and a range that straddles a boundary prints both ends --
-- one tier for a Lv.14-17 mob would be wrong about half the spawn -- jammed into one string and
-- the low tier's color, the shape the bar label prefixes itself with.
assert(mobinfo.check_text({ MinLevel=14, MaxLevel=16 }, 20).text == 'EP', 'a range inside one tier collapses to that tier alone');
local straddle = mobinfo.check_text({ MinLevel=14, MaxLevel=17 }, 20);
assert(straddle.text == 'EP-DC', 'both ends jammed into one string, got ' .. tostring(straddle.text));
assert(straddle.color == mobinfo.CHECK.EP.color, 'the low tier\'s color, got ' .. tostring(straddle.color));
assert(straddle.color2 == mobinfo.CHECK.DC.color, 'the high tier\'s color rides along for the bar gradient, got ' .. tostring(straddle.color2));
assert(mobinfo.check_text({ MinLevel=14, MaxLevel=16 }, 20).color2 == nil, 'a range inside one tier has no second color -- nothing to gradient toward');
assert(mobinfo.check_text({ Level=20 }, 20).text == 'EM', 'a fixed level is its own range');
assert(mobinfo.check_text({ Level=20, MinLevel=1, MaxLevel=99 }, 20).text == 'EM', 'a fixed level wins over the range');
assert(mobinfo.check_text({ MinLevel=14, MaxLevel=17, Notorious=true }, 20).text == '???',
    'an NM is never gauged, whatever its range says');
assert(mobinfo.check_text({ MinLevel=1, MaxLevel=2 }, nil) == nil, 'no player level, nothing to compare');
assert(mobinfo.check_text({ MinLevel=1, MaxLevel=2 }, 0) == nil, 'level 0 is not logged in yet');
assert(mobinfo.check_text({ Job=1 }, 20) == nil, 'a row with no level in it has no check line');
assert(mobinfo.check_text(nil, 20) == nil, 'an unknown mob has no check line');

-- Each tier draws in its own color, and the abbreviations are the ones /check prints.
for key, want in pairs({ TW='TW', EP='EP', DC='DC', EM='EM', T='T', VT='VT', IT='IT', ITG='???' }) do
    local t = mobinfo.CHECK[key];
    assert(t ~= nil and t.text == want, key .. ' abbreviates as ' .. want);
    assert(t.color ~= nil and t.color.r ~= nil and t.color.a == nil,
        key .. ' carries rgb and no alpha -- drawBar takes the opacity from cfg.states');
end

-- Every tier gets its own shade now that the color fills the HP bar itself rather than tinting the
-- label text: two tiers sharing a color would paint two different threat levels the same on a bar.
local seen = {};
for _, key in ipairs({ 'TW', 'EP', 'DC', 'EM', 'T', 'VT', 'IT', 'ITG' }) do
    local c      = mobinfo.CHECK[key].color;
    local packed = c.r .. ',' .. c.g .. ',' .. c.b;
    assert(seen[packed] == nil, key .. ' shares a color with ' .. tostring(seen[packed]));
    seen[packed] = key;
end

-- Lookup: index first (dynamic spawns are keyed by it), then name.
local db = { Indices = { [382] = BONES }, Names = { ['Bomb'] = BOMB } };
assert(mobinfo.find(db, 382, 'Bomb') == BONES, 'the index entry wins over the name');
assert(mobinfo.find(db, 17, 'Bomb') == BOMB, 'an unindexed mob is found by name');
assert(mobinfo.find(db, 17, "\007Bomb") == BOMB, 'a client name marker is stripped');
assert(mobinfo.find(db, 17, 'Orcish Fodder') == nil, 'an unknown name yields nothing');
assert(mobinfo.find(db, 17, nil) == nil, 'a nameless entity yields nothing');
assert(mobinfo.find(nil, 17, 'Bomb') == nil, 'no zone data yields nothing');

-- Panel assembly: each part keyed by where it draws, not by which toggle made it -- the bar's own
-- label (check tier + name + job), the tag box (the level), the two groups flanking the bar, and
-- the rows hung underneath.
local ALL_LINES   = { level = true, check = true, detect = true, resist = true };
local NO_LINES    = { level = false, check = false, detect = false, resist = false };
local ONLY_LEVEL  = { level = true, check = false, detect = false, resist = false };
local ONLY_DETECT = { level = false, check = false, detect = true, resist = false };
local ONLY_CHECK  = { level = false, check = true, detect = false, resist = false };

local LINKER = { MinLevel=14, MaxLevel=17, Job=1, Aggro=false, Notorious=true, Link=true,
                 Sight=true, Sound=true, Scent=true };

-- label segments carry their own spacing (the check tier trails a space, the job leads one), so
-- they concatenate directly -- unlike text() above, which puts a space between every segment.
local function label_text(label)
    if (label == nil) then return nil; end
    local out = {};
    for i, seg in ipairs(label) do out[i] = seg.text; end
    return table.concat(out);
end

local full = mobinfo.panel(LINKER, ALL_LINES, jobname, 20, 'Tough Mist Lizard');
assert(label_text(full.label) == '??? Tough Mist Lizard WAR',
    'check + name + job, got ' .. tostring(label_text(full.label)));
assert(full.tag == '14-17', 'the level tag box, got ' .. tostring(full.tag));
assert(full.hp_color == mobinfo.CHECK.ITG.color, 'the tier colors the HP bar');
for _, seg in ipairs(full.label) do
    assert(seg.color == nil, 'no label segment carries a color -- the whole label draws in cfg.text.color');
end
assert(full.hp_color2 == nil, 'a notorious monster is one tier (ITG), not a straddle -- no gradient');
assert(icons(full.left) == 'PassiveHQ Link', 'threat flanks left, got ' .. icons(full.left));
assert(icons(full.right) == 'Sight Sound Scent', 'senses flank right, got ' .. icons(full.right));
assert(#full.rows == 0, 'a mob with no modifiers hangs no rows');

local bomb = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb');
-- 'EP-DC', not 'EP- DC': check_text concatenates the two tiers into one string now that they
-- share the bar label instead of drawing as two colored segments above it.
assert(label_text(bomb.label) == 'EP-DC Bomb', 'the range straddles a boundary, got ' .. tostring(label_text(bomb.label)));
assert(bomb.tag == '8-10', 'got ' .. tostring(bomb.tag));
assert(bomb.hp_color == mobinfo.CHECK.EP.color, 'a straddling range colors the bar with the low tier, same as the label');
assert(bomb.hp_color2 == mobinfo.CHECK.DC.color, 'and carries the high tier too, for the bar\'s gradient fill');
assert(icons(bomb.left) == 'AggroNQ', 'no link, so the left group is the aggro icon alone');
assert(icons(bomb.right) == 'Sight Magic', 'got ' .. icons(bomb.right));
assert(#bomb.rows == 1, 'the resistance list is the row under the panel');
assert(text(bomb.rows[1]) == 'Fire+25% Ice-50% Wind-50% Earth-50% Lightning-50% Water-50% Light-50% Dark-50%',
    'got ' .. tostring(text(bomb.rows[1])));

local nolevel = mobinfo.panel(BOMB, ALL_LINES, jobname, nil, 'Bomb');
assert(label_text(nolevel.label) == 'Bomb', 'no player level leaves the check segment out, got ' .. tostring(label_text(nolevel.label)));
assert(nolevel.tag == '8-10', 'the tag does not depend on the check level');
assert(nolevel.hp_color == nil, 'no check segment means no bar color either');
assert(nolevel.hp_color2 == nil, 'and no second color for a gradient that has no first');

assert(label_text(mobinfo.panel(LINKER, ALL_LINES, nil, 20, 'Tough Mist Lizard').label) == '??? Tough Mist Lizard',
    'no jobname function means no job suffix, got '
    .. tostring(label_text(mobinfo.panel(LINKER, ALL_LINES, nil, 20, 'Tough Mist Lizard').label)));

-- The name shows for every target, mobdb entry or not: a player reads their own name, an
-- unrecognized mob reads its raw name -- only the check prefix, job suffix and tag require res.
local player = mobinfo.panel(nil, ALL_LINES, jobname, 20, 'PlayerName');
assert(label_text(player.label) == 'PlayerName', 'a player (or unknown mob) gets a name-only label, got ' .. tostring(label_text(player.label)));
assert(player.tag == nil, 'no res means no tag');
assert(#player.left == 0 and #player.right == 0 and #player.rows == 0, 'no res means no detect/resist groups either');
assert(player.hp_color == nil, 'no res means no check color either');

local noNameNoRes = mobinfo.panel(nil, ALL_LINES, jobname, 20, nil);
assert(noNameNoRes.label ~= nil and #noNameNoRes.label == 0,
    'no name and no res still hands back an (empty) label, not nil -- mob is not nil');

-- Each toggle still owns exactly what it names, and nothing else moves when one is off.
local lvl = mobinfo.panel(LINKER, ONLY_LEVEL, jobname, 20, 'Tough Mist Lizard');
assert(label_text(lvl.label) == 'Tough Mist Lizard WAR', 'level alone adds the job suffix, not the check prefix, got ' .. tostring(label_text(lvl.label)));
assert(lvl.tag == '14-17' and #lvl.left == 0 and #lvl.right == 0 and #lvl.rows == 0,
    'level alone is the tag + job suffix, and nothing else');
assert(lvl.hp_color == nil, 'level alone does not color the bar -- that is Show Check\'s toggle');

local det = mobinfo.panel(BOMB, ONLY_DETECT, jobname, 12, 'Bomb');
assert(label_text(det.label) == 'Bomb', 'detect alone leaves the name-only label, got ' .. tostring(label_text(det.label)));
assert(det.tag == nil, 'detect alone has no tag');
assert(icons(det.left) == 'AggroNQ' and icons(det.right) == 'Sight Magic',
    'detect alone is the icons, and the bar keeps its own label');
assert(det.hp_color == nil, 'detect alone does not color the bar either');

local chk = mobinfo.panel(BOMB, ONLY_CHECK, jobname, 12, 'Bomb');
assert(label_text(chk.label) == 'EP-DC Bomb', 'check alone prefixes the bar label -- it does not borrow the level toggle, got ' .. tostring(label_text(chk.label)));
assert(chk.tag == nil and #chk.left == 0 and #chk.rows == 0, 'check alone adds no tag and no other groups');
assert(chk.hp_color == mobinfo.CHECK.EP.color, 'check alone still colors the bar, same as the label prefix');
assert(chk.hp_color2 == mobinfo.CHECK.DC.color, 'and still carries the high tier for the gradient');

-- left/right/rows are always present so the caller indexes them without guarding; label/tag are
-- the two pieces that go nil, and only when there is truly nothing to build (mob itself nil).
local none = mobinfo.panel(BOMB, nil, jobname, 12, 'Bomb');
assert(none.label == nil and none.tag == nil, 'no toggle table at all means no label or tag');
assert(#none.left == 0 and #none.right == 0 and #none.rows == 0, 'and no groups');
assert(none.hp_color == nil, 'and no bar color');

local nolines = mobinfo.panel(BOMB, NO_LINES, jobname, 12, nil);
assert(nolines.label ~= nil and #nolines.label == 0, 'every toggle off (and no name) is an empty label, not a missing one');
assert(nolines.tag == nil and #nolines.left == 0 and #nolines.right == 0 and #nolines.rows == 0);
assert(nolines.hp_color == nil, 'every toggle off means no bar color either');

local shipped = mobinfo.panel(BOMB, config.defaults.mob, jobname, 12, 'Bomb');
assert(shipped.label ~= nil and #shipped.label > 0 and shipped.tag ~= nil and #shipped.left > 0 and #shipped.rows == 1,
    'the defaults ship every toggle on');
assert(shipped.hp_color == mobinfo.CHECK.EP.color, 'the defaults color the bar too');

-- A captured check (checkinfo's entry, `chk`) overrides mobdb's estimate: exact tier and level
-- instead of a range, and never a straddle gradient even though BOMB's own range (8-10 at level 12)
-- straddles EP/DC on its own.
local checked = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb', { level = 25, tier = 'IT' });
assert(label_text(checked.label) == 'IT Bomb', 'the checked tier wins over the mobdb estimate, got ' .. tostring(label_text(checked.label)));
assert(checked.tag == '25', 'the checked level snaps the tag to one number, got ' .. tostring(checked.tag));
assert(checked.hp_color == mobinfo.CHECK.IT.color, 'the bar fills in the checked tier\'s color');
assert(checked.hp_color2 == nil, 'one checked tier is never a straddle, even if mobdb\'s range would have been');

-- checkinfo's plus (0-2, High Evasion/High Defense) trails the tier abbreviation as `+`/`++`, and
-- still colors the bar in the plain tier's one color -- the suffix is text, not a new threat level.
local checkedPlus1 = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb', { level = 25, tier = 'IT', plus = 1 });
assert(label_text(checkedPlus1.label) == 'IT+ Bomb', 'one plus trails the tier as a single +, got ' .. tostring(label_text(checkedPlus1.label)));
assert(checkedPlus1.hp_color == mobinfo.CHECK.IT.color, 'the plus does not change the bar color');

local checkedPlus2 = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb', { level = 25, tier = 'IT', plus = 2 });
assert(label_text(checkedPlus2.label) == 'IT++ Bomb', 'both High Evasion and High Defense is a double ++, got ' .. tostring(label_text(checkedPlus2.label)));

-- The mobdb estimate never carries a suffix -- it has no condition data to derive one from -- even
-- for a tier that would otherwise take one were it a captured check.
local estimateOnly = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb');
assert(not label_text(estimateOnly.label):find('%+'), 'the estimate path never appends a plus, got ' .. tostring(label_text(estimateOnly.label)));

-- A checked mob mobdb has never heard of (res is nil) still gets the exact tier and level -- /check
-- does not need mobdb to work, and job/detect/resist stay off since none of that is in a check.
local checkedNoRes = mobinfo.panel(nil, ALL_LINES, jobname, 20, 'Unrecognized Mob', { level = 30, tier = 'VT' });
assert(label_text(checkedNoRes.label) == 'VT Unrecognized Mob', 'got ' .. tostring(label_text(checkedNoRes.label)));
assert(checkedNoRes.tag == '30', 'the tag needs no mobdb entry when chk supplies the level');
assert(checkedNoRes.hp_color == mobinfo.CHECK.VT.color, 'the bar colors from chk alone too');
assert(#checkedNoRes.left == 0 and #checkedNoRes.right == 0 and #checkedNoRes.rows == 0,
    'no res still means no job suffix and no detect/resist groups');

-- A level of 0 is the server declining to give one (an NM's check, in practice): the tag falls back
-- to mobdb's range when there is one, and to nothing when there isn't -- same as no chk at all.
local checkedNoLevel = mobinfo.panel(BOMB, ALL_LINES, jobname, 12, 'Bomb', { level = 0, tier = 'ITG' });
assert(label_text(checkedNoLevel.label) == '??? Bomb', 'the tier still wins with no usable level, got ' .. tostring(label_text(checkedNoLevel.label)));
assert(checkedNoLevel.tag == '8-10', 'mobdb\'s range is the fallback when chk gives no usable level');

local checkedNoLevelNoRes = mobinfo.panel(nil, ALL_LINES, jobname, 12, 'Unrecognized Mob', { level = 0, tier = 'ITG' });
assert(checkedNoLevelNoRes.tag == nil, 'no usable level and no mobdb entry leaves no tag at all');

-- Show Check off leaves the checked tier out of the label and the bar uncolored, same as the
-- mobdb-estimate path -- the toggle still owns the whole prefix, whichever source supplied it.
local checkedNoToggle = mobinfo.panel(BOMB, ONLY_LEVEL, jobname, 12, 'Bomb', { level = 25, tier = 'IT' });
assert(label_text(checkedNoToggle.label) == 'Bomb', 'check off means no prefix even with a captured check, got ' .. tostring(label_text(checkedNoToggle.label)));
assert(checkedNoToggle.hp_color == nil, 'and no bar color either');
assert(checkedNoToggle.tag == '25', 'the level tag is Show Level & Job\'s toggle, independent of Show Check');

-- The loader. A missing file is the normal case -- mobdb ships ~245 zones and may not be
-- installed at all -- so it must land on nil rather than throwing.
assert(mobinfo.load('no-such-zone-file-12345.lua') == nil, 'a missing zone file yields no data');

local tmp = os.tmpname();
local fh  = io.open(tmp, 'w');
fh:write("return { Names = { ['Bomb'] = { MinLevel = 8, MaxLevel = 10 } }, Indices = { [382] = { MinLevel = 5, MaxLevel = 8 } } };");
fh:close();
local loaded = mobinfo.load(tmp);
assert(loaded ~= nil, 'a mobdb zone file must load under stock lua');
assert(mobinfo.level_text(mobinfo.find(loaded, 1, 'Bomb')) == '8-10', 'names survive the round trip');
assert(mobinfo.level_text(mobinfo.find(loaded, 382, 'Bomb')) == '5-8', 'indices survive the round trip');

fh = io.open(tmp, 'w');
fh:write('this is not lua');
fh:close();
assert(mobinfo.load(tmp) == nil, 'a corrupt zone file yields no data');

fh = io.open(tmp, 'w');
fh:write('return 7;');
fh:close();
assert(mobinfo.load(tmp) == nil, 'a file that does not return a table yields no data');

fh = io.open(tmp, 'w');
fh:write('return {};');
fh:close();
assert(mobinfo.load(tmp).Names ~= nil and mobinfo.load(tmp).Indices ~= nil, 'both tables are always present, so find never indexes nil');
os.remove(tmp);

print('mobinfo.lua ok');

-- checkinfo.lua: the /check capture list, keyed by server id.
local list = {};

checkinfo.record(list, nil, 20, 0x43, 0xAB);
assert(next(list) == nil, 'no entity means nothing recorded');

checkinfo.record(list, fakeEnt(0x10, 100, 0, 500), 20, 0x99, 0xAB);
assert(next(list) == nil, 'an unrecognized type id is not a check response');

checkinfo.record(list, fakeEnt(0x10, 100, 0, 500), 20, 0x43, 0x77);
assert(next(list) == nil, 'an unrecognized message id is not a check response');

checkinfo.record(list, fakeEnt(0x10, 100, 0, 500), 20, 0x43, 0xAB);
assert(list[500].level == 20, 'level is recorded as given, got ' .. tostring(list[500].level));
assert(list[500].type == 'like a decent challenge', 'type resolves through M.TYPES, got ' .. tostring(list[500].type));
assert(list[500].message == 'High Evasion', 'message resolves through M.CONDITIONS, got ' .. tostring(list[500].message));
assert(list[500].tier == 'DC', 'type 0x43 maps to mobinfo\'s DC tier, got ' .. tostring(list[500].tier));
assert(list[500].plus == 1, 'a single "High" in the condition is one plus, got ' .. tostring(list[500].plus));

-- 0xAE is a real condition id and reads as an empty string, not "unrecognized".
checkinfo.record(list, fakeEnt(0x10, 100, 0, 501), 20, 0x44, 0xAE);
assert(list[501] ~= nil and list[501].message == '', 'condition 0xAE is the empty string, not missing');
assert(list[501].tier == 'EM', 'type 0x44 maps to EM, got ' .. tostring(list[501].tier));
assert(list[501].plus == 0, 'the average condition (0xAE) is no plus, got ' .. tostring(list[501].plus));

-- Impossible to gauge: the server sends no usable type at all, so there is nothing to resolve.
checkinfo.record(list, fakeEnt(0x10, 100, 0, 502), 0, 0xFF, 0xF9);
assert(list[502].type == nil and list[502].message == 'Impossible to gauge!', 'an NM check has no type, only the ITG message');
assert(list[502].tier == 'ITG', 'an NM check still gets a tier, matching mobinfo.CHECK.ITG');
assert(list[502].plus == 0, 'an NM check has no condition to count, got ' .. tostring(list[502].plus));

-- Both High Evasion and High Defense (0xAA) is two pluses; either alone is one; Low never counts,
-- even paired with a High (0xAC, 0xB0) -- only "checks better than expected" is worth flagging.
checkinfo.record(list, fakeEnt(0x10, 100, 0, 506), 20, 0x43, 0xAA);
assert(list[506].plus == 2, 'High Evasion, High Defense is two pluses, got ' .. tostring(list[506].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 507), 20, 0x43, 0xAD);
assert(list[507].plus == 1, 'High Defense alone is one plus, got ' .. tostring(list[507].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 508), 20, 0x43, 0xAC);
assert(list[508].plus == 1, 'High Evasion, Low Defense is one plus -- Low does not count, got ' .. tostring(list[508].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 509), 20, 0x43, 0xB0);
assert(list[509].plus == 1, 'Low Evasion, High Defense is one plus, got ' .. tostring(list[509].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 510), 20, 0x43, 0xAF);
assert(list[510].plus == 0, 'Low Defense alone is no plus, got ' .. tostring(list[510].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 511), 20, 0x43, 0xB1);
assert(list[511].plus == 0, 'Low Evasion alone is no plus, got ' .. tostring(list[511].plus));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 512), 20, 0x43, 0xB2);
assert(list[512].plus == 0, 'Low Evasion, Low Defense is no plus, got ' .. tostring(list[512].plus));

-- 0x40 and 0x47 are the chart's two ends; 0x41 ("incredibly easy prey") has no tier of its own
-- below EP in this project's chart, and lands on EP the same as 0x42 ("easy prey").
checkinfo.record(list, fakeEnt(0x10, 100, 0, 503), 20, 0x40, 0xAB);
assert(list[503].tier == 'TW', 'type 0x40 maps to TW, got ' .. tostring(list[503].tier));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 504), 20, 0x41, 0xAB);
assert(list[504].tier == 'EP', 'type 0x41 has no tier below EP, got ' .. tostring(list[504].tier));
checkinfo.record(list, fakeEnt(0x10, 100, 0, 505), 20, 0x47, 0xAB);
assert(list[505].tier == 'IT', 'type 0x47 maps to IT, got ' .. tostring(list[505].tier));

-- A re-check overwrites rather than stacking a second entry for the same server id.
checkinfo.record(list, fakeEnt(0x10, 100, 0, 500), 25, 0x44, 0xAA);
assert(list[500].level == 25 and list[500].type == 'like an even match', 're-checking overwrites the old entry');
assert(list[500].tier == 'EM', 'the tier is overwritten along with everything else');

-- Pruning: only the entity that is now at 0% hp loses its entry; everything else survives.
checkinfo.prune(list, nil);
assert(list[500] ~= nil, 'a nil entity prunes nothing');
checkinfo.prune(list, fakeEnt(0x10, 50, 0, 500));
assert(list[500] ~= nil, 'a living entity is not pruned');
checkinfo.prune(list, fakeEnt(0x10, 0, 0, 500));
assert(list[500] == nil, 'an entity at 0% hp is pruned');
assert(list[501] ~= nil and list[502] ~= nil, 'pruning one server id leaves the others alone');

checkinfo.clear(list);
assert(next(list) == nil, 'clear empties the whole list');

print('checkinfo.lua ok');

-- enemylist.lua: personally-claimed mob tracking, keyed by server id -- mirrors checkinfo.lua's
-- shape. No per-entry data beyond membership, so recording an already-tracked mob is a no-op.
local enemylist = require('lib.enemylist');

local elist = {};
enemylist.record(elist, nil);
assert(next(elist) == nil, 'recording a nil entity must not add anything');

enemylist.record(elist, fakeEnt(0x10, 100, 0, 700));
assert(elist[700] == true, 'a recorded mob is tracked by its server id');

enemylist.record(elist, fakeEnt(0x10, 100, 0, 700));
assert(elist[700] == true, 'recording the same mob twice is a no-op, not an error');

enemylist.prune(elist, nil);
assert(elist[700] == true, 'pruning a nil entity must not touch the list');

enemylist.prune(elist, fakeEnt(0x10, 50, 0, 700));
assert(elist[700] == true, 'a mob still above 0% hp must not be pruned');

enemylist.prune(elist, fakeEnt(0x10, 0, 0, 700));
assert(elist[700] == nil, 'a mob at 0% hp is pruned');

enemylist.record(elist, fakeEnt(0x10, 100, 0, 701));
enemylist.record(elist, fakeEnt(0x10, 100, 0, 702));
enemylist.clear(elist);
assert(next(elist) == nil, 'clear empties the whole list');

print('enemylist.lua ok');

-- resolve_index: server id -> live entity index, via an injected get_server_id lookup (same
-- injection pattern nameplate.lua uses for its memory reader) so this is testable without a real
-- entity manager.
local function fakeServerIds(map)
    return function (index) return map[index] or 0; end;
end

-- Fast path: a non-PC server id (0x1000000 bit set) encodes its own index in the low 12 bits.
local FAST_ID = 0x1000000 + 0x123;
assert(enemylist.resolve_index(fakeServerIds({ [0x123] = FAST_ID }), FAST_ID) == 0x123,
    'the fast path decodes the index straight out of the server id');

-- The bit trick alone is not trusted -- it must be verified against get_server_id, since a stale
-- server id can still carry that bit pattern after the entity at that index changed.
assert(enemylist.resolve_index(fakeServerIds({ [0x123] = 999 }), FAST_ID) == 0,
    'an unverified fast-path guess must fall through to the full scan, not be trusted blind');

-- >= 0x900 wraps back by 0x100, matching HXUI's/Sidekick's own shortcut.
local WRAP_ID = 0x1000000 + 0x905;
assert(enemylist.resolve_index(fakeServerIds({ [0x805] = WRAP_ID }), WRAP_ID) == 0x805,
    'an index >= 0x900 wraps back by 0x100 before verification');

-- No fast-path bit set at all: falls straight to the full walk.
local SLOW_ID = 12345;
assert(enemylist.resolve_index(fakeServerIds({ [42] = SLOW_ID }), SLOW_ID) == 42,
    'a server id with no fast-path bit is found by the full walk');

-- Not found anywhere.
assert(enemylist.resolve_index(fakeServerIds({}), SLOW_ID) == 0,
    'an id that matches nothing yields 0');

print('enemylist.lua resolve_index ok');
