--[[
* NewUI - HP / MP / TP bars drawn in a styled unit-frame panel, tracking
* the player in 3D space.
--]]

addon.name      = 'NewUI';
addon.author    = 'Seekey';
addon.version   = '0.1';
addon.desc      = 'Floating HP/MP/TP bars over the player.';

require('common');

local ffi    = require('ffi');
local d3d    = require('d3d8');
local imgui  = require('imgui');
local stats  = require('stats');
local config = require('config');

local C   = ffi.C;
local dev = d3d.get_device();

----------------------------------------------------------------------------------------------------
-- Visibility gates. Independent checks, each with its own setting:
--
--   show_in_combat     -- has a battle target (<bt>), via SeekBattleActor.
--   show_while_engaged -- entity status says Engaged.
--   show_while_idle    -- entity status says Idle.
--
-- The first two are not the same test. SeekBattleActor keeps returning the last battle actor
-- after you disengage, so it tends to stay true once you have fought anything; status flips back
-- to Idle immediately. Because they disagree, the gates combine as a union, not an intersection
-- -- see config.visible.
----------------------------------------------------------------------------------------------------

-- Battle target (<bt>). Trimmed from Ashita's targets.lua -- only the SeekBattleActor path is
-- needed here, and only to know whether it returns anything. Type names are addon-prefixed so
-- pulling in the full targets.lua later cannot collide with these cdefs.

ffi.cdef[[
    typedef struct {
        uint32_t    GuideNo;
        uint32_t    UniqueNo;
    } NEWUI_CHAR_ID;

    typedef struct {
        uint8_t         padding00[116];
        NEWUI_CHAR_ID   id;
    } NEWUI_XiAtelBuff;

    typedef NEWUI_XiAtelBuff* (__stdcall* NEWUI_SeekBattleActor_f)(void);
]];

local seek_battle_actor = ashita.memory.find('FFXiMain.dll', 0, '66A1????????83EC186685C053565774??0FBFC08B0C85', 0, 0);
local bt_available      = (seek_battle_actor ~= nil and seek_battle_actor ~= 0);

--[[
* Whether the player has a battle target (<bt>).
*
* Fails closed. This used to return true when the signature scan missed, so that a bad scan could
* not hide the panel forever -- but now that the gates are additive (see config.visible), an
* always-true gate means "always visible" instead, which is the worse failure and a silent one.
* A missed scan is reported once at load and by /newui bt.
*
* A non-null actor is not enough on its own: targets.lua's get_bt finishes with
* GetEntity(ent.id.GuideNo), so <bt> is only really set when that index resolves. Index 0 is
* "no entity", which is how a stale actor slips through as a false positive.
*
* @return {boolean}
--]]
local function inCombat()
    if (not bt_available) then
        return false;
    end

    local actor = ffi.cast('NEWUI_SeekBattleActor_f', seek_battle_actor)();
    if (actor == nil) then
        return false;
    end

    return actor.id.GuideNo ~= 0;
end

-- Entity status values: 0 Idle, 1 Engaged, 2/3 Dead, 4 Zoning, 33 Resting. Dead/zoning/resting
-- are none of the gates below, so a panel gated only on idle+engaged hides while resting.
local STATUS_IDLE    = 0;
local STATUS_ENGAGED = 1;

-- Fixed (non-configurable) drawing constant -- not requested as a setting.
local BAR_ROUNDING = 3;

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

-- `alpha`, when given, overrides the color's own stored alpha (bar colors carry no `a`;
-- their opacity always comes from the current fill state instead).
local function packColor(c, alpha)
    return imgui.GetColorU32({ c.r, c.g, c.b, alpha or c.a });
end

--[[
* Draws one bar: empty track, filled portion, and a border outline.
* Fill opacity comes from cfg.states[state].
--]]
local function drawBar(draw_list, left, top, width, height, frac, state, bar_color, cfg, rounding)
    local states = cfg.states;

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(bar_color, states.empty), rounding);

    local fill_w = width * frac;
    if (fill_w > 0) then
        draw_list:AddRectFilled({ left, top }, { left + fill_w, top + height }, packColor(bar_color, states[state]), rounding);
    end

    if (cfg.border_visible) then
        draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.bars.border_color), rounding);
    end
