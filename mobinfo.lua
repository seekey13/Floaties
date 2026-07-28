--[[
* Reference lines for the target panel: level range + job, how the mob detects you, and what it
* is weak or resistant to.
*
* The data is mobdb's. Its zone files (Ashita/addons/mobdb/data/<zone>.lua) are plain
* `return { Names = {...}, Indices = {...} }` tables with no globals and no requires in them, so
* they load under stock lua with loadfile -- which is why this whole module, the loader included,
* stays testable headless. Nothing here touches AshitaCore: the caller passes the path in and a
* job-id -> abbreviation function with it.
*
* Every formatter returns nil when it has nothing to say, so a line with no content is skipped
* rather than drawn blank.
--]]

local M = {};

--[[
* Loads one zone's mob data.
*
* A missing file is the normal case, not an error: mobdb ships ~245 of the game's zones, and it
* may not be installed at all. Both land on nil and the reference lines simply have nothing to
* say -- NewUI must not need mobdb to draw.
*
* @param {string} path - full path to mobdb's <zone>.lua.
* @return {table|nil} { Names, Indices }, both always present when non-nil.
--]]
function M.load(path)
    local chunk = loadfile(path);
    if (chunk == nil) then
        return nil;
    end

    -- pcall for the same reason mobdb has one: the file is data, but it is data that runs.
    local ok, data = pcall(chunk);
    if (not ok or type(data) ~= 'table') then
        return nil;
    end

    return { Names = data.Names or {}, Indices = data.Indices or {} };
end

--[[
* The database entry for one entity, or nil when it is not a known mob.
*
* Index first, name second, matching mobdb: dynamic spawns (the 0x700+ range) differ per zone
* instance and are keyed by index, everything else by name.
*
* @param {table|nil} db - M.load's result.
* @param {number} index - entity index.
* @param {string|nil} name - entity name as the client holds it.
* @return {table|nil}
--]]
function M.find(db, index, name)
    if (db == nil) then
        return nil;
    end

    local byIndex = db.Indices[index];
    if (byIndex ~= nil) then
        return byIndex;
    end

    if (name == nil) then
        return nil;
    end

    -- Names are stored unprefixed, but the client puts markers in front of some of them, so
    -- everything before the first letter is dropped -- same match mobdb's GetByName uses.
    return db.Names[name:match('^[^%a]*(.*)') or name];
end

--[[
* "[Lv14-17 WAR/MNK]" -- the level range, and the job when the mob has one.
*
* A fixed-level mob carries `Level` instead of a range; most carry the range. Job 0 means the
* entry does not name a job, which is most of the low-level fauna, and prints nothing rather than
* a placeholder.
*
* @param {function|nil} jobname - job id -> abbreviation. Omitted, the job is left off.
--]]
function M.level_job(res, jobname)
    if (res == nil) then
        return nil;
    end

    local out = 'Lv' .. (res.Level and tostring(res.Level)
        or string.format('%d-%d', res.MinLevel or 0, res.MaxLevel or 0));

    if (jobname ~= nil and res.Job ~= nil and res.Job > 0) then
        out = out .. ' ' .. (jobname(res.Job) or '?');
        if (res.SubJob ~= nil and res.SubJob > 0) then
            out = out .. '/' .. (jobname(res.SubJob) or '?');
        end
    end

    return '[' .. out .. ']';
end

-- What the mob notices you with, in the order it is worth reading. TrueSight leads Sight because
-- it supersedes it (invisible does not help), and Link trails the lot -- it is not detection, but
-- it is the other thing you want to know before pulling.
local DETECTION = { 'TrueSight', 'Sight', 'Sound', 'Scent', 'Magic', 'JA', 'Blood', 'Link' };

--[[
* "NM Aggro Sight Sound Link" -- aggression, then what it detects with.
*
* Aggro/Passive always prints: "no detection flags" and "does not aggro" are different facts, and
* a line that vanished for a passive mob would read as missing data rather than as a safe mob.
--]]
function M.detection(res)
    if (res == nil) then
        return nil;
    end

    local out = { res.Aggro and 'Aggro' or 'Passive' };
    for _, flag in ipairs(DETECTION) do
        if (res[flag] == true) then
            out[#out + 1] = flag;
        end
    end

    if (res.Notorious) then
        table.insert(out, 1, 'NM');
    end

    return table.concat(out, ' ');
end

-- Damage types, in the order they are collected. Physical before magical, matching mobdb's
-- $physmagic; within each, the game's own element order.
local PHYSICAL = { 'Slashing', 'Piercing', 'H2H', 'Impact' };
local MAGICAL  = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' };

-- mobdb draws these as icons and has the room; a line of words does not, so the two long
-- physical names get the abbreviation a player would use anyway.
local SHORT = { Slashing = 'Slash', Piercing = 'Pierce', Impact = 'Blunt' };

-- "+25%" / "-12.5%" from a 1.25 / 0.875 multiplier. One decimal, trailing ".0" dropped: the data
-- is all eighths, so 12.5 has to survive while 25.0 must not print as "25.0%".
local function percent(potency)
    local delta  = (potency - 1) * 100;
    local digits = string.format('%.1f', math.abs(delta)):gsub('%.0$', '');
    return (delta > 0 and '+' or '-') .. digits .. '%';
end

--[[
* "Fire+25% Ice-50% Dark-50%" -- every damage type the mob does not take normally.
*
* Sorted by potency descending, so what to hit it with reads first and what to avoid reads last.
* Ties keep collection order (see PHYSICAL/MAGICAL) rather than falling out of `pairs`: the table
* is walked every frame, and an order that shuffled between frames would flicker the line.
--]]
function M.resist(res)
    if (res == nil or res.Modifiers == nil) then
        return nil;
    end

    local mods = {};
    for _, names in ipairs({ PHYSICAL, MAGICAL }) do
        for _, name in ipairs(names) do
            local potency = res.Modifiers[name];
            if (potency ~= nil and potency ~= 1) then
                mods[#mods + 1] = {
                    text    = (SHORT[name] or name) .. percent(potency),
                    potency = potency,
                    rank    = #mods + 1,
                };
            end
        end
    end

    if (#mods == 0) then
        return nil;
    end

    table.sort(mods, function (a, b)
        if (a.potency ~= b.potency) then
            return a.potency > b.potency;
        end
        return a.rank < b.rank;
    end);

    local out = {};
    for i, mod in ipairs(mods) do
        out[i] = mod.text;
    end
    return table.concat(out, ' ');
end

--[[
* The enabled, non-empty reference lines for one mob, top to bottom.
*
* @param {table|nil} res - M.find's result; nil (an unknown mob, or a PC) yields no lines.
* @param {table|nil} mob - cfg.mob: the three per-line toggles.
* @return {table} array of strings, possibly empty. Never nil -- callers take #lines as the row
*                 count for the panel's height, so there is nothing to guard.
--]]
function M.lines(res, mob, jobname)
    local out = {};
    if (res == nil or mob == nil) then
        return out;
    end

    local function add(text)
        if (text ~= nil and text ~= '') then
            out[#out + 1] = text;
        end
    end

    if (mob.level) then add(M.level_job(res, jobname)); end
    if (mob.detect) then add(M.detection(res)); end
    if (mob.resist) then add(M.resist(res)); end

    return out;
end

return M;
