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
* This is the project's own reference palette, not `/check`'s chat colors: the tier paints the HP
* bar's fill (M.panel's `hp_color`) and nothing else -- the label's prefix is plain text in
* cfg.text.color -- so every tier needs a shade that reads as a distinct threat level at a glance on
* a bar, not just a distinct abbreviation next to other text. The old palette (borrowed from
* Ashita's `checker` addon so a check in the log and a panel could not disagree) deliberately
* painted VT and IT the same color, which was fine for two letters side by side but would have
* painted two different danger levels' worth of bar identically.
*
* IT alone stands for three tiers the reference chart draws separately (IT, IT+, IT++): mobdb's
* level-difference estimate (check_tier) has no condition data at all, so it can never say which of
* the three a given mob is, and IT takes the chart's darkest (most alarming) of the three rather
* than inventing a split the estimate can't support. A captured /check answers this exactly --
* Message Basic's condition byte names High Evasion / High Defense independently of the difficulty
* byte -- so M.panel appends `+`/`++` to *whichever* tier a checked mob names, straight from
* checkinfo's `plus` (see checkinfo.lua); it reuses that tier's one color rather than needing a
* second entry here, since the suffix is text, not a new threat level.
*
* No alpha: like the bar colors in config.defaults these carry rgb only, and the fill takes its
* opacity from cfg.states the same way every other bar color does (see drawBar).
*
* ponytail: a constant, not seven color pickers in the config window -- this is one reference chart,
* not a palette anyone is meant to retint. Promote to config.defaults if asked.
--]]
M.CHECK = {
    TW  = { text = 'TW',  color = { r = 160/255, g = 160/255, b = 160/255 } },
    EP  = { text = 'EP',  color = { r = 145/255, g = 220/255, b = 145/255 } },
    DC  = { text = 'DC',  color = { r = 175/255, g = 200/255, b = 235/255 } },
    EM  = { text = 'EM',  color = { r = 1,       g = 1,       b = 1       } },
    T   = { text = 'T',   color = { r = 245/255, g = 195/255, b = 80/255  } },
    VT  = { text = 'VT',  color = { r = 240/255, g = 165/255, b = 90/255  } },
    IT  = { text = 'IT',  color = { r = 165/255, g = 20/255,  b = 20/255  } },
    -- No abbreviation was ever printed for Impossible to Gauge, so it borrows the game's own way
    -- of saying "you are not being told": the level itself reads ??? on an NM.
    ITG = { text = '???', color = { r = 130/255, g = 70/255,  b = 210/255 } },
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
* The check line: how the mob would read to a /check, from mobdb's level range, collapsed into the
* one string and one color the HP bar label prefixes itself with.
*
* mobdb gives a *range* for most mobs, and a range can straddle a boundary -- a Lv.14-17 mob is a
* different fight at each end. Both ends are printed when they differ ("EP-DC") rather than picking
* one and being wrong about the other half of the spawn; the label draws it as one string in one
* color, so the two tiers are concatenated directly and the *low* tier's color wins there too.
* `color2`, the *high* tier's color, rides along only for that straddling case -- it is nil
* whenever `color` alone is the whole answer -- so the HP bar (M.panel's `hp_color`/`hp_color2`)
* can fill low-to-high as a gradient instead of silently losing the half the label already drops.
*
* A notorious monster is ITG regardless of level: /check refuses to gauge an NM, and printing a
* tier mobdb's range implies would be inventing an answer the game withholds.
*
* @param {number|nil} level - the player's main job level. nil or 0 (not logged in yet) yields nil.
* @return {table|nil} { text, color, color2 }, or nil when there is nothing to check against.
--]]
function M.check_text(res, level)
    if (res == nil or level == nil or level <= 0) then
        return nil;
    end

    if (res.Notorious == true) then
        return { text = M.CHECK.ITG.text, color = M.CHECK.ITG.color };
    end

    local lo = res.Level or res.MinLevel;
    local hi = res.Level or res.MaxLevel;
    if (lo == nil or hi == nil) then
        return nil;
    end

    local low, high = M.CHECK[M.check_tier(level, lo)], M.CHECK[M.check_tier(level, hi)];
    if (low == high) then
        return { text = low.text, color = low.color };
    end

    return { text = low.text .. '-' .. high.text, color = low.color, color2 = high.color };
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
*                            EP-DC Tough Mist Lizard WAR/MNK
*                    14-17
*     <Aggro> <Link>  [==========  71%  ==========]  <Sight> <Sound> <Scent>
*                      <Fire>+25% <Ice>-50% <Dark>-50%
*
*   label - segments for the name line above the frame: the check tier, the name, and the job, in
*           that order. Every segment carries `mob.aggro_color` when mobdb says the mob aggroes, and
*           no color otherwise (the caller's default). The
*           name always shows -- it is the entity's own display name, not mobdb data --
*           while the check tier and job each require their own toggle, and the job needs a mobdb
*           entry (there is nothing else it could come from). Built whenever `mob ~= nil`, since the
*           name alone is worth drawing for a target mobdb has never heard of (an unrecognized mob,
*           or a player). `nil` only when `mob` itself is `nil` -- there is no toggle table to have
*           decided anything from.
*   tag   - the level-range/fixed-level text for the tag box left of the bar, or `nil`. A captured
*           check (`chk`) snaps this to the single level it reported, in place of mobdb's range,
*           whenever it gave a usable one (see `chk` below); otherwise mobdb's M.level_text.
*   hp_color - the check tier's color (M.CHECK[...].color), for the HP bar's own fill -- the only
*           place the tier's color is drawn. The prefix on `label` carries no color of its own and
*           draws in cfg.text.color like the name it sits next to, so the bar says the tier in color
*           and the name line says it in letters. `nil` under the exact conditions the check prefix itself
*           is left off `label` (Show Check off, or neither a captured check nor a mobdb entry with
*           a player level to check against), since there is then nothing to color the bar with
*           either.
*   hp_color2 - the *high* tier's color when a mobdb-estimated range straddles a boundary
*           (M.check_text's `color2`), so the bar can fill low-to-high as a gradient instead of
*           losing the half the label already drops by concatenating "EP-DC" into one string. Always
*           `nil` when `chk` supplied the tier -- one check answers with exactly one tier, never a
*           straddle -- and whenever `hp_color` itself is `nil`.
*   left  - segments flanking the bar on its left: aggro/passive and Link, the pull decision.
*   right - segments flanking it on its right: what it senses you with.
*   rows  - full-width rows hung under the panel. The resistance list, in practice -- that one has
*           no fixed length, so it cannot flank anything without shoving the bar off-center.
*
* left/right/rows are always present, so the caller indexes those three without guarding; label and
* tag are the two pieces that go nil, and only when there is truly nothing to build them from.
*
* @param {table|nil} res - M.find's result; nil (an unknown mob, or a PC) yields no job suffix, and
*                          no tag/check prefix unless `chk` supplies them -- but still a name-only
*                          label.
* @param {table|nil} mob - cfg.mob: the toggles. nil yields the fully empty shape.
* @param {function|nil} jobname - job id -> abbreviation. Omitted, the job is left off.
* @param {number|nil} level - the player's main job level, for the mobdb-estimated check prefix.
* @param {string|nil} name - the entity's display name, always known (not mobdb data).
* @param {table|nil} chk - checkinfo's captured entry for this entity (`{ level, tier, plus, ... }`),
*                          or `nil` when it has never been /checked. More accurate than mobdb's
*                          estimate when present, so it wins for both the check prefix/bar color and
*                          the level tag -- and needs no mobdb entry of its own to do either, since a
*                          check works on any mob whether or not mobdb recognizes it. Its `level`
*                          only wins when `> 0`; the server sends `0` when it declined to give one
*                          (notably an NM's), and mobdb's range is still worth showing then. Its
*                          `plus` (0-2) trails the tier as `+`/`++` for High Evasion/High Defense;
*                          mobdb's own estimate never carries a suffix, having no condition to draw
*                          one from.
* @return {table} { label, tag, left, right, rows }.
--]]
function M.panel(res, mob, jobname, level, name, chk)
    local out = { left = {}, right = {}, rows = {} };
    if (mob == nil) then
        return out;
    end

    local label = {};
    local hp_color, hp_color2 = nil, nil;

    if (mob.check) then
        local tier = chk ~= nil and chk.tier ~= nil and M.CHECK[chk.tier] or nil;
        local text = tier or (res ~= nil and M.check_text(res, level) or nil);
        if (text ~= nil) then
            -- The +/++ suffix only ever comes from a captured check (chk.plus) -- mobdb's
            -- estimate (M.check_text) has no condition data to draw one from at all.
            local plus = (tier ~= nil and chk.plus or 0);
            -- No `color` of its own: the prefix takes whatever the name and job it sits with take
            -- (the caller's default, or the aggro tint stamped over all three below), so the line
            -- reads as one string instead of a tinted word glued to a white one. The tier's color
            -- is not lost -- it paints the whole HP bar underneath (hp_color), which says the same
            -- thing louder than three letters ever did.
            label[#label + 1] = { text = text.text .. string.rep('+', plus) .. ' ' };
            hp_color, hp_color2 = text.color, text.color2;
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

    -- Aggro tint, stamped last so it catches every segment the three branches above added. The
    -- whole line rather than the name segment alone: the tier prefix and job suffix are drawn in
    -- the name's color precisely so the three read as one string, and coloring a third of that
    -- string would undo exactly that.
    --
    -- Needs mobdb -- res.Aggro is the only thing that knows -- so a mob mobdb has never heard of,
    -- and a PC, keep the caller's plain color. Same "no entry, no data" rule the icons follow, not
    -- a special case for this. Not gated on any of the four toggles either: `detect` owns the icon
    -- groups, and this is a tint on a line that draws whatever those are set to.
    if (res ~= nil and res.Aggro and mob.aggro_color ~= nil) then
        for _, seg in ipairs(label) do
            seg.color = mob.aggro_color;
        end
    end

    local tag = nil;
    if (mob.level) then
        if (chk ~= nil and chk.level ~= nil and chk.level > 0) then
            tag = tostring(chk.level);
        elseif (res ~= nil) then
            tag = M.level_text(res);
        end
    end

    out.label     = label;
    out.tag       = tag;
    out.hp_color  = hp_color;
    out.hp_color2 = hp_color2;

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
