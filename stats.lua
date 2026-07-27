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
* Reads self (party slot 0) and returns HP/MP/TP as 0.0 .. 1.0 fill fractions.
*
* @param {object} party - AshitaCore:GetMemoryManager():GetParty()
* @return {table|nil} { hp, mp, tp } or nil when the slot is not populated.
--]]
function M.read(party)
    if (party == nil or party:GetMemberIsActive(0) == 0) then
        return nil;
    end

    return {
        -- GetMemberHPPercent can report above 100; clamp before dividing.
        hp = M.clamp(party:GetMemberHPPercent(0), 0, 100) / 100,
        mp = M.clamp(party:GetMemberMPPercent(0), 0, 100) / 100,
        -- TP runs 0..3000, not 0..100.
        -- ponytail: single bar across the whole range; add the 1000-point
        -- weaponskill split (see HXUI-DATA-CAPTURE-RESEARCH.md section 7) if it matters.
        tp = M.clamp(party:GetMemberTP(0), 0, 3000) / 3000,
    };
end

return M;