end

local function drawLabel(draw_list, left, top, width, height, value, cfg)
    local label      = ('%d'):fmt(value);
    local tw, th     = imgui.CalcTextSize(label);
    local text_col   = packColor(cfg.text.color);
    draw_list:AddText({ left + (width - tw) / 2, top + (height - th) / 2 }, text_col, label);
end

local function drawPanel(sx, sy, s, bars)
    local cfg    = config.settings;
    local width  = cfg.panel.width;
    local height = config.panel_height(cfg, bars);
    local bw     = config.bar_width(cfg);

    local left     = sx - width / 2;
    local top      = sy;
    local rounding = cfg.panel.rounded and cfg.panel.rounding or 0;

    local draw_list = imgui.GetBackgroundDrawList();

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(cfg.panel.bg), rounding);
    if (cfg.border_visible) then
        draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.panel.border_color), rounding);
    end

    local bar_left     = left + cfg.panel.offset;
    local bar_top      = top + cfg.panel.offset;
    local bar_rounding = cfg.bars.rounded and BAR_ROUNDING or 0;

    for _, key in ipairs(bars) do
        local bar_cfg = cfg.bars[key];
        local h       = bar_cfg.height;

        if (key == 'tp') then
            -- Three separate bars, one per 1000 TP, sharing the row's width.
            -- ponytail: reuses cfg.gap for the horizontal spacing rather than adding a setting.
            local seg_w = (bw - 2 * cfg.gap) / 3;
            for i = 1, 3 do
                local frac = stats.tp_segment(s.tp_raw, i);
                drawBar(draw_list, bar_left + (i - 1) * (seg_w + cfg.gap), bar_top, seg_w, h,
                        frac, (frac >= 1) and 'full' or 'incomplete', bar_cfg.color, cfg, bar_rounding);
            end
        else
            drawBar(draw_list, bar_left, bar_top, bw, h, s[key], 'full', bar_cfg.color, cfg, bar_rounding);
        end

        -- Label stays centered across the whole row, so TP prints over the middle bar.
        drawLabel(draw_list, bar_left, bar_top, bw, h, stats.label(s, key), cfg);

        bar_top = bar_top + h + cfg.gap;
    end
end

--[[
* Draws one party slot's panel over that member's head. Silently skips slots
* that are empty, out of zone (target index 0), or off screen.
--]]
local function drawMember(mm, party, i, view, proj, vp)
    local s = stats.read(party, i);
    if (s == nil) then
        return;
    end

    local index = party:GetMemberTargetIndex(i);
    if (index == 0) then
        return;
    end

    local ent = mm:GetEntity();
    local px  = ent:GetLocalPositionX(index);
    local py  = ent:GetLocalPositionY(index);
    local pz  = ent:GetLocalPositionZ(index) + config.settings.height_offset;

    -- Position struct is stored X, Z, Y - the game's Z is the D3D up-axis.
    local sx, sy, sz = worldToScreen(px, pz, py, view, proj, vp.Width, vp.Height);

    if (sz < 0 or sz > 1 or sx < 0 or sx > vp.Width or sy < 0 or sy > vp.Height) then
        return;
    end

    -- Jobs of party members are only known once they've been seen; an unknown
    -- job reads 0, which bars_for treats as "no MP pool".
    drawPanel(sx, sy, s, config.bars_for(party:GetMemberMainJob(i), party:GetMemberSubJob(i)));
end

