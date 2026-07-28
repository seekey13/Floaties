--[[
* Self-check for stats.lua. Run headless: lua test.lua
--]]

local stats     = require('stats');
local config    = require('config');
local nameplate = require('nameplate');
local mobinfo   = require('mobinfo');

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

-- Party slot indicator: the box plus one bar gap comes out of the bars, never out of the panel,
-- and only for a panel kind that has a slot at all.
local slotcfg = { panel = { offset = 4 }, gap = 2, slot = { enabled = true, size = 12 } };
local offcfg  = { panel = { offset = 4 }, gap = 2, slot = { enabled = false, size = 12 } };

assert(config.slot_box(slotcfg) == 18, 'box width = floor(1.5 * text size), got ' .. tostring(config.slot_box(slotcfg)));
assert(config.slot_width(slotcfg, true) == 20, 'reserved width = box + one gap, got ' .. tostring(config.slot_width(slotcfg, true)));
assert(config.slot_width(slotcfg, false) == 0, 'a panel with no slot reserves nothing');
assert(config.slot_width(offcfg, true) == 0, 'the indicator off reserves nothing');

-- Exactly the old width when off, not merely close to it: switching the tag off must not nudge
-- bars by a rounding remainder.
assert(config.bar_width(offcfg, SELF, true) == config.bar_width(offcfg, SELF), 'off must match the no-slot width exactly');
assert(config.bar_width(slotcfg, SELF, true) == 200 - 2 * 4 - 20, 'bars give up box + gap, got ' .. tostring(config.bar_width(slotcfg, SELF, true)));
assert(config.bar_width(slotcfg, sizes.target, false) == 192, 'the target panel keeps its full bar width');

-- The defaults ship with it on, so they are the case that has to lay out: box floor(1.5*21)=31
-- plus the 1px gap, out of the bars only.
assert(config.slot_width(config.defaults, true) == 32, 'default reserved width, got ' .. tostring(config.slot_width(config.defaults, true)));
assert(config.bar_width(config.defaults, SELF, true) == 196 - 32, 'a default party panel gives up box + gap, got ' .. tostring(config.bar_width(config.defaults, SELF, true)));
assert(config.bar_width(config.defaults, config.defaults.sizes.target, false) == 296, 'the default target panel reserves nothing');
assert(config.label_size(config.defaults, config.defaults.slot.size) ~= nil, 'the default slot text must clear Min Text Size, or the tag never prints');

-- The panel's own footprint is untouched -- the space is taken from the bars inside it.
assert(config.panel_height(slotcfg, SELF) == config.panel_height(offcfg, SELF), 'the tag must not change panel height');

-- Mob reference lines add a row each below the bars: the line plus one gap above it, so the block
-- is separated from the last bar and nothing trails the bottom.
local TARGET = config.defaults.sizes.target;
assert(config.info_height(config.defaults, 0) == 0, 'no lines adds no height');
assert(config.info_height(config.defaults, 3) == 3 * (14 + 1), 'each line costs its height plus a gap, got ' .. tostring(config.info_height(config.defaults, 3)));

assert(config.panel_height(config.defaults, TARGET, { 'hp' }, 3) == 20 + 2 * 2 + 45,
    'three lines on the target panel, got ' .. tostring(config.panel_height(config.defaults, TARGET, { 'hp' }, 3)));

-- Exactly the bar-only height with no lines, not merely close: every existing panel has to keep
-- the geometry it had. Omitting the argument must match passing 0.
assert(config.panel_height(config.defaults, TARGET, { 'hp' }, 0) == config.panel_height(config.defaults, TARGET, { 'hp' }),
    'zero lines must match the old height exactly');

-- info_height must not touch cfg.mob when there is nothing to draw -- panel kinds that never have
-- lines, and every fixture above, ship no `mob` table.
assert(config.info_height(custom, 0) == 0, 'no lines must not read cfg.mob');
assert(config.panel_height(custom, customSize, nil, 0) == config.panel_height(custom, customSize), 'a mob-less config still lays out');

-- The default line height must clear Min Text Size, or the lines never print at the shipped
-- settings -- the same trap the slot tag has.
assert(config.label_size(config.defaults, config.defaults.mob.size) ~= nil, 'the default info text must clear Min Text Size');

