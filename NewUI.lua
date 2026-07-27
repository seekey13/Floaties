--[[
* NewUI - HP / MP / TP bars drawn in a styled unit-frame panel, tracking
* the player in 3D space.
--]]

addon.name      = 'NewUI';
addon.author    = 'Seekey13';
addon.version   = '2.0';
addon.desc      = 'Floating HP/MP/TP bars over the player.';

require('common');

local ffi    = require('ffi');
local d3d    = require('d3d8');
local stats  = require('stats');
local config = require('config');

local C   = ffi.C;
local dev = d3d.get_device();

-- Fixed (non-configurable) drawing constants -- not requested as settings.
local BAR_ROUNDING     = 3;
local TP_DIVIDER_COLOR = 0xFFFFFFFF;

local config_open = { false };

----------------------------------------------------------------------------------------------------
-- World -> screen projection. Lifted from targetlines/helpers.lua.
----------------------------------------------------------------------------------------------------

local function matMul(m1, m2)
    return ffi.new('D3DXMATRIX', {
        m1._11 * m2._11 + m1._12 * m2._21 + m1._13 * m2._31 + m1._14 * m2._41,
        m1._11 * m2._12 + m1._12 * m2._22 + m1._13 * m2._32 + m1._14 * m2._42,
        m1._11 * m2._13 + m1._12 * m2._23 + m1._13 * m2._33 + m1._14 * m2._43,
        m1._11 * m2._14 + m1._12 * m2._24 + m1._13 * m2._34 + m1._14 * m2._44,

        m1._21 * m2._11 + m1._22 * m2._21 + m1._23 * m2._31 + m1._24 * m2._41,
        m1._21 * m2._12 + m1._22 * m2._22 + m1._23 * m2._32 + m1._24 * m2._42,
        m1._21 * m2._13 + m1._22 * m2._23 + m1._23 * m2._33 + m1._24 * m2._43,
        m1._21 * m2._14 + m1._22 * m2._24 + m1._23 * m2._34 + m1._24 * m2._44,

        m1._31 * m2._11 + m1._32 * m2._21 + m1._33 * m2._31 + m1._34 * m2._41,
        m1._31 * m2._12 + m1._32 * m2._22 + m1._33 * m2._32 + m1._34 * m2._42,
        m1._31 * m2._13 + m1._32 * m2._23 + m1._33 * m2._33 + m1._34 * m2._43,
        m1._31 * m2._14 + m1._32 * m2._24 + m1._33 * m2._34 + m1._34 * m2._44,

        m1._41 * m2._11 + m1._42 * m2._21 + m1._43 * m2._31 + m1._44 * m2._41,
        m1._41 * m2._12 + m1._42 * m2._22 + m1._43 * m2._32 + m1._44 * m2._42,
        m1._41 * m2._13 + m1._42 * m2._23 + m1._43 * m2._33 + m1._44 * m2._43,
        m1._41 * m2._14 + m1._42 * m2._24 + m1._43 * m2._34 + m1._44 * m2._44,
    });
end

local function vec4Xf(v, m)
    return ffi.new('D3DXVECTOR4', {
        m._11 * v.x + m._21 * v.y + m._31 * v.z + m._41 * v.w,
        m._12 * v.x + m._22 * v.y + m._32 * v.z + m._42 * v.w,
        m._13 * v.x + m._23 * v.y + m._33 * v.z + m._43 * v.w,
        m._14 * v.x + m._24 * v.y + m._34 * v.z + m._44 * v.w,
    });
end

--[[
* Projects a world point to screen space.
* @return {number,number,number} x, y, ndcDepth. Depth outside 0..1 means it is not on screen.
--]]
local function worldToScreen(x, y, z, view, proj, w, h)
    local p   = vec4Xf(ffi.new('D3DXVECTOR4', { x, y, z, 1 }), matMul(view, proj));
    if (p.w == 0) then return 0, 0, -1; end

    local rhw = 1 / p.w;
    return math.floor((p.x * rhw + 1) * 0.5 * w),
           math.floor((1 - p.y * rhw) * 0.5 * h),
           p.z * rhw;
end

----------------------------------------------------------------------------------------------------
-- Rendering
----------------------------------------------------------------------------------------------------

local function packColor(c)
    return imgui.GetColorU32({ c.r, c.g, c.b, c.a });
end

--[[
* Draws one bar: empty track, filled segment(s) (TP has 3, hp/mp have 1),
* and a border outline.
--]]
local function drawBar(draw_list, left, top, width, height, cells, bar_cfg, cfg)
    local empty_col = packColor(bar_cfg.empty);
    local full_col  = packColor(bar_cfg.full);

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, empty_col, BAR_ROUNDING);

    for _, cell in ipairs(cells) do
        local fill_w = cell.width * cell.frac;
        if (fill_w > 0) then
            draw_list:AddRectFilled({ cell.x, top }, { cell.x + fill_w, top + height }, full_col, BAR_ROUNDING);
        end
    end

    -- TP-only: thin divider lines at the 1000/2000 boundaries.
    if (#cells > 1) then
        for i = 1, #cells - 1 do
            local x = cells[i + 1].x;
            draw_list:AddLine({ x, top }, { x, top + height }, TP_DIVIDER_COLOR, 1.0);
        end
    end

    if (cfg.border.visible) then
        draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.border.color), BAR_ROUNDING);
    end
end

local function drawLabel(draw_list, left, top, width, height, value, cfg)
    local label      = ('%d'):fmt(value);
    local tw, th     = imgui.CalcTextSize(label);
    local text_col   = packColor(cfg.text.color);
    draw_list:AddText({ left + (width - tw) / 2, top + (height - th) / 2 }, text_col, label);
