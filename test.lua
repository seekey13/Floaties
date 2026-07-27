--[[
* Self-check for stats.lua. Run headless: lua test.lua
--]]

local stats     = require('stats');
local config    = require('config');
local nameplate = require('nameplate');

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
assert(config.bar_width(config.defaults, SELF) == 92, 'bar width = size.width - 2*offset, got ' .. tostring(config.bar_width(config.defaults, SELF)));
assert(config.panel_height(config.defaults, SELF) == 60, 'panel height = sum(bar heights) + 2*gap + 2*offset, got ' .. tostring(config.panel_height(config.defaults, SELF)));

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
assert(config.bar_width(config.defaults, sizes.party) == 52, 'party width is its own, got ' .. tostring(config.bar_width(config.defaults, sizes.party)));
assert(config.bar_width(config.defaults, sizes.target) == 192, 'target width is its own, got ' .. tostring(config.bar_width(config.defaults, sizes.target)));
assert(config.panel_height(config.defaults, sizes.party) == 8 * 3 + 2 * 2 + 2 * 4, 'party heights are its own, got ' .. tostring(config.panel_height(config.defaults, sizes.party)));
assert(config.panel_height(config.defaults, sizes.target, { 'hp' }) == 24 + 2 * 4, 'target height is its own, got ' .. tostring(config.panel_height(config.defaults, sizes.target, { 'hp' })));

-- Every kind in size_order must actually exist, and target must carry the one bar it draws.
for _, kind in ipairs(config.size_order) do
    assert(config.defaults.sizes[kind] ~= nil, 'size_order names a missing size table: ' .. kind);
    assert(config.defaults.sizes[kind].width ~= nil, kind .. ' has no width');
end
assert(config.defaults.sizes.target.hp ~= nil, 'the target panel draws an hp bar, so it needs an hp height');

-- MP bar only shows when main or sub has an MP pool.
assert(#config.bars_for(1, 2) == 2, 'WAR/MNK must drop the mp bar');
assert(config.bars_for(1, 2)[2] == 'tp', 'remaining bars stay in draw order');
assert(#config.bars_for(1, 3) == 3, 'WAR/WHM keeps the mp bar (sub has MP)');
assert(#config.bars_for(22, 1) == 3, 'RUN/WAR keeps the mp bar (main has MP)');
assert(#config.bars_for(1, 0) == 2, 'no subjob must not error');

-- Hiding a bar shrinks the panel by that bar's height plus one gap.
assert(config.panel_height(config.defaults, SELF, { 'hp', 'tp' }) == 42,
    'two-bar panel = 16+16 + 1*2 + 2*4, got ' .. tostring(config.panel_height(config.defaults, SELF, { 'hp', 'tp' })));

-- Label size comes from the bar, never from its own setting: bar height less the fixed inset, so
-- the text cannot be taller than what it sits in at any bar height or distance scale.
assert(config.label_size(config.defaults, 16) == 16 - config.label_inset, 'label size = bar height - inset, got ' .. tostring(config.label_size(config.defaults, 16)));
for h = 4, 40 do
    local size = config.label_size(config.defaults, h);
    assert(size == nil or size <= h, 'a label must never be taller than its bar (h=' .. h .. ')');
end

-- Below the floor there is no legible size left, so the bar drops its label rather than drawing
-- mush. That covers both ways a bar gets there: configured too short, or scaled too far away.
-- Derived from min_size, not written out: the floor is a setting and moves.
local FLOOR_H = config.defaults.text.min_size + config.label_inset;
assert(config.label_size(config.defaults, FLOOR_H) == config.defaults.text.min_size, 'the shortest bar that fits the floor still prints it');
assert(config.label_size(config.defaults, FLOOR_H - 1) == nil, 'one pixel under the floor drops the label');
assert(config.label_size(config.defaults, 4) == nil, 'the shortest configurable bar cannot hold a label');
assert(config.label_size(config.defaults, 16 * 0.5) == nil, 'a 16px bar scaled to half drops its label');
assert(config.label_size(config.defaults, 16 * 1.5) ~= nil, 'a 16px bar scaled up keeps it');

-- The regression that prompted the floor: a 10px TP bar printed a 6px label -- sized, fitting and
-- unreadable. The floor is what makes "too small to read" and "not drawn" the same thing, so it
-- has to stay above where ImGui's 13px atlas stops resolving when downscaled.
assert(config.defaults.text.min_size >= 8, 'a floor under 8px lets the mush regime back in');

-- Per-bar label toggles: every drawable bar has one, and they ship on.
for _, key in ipairs(config.bar_order) do
    assert(config.defaults.bars[key].label == true, key .. ' must ship with its label on');
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

local scaling = { distance_scale = true, scale_ref = 6.0, scale_min = 0.35, scale_max = 1.5 };

nearly(config.panel_scale(scaling, 6.0), 1.0, 'the reference depth draws 1:1');
nearly(config.panel_scale(scaling, 12.0), 0.5, 'twice the reference is half size');
nearly(config.panel_scale(scaling, 4.0), 1.5, 'closer than the reference grows');
nearly(config.panel_scale(scaling, 3.0), 1.5, 'growth stops at scale_max');
nearly(config.panel_scale(scaling, 60.0), 0.35, 'shrink stops at scale_min');

-- Behind the lens / degenerate projections must not produce a negative or infinite panel.
nearly(config.panel_scale(scaling, 0), 1.0, 'zero depth yields no scaling');
nearly(config.panel_scale(scaling, -5), 1.0, 'a point behind the camera yields no scaling');
nearly(config.panel_scale(scaling, nil), 1.0, 'a missing depth yields no scaling');

-- Off is the default, and off must be exactly 1 at every depth -- anything else would move
-- panels for people who never asked for this.
assert(config.defaults.distance_scale == false, 'distance scaling ships off');
for _, d in ipairs({ 0.5, 6, 50, 500 }) do
    assert(config.panel_scale(config.defaults, d) == 1, 'disabled scaling is exactly 1 at depth ' .. d);
end

-- The defaults' own reference must leave your own panel unclamped, or scale_ref is untunable
-- from the config window: a self panel pegged at scale_max ignores the slider entirely.
local self_depth = 6.0;
assert(config.panel_scale(scaling, self_depth) < scaling.scale_max,
    'the default reference must not peg self at scale_max');

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
