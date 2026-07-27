--[[
* Persisted NewUI settings + derived layout math.
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
    -- Gates are purely enabling (see M.visible), so all three off means the panel never
    -- draws. Engaged+idle is on by default: visible in normal play, hidden while dead,
    -- zoning or resting.
    show_in_combat     = false, -- show when a battle target is set (<bt>)
    show_while_engaged = true,  -- show when entity status is Engaged
    show_while_idle    = true,  -- show when entity status is Idle
    show_party         = true,  -- draw panels over party members too, not just self
    show_target        = true,  -- draw a panel over whatever you have targeted

    -- Vertical world nudge from the nameplate anchor (top of the model), positive = downward,
    -- since the height axis points down. 0 puts the panel's top edge level with the model's head,
    -- i.e. directly under the nameplate. Split self from party so your own panel can sit clear of
    -- the ones over everyone else.
    height_offset        = 0.0,  -- self (party slot 0)
    party_height_offset  = 0.0,  -- everyone else (slots 1..5)
    target_height_offset = 0.0,  -- current target

    -- Distance scaling. Off by default: on, every panel changes size with range, which is a
    -- large enough visual change that it should be asked for rather than arrive with an update.
    -- See M.panel_scale for the curve and why the reference is a depth rather than a distance.
    distance_scale  = false,
    scale_ref       = 6.0,   -- view depth (yalms) at which a panel draws at 1:1
    scale_min       = 0.35,  -- floor, so a far mob's panel stays a readable smudge
    scale_max       = 1.5,   -- ceiling, so a panel a yalm from the lens does not fill the screen

    panel = {
        offset       = 4,           -- padding: panel edge -> bar edge, all sides
        rounding     = 8,
        rounded      = true,        -- corner rounding on/off (magnitude stays in `rounding`)
        bg           = { r = 0.08, g = 0.12, b = 0.30, a = 0.7 },
        border_color = { r = 0.08, g = 0.12, b = 0.30, a = 0.4 },
    },

    -- Size is the one thing that is *not* shared between the three panel kinds: width, and the
    -- height of each bar in that panel. Everything else above and below (padding, rounding,
    -- colors, alphas, borders, text) stays common, so retinting is still one edit.
    -- Target carries `hp` only -- it is the only bar an arbitrary entity can fill (see stats.read_entity).
    sizes = {
        self   = { width = 100, hp = 16, mp = 16, tp = 16 },
        party  = { width = 100, hp = 16, mp = 16, tp = 16 },
        target = { width = 100, hp = 16 },
    },

    gap            = 2,      -- vertical gap between the 3 bars
    border_visible = true,   -- shared toggle for panel border + bar borders

    bars = {
        rounded      = true,   -- corner rounding on/off for all 3 bars (magnitude is the fixed BAR_ROUNDING constant)
        border_color = { r = 0.08, g = 0.12, b = 0.30, a = 0.2 },   -- shared across hp/mp/tp outlines

        -- Each bar has one color, shared by all three panel kinds; how opaque it draws depends
        -- on `states` below, and how tall on `sizes` above. `label` switches that bar's number
        -- off without touching its height -- a short TP row is usually the one worth silencing.
        hp = { color = { r = 0.95, g = 0.45, b = 0.45 }, label = true },
        mp = { color = { r = 0.95, g = 0.90, b = 0.45 }, label = true },
        tp = { color = { r = 0.55, g = 0.75, b = 0.95 }, label = true },
    },

    -- Shared fill-alpha per state, applied to whichever bar color is drawing.
    -- `full` = fully filled (HP/MP fill, and a TP segment past its threshold).
    -- `incomplete` = a TP segment still charging toward its threshold.
    -- `empty` = the background track behind any bar's fill.
    states = { full = 1.0, empty = 0.2, incomplete = 0.5 },

    -- The label is drawn twice: an outline pass in `outline_color`, then the fill in `color`
    -- (see drawLabel). Outline alpha 0 skips the outline pass entirely.
    --
    -- Its size is not configured -- it comes from the bar (see M.label_size). `min_size` is only
    -- the floor under which the label is dropped instead of drawn.
    --
    -- 9 because ImGui's font is rasterized at 13px and downscaled from there: by 8 the digits
    -- have lost enough pixels to read as texture, and the 1px outline underneath is then wider
    -- than the strokes it is outlining. A 13px bar is the shortest that still prints.
    --
    -- `bold` is a second fill stamped a pixel right of the first, not a bold face: ImGui takes a
    -- font, not a weight, and the atlas is Ashita's, built before any addon loads.
    text = {
        color         = { r = 1, g = 1, b = 1, a = 1 },
        outline_color = { r = 0, g = 0, b = 0, a = 1 },
        min_size      = 9,
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
* Whether the panel should be drawn at all, from the visibility gates.
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

-- Both take the panel kind's own size table (cfg.sizes.self / .party / .target), so the two
-- axes come from the same place and a kind can never be laid out with another's dimensions.
--
-- Both are also linear in every input, which is why distance scaling multiplies their *results*
-- in drawPanel instead of threading a factor through here: scaling the output is identical to
-- scaling the widths, heights, gap and padding, and leaves this math scale-unaware.

function M.bar_width(cfg, size)
    return size.width - 2 * cfg.panel.offset;
end

--[[
* Uniform scale factor for a panel at a given view depth.
*
* The curve is the perspective divide itself: a thing anchored in the world covers ref/depth as
* many pixels at `depth` as it does at `scale_ref`. Using that -- rather than a hand-rolled
* near/far lerp -- is what keeps the panel shrinking in step with the nameplate above it, since
* the plate is subject to the same divide.
*
* `depth` is the w component out of the projection (see worldToScreen), i.e. distance along the
* camera's forward axis, not the euclidean distance to the entity. That is deliberate: it is the
* quantity the perspective divide actually uses, it is already computed, and it does not need the
* camera position read out of memory.
*
* scale_ref defaults to 6, roughly where the third-person camera sits, so your own panel lands
* near 1:1 and everything else scales away from that. A larger reference would peg self at
* scale_max permanently.
*
* @param {number|nil} depth - view depth; nil or <= 0 (behind the lens) yields no scaling.
* @return {number}
--]]
function M.panel_scale(cfg, depth)
    if (not cfg.distance_scale or depth == nil or depth <= 0) then
        return 1;
    end
    return math.min(math.max(cfg.scale_ref / depth, cfg.scale_min), cfg.scale_max);
end

-- Pixels taken off the bar height to get the label's font size. Fixed, not configured: it exists
-- so a full-height digit never touches the bar's own border, which is a look, not a preference.
M.label_inset = 0;

--[[
* Font size for the label drawn inside a bar.
*
* Tied to the bar rather than configured separately, so the text can never be taller than what it
* sits in -- at any configured bar height, and at any distance scale, since `bar_height` is the
* drawn height and already carries the scale.
*
* Floored to a whole pixel. ImGui downscales one 13px atlas glyph to whatever size it is asked
* for, so a size that drifts by fractions every frame -- which is what a distance-scaled panel
* hands it while the camera moves -- resamples the same digit differently each frame and reads as
* the text shimmering. Whole pixels hold it still until the size genuinely changes.
*
* @param {number} bar_height - drawn height of the bar in pixels.
* @return {number|nil} font size, or nil when the bar cannot hold a legible one and the label
*                      should be dropped for that bar.
--]]
function M.label_size(cfg, bar_height)
    local size = math.floor(bar_height - M.label_inset);
    if (size < cfg.text.min_size) then
        return nil;
    end
    return size;
end

-- Sizes over the floor across which the label fades in, in pixels.
M.label_fade_range = 3;

--[[
* Opacity multiplier for a label, so the floor is a fade rather than a cliff.
*
* A hard cutoff blinks: view depth wobbles as the camera moves, so a bar sitting near the floor
* crosses it several times a second and its label pops in and out. Ramping the alpha over the
* first few pixels above the floor makes that crossing continuous -- the label is already
* invisible by the time it is dropped, so there is nothing left to pop.
*
* @param {number} size - font size from M.label_size.
* @return {number} 0 .. 1.
--]]
function M.label_fade(cfg, size)
    local over = size - cfg.text.min_size;
    if (over >= M.label_fade_range) then
        return 1;
    end
    return math.max(over / M.label_fade_range, 0);
end

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
    settings.register('settings', 'newui_settings_update', function (s)
        M.settings = s;
    end);
    return M.settings;
end

function M.save()
    require('settings').save();
end

return M;
