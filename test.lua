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

print('config.lua ok');
