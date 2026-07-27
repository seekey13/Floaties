--[[
* Pure stat normalization. No Ashita dependencies so it stays testable (see test.lua).
--]]

local M = {};

function M.clamp(v, lo, hi)
    if (v < lo) then return lo; end
    if (v > hi) then return hi; end
    return v;
end

--[[
* Reads one party slot and returns HP/MP/TP as both raw values (for text
* labels) and 0.0 .. 1.0 fill fractions (for bar widths).
*
* @param {object} party - AshitaCore:GetMemoryManager():GetParty()
* @param {number} index - party slot, 0 .. 5. Defaults to 0 (self).
* @return {table|nil} { hp, hp_raw, mp, mp_raw, tp, tp_raw } or nil when the slot is not populated.
--]]
function M.read(party, index)
    index = index or 0;

    if (party == nil or party:GetMemberIsActive(index) == 0) then
        return nil;
    end

    local hp_raw = party:GetMemberHP(index);
    local mp_raw = party:GetMemberMP(index);
    local tp_raw = M.clamp(party:GetMemberTP(index), 0, 3000);

    return {
        -- GetMemberHPPercent can report above 100; clamp before dividing.
        hp     = M.clamp(party:GetMemberHPPercent(index), 0, 100) / 100,
        hp_raw = hp_raw,
        mp     = M.clamp(party:GetMemberMPPercent(index), 0, 100) / 100,
        mp_raw = mp_raw,
        -- TP runs 0..3000, not 0..100.
        tp     = tp_raw / 3000,
        tp_raw = tp_raw,
    };
end

--[[
* Number to print on a bar. Party packets carry raw HP/MP only for self; for
* other members they read 0 while the percent is still valid, so fall back to
* the percent rather than printing a bogus 0.
*
* @return {number} raw value, or the percent when only that is known.
--]]
function M.label(s, key)
    local raw = s[key .. '_raw'];
    if (key == 'tp' or raw > 0) then
        return raw;
    end
    return math.floor(s[key] * 100);
end

--[[
* Fill fraction for one of the TP bar's 3 segments (1000 TP each, matching
* the weaponskill thresholds at 1000/2000/3000).
*
* @param {number} tp_raw - current TP, 0..3000.
* @param {number} segment - 1, 2, or 3.
* @return {number} 0.0 .. 1.0
--]]
function M.tp_segment(tp_raw, segment)
    return M.clamp((tp_raw - (segment - 1) * 1000) / 1000, 0, 1);
end

return M;
