--[[
* Tracks which mobs you (or your pet/avatar/automaton, or a trust in your own party) have
* personally damaged or affected, keyed by server id -- pure, mirrors checkinfo.lua's shape.
* Floaties.lua decodes the Action packet (0x0028), decides whether the actor counts as "you" and
* whether the target is a mob, and calls M.record with the resolved target entity; this module
* only owns the list itself and has no per-entry data beyond membership.
*
* This is not a ranked hate/enmity list -- the server does not send real enmity numbers to the
* client during normal play (the only exact read is casting Libra) -- only "you hit this mob, at
* some point, and it is not dead yet".
--]]

local M = {};

--[[
* Records one mob as currently "yours". Overwrites nothing -- a second hit on an already-recorded
* mob is a no-op, since there is no data on the entry to refresh.
*
* @param {table} list - the list to write into, keyed by server id.
* @param {userdata|nil} ent - entity from GetEntity(target index), i.e. the mob that was hit.
--]]
function M.record(list, ent)
    if (ent == nil) then
        return;
    end
    list[ent.ServerId] = true;
end

--[[
* Drops one entity's entry once it is dead. Same reasoning as checkinfo.prune: a corpse, or a new
* spawn reusing the same server id, is not the mob that was hit.
*
* @param {table} list - the list to prune.
* @param {userdata|nil} ent - the entity to check.
--]]
function M.prune(list, ent)
    if (ent ~= nil and ent.HPPercent == 0) then
        list[ent.ServerId] = nil;
    end
end

--[[
* Discards the whole list. Same reasoning as checkinfo.clear -- a server id is only unique within
* one zone instance.
*
* @param {table} list - the list to empty.
--]]
function M.clear(list)
    for k in pairs(list) do
        list[k] = nil;
    end
end

--[[
* Resolves a server id to a live entity index, or 0 when it cannot be found.
*
* Non-PC server ids (mobs, pets, trusts, static NPCs) encode their own index in the low 12 bits
* when the 0x1000000 bit is set -- the same shortcut HXUI's GetIndexFromId (helpers.lua) and
* Sidekick's resolve_entity_name (lib/core/common.lua) both already use. That bit trick alone is
* never trusted blind: it is verified against get_server_id first, since a stale server id can
* still carry the same bit pattern after the entity actually at that index has changed. Only on a
* miss does this fall back to a full walk of every index -- rare for this module's caller, since
* 0x0028's targets are near-always live entities.
*
* get_server_id is an injected function (real caller: `function(i) return
* mm:GetEntity():GetServerId(i) end`), the same injection pattern nameplate.lua uses for its
* memory reader -- what makes this testable with a fake lookup table instead of a real entity
* manager.
*
* @param {function} get_server_id - function(index) -> server id.
* @param {number} server_id - the id to resolve.
* @return {number} entity index, or 0 if not found.
--]]
function M.resolve_index(get_server_id, server_id)
    if (server_id % (0x1000000 * 2) >= 0x1000000) then
        local idx = server_id % 0x1000;
        if (idx >= 0x900) then
            idx = idx - 0x100;
        end
        if (idx < 0x900 and get_server_id(idx) == server_id) then
            return idx;
        end
    end

    for i = 1, 0x8FF do
        if (get_server_id(i) == server_id) then
            return i;
        end
    end

    return 0;
end

return M;
