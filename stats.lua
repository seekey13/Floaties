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
* Reads self (party slot 0) and returns HP/MP/TP as both raw values (for text
* labels) and 0.0 .. 1.0 fill fractions (for bar widths).
*
* @param {object} party - AshitaCore:GetMemoryManager():GetParty()
* @return {table|nil} { hp, hp_raw, mp, mp_raw, tp, tp_raw } or nil when the slot is not populated.
--]]
function M.read(party)
    if (party == nil or party:GetMemberIsActive(0) == 0) then
        return nil;
    end

    local hp_raw = party:GetMemberHP(0);
    local mp_raw = party:GetMemberMP(0);
    local tp_raw = M.clamp(party:GetMemberTP(0), 0, 3000);

    return {
        -- GetMemberHPPercent can report above 100; clamp before dividing.
        hp     = M.clamp(party:GetMemberHPPercent(0), 0, 100) / 100,
        hp_raw = hp_raw,
        mp     = M.clamp(party:GetMemberMPPercent(0), 0, 100) / 100,
        mp_raw = mp_raw,
        -- TP runs 0..3000, not 0..100.
        tp     = tp_raw / 3000,
        tp_raw = tp_raw,
    };
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
