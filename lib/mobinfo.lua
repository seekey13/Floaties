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
* is Floaties.lua's, so this file still loads under stock lua.
--]]

local M = {};

--[[
* Loads one zone's mob data.
*
* A missing file is the normal case, not an error: mobdb ships ~245 of the game's zones, and it
* may not be installed at all. Both land on nil and the reference lines simply have nothing to
* say -- Floaties must not need mobdb to draw.
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
* The bare level tag for the box left of the bar: just the number(s), no `Lv.` prefix and no job
* -- those live in the HP bar's own label now (see M.panel), which is a different draw with its
* own toggle and its own reason to include or drop the job.
*
* A fixed-level mob carries `Level` instead of a range; most carry the range.
--]]
function M.level_text(res)
    if (res == nil) then return nil; end
    return res.Level and tostring(res.Level)
        or string.format('%d-%d', res.MinLevel or 0, res.MaxLevel or 0);
end

--[[
* /check tiers: the abbreviation drawn, and the color it is drawn in.
*
* Colors are Ashita's `checker` addon's, translated from the chat color indices it prints with
* (checker.lua's `types` table) into the RGB of the name Ashita's chat lib gives each index --
* 67 Grey, 2 LawnGreen, 8 Coral, 68 Salmon, 76 Tomato, 5 Magenta. Same ladder on the panel as in
* the log, so a check you ran and a panel you glanced at cannot disagree.
*
* VT and IT deliberately share Tomato: checker prints both with index 76, and re-tinting one of
* them here would put a color on screen that /check never produces. The abbreviations already tell
* them apart.
*
* No alpha: like the bar colors in config.defaults these carry rgb only, and drawText takes the
* opacity from cfg.text.color so the shared text alpha still governs them.
*
* ponytail: a constant, not seven color pickers in the config window -- these are the game's own
* check colors, not a palette anyone is meant to retint. Promote to config.defaults if asked.
--]]
M.CHECK = {
    TW  = { text = 'TW',  color = { r = 128/255, g = 128/255, b = 128/255 } },   -- 67 Grey
    EP  = { text = 'EP',  color = { r = 124/255, g = 252/255, b = 0       } },   -- 2  LawnGreen
    -- 102 is the one index Ashita's chat.colors does not name. It sits between the yellows and
    -- the purples in that table, and the game draws Decent Challenge as a pale blue, so this is
    -- LightSkyBlue: the closest reading of an index there is no published RGB for.
    DC  = { text = 'DC',  color = { r = 135/255, g = 206/255, b = 250/255 } },   -- 102
    EM  = { text = 'EM',  color = { r = 1,       g = 127/255, b = 80/255  } },   -- 8  Coral
    T   = { text = 'T',   color = { r = 250/255, g = 128/255, b = 114/255 } },   -- 68 Salmon
    VT  = { text = 'VT',  color = { r = 1,       g = 99/255,  b = 71/255  } },   -- 76 Tomato
    IT  = { text = 'IT',  color = { r = 1,       g = 99/255,  b = 71/255  } },   -- 76 Tomato
    -- No abbreviation was ever printed for Impossible to Gauge, so it borrows the game's own way
    -- of saying "you are not being told": the level itself reads ??? on an NM.
    ITG = { text = '???', color = { r = 1,       g = 0,       b = 1       } },   -- 5  Magenta
};

--[[
* The level difference at which a tier boundary sits, for a player at `level`.
*
* The bands widen with level -- Too Weak is 7 levels down at 1 and 20 down at 75 -- because the
* server derives the tier from the experience the kill would award, and the exp curve flattens.
* Interpolating the two published endpoints linearly reproduces that within a level across the
* range, at the cost of one line instead of the whole 75x75 exp table.
*
* ponytail: clamped at 75, the last level the boundaries are documented for. A higher-cap server
* would read every boundary as its level-75 value; extend with the real endpoints if that matters.
*
* @param {number} lo - the boundary's diff at level 1.
* @param {number} hi - its diff at level 75.
--]]
local function bound(lo, hi, level)
    local t = (math.min(math.max(level, 1), 75) - 1) / 74;
    return math.floor(lo + (hi - lo) * t + 0.5);
end

--[[
* Which /check tier a mob of `mob_level` is to a player of `level`.
*
* Ordered from the bottom up, so each test only has to clear the band below it. Even Match is the
* one exact case (a mob of your own level and no other), which is why it is `== 0` rather than a
* band of its own.
*
* @return {string} a key into M.CHECK. Never nil -- every level difference is some tier.
--]]
function M.check_tier(level, mob_level)
    local diff = mob_level - level;

    if (diff < bound(-6, -19, level)) then return 'TW'; end
    if (diff < bound(-2, -7,  level)) then return 'EP'; end
    if (diff < 0)                     then return 'DC'; end
    if (diff == 0)                    then return 'EM'; end
    if (diff <= bound(4, 3, level))   then return 'T';  end
    if (diff <= bound(5, 7, level))   then return 'VT'; end
    return 'IT';
end

--[[
* The check line: how the mob would read to a /check, from mobdb's level range.
*
* mobdb gives a *range* for most mobs, and a range can straddle a boundary -- a Lv.14-17 mob is a
* different fight at each end. Both ends are printed when they differ ("EP-DC"), each in its own
* color, rather than picking one and being wrong about the other half of the spawn. The dash rides
* on the first segment so the pair is two draws, not three.
*
* A notorious monster is ITG regardless of level: /check refuses to gauge an NM, and printing a
* tier mobdb's range implies would be inventing an answer the game withholds.
*
* @param {number|nil} level - the player's main job level. nil or 0 (not logged in yet) yields nil.
* @return {table|nil} segments, or nil when there is nothing to check against.
--]]
function M.check(res, level)
    if (res == nil or level == nil or level <= 0) then
        return nil;
    end

    if (res.Notorious == true) then
        return { M.CHECK.ITG };
    end

    local lo = res.Level or res.MinLevel;
    local hi = res.Level or res.MaxLevel;
    if (lo == nil or hi == nil) then
        return nil;
    end

    local low, high = M.CHECK[M.check_tier(level, lo)], M.CHECK[M.check_tier(level, hi)];
    if (low == high) then
        return { low };
    end

    return { { text = low.text .. '-', color = low.color }, high };
end

--[[
* M.check's (possibly two-segment) result, collapsed into the one string the HP bar label
* prefixes itself with. The dash inside "EP-DC" used to be where the two segments met, drawn in
* two colors on a row above the bar; on the bar label there is one string and one color, so the
* segment texts are concatenated and the *low* tier's color wins -- the same color the dash rode
* on before.
*
* @return {table|nil} { text, color }, or nil when M.check has nothing to say.
--]]
function M.check_text(res, level)
    local segs = M.check(res, level);
    if (segs == nil) then
        return nil;
    end

    local text = segs[1].text;
    if (segs[2] ~= nil) then
        text = text .. segs[2].text;
    end

    return { text = text, color = segs[1].color };
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
*                    14-17
*     <Aggro> <Link>  [== EP-DC Tough Mist Lizard WAR/MNK ==]  <Sight> <Sound> <Scent>
*                      <Fire>+25% <Ice>-50% <Dark>-50%
*
*   label - segments for the HP bar's own label: the check tier, the name, and the job, in that
*           order. The name always shows -- it is the entity's own display name, not mobdb data --
*           while the check tier and job each require both a mobdb entry and their own toggle.
*           Built whenever `mob ~= nil`, since the name alone is worth drawing for a target mobdb
*           has never heard of (an unrecognized mob, or a player). `nil` only when `mob` itself is
*           `nil` -- there is no toggle table to have decided anything from.
*   tag   - the level-range/fixed-level text for the tag box left of the bar (M.level_text), or
*           `nil`. Requires mobdb data, unlike label -- there is no tag to show for a mob with no
*           level.
*   left  - segments flanking the bar on its left: aggro/passive and Link, the pull decision.
*   right - segments flanking it on its right: what it senses you with.
*   rows  - full-width rows hung under the panel. The resistance list, in practice -- that one has
*           no fixed length, so it cannot flank anything without shoving the bar off-center.
*
* left/right/rows are always present, so the caller indexes those three without guarding; label and
* tag are the two pieces that go nil, and only when there is truly nothing to build them from.
*
* @param {table|nil} res - M.find's result; nil (an unknown mob, or a PC) yields no tag, check
*                          prefix, or job suffix -- but still a name-only label.
* @param {table|nil} mob - cfg.mob: the toggles. nil yields the fully empty shape.
* @param {function|nil} jobname - job id -> abbreviation. Omitted, the job is left off.
* @param {number|nil} level - the player's main job level, for the check prefix.
* @param {string|nil} name - the entity's display name, always known (not mobdb data).
* @return {table} { label, tag, left, right, rows }.
--]]
function M.panel(res, mob, jobname, level, name)
    local out = { left = {}, right = {}, rows = {} };
    if (mob == nil) then
        return out;
    end

    local label = {};

    if (mob.check and res ~= nil) then
        local chk = M.check_text(res, level);
        if (chk ~= nil) then
            label[#label + 1] = { text = chk.text .. ' ', color = chk.color };
        end
    end

    if (name ~= nil) then
        label[#label + 1] = { text = name };
    end

    if (mob.level and res ~= nil and res.Job ~= nil and res.Job > 0 and jobname ~= nil) then
        local job = jobname(res.Job) or '?';
        if (res.SubJob ~= nil and res.SubJob > 0) then
            job = job .. '/' .. (jobname(res.SubJob) or '?');
        end
        label[#label + 1] = { text = ' ' .. job };
    end

    out.label = label;
    out.tag   = (mob.level and res ~= nil) and M.level_text(res) or nil;

    if (res == nil) then
        return out;
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
