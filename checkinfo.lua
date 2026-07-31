--[[
* Captures what /check reported about an entity, keyed by its server id, so a re-target does not
* need a re-check to know what was already learned. Pure -- Floaties.lua unpacks the Message Basic
* packet (0x0029) and resolves the entity, and hands the raw fields in here; this module owns the
* decision of what counts as a check response and how its codes read.
*
* The condition and type tables are Ashita's own `checker` addon's (checker.lua's `conditions` and
* `types`), re-expressed as plain strings instead of `chat`-colored T{} values: this file has to
* stay loadable under stock lua (see CLAUDE.md), and chat's coloring is a presentation detail for
* whichever UI branch reads this list later, not a fact worth freezing into the capture.
*
* Nothing here is wired to the target panel yet -- that is a later branch's job. This module only
* builds and maintains the list.
--]]

local M = {};

-- Message basic's `m` field: the condition half of a /check response. 0xAE is a real condition
-- (average evasion and defense) and reads as an empty string, so a nil lookup -- not a falsy one --
-- is what "not a condition id" means.
M.CONDITIONS = {
    [0xAA] = 'High Evasion, High Defense',
    [0xAB] = 'High Evasion',
    [0xAC] = 'High Evasion, Low Defense',
    [0xAD] = 'High Defense',
    [0xAE] = '',
    [0xAF] = 'Low Defense',
    [0xB0] = 'Low Evasion, High Defense',
    [0xB1] = 'Low Evasion',
    [0xB2] = 'Low Evasion, Low Defense',
};

-- Message basic's `p2` field: the difficulty half, alongside the condition above.
M.TYPES = {
    [0x40] = 'too weak to be worthwhile',
    [0x41] = 'like incredibly easy prey',
    [0x42] = 'like easy prey',
    [0x43] = 'like a decent challenge',
    [0x44] = 'like an even match',
    [0x45] = 'tough',
    [0x46] = 'very tough',
    [0x47] = 'incredibly tough',
};

-- The message id an NM's /check response carries instead of a condition -- the server withholds
-- the difficulty entirely rather than sending one from M.TYPES, so there is no type to resolve.
local IMPOSSIBLE_TO_GAUGE = 0xF9;

--[[
* Records one /check response against the entity it was about. Overwrites any existing entry for
* that server id -- a re-check is the freshest truth about that entity, not a second opinion to
* keep alongside the first.
*
* Both `message` and `ptype` have to resolve for this to be a check response at all -- Message
* Basic carries hundreds of unrelated client messages, and an id that happens to collide with
* M.CONDITIONS while `ptype` names no real tier is not a check. Silently does nothing for either
* case: an unresolved packet or an unrecognized code pair is the overwhelmingly common case here,
* not an error worth surfacing.
*
* @param {table} list - the list to write into, keyed by server id.
* @param {userdata|nil} ent - entity from GetEntity(target index), i.e. who this /check was about.
* @param {number} level - message basic's `p1`. <= 0 means the server declined to give a level.
* @param {number} ptype - message basic's `p2`, the difficulty message id.
* @param {number} message - message basic's `m`, the condition message id (or IMPOSSIBLE_TO_GAUGE).
--]]
function M.record(list, ent, level, ptype, message)
    if (ent == nil) then
        return;
    end

    if (message == IMPOSSIBLE_TO_GAUGE) then
        list[ent.ServerId] = { level = level, type = nil, message = 'Impossible to gauge!' };
        return;
    end

    local t, c = M.TYPES[ptype], M.CONDITIONS[message];
    if (t == nil or c == nil) then
        return;
    end

    list[ent.ServerId] = { level = level, type = t, message = c };
end

--[[
* Drops one entity's entry once it is dead. A corpse re-targeted later, or a new spawn that reuses
* the same server id, is not the mob that was checked, so a stale entry would read as wrong rather
* than merely missing.
*
* @param {table} list - the list to prune.
* @param {userdata|nil} ent - the entity to check, e.g. the currently resolved target.
--]]
function M.prune(list, ent)
    if (ent ~= nil and ent.HPPercent == 0) then
        list[ent.ServerId] = nil;
    end
end

--[[
* Discards the whole list. Server ids are only unique within a zone instance, so nothing recorded
* under the old one can be trusted to still mean the same entity after a zone change.
*
* @param {table} list - the list to empty.
--]]
function M.clear(list)
    for k in pairs(list) do
        list[k] = nil;
    end
end

return M;
