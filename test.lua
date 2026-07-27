--[[
* Self-check for stats.lua. Run headless: lua test.lua
--]]

local stats  = require('stats');
local config = require('config');

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

print('stats.lua ok');

-- config.lua: derived layout math must match the defaults' expected geometry.
assert(config.bar_width(config.defaults) == 92, 'bar width = panel.width - 2*offset, got ' .. tostring(config.bar_width(config.defaults)));
assert(config.panel_height(config.defaults) == 60, 'panel height = sum(bar heights) + 2*gap + 2*offset, got ' .. tostring(config.panel_height(config.defaults)));

local custom = { panel = { width = 200, offset = 10 }, gap = 5, bars = { hp = { height = 20 }, mp = { height = 30 }, tp = { height = 40 } } };
assert(config.bar_width(custom) == 180, 'bar width recomputes from custom panel, got ' .. tostring(config.bar_width(custom)));
assert(config.panel_height(custom) == 20 + 30 + 40 + 2 * 5 + 2 * 10, 'panel height recomputes from custom bars, got ' .. tostring(config.panel_height(custom)));

-- MP bar only shows when main or sub has an MP pool.
assert(#config.bars_for(1, 2) == 2, 'WAR/MNK must drop the mp bar');
assert(config.bars_for(1, 2)[2] == 'tp', 'remaining bars stay in draw order');
assert(#config.bars_for(1, 3) == 3, 'WAR/WHM keeps the mp bar (sub has MP)');
assert(#config.bars_for(22, 1) == 3, 'RUN/WAR keeps the mp bar (main has MP)');
assert(#config.bars_for(1, 0) == 2, 'no subjob must not error');

-- Hiding a bar shrinks the panel by that bar's height plus one gap.
assert(config.panel_height(config.defaults, { 'hp', 'tp' }) == 42,
    'two-bar panel = 16+16 + 1*2 + 2*4, got ' .. tostring(config.panel_height(config.defaults, { 'hp', 'tp' })));

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

print('config.lua ok');
