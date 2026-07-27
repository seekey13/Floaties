--[[
* NewUI - HP / MP / TP bars drawn above your character's head in 3D space.
--]]

addon.name      = 'NewUI';
addon.author    = 'Seekey13';
addon.version   = '1.0';
addon.desc      = 'Floating HP/MP/TP bars over the player.';

require('common');

local ffi   = require('ffi');
local d3d   = require('d3d8');
local prims = require('primitives');
local stats = require('stats');

local C     = ffi.C;
local dev   = d3d.get_device();

-- Bar geometry, in pixels.
local BAR_W     = 90;
local BAR_H     = 5;
local BAR_GAP   = 2;

-- Vertical placement in world units. The height axis points DOWN, so negative
-- raises the anchor. Tune in-game with: /newui height <n>
local HEIGHT_OFFSET = -2.4;

local enabled = true;

local bars = T{
    T{ key = 'hp', color = 0xFFE03C3C },    -- red
    T{ key = 'mp', color = 0xFF3C6EE0 },    -- blue
    T{ key = 'tp', color = 0xFFE0D23C },    -- yellow
};

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

local function setVisible(v)
    bars:each(function (b)
        b.bg.visible = v;
        b.fg.visible = v;
    end);
end

ashita.events.register('load', 'newui_load', function ()
    bars:each(function (b)
        -- Background first so the fill primitive draws over it.
        b.bg = prims.new(T{
            visible = false, can_focus = false, locked = true,
            color = 0xB0000000, width = BAR_W, height = BAR_H,
        });
        b.fg = prims.new(T{
            visible = false, can_focus = false, locked = true,
            color = b.color, width = BAR_W, height = BAR_H,
        });
    end);
end);

ashita.events.register('unload', 'newui_unload', function ()
    bars:each(function (b)
        if (b.bg ~= nil) then b.bg:destroy(); b.bg = nil; end
        if (b.fg ~= nil) then b.fg:destroy(); b.fg = nil; end
    end);
end);

ashita.events.register('d3d_present', 'newui_present', function ()
    if (not enabled) then
        return;
    end

    local mm     = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    local party  = mm:GetParty();

    -- Not logged in / zoning: main job reads 0.
    if (player == nil or player:GetMainJob() == 0) then
        return setVisible(false);
    end

    local s = stats.read(party);
    if (s == nil) then
        return setVisible(false);
    end

    local index = party:GetMemberTargetIndex(0);
    if (index == 0) then
        return setVisible(false);
    end

    -- Viewport is read per frame; capturing it once breaks on resolution change.
    local _, vp   = dev:GetViewport();
    local _, view = dev:GetTransform(C.D3DTS_VIEW);
    local _, proj = dev:GetTransform(C.D3DTS_PROJECTION);

    local ent = mm:GetEntity();
    local px  = ent:GetLocalPositionX(index);
    local py  = ent:GetLocalPositionY(index);
    local pz  = ent:GetLocalPositionZ(index) + HEIGHT_OFFSET;

    -- Position struct is stored X, Z, Y - the game's Z is the D3D up-axis.
    local sx, sy, sz = worldToScreen(px, pz, py, view, proj, vp.Width, vp.Height);

    if (sz < 0 or sz > 1 or sx < 0 or sx > vp.Width or sy < 0 or sy > vp.Height) then
        return setVisible(false);
    end

    local left = sx - (BAR_W / 2);
    for i, b in ipairs(bars) do
        local top = sy + ((i - 1) * (BAR_H + BAR_GAP));

        b.bg.position_x = left;
        b.bg.position_y = top;
        b.bg.visible    = true;

        b.fg.position_x = left;
        b.fg.position_y = top;
        b.fg.width      = math.ceil(BAR_W * s[b.key]);
        b.fg.visible    = s[b.key] > 0;
    end
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

    if (sub == 'height' and args[3] ~= nil) then
        HEIGHT_OFFSET = tonumber(args[3]) or HEIGHT_OFFSET;
        print(('[NewUI] height offset: %.2f (negative is up)'):fmt(HEIGHT_OFFSET));
        return;
    end

    enabled = not enabled;
    if (not enabled) then setVisible(false); end
    print(('[NewUI] %s'):fmt(enabled and 'on' or 'off'));
end);
