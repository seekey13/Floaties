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
* Magic" has to be parsed, and it lets icons and text share one run (see M.panel). A segment is:
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
    return db.Names[name:match('^[^%a]*(.*)')];
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

    local out = 'Lv.' .. (res.Level and tostring(res.Level)
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
-- it supersedes it -- invisible does not help. Link is deliberately not in here: it is not a sense,
-- and it belongs with the aggro flag (see M.threat).
local SENSES = { 'TrueSight', 'Sight', 'Sound', 'Scent', 'Magic', 'JA', 'Blood' };

--[[
* What happens when you walk up to it: aggro or passive, and whether it links.
*
* These two are the pull decision, so they lead the line, left of the level -- the senses on the
* other side answer a different question (how to approach), and splitting them puts each group
* where it is looked for instead of running eight glyphs together.
*
* Aggro/Passive always draws: "no detection flags" and "does not aggro" are different facts, and a
* group that vanished for a passive mob would read as missing data rather than as a safe mob.
*
* Notorious is not a segment of its own, because mobdb has no NM icon: it has HQ variants of the
* aggro/passive one (a gold frame), which is one glyph carrying both facts. The text fallback still
* spells it out as a separate word, since there is no frame to see.
*
* @return {table|nil} segments.
--]]
function M.threat(res)
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

    if (res.Link == true) then
        out[#out + 1] = { icon = 'Link', alt = 'Link' };
    end

    return out;
end

--[[
* What it notices you with, one icon each, drawn right of the level.
*
* @return {table|nil} segments -- empty for a mob that senses nothing, which is a real answer and
*                     not a missing one. M.lines simply has nothing to append.
--]]
function M.senses(res)
    if (res == nil) then
        return nil;
    end

    local out = {};
    for _, flag in ipairs(SENSES) do
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

    -- potency/rank ride along on the segments: they exist to sort by, and the renderer reads
    -- icon/alt/text and never goes looking for a fourth key.
    return mods;
end

--[[
* Everything the target panel draws from mobdb, split by where it goes rather than by which toggle
* produced it -- the caller places each part and needs no idea which flag it came from:
*
*     <Aggro> <Link>  [====== Lv.14-17 WAR/MNK ======]  <Sight> <Sound> <Scent>
*                      <Fire>+25% <Ice>-50% <Dark>-50%
*
*   label - text for the HP bar's own label. The level, in place of the HP percent, because a bar
*           already *is* the percent -- the number on top of a full bar was saying "100%" over a
*           full bar. (The caller switches back to the percent once the mob is damaged, which is
*           the point at which the percent starts saying something the fill does not.)
*   left  - segments flanking the bar on its left: aggro/passive and Link, the pull decision.
*   right - segments flanking it on its right: what it senses you with.
*   rows  - full-width rows hung under the panel. The resistance list, in practice -- that one has
*           no fixed length, so it cannot flank anything without shoving the bar off-center.
*
* All four are always present (label may be nil), so the caller indexes instead of guarding, and a
* mob with nothing to say is empty groups rather than a missing table.
*
* @param {table|nil} res - M.find's result; nil (an unknown mob, or a PC) yields the empty shape.
* @param {table|nil} mob - cfg.mob: the three toggles.
* @return {table} { label, left, right, rows }.
--]]
function M.panel(res, mob, jobname)
    local out = { left = {}, right = {}, rows = {} };
    if (res == nil or mob == nil) then
        return out;
    end

    if (mob.level) then
        out.label = M.level_job(res, jobname);
    end

    -- Neither returns nil past the res check above, so there is nothing to fall back to.
    if (mob.detect) then
        out.left, out.right = M.threat(res), M.senses(res);
    end

    -- nil is the whole of "nothing to say": M.resist never returns an empty list, and assigning
    -- nil leaves rows empty rather than putting a blank row in it.
    if (mob.resist) then
        out.rows[1] = M.resist(res);
    end

    return out;
end

return M;
