--[[
* NewUI - HP / MP / TP bars drawn in a styled unit-frame panel, tracking
* the player in 3D space.
--]]

addon.name      = 'NewUI';
addon.author    = 'Seekey';
addon.version   = '0.1';
addon.desc      = 'Floating HP/MP/TP bars over the player.';

require('common');

local ffi       = require('ffi');
local d3d       = require('d3d8');
local imgui     = require('imgui');
local stats     = require('stats');
local config    = require('config');
local nameplate = require('nameplate');
local mobinfo   = require('mobinfo');

local C   = ffi.C;
local dev = d3d.get_device();

----------------------------------------------------------------------------------------------------
-- Visibility gates. Independent checks, each with its own setting:
--
--   show_in_combat     -- battle target (<bt>) resolves to a living mob, via SeekBattleActor.
--   show_while_engaged -- entity status says Engaged.
--   show_while_idle    -- entity status says Idle.
--
-- The first two are not the same test: status drops to Idle the moment you disengage, while the
-- battle target stays valid as long as the claimed mob is alive. Because they can disagree, the
-- gates combine as a union, not an intersection -- see config.visible.
----------------------------------------------------------------------------------------------------

-- Battle target (<bt>) comes from Ashita's targets.lua, copied in unmodified at lib/targets.lua
-- (same file Sidekick uses at lib/core/targets.lua). It errors at load if any of its four
-- signature scans miss -- pcall so a miss degrades the in-combat gate instead of killing the
-- whole addon, which is what a bare require would do.
local targets = nil;
do
    local ok, lib = pcall(require, 'lib.targets');
    targets = ok and lib or nil;
end

-- Entity status values: 0 Idle, 1 Engaged, 2/3 Dead, 4 Zoning, 33 Resting. Dead/zoning/resting
-- are none of the gates, so a panel gated only on idle+engaged hides while resting.
local STATUS_IDLE    = 0;
local STATUS_ENGAGED = 1;

--[[
* The battle target (<bt>) entity, or nil.
*
* Thin wrapper over targets.get_bt -- the library's own answer is taken as-is, with no filtering
* on top of it. The pcall is the one thing added, and for the same reason Sidekick's is_combat
* has one: get_bt indexes the entity table with whatever the underlying pointer holds, so a bad
* index throws, and this runs every frame.
*
* @return {userdata|nil}
--]]
local function battleTarget()
    if (targets == nil) then
        return nil;
    end

    local ok, ent = pcall(targets.get_bt);
    return ok and ent or nil;
end

--[[
* Whether a <bt> entity counts as being in combat with something.
*
* get_bt is not a combat test: SeekBattleActor keeps handing back an entity after the fight ends,
* and that entity is not always a mob -- a trust in your own party turns up there, which is what
* made the gate stick on. Sidekick solves the same problem in is_combat with the mob SpawnFlags
* test; the party test on top of it is for trusts and pets, which live in the 0x700 index range
* and carry the mob flag despite being yours.
*
* @param {userdata|nil} ent - The battle target entity.
* @param {userdata} party - The party memory manager.
* @return {boolean}
--]]
local function isEnemy(ent, party)
    if (ent == nil) then
        return false;
    end

    -- Not a mob: PC, NPC, or whatever stale index the pointer held.
    if (bit.band(ent.SpawnFlags, 0x10) == 0) then
        return false;
    end

    -- A corpse is still handed back for a while after the kill.
    if (ent.HPPercent == 0 or ent.Status == 2 or ent.Status == 3) then
        return false;
    end

    -- 0..17 covers party and both alliance parties, so alliance trusts are caught too.
    for i = 0, 17 do
        if (party:GetMemberIsActive(i) == 1 and party:GetMemberServerId(i) == ent.ServerId) then
            return false;
        end
    end

    return true;
end

--[[
* Index of the entity to draw a target panel over, before it is checked for validity.
*
* The cursor read goes through Ashita's own target manager, not lib.targets, so it survives a
* missed signature scan. Only the <bt> fallback carries that dependency.
*
* @param {userdata} mm - the memory manager.
* @param {userdata|nil} bt - the battle target, already resolved by the caller this frame.
* @return {number} target index, or 0 when nothing is targeted.
--]]
local function targetIndex(mm, bt)
    local t = mm:GetTarget();
    if (t == nil) then
        return 0;
    end

    -- A sub-target (the green cursor, e.g. picking a cure recipient) moves the live selection to
    -- slot 1; slot 0 then still holds whatever was targeted before it opened. lib.targets' get_t
    -- resolves <t> the same way.
    local index = t:GetTargetIndex(t:GetIsSubTargetActive());
    if (index ~= 0) then
        return index;
    end

    -- Nothing selected: fall back to what you are fighting, so clearing your target mid-fight
    -- does not blank the panel.
    return bt ~= nil and bt.TargetIndex or 0;
end

