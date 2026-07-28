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
*
* A line is an array of *segments*, not a string, because the detection and resistance lines draw
* as mobdb's own icons rather than as words -- a row of glyphs reads at a glance where "Aggro Sight
* Magic" has to be parsed. A segment is:
*
*   icon - mobdb icon name (Ashita/addons/mobdb/icons/<icon>.png), or nil for a text-only segment.
*   alt  - the word the icon stands for, drawn instead of it when the texture is missing.
*   text - text drawn after the icon, and after `alt` in the fallback. The percentage, in practice.
*
* The fallback is not decoration: mobdb's data files and its icons are separate installs, and a
* resistance segment that lost its icon would otherwise print a bare "+25%" with nothing saying
* which element. Picking the icon stays here, with the flag that chooses it; loading and drawing it
* is NewUI.lua's, so this file still loads under stock lua.
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
* "Lv14-17 WAR/MNK" -- the level range, and the job when the mob has one.
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

    return out;
end

-- What the mob notices you with, in the order it is worth reading. TrueSight leads Sight because
-- it supersedes it (invisible does not help), and Link trails the lot -- it is not detection, but
-- it is the other thing you want to know before pulling.
local DETECTION = { 'TrueSight', 'Sight', 'Sound', 'Scent', 'Magic', 'JA', 'Blood', 'Link' };

--[[
* Aggression, then what it detects with -- one icon each.
*
* Aggro/Passive always draws: "no detection flags" and "does not aggro" are different facts, and a
* line that vanished for a passive mob would read as missing data rather than as a safe mob.
*
* Notorious is not a segment of its own, because mobdb has no NM icon: it has HQ variants of the
* aggro/passive one (a gold frame), which is one glyph carrying both facts. The text fallback still
* spells it out as a separate word, since there is no frame to see.
*
* @return {table|nil} segments.
--]]
function M.detection(res)
    if (res == nil) then
        return nil;
    end

    local mood = res.Aggro and 'Aggro' or 'Passive';
    local out  = {
        {
            icon = mood .. (res.Notorious and 'HQ' or 'NQ'),
            alt  = (res.Notorious and 'NM ' or '') .. mood,
        },
    };

    for _, flag in ipairs(DETECTION) do
        if (res[flag] == true) then
            out[#out + 1] = { icon = flag, alt = flag };
        end
    end

    return out;
end

-- Damage types, in the order they are collected. Physical before magical, matching mobdb's
-- $physmagic; within each, the game's own element order.
local PHYSICAL = { 'Slashing', 'Piercing', 'H2H', 'Impact' };
local MAGICAL  = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water', 'Light', 'Dark' };

-- Fallback wording only -- with the icons present these names are never drawn. A panel is narrow,
-- so the long physical names get the abbreviation a player would use anyway. (The keys are also the
-- icon names, which is why the table is a rename and not a rewrite: mobdb names the file Slashing.)
local SHORT = { Slashing = 'Slash', Piercing = 'Pierce', Impact = 'Blunt' };

-- "+25%" / "-12.5%" from a 1.25 / 0.875 multiplier. One decimal, trailing ".0" dropped: the data
-- is all eighths, so 12.5 has to survive while 25.0 must not print as "25.0%".
local function percent(potency)
    local delta  = (potency - 1) * 100;
    local digits = string.format('%.1f', math.abs(delta)):gsub('%.0$', '');
    return (delta > 0 and '+' or '-') .. digits .. '%';
end

--[[
* An icon and a percentage for every damage type the mob does not take normally.
*
* Sorted by potency descending, so what to hit it with reads first and what to avoid reads last.
* Ties keep collection order (see PHYSICAL/MAGICAL) rather than falling out of `pairs`: the table
* is walked every frame, and an order that shuffled between frames would flicker the line.
*
* Unlike mobdb, equal potencies each keep their own percentage instead of one being printed for the
* run: mobdb lays its icons out on a window-wide row where the grouping reads, and these sit on a
* panel that is only as wide as its widest line, where a number lining up under the wrong icon is
* the likelier reading.
*
* @return {table|nil} segments.
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
                    icon    = name,
                    alt     = SHORT[name] or name,
                    text    = percent(potency),
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

    -- Rebuilt rather than returned as-is: potency/rank exist to sort by and have no business
    -- reaching the renderer, which would then be free to start reading them.
    local out = {};
    for i, mod in ipairs(mods) do
        out[i] = { icon = mod.icon, alt = mod.alt, text = mod.text };
    end
    return out;
end

--[[
* The enabled, non-empty reference lines for one mob, top to bottom.
*
* @param {table|nil} res - M.find's result; nil (an unknown mob, or a PC) yields no lines.
* @param {table|nil} mob - cfg.mob: the three per-line toggles.
* @return {table} array of segment arrays, possibly empty. Never nil -- callers take #lines as the
*                 row count for the panel's height, so there is nothing to guard.
--]]
function M.lines(res, mob, jobname)
    local out = {};
    if (res == nil or mob == nil) then
        return out;
    end

    local function add(segments)
        if (segments ~= nil and #segments > 0) then
            out[#out + 1] = segments;
        end
    end

    -- The level line has no icon to draw -- mobdb ships none for a level range or a job -- so it
    -- stays the one line that is a single run of text, wrapped as a segment to keep the shape.
    if (mob.level) then
        local text = M.level_job(res, jobname);
        if (text ~= nil) then
            add({ { text = text } });
        end
    end

    if (mob.detect) then add(M.detection(res)); end
    if (mob.resist) then add(M.resist(res)); end

    return out;
end

return M;
