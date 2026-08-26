--[[
* Pure stat normalization. No Ashita dependencies so it stays testable (see test.lua).
--]]

local M = {};

function M.clamp(v, lo, hi)
    if (v < lo) then return lo; end
    if (v > hi) then return hi; end
    return v;
end

-- Single-bit flag test. Not bit.band: `bit` is a LuaJIT global, and test.lua runs under plain lua.
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
* Only HP is available -- the client is told a mob's HP as a percent and nothing else -- so
* callers draw the { 'hp' } bar set. hp_raw = 0 is not a placeholder: it is the condition M.label
* already tests to fall back to printing that percent.
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
* Reads a pet into the same shape M.read returns.
*
* HP comes from the entity like any other (the client is told a percent and nothing else), but MP
* and TP do not: they are only published for *your own* pet, through the player block rather than
* the entity, so the caller reads them there and hands them in. Another member's pet gets
* M.read_entity instead -- there is nowhere to read its MP or TP from.
*
* Both extras stay optional so this one reader covers "your pet, MP known" and "your pet, no MP
* pool at all" without the caller branching: nil is normalized to an empty bar, and which bars are
* actually drawn is config.pet_bars' decision, not this function's.
*
* @param {userdata|nil} ent - the pet's entity from GetEntity(index).
* @param {number|nil} mp_percent - GetPetMPPercent(), 0..100.
* @param {number|nil} tp_raw - GetPetTP(), 0..3000.
* @return {table|nil} { hp, hp_raw, mp, mp_raw, tp, tp_raw } or nil when there is no entity.
--]]
function M.read_pet(ent, mp_percent, tp_raw)
    local s = M.read_entity(ent);
    if (s == nil) then
        return nil;
    end

    tp_raw = M.clamp(tp_raw or 0, 0, 3000);

    -- mp_raw/hp_raw 0 for the same reason M.read_entity sets it: a pet's pools are published as a
    -- percent, so M.label falls back to printing that percent with a % sign.
    s.mp     = M.clamp(mp_percent or 0, 0, 100) / 100;
    s.mp_raw = 0;
    s.tp     = tp_raw / 3000;
    s.tp_raw = tp_raw;
    return s;
end

--[[
* Whether an entity should get a target panel drawn over it.
*
* Not Floaties's isEnemy: a trust or pet you targeted is fine to draw, so the party scan covers only
* slots 0..5 -- the ones drawMember already draws -- to stop a second panel stacking on the first.
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
* The second return says which of the two happened, so the caller can mark a
* percent with a % sign -- derived by the branch that picked the number, so the
* two can never disagree.
*
* @return {number,boolean} the value, and whether it is a percent rather than a raw amount.
--]]
function M.label(s, key)
    local raw = s[key .. '_raw'];
    if (key == 'tp' or raw > 0) then
        return raw, false;
    end
    -- The server's percent is a whole number; round rather than floor so the
    -- float round-trip through the 0..1 fraction cannot shave off a point.
    return math.floor(s[key] * 100 + 0.5), true;
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