----------------------------------------------------------------------------------------------------
-- Gate state. Recomputed once per frame, before anything can return early, so the config window's
-- status line still reads true while the panel itself is hidden -- that line is the whole point
-- when a gate is misbehaving.
--
-- Keys match config.gates so this table can be handed straight to config.visible.
----------------------------------------------------------------------------------------------------

local gate_state = {
    show_in_combat     = false,
    show_while_engaged = false,
    show_while_idle    = false,

    -- Diagnostics, not gates.
    status      = -1,       -- raw entity status, -1 when unknown (not logged in / zoning)
    bt_text     = 'none',   -- battle target name + hp, or why it was rejected
    target_text = 'none',   -- current target name + hp, or why it was rejected
};

-- Entity index the target panel draws over, or 0 for none. Resolved in updateGateState next to the
-- diagnostic string describing it, so the two can never disagree about which entity is meant.
local target_index = 0;

local function updateGateState(mm, player, party)
    if (player == nil or player:GetMainJob() == 0) then
        gate_state.show_in_combat     = false;
        gate_state.show_while_engaged = false;
        gate_state.show_while_idle    = false;
        gate_state.status             = -1;
        gate_state.bt_text            = 'not logged in';
        gate_state.target_text        = 'not logged in';
        target_index                  = 0;
        return;
    end

    local status = mm:GetEntity():GetStatus(party:GetMemberTargetIndex(0));
    local bt     = battleTarget();
    local enemy  = isEnemy(bt, party);

    gate_state.show_in_combat     = enemy;
    gate_state.show_while_engaged = status == STATUS_ENGAGED;
    gate_state.show_while_idle    = status == STATUS_IDLE;
    gate_state.status             = status;

    -- Rejected targets still print, so "gate is off but get_bt has something" is readable rather
    -- than looking identical to "get_bt has nothing".
    gate_state.bt_text = bt == nil and 'none'
        or ('%s hp=%d%% status=%d flags=0x%X%s'):fmt(bt.Name, bt.HPPercent, bt.Status, bt.SpawnFlags,
                                                     enemy and '' or ' REJECTED');

    -- Same treatment for the target panel: a rejected target still prints, so "targeting an NPC"
    -- reads differently from "targeting nothing".
    local ti         = targetIndex(mm, bt);
    local tent       = ti ~= 0 and GetEntity(ti) or nil;
    local targetable = stats.targetable(tent, party);

    target_index = targetable and ti or 0;

    gate_state.target_text = tent == nil and 'none'
        or ('%s hp=%d%% status=%d flags=0x%X%s'):fmt(tent.Name, tent.HPPercent, tent.Status,
                                                     tent.SpawnFlags, targetable and '' or ' REJECTED');
end

----------------------------------------------------------------------------------------------------
-- Mob reference data. mobdb's zone files, loaded straight off disk -- see mobinfo.lua for why that
-- works without mobdb itself being loaded. NewUI never requires mobdb to draw: no file (or no
-- mobdb at all) is nil here, and the target panel just draws no reference lines.
----------------------------------------------------------------------------------------------------

local mob_db   = nil;
local mob_zone = -1;   -- -1 rather than 0, so the first load still fires for a zoneless client

local function loadZone(zone)
    if (zone == mob_zone) then
        return;
    end

    mob_zone = zone;
    mob_db   = zone ~= 0
        and mobinfo.load(('%saddons/mobdb/data/%u.lua'):fmt(AshitaCore:GetInstallPath(), zone))
        or nil;
end

--[[
* mobdb's own icon PNGs, by the name mobinfo puts in a segment.
*
* Loaded on first use rather than by scanning the directory at startup (what mobdb does): the ~20
* icons a target panel can ask for are a fraction of what ships, and a miss has to be handled
* anyway -- mobdb's data and its icons are separate installs, and either can be absent.
*
* The cached entry holds the cdata pointer alongside the integer handle AddImage wants, because
* gc_safe_release ties the texture's lifetime to that pointer: caching the number alone would let
* the collector release the texture out from under a handle still being drawn every frame. `false`
* marks a load that failed, so a missing file is retried never rather than every frame.
*
* The load is pcall'd for the same reason lib.targets is, and the same reason mobdb pcalls its own
* first D3DX call (compatibility.lua): whether `D3DXCreateTextureFromFileA` resolves at all depends
* on the Ashita build, and an unresolved symbol *raises* rather than returning a failed HRESULT.
* Unguarded that throw lands inside d3d_present, which draws the config window before the panels --
* so the window would keep reporting the panel as shown while every panel after the throw was gone.
* Caught, a whole missing D3DX degrades to the text fallback, which is what a missing PNG already
* does.
*
* @return {number|nil} the texture handle, or nil when there is no icon by that name.
--]]
local icon_cache = {};

local function loadIcon(name)
    local out  = ffi.new('IDirect3DTexture8*[1]');
    local path = ('%saddons/mobdb/icons/%s.png'):fmt(AshitaCore:GetInstallPath(), name);

    if (C.D3DXCreateTextureFromFileA(dev, path, out) ~= C.S_OK) then
        return nil;
    end

    local tex = d3d.gc_safe_release(ffi.cast('IDirect3DTexture8*', out[0]));
    return { tex = tex, id = tonumber(ffi.cast('uint32_t', tex)) };
