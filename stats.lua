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
* Single-bit flag test.
*
* Not bit.band: `bit` is a LuaJIT global, and this file is required by test.lua, which the
* README says to run under plain `lua` -- where it is nil. Single bit only, so callers test
* one mask at a time rather than an ORed pair.
--]]
local function hasFlag(v, mask)
    return v % (mask * 2) >= mask;
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
* Reads an entity (rather than a party slot) into the same shape M.read returns.
*
* Only HP is available: the client is told a mob's HP as a percent and nothing else -- no raw
* HP, no MP, no TP. Callers therefore draw the { 'hp' } bar set.
*
* hp_raw = 0 is not a placeholder. It is the condition M.label already tests to fall back to
* printing the percent, which is the only number there is here.
*
* @param {userdata|nil} ent - entity from GetEntity(index).
* @return {table|nil} { hp, hp_raw } or nil when there is no entity.
--]]
function M.read_entity(ent)
    if (ent == nil) then
        return nil;
    end

    return {
        hp     = M.clamp(ent.HPPercent, 0, 100) / 100,
        hp_raw = 0,
    };
end

--[[
* Whether an entity should get a target panel drawn over it.
*
* A different question from NewUI's isEnemy, which gates "am I in combat" and scans all 18
* alliance slots to reject trusts and pets. Here a trust or pet you have targeted is a fine
* thing to draw, so the party scan only covers 0..5 -- the slots drawMember already draws --
* and exists to stop a second panel stacking on top of the first.
*
* @param {userdata|nil} ent - entity from GetEntity(index).
* @param {object} party - AshitaCore:GetMemoryManager():GetParty()
* @return {boolean}
--]]
function M.targetable(ent, party)
    if (ent == nil) then
        return false;
    end

    -- Mob (0x10) or PC (0x01). NPCs (0x02) are excluded -- a shopkeeper with a health bar
    -- over it is noise, and targeting NPCs to talk to them is constant.
    if (not (hasFlag(ent.SpawnFlags, 0x10) or hasFlag(ent.SpawnFlags, 0x01))) then
        return false;
    end

    -- Corpses stay targetable in game for a while after the kill.
    if (ent.HPPercent == 0 or ent.Status == 2 or ent.Status == 3) then
        return false;
    end

    if (party ~= nil) then
        for i = 0, 5 do
            if (party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == ent.ServerId) then
                return false;
            end
        end
    end

    return true;
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
    -- The server's percent is a whole number; round rather than floor so the
    -- float round-trip through the 0..1 fraction cannot shave off a point.
    return math.floor(s[key] * 100 + 0.5);
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