end

local function drawPanel(sx, sy, s)
    local cfg    = config.settings;
    local width  = cfg.panel.width;
    local height = config.panel_height(cfg);
    local bw     = config.bar_width(cfg);

    local left = sx - width / 2;
    local top  = sy;

    local draw_list = imgui.GetBackgroundDrawList();

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(cfg.panel.bg), cfg.panel.rounding);
    if (cfg.border.visible) then
        draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.border.color), cfg.panel.rounding);
    end

    local bar_left = left + cfg.panel.offset;
    local bar_top  = top + cfg.panel.offset;

    for _, key in ipairs(config.bar_order) do
        local bar_cfg = cfg.bars[key];
        local h       = bar_cfg.height;
        local cells;

        if (key == 'tp') then
            cells = {};
            local seg_w = bw / 3;
            for i = 1, 3 do
                cells[i] = { x = bar_left + (i - 1) * seg_w, width = seg_w, frac = stats.tp_segment(s.tp_raw, i) };
            end
        else
            cells = { { x = bar_left, width = bw, frac = s[key] } };
        end

        drawBar(draw_list, bar_left, bar_top, bw, h, cells, bar_cfg, cfg);
        drawLabel(draw_list, bar_left, bar_top, bw, h, s[key .. '_raw'], cfg);

        bar_top = bar_top + h + cfg.gap;
    end
end

local function drawConfigWindow()
    if (not config_open[1]) then return; end

    local cfg = config.settings;

    local function sliderInt(label, obj, key, lo, hi)
        local v = { obj[key] };
        if (imgui.SliderInt(label, v, lo, hi)) then
            obj[key] = v[1];
            config.save();
        end
    end

    local function colorEdit(label, c)
        local col = { c.r, c.g, c.b, c.a };
        if (imgui.ColorEdit4(label, col)) then
            c.r, c.g, c.b, c.a = col[1], col[2], col[3], col[4];
            config.save();
        end
    end

    local function checkbox(label, obj, key)
        local v = { obj[key] };
        if (imgui.Checkbox(label, v)) then
            obj[key] = v[1];
            config.save();
        end
    end

    if (imgui.Begin('NewUI Config', config_open)) then
        sliderInt('Panel Width', cfg.panel, 'width', 40, 300);
        sliderInt('Panel Offset', cfg.panel, 'offset', 0, 20);
        sliderInt('Panel Rounding', cfg.panel, 'rounding', 0, 20);
        sliderInt('Bar Gap', cfg, 'gap', 0, 10);

        imgui.Separator();
        sliderInt('HP Height', cfg.bars.hp, 'height', 4, 40);
        colorEdit('HP Full', cfg.bars.hp.full);
        colorEdit('HP Empty', cfg.bars.hp.empty);

        imgui.Separator();
        sliderInt('MP Height', cfg.bars.mp, 'height', 4, 40);
        colorEdit('MP Full', cfg.bars.mp.full);
        colorEdit('MP Empty', cfg.bars.mp.empty);

        imgui.Separator();
        sliderInt('TP Height', cfg.bars.tp, 'height', 4, 40);
        colorEdit('TP Full', cfg.bars.tp.full);
        colorEdit('TP Empty', cfg.bars.tp.empty);

        imgui.Separator();
        colorEdit('Panel Background', cfg.panel.bg);
        checkbox('Border Visible', cfg.border, 'visible');
        colorEdit('Border Color', cfg.border.color);
        colorEdit('Text Color', cfg.text.color);
    end
    imgui.End();
end

ashita.events.register('load', 'newui_load', function ()
    config.load();
end);

ashita.events.register('d3d_present', 'newui_present', function ()
    drawConfigWindow();

    if (not config.settings.enabled) then
        return;
    end

    local mm     = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    local party  = mm:GetParty();

    -- Not logged in / zoning: main job reads 0.
    if (player == nil or player:GetMainJob() == 0) then
        return;
    end

    local s = stats.read(party);
    if (s == nil) then
        return;
    end

    local index = party:GetMemberTargetIndex(0);
    if (index == 0) then
        return;
    end

    -- Viewport is read per frame; capturing it once breaks on resolution change.
    local _, vp   = dev:GetViewport();
    local _, view = dev:GetTransform(C.D3DTS_VIEW);
    local _, proj = dev:GetTransform(C.D3DTS_PROJECTION);

    local ent = mm:GetEntity();
    local px  = ent:GetLocalPositionX(index);
    local py  = ent:GetLocalPositionY(index);
    local pz  = ent:GetLocalPositionZ(index) + config.settings.height_offset;

    -- Position struct is stored X, Z, Y - the game's Z is the D3D up-axis.
    local sx, sy, sz = worldToScreen(px, pz, py, view, proj, vp.Width, vp.Height);

    if (sz < 0 or sz > 1 or sx < 0 or sx > vp.Width or sy < 0 or sy > vp.Height) then
        return;
    end

    drawPanel(sx, sy, s);
end);

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

ashita.events.register('command', 'newui_command', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/newui') then
        return;
    end
    e.blocked = true;

    local sub = (args[2] or ''):lower();

    if (sub == 'config') then
        config_open[1] = not config_open[1];
        return;
    end

    if (sub == 'height' and args[3] ~= nil) then
        config.settings.height_offset = tonumber(args[3]) or config.settings.height_offset;
        config.save();
        print(('[NewUI] height offset: %.2f (positive is below feet)'):fmt(config.settings.height_offset));
        return;
    end

    config.settings.enabled = not config.settings.enabled;
    config.save();
    print(('[NewUI] %s'):fmt(config.settings.enabled and 'on' or 'off'));
end);