end

local function iconHandle(name)
    if (name == nil) then
        return nil;
    end

    local hit = icon_cache[name];
    if (hit ~= nil) then
        return hit and hit.id or nil;
    end

    local ok, entry = pcall(loadIcon, name);
    icon_cache[name] = (ok and entry) or false;
    return icon_cache[name] and icon_cache[name].id or nil;
end

-- AddImage multiplies the texture by this, so opaque white is "draw the PNG as authored". The icons
-- are already colored per element and per flag, and cfg.text.color has no business retinting them.
local ICON_TINT = 0xFFFFFFFF;

-- Ashita renamed the job resource between versions; mobdb carries the same fallback in its
-- compatibility.lua. Resolved once at load -- the answer cannot change mid-session.
local JOB_RESOURCE = AshitaCore:GetResourceManager():GetString('jobs.names_abbr', 1) == 'WAR'
    and 'jobs.names_abbr' or 'jobs_abbr';

local function jobName(id)
    return AshitaCore:GetResourceManager():GetString(JOB_RESOURCE, id);
end

-- Fixed (non-configurable) drawing constant -- not requested as a setting.
local BAR_ROUNDING = 3;

local config_open = { false };

-- Last error thrown out of the panel drawing, or nil. d3d_present draws the config window *before*
-- the panels, so a throw below it left the window truthfully reporting "Panel: shown" over a screen
-- with no panel on it, and Ashita's own log was the only place the reason existed. Kept here and
-- printed in the window, so the addon says why it drew nothing.
local draw_error = nil;

-- Display names for config.size_order, matching the wording the height-offset sliders already use.
local SIZE_LABELS = { self = 'Self', party = 'Party', target = 'Target' };

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
*
* The fourth return is p.w, the view-space depth the perspective divide is about to happen by --
* distance along the camera's forward axis. It is handed back because it is exactly the quantity
* distance scaling needs (config.panel_scale), and computing it here costs nothing.
*
* @return {number,number,number,number} x, y, ndcDepth, viewDepth. ndcDepth outside 0..1 means it
*         is not on screen.
--]]
local function worldToScreen(x, y, z, view, proj, w, h)
    local p   = vec4Xf(ffi.new('D3DXVECTOR4', { x, y, z, 1 }), matMul(view, proj));
    if (p.w == 0) then return 0, 0, -1, 0; end

    local rhw = 1 / p.w;
    return math.floor((p.x * rhw + 1) * 0.5 * w),
           math.floor((1 - p.y * rhw) * 0.5 * h),
           p.z * rhw,
           p.w;
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

-- Drawn width of `text` at `size` px, bold's extra pixel included. CalcTextSize measures at the UI
-- font, so the metrics need the same ratio the glyphs get. Shared with drawText's own fit check,
-- so a panel widened to hold a line (drawPanel) can never then have that line rejected as too wide.
local function textWidth(text, size, cfg)
    local tw = imgui.CalcTextSize(text);
    return tw * (size / imgui.GetFontSize()) + (cfg.text.bold and 1 or 0);
end

-- Draws `text` centered in the box (left, top, width, height) at `size` px, with the shared
-- outline and bold treatment. `size` nil (config.label_size' answer for a box too short to hold a
-- legible glyph) draws nothing, as does text too big for the box it was given.
local function drawText(draw_list, left, top, width, height, text, size, cfg)
    if (size == nil) then return; end

    local font = imgui.GetFont();
    local base = imgui.GetFontSize();

    -- Bold is the fill stamped a second time a pixel right, thickening every vertical stroke;
    -- ImGui takes a font, not a weight. `bx` is 0 when bold is off, so it drops out of the metrics.
    local bx = cfg.text.bold and 1 or 0;

    local k     = size / base;
    local _, th = imgui.CalcTextSize(text);
    local tw    = textWidth(text, size, cfg);
    th = th * k;

    -- Height is near enough a no-op (the size was derived to fit); width is what catches a 4 digit
    -- value in a narrow panel.
    if (th > height or tw > width) then return; end

    -- Whole pixels, for the same reason the size is floored (config.label_size): a glyph whose
    -- origin lands mid-pixel is filtered differently every frame the panel drifts.
    local x = math.floor(left + (width - tw) / 2);
    local y = math.floor(top + (height - th) / 2);

    -- AddText draws a fill and nothing else, so the outline is the same string stamped in the
    -- outline color one pixel out in each direction, underneath. Four offsets, not eight: at a
    -- single pixel the diagonals are already covered by their two neighbours. The right-hand one
    -- clears the bold stamp too, or bold text would lose its outline down that edge.
    -- ponytail: the offset stays 1px at every text size, and outline alpha 0 is the off switch.
    local outline = cfg.text.outline_color;
    if (outline.a > 0) then
        local col = packColor(outline);
        draw_list:AddText(font, size, { x - 1, y }, col, text);
        draw_list:AddText(font, size, { x + 1 + bx, y }, col, text);
        draw_list:AddText(font, size, { x, y - 1 }, col, text);
        draw_list:AddText(font, size, { x, y + 1 }, col, text);
    end

    local fill = packColor(cfg.text.color);
    draw_list:AddText(font, size, { x, y }, fill, text);
    if (cfg.text.bold) then
        draw_list:AddText(font, size, { x + bx, y }, fill, text);
    end