-- MP bar only shows when main or sub has an MP pool.
assert(#config.bars_for(1, 2) == 2, 'WAR/MNK must drop the mp bar');
assert(config.bars_for(1, 2)[2] == 'tp', 'remaining bars stay in draw order');
assert(#config.bars_for(1, 3) == 3, 'WAR/WHM keeps the mp bar (sub has MP)');
assert(#config.bars_for(22, 1) == 3, 'RUN/WAR keeps the mp bar (main has MP)');
assert(#config.bars_for(1, 0) == 2, 'no subjob must not error');

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
--   actor 0x1000: +0x67C feet height 10.0, +0x6B8 -> 0x2000
--   0x2000 +0x0C -> 0x3000 -> 0x4000 (the skeleton)
--   0x4000 +0x32 bone count, bones start at 0x30 + 0x04 + 0x1E*count + 4
local ACTOR = 0x1000;

local function fakeMem(u32, u16, f32)
    return {
        read_uint32 = function (a) return u32[a] or 0; end,
        read_uint16 = function (a) return u16[a] or 0; end,
        read_float  = function (a) return f32[a] or 0; end,
    };
end

local function skeleton(bone_z, count)
    count = count or #bone_z;
    local gens = 0x4000 + 0x30 + 0x04 + 0x1E * count + 4;
    local f32  = { [ACTOR + 0x67C] = 10.0 };
    for i, z in ipairs(bone_z) do
        f32[gens + (i - 1) * 0x1A + 0x12] = z;
    end
    return fakeMem(
        { [ACTOR + 0x6B8] = 0x2000, [0x2000 + 0x0C] = 0x3000, [0x3000] = 0x4000 },
        { [0x4000 + 0x32] = count },
        f32);
end

local function near(a, b) return a ~= nil and math.abs(a - b) < 1e-6; end

-- Height is down-positive, so the *highest* bone is the smallest Z, and it is relative to the
-- actor origin: 10.0 feet + (-1.8) head = 8.2.
assert(near(nameplate.top(skeleton({ -1.0, -1.8, -0.5 }), ACTOR), 8.2),
    'top = feet + highest (least) bone z, got ' .. tostring(nameplate.top(skeleton({ -1.0, -1.8, -0.5 }), ACTOR)));
assert(near(nameplate.top(skeleton({ -0.5, -1.0, -1.8 }), ACTOR), 8.2), 'bone order must not matter');
assert(near(nameplate.top(skeleton({ 0.0 }), ACTOR), 10.0), 'a single bone at the origin is the feet height');

-- A half-written bone reads NaN; it must not poison the minimum.
local nan = 0 / 0;
assert(near(nameplate.top(skeleton({ nan, -1.8, nan }), ACTOR), 8.2), 'NaN bones must be skipped');
assert(nameplate.top(skeleton({ nan }), ACTOR) == nil, 'all-NaN skeleton yields no anchor');

-- Every pointer in the chain can read 0 during a zone or model swap. None may throw.
assert(nameplate.top(skeleton({ -1.0 }), nil) == nil, 'nil actor pointer yields nil');
assert(nameplate.top(skeleton({ -1.0 }), 0) == nil, 'null actor pointer yields nil');
assert(nameplate.top(fakeMem({}, {}, {}), ACTOR) == nil, 'null skeleton base yields nil');
assert(nameplate.top(fakeMem({ [ACTOR + 0x6B8] = 0x2000 }, {}, {}), ACTOR) == nil, 'null skeleton offset yields nil');
assert(nameplate.top(fakeMem({ [ACTOR + 0x6B8] = 0x2000, [0x2000 + 0x0C] = 0x3000 }, {}, {}), ACTOR) == nil,
    'null skeleton address yields nil');

-- Bone count guards: 0 is an empty model, a huge count means the walk landed on non-skeleton
-- memory and must not be read as thousands of floats.
assert(nameplate.top(skeleton({}, 0), ACTOR) == nil, 'zero bones yields nil');
assert(nameplate.top(skeleton({}, 257), ACTOR) == nil, 'an implausible bone count yields nil');
assert(nameplate.top(skeleton({}, 256), ACTOR) ~= nil, '256 bones is still walked');

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

-- Level and job. The job is dropped entirely at Job 0 rather than printing a placeholder -- most
-- low-level fauna carries no job.
assert(mobinfo.level_job(BOMB, jobname) == '[Lv8-10]', 'job 0 prints the range alone, got ' .. tostring(mobinfo.level_job(BOMB, jobname)));
assert(mobinfo.level_job({ MinLevel=14, MaxLevel=17, Job=1 }, jobname) == '[Lv14-17 WAR]',
    'range + main job, got ' .. tostring(mobinfo.level_job({ MinLevel=14, MaxLevel=17, Job=1 }, jobname)));
assert(mobinfo.level_job({ MinLevel=14, MaxLevel=17, Job=1, SubJob=2 }, jobname) == '[Lv14-17 WAR/MNK]', 'sub job is appended');
assert(mobinfo.level_job({ MinLevel=14, MaxLevel=17, Job=1, SubJob=0 }, jobname) == '[Lv14-17 WAR]', 'sub job 0 is not a job');
assert(mobinfo.level_job({ Level=75, MinLevel=75, MaxLevel=75, Job=1 }, jobname) == '[Lv75 WAR]', 'a fixed level prints once, not as a range');
assert(mobinfo.level_job({ MinLevel=1, MaxLevel=2, Job=1 }, nil) == '[Lv1-2]', 'no job lookup means no job');
assert(mobinfo.level_job({ MinLevel=1, MaxLevel=2, Job=99 }, jobname) == '[Lv1-2 ?]', 'an unknown job id must not error');
assert(mobinfo.level_job(nil, jobname) == nil, 'an unknown mob has no level line');

-- Detection. Aggro/Passive always leads: "detects nothing" and "does not aggro" are different
-- facts, and a vanishing line would read as missing data rather than as a safe mob.
assert(mobinfo.detection(BOMB) == 'Aggro Sight Magic', 'got ' .. tostring(mobinfo.detection(BOMB)));
assert(mobinfo.detection(BONES) == 'Aggro Sound Blood', 'got ' .. tostring(mobinfo.detection(BONES)));
assert(mobinfo.detection({ Aggro=false }) == 'Passive', 'a passive mob with no flags still prints');
assert(mobinfo.detection({ Aggro=true, Link=true, TrueSight=true, Sight=true }) == 'Aggro TrueSight Sight Link',
    'link trails the detection flags, got ' .. tostring(mobinfo.detection({ Aggro=true, Link=true, TrueSight=true, Sight=true })));
assert(mobinfo.detection({ Aggro=true, Notorious=true, Sound=true }) == 'NM Aggro Sound', 'NM leads the line');
assert(mobinfo.detection(nil) == nil, 'an unknown mob has no detection line');

-- Weakness/resistance, sorted by potency descending so what to hit it with reads first.
assert(mobinfo.resist(BOMB) == 'Fire+25% Ice-50% Wind-50% Earth-50% Lightning-50% Water-50% Light-50% Dark-50%',
    'got ' .. tostring(mobinfo.resist(BOMB)));
assert(mobinfo.resist(BONES) == 'Blunt+25% Fire+25% Light+25% H2H+12.5% Slash-12.5% Ice-12.5% Pierce-50% Dark-50%',
    'got ' .. tostring(mobinfo.resist(BONES)));

-- Eighths are what the data is made of, so the half-percent has to survive while a whole one must
-- not print a trailing zero.
assert(mobinfo.resist({ Modifiers={ Fire=1.125 } }) == 'Fire+12.5%', 'got ' .. tostring(mobinfo.resist({ Modifiers={ Fire=1.125 } })));
assert(mobinfo.resist({ Modifiers={ Fire=1.25 } }) == 'Fire+25%', 'a whole percent drops its decimal');
assert(mobinfo.resist({ Modifiers={ Fire=0.875 } }) == 'Fire-12.5%', 'a resistance is signed negative');

-- Ties keep collection order (physical first, then the elements in game order) rather than falling
-- out of `pairs`: this is rebuilt every frame, and a shuffling order would flicker the line.
local tied = { Modifiers={ Dark=0.5, Fire=0.5, Slashing=0.5, Water=0.5 } };
assert(mobinfo.resist(tied) == 'Slash-50% Fire-50% Water-50% Dark-50%', 'got ' .. tostring(mobinfo.resist(tied)));
assert(mobinfo.resist(tied) == mobinfo.resist(tied), 'the same mob must format identically twice');

assert(mobinfo.resist({ Modifiers={ Fire=1, Ice=1 } }) == nil, 'a mob that takes everything normally has no line');
assert(mobinfo.resist({}) == nil, 'a row with no modifiers has no line');
assert(mobinfo.resist(nil) == nil, 'an unknown mob has no resist line');

-- Lookup: index first (dynamic spawns are keyed by it), then name.
local db = { Indices = { [382] = BONES }, Names = { ['Bomb'] = BOMB } };
assert(mobinfo.find(db, 382, 'Bomb') == BONES, 'the index entry wins over the name');
assert(mobinfo.find(db, 17, 'Bomb') == BOMB, 'an unindexed mob is found by name');
assert(mobinfo.find(db, 17, 'Bomb') ~= nil, 'sanity');
assert(mobinfo.find(db, 17, "\007Bomb") == BOMB, 'a client name marker is stripped');
assert(mobinfo.find(db, 17, 'Orcish Fodder') == nil, 'an unknown name yields nothing');
assert(mobinfo.find(db, 17, nil) == nil, 'a nameless entity yields nothing');
assert(mobinfo.find(nil, 17, 'Bomb') == nil, 'no zone data yields nothing');

-- Line assembly: each toggle owns one line, and a line with nothing to say is skipped rather than
-- drawn blank -- so ticking all three does not guarantee three rows.
local ALL_LINES  = { level = true, detect = true, resist = true };
local NO_LINES   = { level = false, detect = false, resist = false };
local ONLY_LEVEL = { level = true, detect = false, resist = false };

assert(#mobinfo.lines(BOMB, ALL_LINES, jobname) == 3, 'all three lines on');
assert(mobinfo.lines(BOMB, ALL_LINES, jobname)[1] == '[Lv8-10]', 'level leads');
assert(mobinfo.lines(BOMB, ALL_LINES, jobname)[2] == 'Aggro Sight Magic', 'detection second');
assert(#mobinfo.lines(BOMB, NO_LINES, jobname) == 0, 'all three off draws nothing');
assert(#mobinfo.lines(BOMB, ONLY_LEVEL, jobname) == 1, 'each toggle is independent');
assert(#mobinfo.lines({ MinLevel=1, MaxLevel=1, Aggro=false }, ALL_LINES, jobname) == 2,
    'a mob with no modifiers drops that line and keeps the rest');
assert(#mobinfo.lines(nil, ALL_LINES, jobname) == 0, 'an unknown mob draws no lines');
assert(#mobinfo.lines(BOMB, nil, jobname) == 0, 'no settings draws no lines');
assert(#mobinfo.lines(BOMB, config.defaults.mob, jobname) == 3, 'the defaults ship all three lines on');

-- The loader. A missing file is the normal case -- mobdb ships ~245 zones and may not be
-- installed at all -- so it must land on nil rather than throwing.
assert(mobinfo.load('no-such-zone-file-12345.lua') == nil, 'a missing zone file yields no data');

local tmp = os.tmpname();
local fh  = io.open(tmp, 'w');
fh:write("return { Names = { ['Bomb'] = { MinLevel = 8, MaxLevel = 10 } }, Indices = { [382] = { MinLevel = 5, MaxLevel = 8 } } };");
fh:close();
local loaded = mobinfo.load(tmp);
assert(loaded ~= nil, 'a mobdb zone file must load under stock lua');
assert(mobinfo.level_job(mobinfo.find(loaded, 1, 'Bomb')) == '[Lv8-10]', 'names survive the round trip');
assert(mobinfo.level_job(mobinfo.find(loaded, 382, 'Bomb')) == '[Lv5-8]', 'indices survive the round trip');

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