local function drawConfigWindow()
    if (not config_open[1]) then return; end

    local cfg = config.settings;

    local function slider(fn, label, obj, key, lo, hi)
        local v = { obj[key] };
        if (fn(label, v, lo, hi)) then
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

    local function colorEdit3(label, c)
        local col = { c.r, c.g, c.b };
        if (imgui.ColorEdit3(label, col)) then
            c.r, c.g, c.b = col[1], col[2], col[3];
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
        checkbox('Show In Combat', cfg, 'show_in_combat');
        checkbox('Show While Engaged', cfg, 'show_while_engaged');
        checkbox('Show While Idle', cfg, 'show_while_idle');
        checkbox('Show Party Members', cfg, 'show_party');
        slider(imgui.SliderInt, 'Panel Width', cfg.panel, 'width', 40, 300);
        slider(imgui.SliderInt, 'Panel Offset', cfg.panel, 'offset', 0, 20);
        slider(imgui.SliderInt, 'Panel Rounding', cfg.panel, 'rounding', 0, 20);
        checkbox('Panel Rounded', cfg.panel, 'rounded');
        colorEdit('Panel Background', cfg.panel.bg);
        colorEdit('Panel Border Color', cfg.panel.border_color);
        slider(imgui.SliderInt, 'Bar Gap', cfg, 'gap', 0, 10);
        checkbox('Border Visible', cfg, 'border_visible');

        imgui.Separator();
        checkbox('Bars Rounded', cfg.bars, 'rounded');
        colorEdit('Bar Border Color', cfg.bars.border_color);
        colorEdit3('HP Color', cfg.bars.hp.color);
        slider(imgui.SliderInt, 'HP Height', cfg.bars.hp, 'height', 4, 40);
        colorEdit3('MP Color', cfg.bars.mp.color);
        slider(imgui.SliderInt, 'MP Height', cfg.bars.mp, 'height', 4, 40);
        colorEdit3('TP Color', cfg.bars.tp.color);
        slider(imgui.SliderInt, 'TP Height', cfg.bars.tp, 'height', 4, 40);

        imgui.Separator();
        slider(imgui.SliderFloat, 'Full Alpha', cfg.states, 'full', 0, 1);
        slider(imgui.SliderFloat, 'Empty Alpha', cfg.states, 'empty', 0, 1);
        slider(imgui.SliderFloat, 'Incomplete Alpha', cfg.states, 'incomplete', 0, 1);

        imgui.Separator();
        colorEdit('Text Color', cfg.text.color);
    end
    imgui.End();
end

ashita.events.register('load', 'newui_load', function ()
    config.load();

    -- FFXiMain.dll is packed on disk and only unpacked in memory, so a signature can only be
    -- confirmed at runtime. Say so loudly rather than letting the gate quietly never match.
    if (not bt_available) then
        print('[NewUI] SeekBattleActor signature not found -- "Show In Combat" will never match. Use "Show While Engaged" instead.');
    end
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

    -- Gated on your own status, not each member's, so the whole set shows/hides together.
    local status = mm:GetEntity():GetStatus(party:GetMemberTargetIndex(0));
    if (not config.visible(config.settings, {
            show_in_combat     = inCombat(),
            show_while_engaged = status == STATUS_ENGAGED,
            show_while_idle    = status == STATUS_IDLE,
        })) then
        return;
    end

    -- Viewport is read per frame; capturing it once breaks on resolution change.
    local _, vp   = dev:GetViewport();
    local _, view = dev:GetTransform(C.D3DTS_VIEW);
    local _, proj = dev:GetTransform(C.D3DTS_PROJECTION);

    -- Slot 0 is self; 1..5 are the rest of the party.
    for i = 0, (config.settings.show_party and 5 or 0) do
        drawMember(mm, party, i, view, proj, vp);
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

    if (sub == 'config') then
        config_open[1] = not config_open[1];
        return;
    end

    -- Prints what the battle-target gate is actually seeing. Run it engaged, then idle:
    -- guide should be non-zero only while engaged. If addr is 0 the signature never resolved,
    -- and if guide stays non-zero after disengaging the pointer is stale on this client --
    -- either way "Show In Combat" is not usable here and "Show While Engaged" is.
    if (sub == 'bt') then
        if (not bt_available) then
            print(('[NewUI] bt: signature not found (scan returned %s)'):fmt(tostring(seek_battle_actor)));
            return;
        end

        local mm     = AshitaCore:GetMemoryManager();
        local actor  = ffi.cast('NEWUI_SeekBattleActor_f', seek_battle_actor)();
        local status = mm:GetEntity():GetStatus(mm:GetParty():GetMemberTargetIndex(0));

        print(('[NewUI] bt: addr=%08X actor=%s guide=%s status=%d -> inCombat=%s'):fmt(
            seek_battle_actor,
            actor ~= nil and 'set' or 'nil',
            actor ~= nil and tostring(actor.id.GuideNo) or '-',
            status,
            tostring(inCombat())));
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
