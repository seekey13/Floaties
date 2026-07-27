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
    enabled       = true,
    height_offset = 0.3,   -- positive = below feet (axis points down)

    panel = {
        width        = 100,
        offset       = 4,           -- padding: panel edge -> bar edge, all sides
        rounding     = 8,
        rounded      = true,        -- corner rounding on/off (magnitude stays in `rounding`)
        bg           = { r = 0.08, g = 0.12, b = 0.30, a = 0.7 },
        border_color = { r = 0.08, g = 0.12, b = 0.30, a = 0.4 },
    },

    gap            = 2,      -- vertical gap between the 3 bars
    border_visible = true,   -- shared toggle for panel border + bar borders

    bars = {
        rounded      = true,   -- corner rounding on/off for all 3 bars (magnitude is the fixed BAR_ROUNDING constant)
        border_color = { r = 0.08, g = 0.12, b = 0.30, a = 0.2 },   -- shared across hp/mp/tp outlines

        -- Each bar has one color; how opaque it draws depends on `states` below.
        hp = { height = 16, color = { r = 0.95, g = 0.45, b = 0.45 } },
        mp = { height = 16, color = { r = 0.95, g = 0.90, b = 0.45 } },
        tp = { height = 16, color = { r = 0.55, g = 0.75, b = 0.95 } },
    },

    -- Shared fill-alpha per state, applied to whichever bar color is drawing.
    -- `full` = fully filled (HP/MP fill, and a TP segment past its threshold).
    -- `incomplete` = a TP segment still charging toward its threshold.
    -- `empty` = the background track behind any bar's fill.
    states = { full = 1.0, empty = 0.2, incomplete = 0.5 },

    text = { color = { r = 1, g = 1, b = 1, a = 1 } },
};

-- Bars in draw order, top to bottom.
M.bar_order = { 'hp', 'mp', 'tp' };

function M.bar_width(cfg)
    return cfg.panel.width - 2 * cfg.panel.offset;
end

function M.panel_height(cfg)
    local sum = 0;
    for _, key in ipairs(M.bar_order) do
        sum = sum + cfg.bars[key].height;
    end
    return sum + 2 * cfg.gap + 2 * cfg.panel.offset;
end

function M.load()
    local settings = require('settings');
    M.settings = settings.load(M.defaults);
    settings.register('settings', 'newui_settings_update', function (s)
        M.settings = s;
    end);
    return M.settings;
end

function M.save()
    require('settings').save();
end

return M;
