--[[
* Persisted Floaties settings + derived layout math.
*
* Derived math (bar_width, panel_height) is kept as pure functions taking a
* plain settings table so it stays testable (see test.lua) and can never
* drift out of sync with the bar heights it's computed from.
*
* `settings`/`imgui` are Ashita-only, so requiring them happens lazily inside
* M.load/M.save rather than at file scope -- this file must still `require`
* cleanly under plain lua for tests.
--]]

local M = {};

M.defaults = {
    enabled            = true,
    -- Whether the config window itself was open at last save, so a reload (or relog) puts it back
    -- the way it was left instead of always starting closed.
    config_visible     = false,
    -- Gates are purely enabling (see M.visible), so all three off means the self/party panels
    -- never draw. All three on: visible in normal play, hidden while dead, zoning or resting.
    -- They do not reach the target panel -- having a target is its own answer to whether it
    -- should draw, so it hangs off show_target alone (see drawPanels).
    show_in_combat     = true,  -- show when a battle target is set (<bt>)
    show_while_engaged = true,  -- show when entity status is Engaged
    show_while_idle    = true,  -- show when entity status is Idle
    show_party         = true,  -- draw panels over party members too, not just self

    -- Pets (avatar / automaton / wyvern / jug pet / luopan / charmed mob) get a party-sized panel
    -- of their own. Split in two because the two halves cost different amounts of screen: your own
    -- pet is one more panel and is the one you actually manage, while a full party of summoners is
    -- six -- both ship on, but the expensive half is the one worth being able to switch off on its
    -- own without losing the pet you are steering. They share the party panel's size and
    -- height offset outright rather than carrying their own: a pet is a party-member-shaped thing,
    -- and a third set of sliders to keep in step with the party's is a setting nobody would want to
    -- have to match up.
    show_pet           = true,   -- your own pet
    show_party_pets    = true,   -- every other party member's pet
    -- Publish our own pet's MP/TP to config/addons/floaties/ and read what the other Floaties
    -- sessions on this PC publish, so a second box's avatar draws the same three bars its own
    -- session does instead of the lone HP percent an entity carries (see lib/petshare.lua). One
    -- switch covers both halves: a session that will not publish has no business reading, and the
    -- exchange is worthless unless both ends are in it.
    share_pet          = true,
    -- Switch the client's own nameplate off over party members 1..5, leaving their panel as the
    -- only thing above their head (see updateNameMask). On by default, the same call the target
    -- panels make below: a panel that draws a member's name already replaced their plate, and
    -- leaving both up is the same name twice. Your own plate is not touched -- that is
    -- `noname`'s job.
    hide_party_names   = true,

    -- Same, for every mob a target or enemy-list panel is actually drawing over: that panel already
    -- prints the mob's name above its frame (with the check tier and job on it), so the client's
    -- plate is the same name twice in the same space. On by default, unlike the party one, because
    -- the duplication it removes is one this addon created -- a mob panel puts a name up there
    -- whether you asked for a second one or not.
    --
    -- Keyed on panels that *drew*, not on what is targeted, so a mob whose panel is off screen,
    -- capped out by enemy_list_max, or switched off entirely keeps the only name it has left.
    hide_target_names  = true,

    -- Text height in px for the name a hidden plate leaves behind (drawn above the panel, see
    -- drawPanel). Its own setting rather than mob.size, which it borrowed at first: they are the
    -- same *kind* of line -- outside the frame, holding at text.min_size instead of shrinking away
    -- -- but one is a nameplate standing in for the client's and the other is reference data under
    -- a target, and sizing the plate to taste should not resize a mob's resist row with it.
    name_size          = 25,

    -- The same, for the name line over a target/enemy-list panel. Its own knob rather than sharing
    -- name_size: a stand-in plate and a target's name line are the same *shape* of line, but the
    -- target one is longer by however much the check tier and job pairing add, and it is the one
    -- you read at a distance you are not standing at -- so it ships larger than the party's
    -- rather than equal to it.
    target_name_size   = 34,
    show_target        = true,  -- draw a panel over whatever you have targeted, ungated
    show_enemy_list    = true,  -- draw a panel over every mob you've personally hit/affected, ungated
    enemy_list_max     = 8,     -- cap on how many enemy-list panels draw in one frame

    -- Vertical world nudge from the nameplate anchor (top of the model), positive = downward,
    -- since the height axis points down. 0 puts the panel's top edge level with the model's head,
    -- i.e. directly under the nameplate. Split self from party so your own panel can sit clear of
    -- the ones over everyone else -- self hangs slightly lower, since your own model is the one
    -- the camera is closest to and its plate is the one with the most room under it.
    height_offset        = 0.15,   -- self (party slot 0)
    party_height_offset  = 0.1,    -- everyone else (slots 1..5)
    target_height_offset = 0.129,  -- current target

    -- Distance scaling, on: panels keep their proportion to the nameplate above them instead of
    -- staying a fixed pixel size at every range.
    distance_scale  = true,
    scale_ref       = 6.0,   -- view depth (yalms) at which a panel draws at 1:1
    -- Ceiling on the growth half of the curve. ref/depth runs away as depth goes to zero, and a
    -- target you are standing on top of projects at a very small depth -- without a cap that is a
    -- panel filling the screen. The floor stays fixed (SCALE_MIN); the ceiling is taste, because
    -- how big is too big depends on the configured panel size it multiplies.
    scale_max       = 1.5,

    -- Colors are 0..1 floats; the config window edits them as 0..255, so the ones that came from
    -- it are written as that integer over 255 rather than a rounded decimal that would show up
    -- one off what was picked.
    panel = {
        offset       = 2,           -- padding: panel edge -> bar edge, all sides
        rounding     = 6,           -- 0 turns rounding off; no separate on/off switch
        -- Black at 125/255: a scrim dark enough to hold the bars off the world behind them
        -- without becoming a solid slab over it, with a black border at 100/255 to keep the
        -- scrim's own edge readable against a bright zone. Borders draw unconditionally, so
        -- alpha alone (not a checkbox) is what hides one -- set it to 0.
        bg           = { r = 0, g = 0, b = 0, a = 125/255 },
        border_color = { r = 0, g = 0, b = 0, a = 100/255 },
    },

    -- The one thing *not* shared between panel kinds: width, and each bar's height. Target
    -- carries `hp` only -- the only bar an arbitrary entity can fill (see stats.read_entity).
    -- Sized by importance: target widest (it is the thing being read at a glance), then self,
    -- then the five party panels, which are on screen all at once and are mostly glanced at.
    sizes = {
        self   = { width = 200, hp = 8, mp = 6, tp = 10 },
        party  = { width = 150, hp = 8, mp = 6, tp = 10 },
        target = { width = 300, hp = 23 },
    },

    gap            = 0,      -- vertical gap between the 3 bars; 0 stacks them flush

    -- Tag box left of the bars, inside the panel: "P1".."P5" for a party member, or a mob's level
    -- (range or fixed) for a target -- see mobinfo.panel's `tag`. The panel keeps its configured
    -- width, so this takes its space out of the bars. Your own panel gets no tag and reserves no
    -- box -- slot 0 needs no telling apart. `enabled` below is the party tag's own switch; a
    -- target panel's tag is gated by `mob.level` instead (see the `mob` block below).
    -- Off by default: the box's width comes out of the bars, and a party panel already sits over
    -- the member it belongs to, so "P3" is telling you what the panel's own position says.
    slot = {
        enabled = false,
        size    = 21,   -- text height in px; the box's width is derived from it (M.slot_box)
    },

    -- Mob reference drawn around the target panel, read out of mobdb's zone data -- see
    -- mobinfo.panel for where each piece lands. Each is independently switchable, and anything
    -- with nothing to say (an unknown mob, a mob that takes every damage type normally) is skipped
    -- rather than drawn blank, so switching one on does not guarantee content. Target panels only:
    -- party members are not mobs.
    mob = {
        -- Off by default, unlike the other three: mobdb's level *range* is an estimate wide enough
        -- ("14-17") to be worth less than the space it takes in the tag box, and `check` below
        -- already puts the relative-difficulty read on the bar. Switch it on to get the exact
        -- level a captured /check reports (see checkinfo.lua).
        level  = false,
        check  = true,   -- EP/DC/T... prefix on the HP bar's own label, colored by the lower tier
        detect = true,   -- aggro/passive + Link flanking left, the senses flanking right
        resist = true,   -- element icon + percentage, on a row under the panel
        -- Row height in px: the text size, and the icons' side. The second piece of text with a
        -- size of its own (see slot.size), but unlike the others it holds at text.min_size instead
        -- of dropping out below it (M.info_row) -- the panel widens to hold whatever the lines come
        -- out as rather than the text shrinking to fit. Ships large (32): these rows are the only
        -- thing on the panel carrying facts nothing else shows, and they are read at the range you
        -- decide whether to pull from, not at the range you are standing at.
        size   = 32,

        -- The name line over an aggressive mob draws in this instead of text.color -- the whole
        -- line, tier and job included, so it still reads as one string rather than a tinted word
        -- glued to a white one (the same call the check prefix makes, see mobinfo.panel).
        --
        -- #FFBABA, a paler take on the HP bar's own red: the line is saying "this one walks over to
        -- you", which is the same warning the bar under it is already colored for -- lifted off the
        -- bar's exact tint because a whole name line at full saturation reads as an error message.
        -- Not gated by `detect` -- that switch owns the icon groups, and this is a tint on a line
        -- that draws either way. Set it to text.color's white to switch it off; there is no
        -- separate toggle for one color.
        aggro_color = { r = 1, g = 186/255, b = 186/255 },
    },

    bars = {
        rounding     = 3,      -- corner rounding for all 3 bars; 0 turns it off, no separate switch
        border_color = { r = 0, g = 0, b = 0, a = 100/255 },   -- shared across hp/mp/tp outlines

        -- Each bar has one color, shared by all three panel kinds; opacity comes from `states`
        -- below, height from `sizes` above. `label` silences that bar's number, height untouched.
        -- All three ship silent: at the heights above, a digit is most of the bar it sits in, and
        -- the fill is already the read -- switch HP's on if you want the number as well.
        hp = { color = { r = 1, g = 140/255, b = 140/255 }, label = false },
        mp = { color = { r = 1, g = 1, b = 140/255 }, label = false },
        tp = { color = { r = 141/255, g = 1, b = 1 }, label = false },
    },

    -- Shared fill-alpha per state, applied to whichever bar color is drawing.
    -- `full` = fully filled (HP/MP fill, and a TP segment past its threshold).
    -- `incomplete` = a TP segment still charging toward its threshold.
    -- `empty` = the background track behind any bar's fill.
    states = { full = 1.0, empty = 0.15, incomplete = 0.5 },

    -- Outline alpha 0 skips the outline pass; `bold` is a second fill stamped a pixel right, not
    -- a bold face (the atlas is Ashita's, built before any addon loads). Size is not configured --
    -- it comes from the bar (M.label_size); `min_size` is the floor under which it is dropped.
    -- It also gates the slot tag, and is the floor the mob rows hold at instead of dropping.
    --
    -- 1 is that floor switched off: nothing this ships with prints a number inside a bar (see
    -- bars.*.label), so a floor tall enough to keep one crisp would only be dropping the slot tag
    -- and clipping the reference rows at range. Raise it back toward 12 -- just under the 13px
    -- ImGui rasterizes its atlas at -- if you switch a bar label on, or the short bars above will
    -- print digits downsampled into mush rather than going quiet.
    text = {
        color         = { r = 1, g = 1, b = 1, a = 1 },
        outline_color = { r = 0, g = 0, b = 0, a = 1 },
        min_size      = 1,
        bold          = true,
    },
};

-- Bars in draw order, top to bottom.
M.bar_order = { 'hp', 'mp', 'tp' };

-- Panel kinds, keying M.settings.sizes. Order is config-window order only.
M.size_order = { 'self', 'party', 'target' };

-- Jobs with an MP pool, by job id: WHM BLM RDM PLD DRK SMN BLU SCH GEO RUN.
M.mp_jobs = {
    [3] = true, [4] = true, [5] = true, [7] = true, [8] = true,
    [15] = true, [16] = true, [20] = true, [21] = true, [22] = true,
};

--[[
* Bars to draw for a job pairing. MP is dropped unless main or sub has MP.
* @return {table} subset of M.bar_order, same order.
--]]
function M.bars_for(main_job, sub_job)
    if (M.mp_jobs[main_job] or M.mp_jobs[sub_job]) then
        return M.bar_order;
    end
    return { 'hp', 'tp' };
end

-- Owner main-job ids whose pet carries an MP pool of its own: SMN (avatar) and PUP (automaton).
-- A wyvern, a jug pet and a luopan read 0 MP forever, so keying off the *owner's* job keeps a
-- permanently empty bar off those panels. Deliberately not a test of the live percent, which would
-- make an avatar's bar vanish the frame it spends its last MP and come back on the next tick.
-- ponytail: a charmed PC or mob (Charm, Bewitchment) is not in here and draws no MP bar; add its
-- owner's job id if that ever matters.
M.pet_mp_jobs = { [15] = true, [18] = true };

--[[
* Bars to draw for your own pet, from the job that summoned it.
*
* Only ever asked about *your* pet: another member's pet publishes nothing but an HP percent, so its
* caller draws the one bar without consulting this.
*
* @param {number} main_job - the owner's main job id.
* @return {table} subset of M.bar_order, same order.
--]]
function M.pet_bars(main_job)
    if (M.pet_mp_jobs[main_job]) then
        return M.bar_order;
    end
    return { 'hp', 'tp' };
end

-- Visibility gates, by setting name. Adding one is a string here plus a checkbox.
M.gates = { 'show_in_combat', 'show_while_engaged', 'show_while_idle' };

--[[
* Whether the self and party panels should be drawn at all, from the visibility
* gates. The target panel is not gated -- see drawPanels in Floaties.lua.
*
* Each gate purely *enables*: the panel shows when at least one enabled gate's
* condition is currently true, and is hidden otherwise. Enabling several is a
* union, not an intersection -- being engaged is enough on its own even while
* the battle-target check disagrees.
*
* No gate enabled therefore means never visible, which is why the defaults ship
* with engaged+idle on. This used to fall back to "always show", so a gate you
* had switched on could not hide anything until you switched a second one on
* too -- the setting looked broken because nothing it did was observable.
*
* @param {table} conditions - current state keyed by the same names as M.gates.
* @return {boolean}
--]]
function M.visible(cfg, conditions)
    for _, gate in ipairs(M.gates) do
        if (cfg[gate] and conditions[gate]) then
            return true;
        end
    end
    return false;
end

-- Both take the panel kind's own size table (cfg.sizes.self / .party / .target), so a kind can
-- never be laid out with another's dimensions. Both are linear in every input, which is why
-- distance scaling multiplies their *results* in drawPanel instead of threading a factor here.

-- Box width per unit of text height. "P1" measures ~1.1-1.25x its own height in both Ashita's
-- font and ImGui's built-in one, so 1.5 leaves room either side at every size -- and the ratio is
-- size-independent, so one constant covers the whole slider range.
-- ponytail: a fixed aspect instead of a second slider; add a width setting if a font overflows it.
local SLOT_ASPECT = 1.5;

-- Width of the slot box itself, without the gap that separates it from the bars.
function M.slot_box(cfg)
    return math.floor(cfg.slot.size * SLOT_ASPECT);
end

--[[
* Horizontal space the tag box takes out of a panel's content: the box plus one bar gap beside
* it, so the box sits off the bars by the same distance the bars sit off each other.
*
* Trusts the caller's decision outright -- whoever built (or withheld) the tag string already
* knows whether this panel has one. Target panels get a tag too now, gated by `cfg.mob.level`
* rather than `cfg.slot.enabled` (see mobinfo.panel's `tag`), so re-deciding off `slot.enabled`
* here would either duplicate that gate or fight it.
*
* @param {boolean} has_tag - whether this panel has a tag box to draw at all.
* @return {number} 0 when there is no tag, so bar_width lands back on exactly its old value
*                  rather than near it.
--]]
function M.slot_width(cfg, has_tag)
    if (not has_tag) then
        return 0;
    end
    return M.slot_box(cfg) + cfg.gap;
end

function M.bar_width(cfg, size, has_tag)
    return size.width - 2 * cfg.panel.offset - M.slot_width(cfg, has_tag);
end

-- Floor on the scale curve. Fixed, not a setting: a panel shrunk past this is an unreadable smudge
-- whatever your panel size is, so there is nothing to prefer. The ceiling is `cfg.scale_max`.
local SCALE_MIN = 0.35;

--[[
* Uniform scale factor for a panel at a given view depth.
*
* The curve is the perspective divide itself -- a world-anchored thing covers ref/depth as many
* pixels at `depth` as at `scale_ref` -- which is what keeps the panel shrinking in step with the
* nameplate above it, since the plate goes through the same divide.
*
* `depth` is the w component out of the projection (see worldToScreen): distance along the
* camera's forward axis, not euclidean distance. It is already computed and needs no camera
* position read out of memory.
*
* @param {number|nil} depth - view depth; nil or <= 0 (behind the lens) yields no scaling.
* @return {number}
--]]
function M.panel_scale(cfg, depth)
    if (not cfg.distance_scale or depth == nil or depth <= 0) then
        return 1;
    end
    -- Ceiling last, so the setting always wins: it is the one of the two a user can point at.
    return math.min(math.max(cfg.scale_ref / depth, SCALE_MIN), cfg.scale_max);
end

--[[
* Font size for the label drawn inside a bar: the bar's own drawn height, so the text can never
* be taller than what it sits in, at any configured height or distance scale.
*
* Floored to a whole pixel. ImGui downscales one 13px atlas glyph to whatever size it is asked
* for, so a size drifting by fractions every frame -- what a distance-scaled panel hands it while
* the camera moves -- resamples the same digit differently each frame and reads as a shimmer.
*
* @param {number} bar_height - drawn height of the bar in pixels.
* @return {number|nil} font size, or nil when the bar cannot hold a legible one and the label
*                      should be dropped for that bar.
--]]
function M.label_size(cfg, bar_height)
    local size = math.floor(bar_height);
    if (size < cfg.text.min_size) then
        return nil;
    end
    return size;
end

--[[
* Drawn height of one mob reference row at a distance scale -- which is also its text size and its
* icons' side.
*
* Unlike a bar label, this does *not* drop out below text.min_size: it holds there instead. A label
* that goes quiet still leaves a bar behind it that reads at any size, while these lines are the
* only thing on the panel carrying facts nothing else shows -- what a mob aggros to is exactly what
* you want at the range where the panel has shrunk, and blanking it there reads as broken data.
*
* The floor never rises above the configured size, so Info Text Size dragged below Min Text Size is
* honoured rather than bumped up to a size nobody asked for.
*
* This is the whole of the reference block's geometry: the lines hang *below* the panel, so nothing
* reserves height for them and there is no info_height to keep in step with this -- drawPanel steps
* one row at a time from the panel's bottom edge.
*
* @param {number|nil} scale - distance scale; nil is 1:1.
* @param {number|nil} size - the row's configured size; nil is mob.size. The party name line above
*                            the panel is the same shape of line with a size of its own, and this
*                            rule -- shrink with the panel, but never past being readable -- is the
*                            reason either of them is outside the frame in the first place, so it
*                            stays in one function rather than being restated per caller.
--]]
function M.info_row(cfg, scale, size)
    size = size or cfg.mob.size;
    return math.max(size * (scale or 1), math.min(size, cfg.text.min_size));
end

-- Bars only -- the reference lines are drawn under the panel, not inside it, and cost it no height.
function M.panel_height(cfg, size, bars)
    bars = bars or M.bar_order;
    local sum = 0;
    for _, key in ipairs(bars) do
        sum = sum + size[key];
    end
    return sum + (#bars - 1) * cfg.gap + 2 * cfg.panel.offset;
end

function M.load()
    local settings = require('settings');
    -- settings.load calls defaults:copy()/:merge(), which live on Ashita's T
    -- metatable. Wrapping here (not at file scope) keeps this file loadable
    -- under plain lua for test.lua. Nested tables need no wrap -- copy/merge
    -- recurse through table_mt directly.
    M.settings = settings.load(T(M.defaults));
    settings.register('settings', 'floaties_settings_update', function (s)
        M.settings = s;
    end);
    return M.settings;
end

function M.save()
    require('settings').save();
end

return M;
