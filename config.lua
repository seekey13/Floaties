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
    -- Gates are purely enabling (see M.visible), so all three off means the self/party panels
    -- never draw. All three on: visible in normal play, hidden while dead, zoning or resting.
    -- They do not reach the target panel -- having a target is its own answer to whether it
    -- should draw, so it hangs off show_target alone (see drawPanels).
    show_in_combat     = true,  -- show when a battle target is set (<bt>)
    show_while_engaged = true,  -- show when entity status is Engaged
    show_while_idle    = true,  -- show when entity status is Idle
    show_party         = true,  -- draw panels over party members too, not just self
    show_target        = true,  -- draw a panel over whatever you have targeted, ungated

    -- Vertical world nudge from the nameplate anchor (top of the model), positive = downward,
    -- since the height axis points down. 0 puts the panel's top edge level with the model's head,
    -- i.e. directly under the nameplate. Split self from party so your own panel can sit clear of
    -- the ones over everyone else -- self hangs slightly lower, since its taller bars would
    -- otherwise crowd the plate.
    height_offset        = 0.228,  -- self (party slot 0)
    party_height_offset  = 0.125,  -- everyone else (slots 1..5)
    target_height_offset = 0.125,  -- current target

    -- Distance scaling, on: panels keep their proportion to the nameplate above them instead of
    -- staying a fixed pixel size at every range.
    distance_scale  = true,
    scale_ref       = 6.0,   -- view depth (yalms) at which a panel draws at 1:1

    -- Colors are 0..1 floats; the config window edits them as 0..255, so the ones that came from
    -- it are written as that integer over 255 rather than a rounded decimal that would show up
    -- one off what was picked.
    panel = {
        offset       = 2,           -- padding: panel edge -> bar edge, all sides
        rounding     = 6,
        rounded      = true,        -- corner rounding on/off (magnitude stays in `rounding`)
        -- Black at 100/255: a scrim dark enough to hold the bars off the world behind them
        -- without becoming a solid slab over it. The border is fully transparent -- the panel
        -- reads as its own shape, and `border_visible` is left on for the bar outlines.
        bg           = { r = 0, g = 0, b = 0, a = 100/255 },
        border_color = { r = 0, g = 0, b = 0, a = 0 },
    },

    -- The one thing *not* shared between panel kinds: width, and each bar's height. Target
    -- carries `hp` only -- the only bar an arbitrary entity can fill (see stats.read_entity).
    -- Sized by importance: target widest (it is the thing being read at a glance), then self,
    -- then the five party panels, which are on screen all at once and are mostly glanced at.
    sizes = {
        self   = { width = 200, hp = 18, mp = 10, tp = 16 },
        party  = { width = 150, hp = 14, mp = 7,  tp = 10 },
        target = { width = 300, hp = 20 },
    },

    gap            = 1,      -- vertical gap between the 3 bars
    border_visible = true,   -- shared toggle for panel border + bar borders

    -- Party slot tag ("P1".."P5") in a box left of the bars, inside the panel. The panel keeps its
    -- configured width, so this takes its space out of the bars. Your own panel and target panels
    -- get no tag and reserve no box -- slot 0 needs no telling apart, and an arbitrary entity has
    -- no party slot.
    slot = {
        enabled = true,
        size    = 21,   -- text height in px; the box's width is derived from it (M.slot_box)
    },

    -- Mob reference drawn around the target panel, read out of mobdb's zone data -- see
    -- mobinfo.panel for where each piece lands. Each is independently switchable, and anything
    -- with nothing to say (an unknown mob, a mob that takes every damage type normally) is skipped
    -- rather than drawn blank, so switching one on does not guarantee content. Target panels only:
    -- party members are not mobs.
    mob = {
        level  = true,   -- Lv.14-17 WAR, labelling the HP bar until the mob is damaged
        check  = true,   -- EP/DC/T..., colored by tier, on a row above the panel
        detect = true,   -- aggro/passive + Link flanking left, the senses flanking right
        resist = true,   -- element icon + percentage, on a row under the panel
        -- Row height in px: the text size, and the icons' side. The second piece of text with a
        -- size of its own (see slot.size), but unlike the others it holds at text.min_size instead
        -- of dropping out below it (M.info_row) -- the panel widens to hold whatever the lines come
        -- out as rather than the text shrinking to fit.
        size   = 14,
    },

    bars = {
        rounded      = true,   -- corner rounding on/off for all 3 bars (magnitude is the fixed BAR_ROUNDING constant)
        border_color = { r = 0, g = 0, b = 0, a = 150/255 },   -- shared across hp/mp/tp outlines

        -- Each bar has one color, shared by all three panel kinds; opacity comes from `states`
        -- below, height from `sizes` above. `label` silences that bar's number, height untouched.
        -- Only HP is labelled: its number is the one being read, and MP/TP keep their (shorter)
        -- bars without digits crowding them.
        hp = { color = { r = 1, g = 140/255, b = 140/255 }, label = true },
        mp = { color = { r = 1, g = 1, b = 140/255 }, label = false },
        tp = { color = { r = 141/255, g = 1, b = 1 }, label = false },
    },

    -- Shared fill-alpha per state, applied to whichever bar color is drawing.
    -- `full` = fully filled (HP/MP fill, and a TP segment past its threshold).
    -- `incomplete` = a TP segment still charging toward its threshold.
    -- `empty` = the background track behind any bar's fill.
    states = { full = 1.0, empty = 0.2, incomplete = 0.5 },

    -- Outline alpha 0 skips the outline pass; `bold` is a second fill stamped a pixel right, not
    -- a bold face (the atlas is Ashita's, built before any addon loads). Size is not configured --
    -- it comes from the bar (M.label_size); `min_size` is the floor under which it is dropped.
    -- 12 sits just under the 13px ImGui rasterizes at, so a label that does print is drawn at or
    -- near the atlas size instead of being downsampled into texture -- and a bar too short to
    -- carry a crisp digit goes quiet rather than printing mush. It also gates the slot tag.
    text = {
        color         = { r = 1, g = 1, b = 1, a = 1 },
        outline_color = { r = 0, g = 0, b = 0, a = 1 },
        min_size      = 12,
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
* Horizontal space the slot indicator takes out of a panel's content: the box plus one bar gap
* beside it, so the box sits off the bars by the same distance the bars sit off each other.
*
* @param {boolean} has_slot - whether this panel kind has a slot at all (false for target).
* @return {number} 0 when there is no slot or the indicator is off, so bar_width lands back on
*                  exactly its old value rather than near it.
--]]
function M.slot_width(cfg, has_slot)
    -- has_slot first: callers that never show one (and test fixtures) need no `slot` table.
    if (not has_slot or not cfg.slot.enabled) then
        return 0;
    end
    return M.slot_box(cfg) + cfg.gap;
end

function M.bar_width(cfg, size, has_slot)
    return size.width - 2 * cfg.panel.offset - M.slot_width(cfg, has_slot);
end

-- Clamps on the scale curve. Fixed, not settings: they stop a far panel vanishing and a near one
-- filling the screen, which is not a preference. scale_ref is the knob.
local SCALE_MIN, SCALE_MAX = 0.35, 1.5;

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
    return math.min(math.max(cfg.scale_ref / depth, SCALE_MIN), SCALE_MAX);
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
--]]
function M.info_row(cfg, scale)
    return math.max(cfg.mob.size * (scale or 1), math.min(cfg.mob.size, cfg.text.min_size));
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