end

-- `percent` (from stats.label) prints a % sign: a target at "42" reads as 42 HP left, not 42%.
--
-- Sized off `height`, the bar's drawn height, so it tracks the configured height and the distance
-- scale alike. Too short for a legible digit, or too narrow for the value, drops the label -- per
-- bar, so a 4px TP row can go quiet while HP above it still prints.
local function drawLabel(draw_list, left, top, width, height, value, percent, cfg)
    drawText(draw_list, left, top, width, height,
             percent and ('%d%%'):fmt(value) or ('%d'):fmt(value),
             config.label_size(cfg, height), cfg);
end

-- Panels with no reference lines pass this rather than nil, so #lines is always a number.
local NO_LINES = {};

--[[
* Drawn width of one mob reference segment (see mobinfo.lua for the shape).
*
* The icon is square at the text size, not at the row height: the two differ by less than a pixel
* (the size is the row floored) and one number keeps the measurement here and the layout in
* drawInfoLine from ever disagreeing about where the next segment starts.
*
* @param {number} size - font size the line is drawn at, and the icon's side.
--]]
local function segmentWidth(seg, size, cfg)
    -- Each piece measured exactly as drawText will lay it out -- separately, not as one
    -- concatenation. textWidth adds bold's extra pixel per call, so measuring "Fire" .. "+25%" as
    -- one string comes out a pixel short of the two stamps that actually draw, and the panel it
    -- sized would be overflowed by a pixel per fallback segment.
    local width = iconHandle(seg.icon) ~= nil and size
        or (seg.alt ~= nil and textWidth(seg.alt, size, cfg) or 0);

    return width + (seg.text ~= nil and textWidth(seg.text, size, cfg) or 0);
end

