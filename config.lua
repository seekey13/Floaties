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
        width    = 100,
        offset   = 4,           -- padding: panel edge -> bar edge, all sides
        rounding = 8,
        bg       = { r = 0.11, g = 0.10, b = 0.20, a = 1.0 },
    },

    gap = 2,   -- vertical gap between the 3 bars

    bars = {
        hp = { height = 16, full = { r = 0.91, g = 0.59, b = 0.64, a = 1 }, empty = { r = 0.55, g = 0.38, b = 0.42, a = 1 } },
        mp = { height = 16, full = { r = 0.85, g = 0.72, b = 0.60, a = 1 }, empty = { r = 0.55, g = 0.47, b = 0.42, a = 1 } },
        tp = { height = 16, full = { r = 0.60, g = 0.86, b = 0.90, a = 1 }, empty = { r = 0.40, g = 0.55, b = 0.60, a = 1 } },
    },

    border = { visible = true, color = { r = 0.20, g = 0.18, b = 0.30, a = 1 } },
    text   = { color = { r = 1, g = 1, b = 1, a = 1 } },
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