local function lineWidth(segments, size, gap, cfg)
    local width = 0;
    for _, seg in ipairs(segments) do
        width = width + segmentWidth(seg, size, cfg);
    end
    return width + math.max(#segments - 1, 0) * gap;
end

--[[
* Draws one reference line centered in (left, width), laid out left to right.
*
* Segments are placed at an explicit x rather than centered individually, so drawText is handed a
* box exactly as wide as the text it holds -- its own centering then collapses to a no-op and the
* outline/bold treatment stays in one place.
*
* @param {number} row - the row's height; the line is centered vertically in it.
--]]
local function drawInfoLine(draw_list, left, top, width, row, segments, size, gap, cfg)
    local x = math.floor(left + (width - lineWidth(segments, size, gap, cfg)) / 2);
    local y = math.floor(top + (row - size) / 2);

    for _, seg in ipairs(segments) do
        local handle = iconHandle(seg.icon);

        if (handle ~= nil) then
            draw_list:AddImage(handle, { x, y }, { x + size, y + size }, { 0, 0 }, { 1, 1 }, ICON_TINT);
            x = x + size;
        elseif (seg.alt ~= nil) then
            local w = textWidth(seg.alt, size, cfg);
            drawText(draw_list, x, top, w, row, seg.alt, size, cfg);
            x = x + w;
        end

        if (seg.text ~= nil) then
            local w = textWidth(seg.text, size, cfg);
            drawText(draw_list, x, top, w, row, seg.text, size, cfg);
            x = x + w;
        end

        x = x + gap;
    end
end

-- `size` is the panel kind's own cfg.sizes entry; everything else about the panel is shared.
-- `scale` multiplies every pixel dimension, padding and rounding included -- a shrunk panel with a
-- full-size border swallows its own bars.
-- `slot` is the party slot index for the tag on the left, or nil for a panel that has none.
-- `lines` is the mob reference text drawn under the bars (mobinfo.lines), empty for most panels.
local function drawPanel(sx, sy, s, bars, size, scale, slot, lines)
    local cfg = config.settings;
    lines     = lines or NO_LINES;

    -- Two terms, not one scaled sum: the reference block stops shrinking at its floor while the
    -- bars above it keep going, so config.info_height applies the scale itself (see info_row).
    local height = config.panel_height(cfg, size, bars) * scale
                 + config.info_height(cfg, #lines, scale);

    -- The slot box comes out of the bars, not out of the panel: `width` is what was configured,
    -- so switching the tag on shifts the bars right and shortens them instead of growing the frame.
    local bw     = config.bar_width(cfg, size, slot ~= nil) * scale;
    local slot_w = config.slot_width(cfg, slot ~= nil) * scale;
    local pad    = cfg.panel.offset * scale;
    local gap    = cfg.gap * scale;

    -- Reference lines are as long as the mob's data makes them, so the panel widens to hold the
    -- longest instead of the text being shrunk to mush or dropped -- a resistance list is the one
    -- thing here that has no natural width. The bars keep the width they were configured with and
    -- stay centered on the anchor, so widening moves nothing that was already there; with no lines
    -- this lands on exactly the old geometry (content = width - 2*pad, so content_left = left+pad).
    --
    -- The row never goes away: it bottoms out at a legible size instead of dropping the way a bar
    -- label does (config.info_row), so there is no nil to guard here. Floored for the font and the
    -- icon side, for the same reason label_size floors -- a size drifting by fractions as the
    -- camera moves resamples the same glyph every frame.
    local row       = config.info_row(cfg, scale);
    local info_size = math.floor(row);
    local content   = bw + slot_w;
    local width     = size.width * scale;

    for _, line in ipairs(lines) do
        -- The spare pixel is not cosmetic: without it the width the line is measured at and
        -- the width it is later fit-checked against differ by a float rounding step, and the
        -- line the panel just grew for gets dropped for being one ULP too wide.
        width = math.max(width, lineWidth(line, info_size, gap, cfg) + 2 * pad + 1);
    end

    local left     = sx - width / 2;
    local top      = sy;
    local rounding = cfg.panel.rounded and cfg.panel.rounding * scale or 0;

    local draw_list = imgui.GetBackgroundDrawList();

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(cfg.panel.bg), rounding);
    if (cfg.border_visible) then
        draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.panel.border_color), rounding);
    end

    local content_left = sx - content / 2;
    local bar_left     = content_left + slot_w;
    local bar_top      = top + pad;
    local bar_rounding = cfg.bars.rounded and BAR_ROUNDING * scale or 0;

    -- The tag spans the bars' height rather than the top bar's, so it reads as one label against
    -- the whole stack -- the reference lines below are not part of that stack and are excluded, or
    -- a mob panel's tag would drift away from the bars it labels. (Target panels have no tag, so
    -- today the two are never combined; excluding them costs nothing and stays right if they are.)
    -- Sized from its own setting (not from a bar), but through the same label_size, so it snaps to
    -- whole pixels and drops out when the distance scale makes it mush.
    if (slot ~= nil and cfg.slot.enabled) then
        drawText(draw_list, content_left, bar_top, config.slot_box(cfg) * scale,
                 height - 2 * pad - config.info_height(cfg, #lines, scale),
                 ('P%d'):fmt(slot), config.label_size(cfg, cfg.slot.size * scale), cfg);
    end

    -- Labels need no scale gate of their own: each is sized from the drawn height of its own bar
    -- and hides itself when that height stops fitting a digit (see drawLabel).
    for _, key in ipairs(bars) do
        local bar_cfg = cfg.bars[key];
        local h       = size[key] * scale;

        if (key == 'tp') then
            -- Three separate bars, one per 1000 TP, sharing the row's width.
            -- ponytail: reuses cfg.gap for the horizontal spacing rather than adding a setting.
            local seg_w = (bw - 2 * gap) / 3;
            for i = 1, 3 do
                local frac = stats.tp_segment(s.tp_raw, i);
                drawBar(draw_list, bar_left + (i - 1) * (seg_w + gap), bar_top, seg_w, h,
                        frac, (frac >= 1) and 'full' or 'incomplete', bar_cfg.color, cfg, bar_rounding);
            end
        else
            drawBar(draw_list, bar_left, bar_top, bw, h, s[key], 'full', bar_cfg.color, cfg, bar_rounding);
        end

        -- Label stays centered across the whole row, so TP prints over the middle bar. Both of
        -- stats.label's returns are bound: inlining the call would drop the % flag.
        if (bar_cfg.label) then
            local value, percent = stats.label(s, key);
            drawLabel(draw_list, bar_left, bar_top, bw, h, value, percent, cfg);
        end

        bar_top = bar_top + h + gap;
    end

    -- Reference lines, centered on the whole panel rather than on the bars: they are what the
    -- panel was widened for, so they get its full width. bar_top is already one gap past the last
    -- bar, which is exactly the separation the block wants. `row` is the unfloored height (the same
    -- one config.info_height reserved), so the floored font size can never fail its own height
    -- check by a fraction, and the block always lands inside the panel it was measured for.
    for _, line in ipairs(lines) do
        drawInfoLine(draw_list, left + pad, bar_top, width - 2 * pad, row, line, info_size, gap, cfg);
        bar_top = bar_top + row + gap;
    end
end

--[[
* Draws one panel over the entity at `index`. Silently skips entities that are out of zone
* (index 0) or off screen.
*
* @param {table} size - the panel kind's cfg.sizes entry (width + per-bar heights).
* @param {number} offset - world height nudge from the nameplate anchor, positive = down.
* @param {number|nil} slot - party slot index for the slot tag; nil for a panel with no slot.
* @param {table|nil} lines - mob reference lines to draw under the bars; nil for none.
--]]
local function drawAt(mm, index, s, bars, size, offset, slot, lines, view, proj, vp)
    if (index == 0) then
        return;
    end

    local ent = mm:GetEntity();
    local px  = ent:GetLocalPositionX(index);
    local py  = ent:GetLocalPositionY(index);

    -- Anchor at the top of the model -- where the game hangs the nameplate -- so the offset from
    -- the plate holds on a mount, a Galka, or mid-jump. Falls back to feet when the skeleton is
    -- unreadable for a frame.
    local top = nameplate.top(ashita.memory, ent:GetActorPointer(index));
    local pz  = (top or ent:GetLocalPositionZ(index)) + offset;

    -- Position struct is stored X, Z, Y - the game's Z is the D3D up-axis.
    local sx, sy, sz, depth = worldToScreen(px, pz, py, view, proj, vp.Width, vp.Height);

    if (sz >= 0 and sz <= 1 and sx >= 0 and sx <= vp.Width and sy >= 0 and sy <= vp.Height) then
        -- Scale comes from the anchor point, so the panel keeps its top edge pinned under the
        -- nameplate and grows or shrinks downward from there.
        drawPanel(sx, sy, s, bars, size, config.panel_scale(config.settings, depth), slot, lines);
    end
end

--[[
* Draws one party slot's panel over that member's head. Silently skips slots that are empty.
--]]
local function drawMember(mm, party, i, view, proj, vp)
    local s = stats.read(party, i);
    if (s == nil) then
        return;
    end

    -- Jobs of party members are only known once they've been seen; an unknown
    -- job reads 0, which bars_for treats as "no MP pool".
    local cfg  = config.settings;
    local mine = i == 0;

    -- No slot tag on your own panel: the panel over your own head is the one you never need told
    -- apart from the others. nil rather than 0, so the box is not reserved either -- your bars keep
    -- the full width instead of sitting beside a blank space. Written out rather than
    -- `mine and nil or i`, which collapses to `i` in lua.
    local slot = nil;
    if (not mine) then
        slot = i;
    end

    -- nil lines: party members are not mobs, so there is nothing to look up for them.
    drawAt(mm, party:GetMemberTargetIndex(i), s,
           config.bars_for(party:GetMemberMainJob(i), party:GetMemberSubJob(i)),
           mine and cfg.sizes.self or cfg.sizes.party,
           mine and cfg.height_offset or cfg.party_height_offset,
           slot, nil, view, proj, vp);
end

-- HP is the only stat the client is told about an arbitrary entity, so the target panel is always
-- this one bar. Hoisted out of the frame loop rather than built per call.
local TARGET_BARS = { 'hp' };

--[[
* Draws a panel over the current target. target_index is already resolved and validated by
* updateGateState, so a rejected or absent target is just 0 here.
--]]
local function drawTarget(mm, view, proj, vp)
    local ent = target_index ~= 0 and GetEntity(target_index) or nil;
    local s   = stats.read_entity(ent);
    if (s == nil) then
        return;
    end

    -- Reference lines are mob data, so they are looked up only for a mob -- a PC target passes the
    -- flag test in stats.targetable but has no entry, and looking one up by their name could only
    -- ever hit a mob that happens to share it.
    local res = nil;
    if (bit.band(ent.SpawnFlags, 0x10) ~= 0) then
        res = mobinfo.find(mob_db, target_index, ent.Name);
    end

    -- nil slot: an arbitrary entity has no party slot, so the panel reserves no box for one.
    drawAt(mm, target_index, s, TARGET_BARS, config.settings.sizes.target,
           config.settings.target_height_offset, nil,
           mobinfo.lines(res, config.settings.mob, jobName), view, proj, vp);
end

-- Every panel for one frame. Split out of d3d_present so the pcall guarding it can take arguments
-- instead of a closure allocated per frame.
local function drawPanels(mm, party, view, proj, vp)
    -- Slot 0 is self; 1..5 are the rest of the party.
    for i = 0, (config.settings.show_party and 5 or 0) do
        drawMember(mm, party, i, view, proj, vp);
    end

    if (config.settings.show_target) then
        drawTarget(mm, view, proj, vp);
    end
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

    -- Live gate state, so a gate that is not firing can be told apart from one that is firing
    -- when it should not. Green = the condition is true right now, red = false.
    local function gateState(label, key)
        local on = gate_state[key];
        imgui.TextColored(on and { 0.4, 1.0, 0.4, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
                          ('%s: %s'):fmt(label, tostring(on)));
    end

    if (imgui.Begin('NewUI Config', config_open)) then
        gateState('In Combat', 'show_in_combat');
        imgui.SameLine();
        gateState('Engaged', 'show_while_engaged');
        imgui.SameLine();
        gateState('Idle', 'show_while_idle');
        imgui.SameLine();
        imgui.Text(('| status=%d'):fmt(gate_state.status));
        imgui.Text(('bt: %s'):fmt(gate_state.bt_text));
        imgui.Text(('target: %s'):fmt(gate_state.target_text));

        -- The decision itself, so a gate that reads false while the panel is plainly on screen
        -- is impossible to miss. Hidden with every gate off is correct, not a bug -- say so.
        --
        -- `enabled` is part of that decision and used to be left out of it: it short-circuits ahead
        -- of the gates in d3d_present, is persisted, and its only switch is the bare `/newui`
        -- command -- so an addon toggled off weeks ago read "Panel: shown" here forever while
        -- drawing nothing, and the one line meant to settle "is this a gate problem?" was the line
        -- lying. Both halves, or the status is worse than no status.
        local shown = cfg.enabled and config.visible(cfg, gate_state);
        imgui.TextColored(shown and { 0.4, 1.0, 0.4, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
                          ('Panel: %s'):fmt(shown and 'shown' or 'hidden'));

        if (not cfg.enabled) then
            imgui.SameLine();
            imgui.Text('-- addon switched off; tick Enabled below, or /newui');
        elseif (not (cfg.show_in_combat or cfg.show_while_engaged or cfg.show_while_idle)) then
            imgui.SameLine();
            imgui.Text('-- no gate enabled, so nothing can enable it');
        end

        -- "Panel: shown" over an empty screen means the draw threw, not that a gate is wrong. The
        -- message is the one thing that could tell them apart, and it used to be the thing that got
        -- swallowed -- see the pcall in d3d_present.
        if (draw_error ~= nil) then
            imgui.TextColored({ 1.0, 0.4, 0.4, 1.0 }, ('draw error: %s'):fmt(draw_error));
        end

        imgui.Separator();

        -- The master switch, the same setting `/newui` flips. It had no widget at all, which is how
        -- it managed to be off and invisible at once -- every other persisted setting is reachable
        -- from this window, and this is the one that stops the addon drawing.
        checkbox('Enabled', cfg, 'enabled');

        checkbox('Show In Combat', cfg, 'show_in_combat');
        checkbox('Show While Engaged', cfg, 'show_while_engaged');
        checkbox('Show While Idle', cfg, 'show_while_idle');
        checkbox('Show Party Members', cfg, 'show_party');
        checkbox('Show Target', cfg, 'show_target');
        slider(imgui.SliderFloat, 'Self Height Offset', cfg, 'height_offset', -4, 4);
        slider(imgui.SliderFloat, 'Party Height Offset', cfg, 'party_height_offset', -4, 4);
        slider(imgui.SliderFloat, 'Target Height Offset', cfg, 'target_height_offset', -4, 4);
        slider(imgui.SliderInt, 'Panel Offset', cfg.panel, 'offset', 0, 20);
        slider(imgui.SliderInt, 'Panel Rounding', cfg.panel, 'rounding', 0, 20);
        checkbox('Panel Rounded', cfg.panel, 'rounded');
        colorEdit('Panel Background', cfg.panel.bg);
        colorEdit('Panel Border Color', cfg.panel.border_color);
        slider(imgui.SliderInt, 'Bar Gap', cfg, 'gap', 0, 10);
        checkbox('Border Visible', cfg, 'border_visible');

        -- Size does nothing while the tag is off, so it only appears with it -- same as the
        -- distance-scale reference below.
        checkbox('Party Slot Indicator', cfg.slot, 'enabled');
        if (cfg.slot.enabled) then
            slider(imgui.SliderInt, 'Slot Text Size', cfg.slot, 'size', 8, 40);
        end

        -- Target panel reference lines. The data line is the diagnostic: "loaded" with every line
        -- ticked and still nothing under the bar means this mob is not in mobdb's file, rather
        -- than mobdb not being installed at all.
        imgui.Separator();
        imgui.Text('Target Info Lines');
        checkbox('Show Level & Job', cfg.mob, 'level');
        checkbox('Show Detection', cfg.mob, 'detect');
        checkbox('Show Weakness/Resist', cfg.mob, 'resist');
        slider(imgui.SliderInt, 'Info Text Size', cfg.mob, 'size', 8, 40);
        imgui.Text(('mob data: zone %d, %s'):fmt(mob_zone, mob_db ~= nil and 'loaded' or 'none'));

        -- Icon state beside the data state, for the other half of "the lines look wrong": data
        -- loaded but every line reading as words means the PNGs (or D3DX itself) are missing, not
        -- that the mob is absent from mobdb. Counted here rather than kept as a running total --
        -- this only walks a table of ~20 entries, and only while the window is open.
        local loaded, missing = 0, 0;
        for _, entry in pairs(icon_cache) do
            if (entry) then loaded = loaded + 1; else missing = missing + 1; end
        end
        imgui.Text(('icons: %d loaded, %d missing'):fmt(loaded, missing));

        -- The reference does nothing while the checkbox is off, so it is only drawn when it is on.
        imgui.Separator();
        checkbox('Scale With Distance', cfg, 'distance_scale');
        if (cfg.distance_scale) then
            slider(imgui.SliderFloat, 'Scale Reference Depth', cfg, 'scale_ref', 1, 30);
        end

        -- Size is per panel kind; a kind only lists the bars it can actually draw, which is why
        -- Target shows an HP height and nothing else.
        imgui.Separator();
        for _, kind in ipairs(config.size_order) do
            local size  = cfg.sizes[kind];
            local title = SIZE_LABELS[kind];
            imgui.Text(('%s Panel'):fmt(title));
            slider(imgui.SliderInt, ('%s Width'):fmt(title), size, 'width', 40, 300);
            for _, key in ipairs(config.bar_order) do
                if (size[key] ~= nil) then
                    slider(imgui.SliderInt, ('%s %s Height'):fmt(title, key:upper()), size, key, 4, 40);
                end
            end
        end

        imgui.Separator();
        checkbox('Bars Rounded', cfg.bars, 'rounded');
        colorEdit('Bar Border Color', cfg.bars.border_color);
        colorEdit3('HP Color', cfg.bars.hp.color);
        colorEdit3('MP Color', cfg.bars.mp.color);
        colorEdit3('TP Color', cfg.bars.tp.color);

        imgui.Separator();
        slider(imgui.SliderFloat, 'Full Alpha', cfg.states, 'full', 0, 1);
        slider(imgui.SliderFloat, 'Empty Alpha', cfg.states, 'empty', 0, 1);
        slider(imgui.SliderFloat, 'Incomplete Alpha', cfg.states, 'incomplete', 0, 1);

        imgui.Separator();
        colorEdit('Text Color', cfg.text.color);
        colorEdit('Text Outline Color', cfg.text.outline_color);
        slider(imgui.SliderInt, 'Min Text Size', cfg.text, 'min_size', 1, 20);
        checkbox('Bold Text', cfg.text, 'bold');

        -- Per bar, so a row can keep its height and lose only its number.
        for _, key in ipairs(config.bar_order) do
            checkbox(('Show %s Text'):fmt(key:upper()), cfg.bars[key], 'label');
        end
    end
    imgui.End();
end

ashita.events.register('load', 'newui_load', function ()
    config.load();

    -- Loading mid-session has no zone packet to wait for.
    loadZone(AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));

    -- FFXiMain.dll is packed on disk and only unpacked in memory, so targets.lua's signatures can
    -- only be confirmed at runtime. Say so loudly rather than letting the gate quietly never match.
    if (targets == nil) then
        print('[NewUI] lib/targets.lua failed to load -- "Show In Combat" will never match. Use "Show While Engaged" instead.');
    end
end);

-- 0x00A is zone-in; the zone id sits at 0x30. Same hook and offset mobdb reloads its own data on.
ashita.events.register('packet_in', 'newui_packet', function (e)
    if (e.id == 0x00A) then
        loadZone(struct.unpack('H', e.data, 0x30 + 1));
    end
end);

ashita.events.register('d3d_present', 'newui_present', function ()
    local mm     = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    local party  = mm:GetParty();

    -- Before every early return below, so the config window's status line keeps updating while
    -- the addon is disabled or the panel is gated off.
    updateGateState(mm, player, party);

    drawConfigWindow();

    if (not config.settings.enabled) then
        return;
    end

    -- Not logged in / zoning: main job reads 0.
    if (player == nil or player:GetMainJob() == 0) then
        return;
    end

    -- Gated on your own status, not each member's, so the whole set shows/hides together.
    if (not config.visible(config.settings, gate_state)) then
        return;
    end

    -- Viewport is read per frame; capturing it once breaks on resolution change.
    local _, vp   = dev:GetViewport();
    local _, view = dev:GetTransform(C.D3DTS_VIEW);
    local _, proj = dev:GetTransform(C.D3DTS_PROJECTION);

    -- Trapped rather than left to propagate: an uncaught throw here takes every panel after it with
    -- it and reports nothing, because the config window has already drawn for this frame. The
    -- message goes to `draw_error`, which that window prints. Named function, not a closure, so the
    -- guard does not allocate once a frame.
    local ok, err = pcall(drawPanels, mm, party, view, proj, vp);
    draw_error = (not ok) and tostring(err) or nil;
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

    -- One-shot print of the same state the config window's status line shows, for when you would
    -- rather watch the log across a fight than keep the window open.
    if (sub == 'bt') then
        print(('[NewUI] in_combat=%s engaged=%s idle=%s status=%d bt=%s target=%s'):fmt(
            tostring(gate_state.show_in_combat),
            tostring(gate_state.show_while_engaged),
            tostring(gate_state.show_while_idle),
            gate_state.status,
            gate_state.bt_text,
            gate_state.target_text));
        return;
    end

    if (sub == 'height' and args[3] ~= nil) then
        config.settings.height_offset = tonumber(args[3]) or config.settings.height_offset;
        config.save();
        print(('[NewUI] self height offset: %.2f (from the nameplate anchor, positive is down)'):fmt(config.settings.height_offset));
        return;
    end

    config.settings.enabled = not config.settings.enabled;
    config.save();
    print(('[NewUI] %s'):fmt(config.settings.enabled and 'on' or 'off'));
end);
