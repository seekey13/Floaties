--[[
* Floaties - HP / MP / TP bars drawn in a styled unit-frame panel, tracking
* the player in 3D space.
--]]

addon.name      = 'Floaties';
addon.author    = 'Seekey';
addon.version   = '0.1';
addon.desc      = 'Floating HP/MP/TP bars over the player.';

require('common');

local ffi       = require('ffi');
local d3d       = require('d3d8');
local imgui     = require('imgui');
local stats     = require('lib.stats');
local config    = require('lib.config');
local nameplate = require('lib.nameplate');
local mobinfo   = require('lib.mobinfo');
local checkinfo = require('lib.checkinfo');
local enemylist = require('lib.enemylist');
local petshare  = require('lib.petshare');

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

    -- Opportunistic cleanup: this is already the one entity read every frame, so a checked mob
    -- dying while targeted is caught here for free. One that dies off-target lingers until the
    -- list is cleared at zone.
    checkinfo.prune(check_list, tent);

    target_index = targetable and ti or 0;

    gate_state.target_text = tent == nil and 'none'
        or ('%s hp=%d%% status=%d flags=0x%X%s'):fmt(tent.Name, tent.HPPercent, tent.Status,
                                                     tent.SpawnFlags, targetable and '' or ' REJECTED');
end

----------------------------------------------------------------------------------------------------
-- Mob reference data. mobdb's zone files, loaded straight off disk -- see mobinfo.lua for why that
-- works without mobdb itself being loaded. Floaties never requires mobdb to draw: no file (or no
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

----------------------------------------------------------------------------------------------------
-- /check capture. What the last /check said about an entity, keyed by its server id, so a
-- re-target does not need a re-check -- see checkinfo.lua. drawTarget hands this target's entry (if
-- any) into mobinfo.panel, which prefers it over the mobdb-derived estimate.
----------------------------------------------------------------------------------------------------

local check_list = {};

----------------------------------------------------------------------------------------------------
-- Enemy list. Every mob you (or your pet/avatar/automaton) have personally hit or affected, keyed by server
-- id -- see lib/enemylist.lua. Populated off the Action packet (0x0028) in the packet_in handler
-- below; drawClaimed (Task 4) reads it every frame.
----------------------------------------------------------------------------------------------------

local claimed_list = {};

----------------------------------------------------------------------------------------------------
-- Nameplate hiding. The client's own name over a head duplicates what that head's panel already
-- says, and sits in exactly the space the panel wants -- so this switches the plate off per
-- entity, leaving the panel as the only thing over them. Two independent sources feed it: party
-- members/pets (hide_party_names) and whichever mobs a target/enemy-list panel actually drew
-- (hide_target_names, fed by named_mobs).
--
-- Bit 0x08 of an entity's Render.Flags2 is the client's own "name hidden" mask -- the same one
-- Ashita's `noname` addon sets on the local player (addons/noname/noname.lua). It is per entity,
-- so it reaches any index, and it is what the game itself toggles, so nothing here is drawing or
-- suppressing a plate on its own.
--
-- Your own entity is never masked from here, by either source: that plate is `noname`'s to own,
-- and clearing the bit back off it when you untarget yourself would undo *its* hiding. Two addons
-- fighting over one flag on one entity is the failure, not the plate.
----------------------------------------------------------------------------------------------------

local NAME_MASK = 0x08;

-- Setting the bit once a frame is not enough on its own: the client's own entity update clears it
-- back out, and the plate renders in the gap between that clear and the next d3d_present write --
-- one frame of name, every time an entity update packet (0x00D/0x00E) lands on a masked member.
-- That is the flash.
--
-- The instruction doing it is `and ecx, 0FFFFFFF7h` / `mov [eax+128h], ecx` -- +0x128 is
-- Render.Flags2 (Ashita's own entity_t: VTable, movement, ..., Render at +0x120), and 0xF7 is
-- ~0x08. Patching the immediate to 0xF8 leaves bit 0x08 alone, so the client stops fighting the
-- mask instead of us out-writing it. The per-frame write above still has to happen -- the flags are
-- rebuilt wholesale on spawn and zone, which no patch to this one instruction covers.
--
-- Byte-identical to what `noname` writes, deliberately: the two addons patch the same byte, so
-- writing the same value means whichever loads second is a no-op rather than a conflict.
--
-- ponytail: it also clears bits 0-2, which the original did not (0xF8 is ~0x07). `and ecx, -1`
-- (0xFF) would preserve the mask without that side effect, but this is the byte `noname` has
-- shipped for years across every entity in the game, so the tested value wins over the tidier one.
local NAME_PATCH_SIG = '83E1F789882801000033C0668B4608';

local name_patch_ptr = nil;     -- nil = not scanned yet, 0 = scanned and missed (never rescanned)
local name_patched   = false;   -- whether *this* addon wrote the patch, so it only restores its own
local name_patch_on  = false;   -- last requested state, so the patch is touched on change only

--[[
* Applies or restores the one-byte patch that stops the client clearing the name mask.
*
* Called on change only (see updateNameMask), not per frame: it is a code patch, so with the
* setting off the client is left completely untouched rather than carrying a patch for a feature
* nobody switched on.
*
* @param {boolean} on - true to patch, false to restore.
--]]
local function patchNameClear(on)
    if (not on) then
        -- Restores only what this addon wrote. If `noname` owns the byte instead, handing it back
        -- to 0xF7 here would break *its* hiding on our unload -- so ownership, not the byte's
        -- current value, decides.
        if (name_patched) then
            ashita.memory.write_uint8(name_patch_ptr + 0x02, 0xF7);
            name_patched = false;
        end
        return;
    end

    if (name_patch_ptr == nil) then
        -- FFXiMain.dll is packed on disk, so this can only be confirmed at runtime -- same reason
        -- lib/targets.lua's scans are. A miss degrades to the old one-frame flash, so say so once
        -- rather than failing the whole feature.
        name_patch_ptr = ashita.memory.find('FFXiMain.dll', 0, NAME_PATCH_SIG, 0, 0);
        if (name_patch_ptr == 0) then
            print('[Floaties] name-mask signature not found -- hidden party nameplates will flash back on entity updates.');
        end
    end

    -- Already 0xF8 means `noname` got here first: take the benefit and claim no ownership, so its
    -- patch survives our unload.
    if (name_patch_ptr ~= 0 and ashita.memory.read_uint8(name_patch_ptr + 0x02) == 0xF7) then
        ashita.memory.write_uint8(name_patch_ptr + 0x02, 0xF8);
        name_patched = true;
    end
end

-- Target indices the mask is currently set on, so it can be cleared back off the exact entities it
-- was set on. Not derivable from the party at clear time -- the member who *left* is precisely the
-- one no longer in it.
local masked = {};

-- Target indices a mob panel drew a name over last frame, filled by drawMobPanel and drained by
-- updateNameMask. A record of what *drew* rather than a re-derivation of what is targeted or
-- claimed: the panel already answers every question the mask needs answered -- gates, Show
-- switches, enemy_list_max, off-screen, a target that failed to resolve -- and re-deciding all of
-- that here is a second copy of that logic to keep in step with the first.
--
-- The cost is one frame of lag each way: a plate you just targeted survives the frame its panel
-- first drew, and stays hidden for the frame after the panel stops. At 30+ fps that is under the
-- flash the FFXiMain patch exists to remove, and both ends self-correct.
local named_mobs = {};

--[[
* Sets or clears the name mask on one entity.
*
* @param {number} index - target index; 0 (empty slot) is a no-op.
* @param {boolean} on - true to hide the name, false to restore it.
* @return {boolean} whether the entity was there to write to.
--]]
local function setNameMask(index, on)
    local ent = index ~= 0 and GetEntity(index) or nil;
    if (ent == nil or ent.ActorPointer == 0) then
        return false;
    end

    local flags = ent.Render.Flags2;
    ent.Render.Flags2 = on and bit.bor(flags, NAME_MASK) or bit.band(flags, bit.bnot(NAME_MASK));
    return true;
end

--[[
* Brings the set of masked nameplates in line with the setting, once a frame.
*
* Re-set every frame rather than once on party change: the client rebuilds an entity's render flags
* on its own updates (which is the whole reason `noname` patches FFXiMain to stop it -- see its
* load handler), so a one-shot write survives only until the next update and the plate flickers
* back. Writing the same bit that is already set costs one compare.
*
* Cleared explicitly rather than left to that same rebuild: "the client will drop it eventually" is
* not something to hand the user as an off switch, and it would leave a member's name gone for
* however long the next update takes.
*
* Called before every early return in d3d_present, so switching the addon off (or the setting off)
* gives names back on the spot instead of only once panels are drawing again.
--]]
local function updateNameMask(mm, party)
    local cfg   = config.settings;
    local party_names = cfg.enabled and cfg.hide_party_names;
    local mob_names   = cfg.enabled and cfg.hide_target_names;

    -- One patch serves both sources -- it stops the client clearing the bit, and neither source
    -- cares which one asked for that.
    local want = party_names or mob_names;
    local now  = {};

    -- On change only: patching is not idempotent bookkeeping, it is a write into the client's code.
    if (want ~= name_patch_on) then
        name_patch_on = want;
        patchNameClear(want);
    end

    -- Drained whether or not the setting is on, so switching it off mid-fight cannot leave a stale
    -- frame's worth of indices to mask on the next one.
    local drew = named_mobs;
    named_mobs = {};

    if (party_names) then
        local em = mm:GetEntity();

        for i = 0, 5 do
            if (party:GetMemberIsActive(i) == 1) then
                local index = party:GetMemberTargetIndex(i);

                -- Slot 0 starts at 1 for the member's own plate: your name is `noname`'s to hide,
                -- not ours. Your *pet* is not you, though -- nothing else is hiding its plate, and
                -- "hide the party's nameplates" plainly includes the thing standing next to you --
                -- so the loop runs from 0 and only the member half of slot 0 is skipped.
                if (i ~= 0 and index ~= 0) then
                    now[index] = true;
                end

                -- Pets are masked whether or not their panel is drawing, for the same reason the
                -- members' are: this setting is independent of the Show switches (see below), and
                -- tying it to them would un-hide a plate the moment panels were switched off.
                local pet = index ~= 0 and em:GetPetTargetIndex(index) or 0;
                if (pet ~= 0) then
                    now[pet] = true;
                end
            end
        end
    end

    if (mob_names) then
        -- Your own index is skipped here for the same reason slot 0's member is above: targeting
        -- yourself draws a panel like anything else, but that plate belongs to `noname`.
        local me = party:GetMemberTargetIndex(0);
        for index in pairs(drew) do
            if (index ~= me) then
                now[index] = true;
            end
        end
    end

    -- Unmask first, so a member leaving and the index being reused within the same frame cannot
    -- clear the bit right back off the entity the second pass just set it on.
    for index in pairs(masked) do
        if (not now[index]) then
            -- Dropped either way: a member who zoned out leaves an unreadable entity behind, and
            -- retrying that write every frame forever would never succeed anyway. The mask goes
            -- with the entity.
            setNameMask(index, false);
            masked[index] = nil;
        end
    end

    for index in pairs(now) do
        if (setNameMask(index, true)) then
            masked[index] = true;
        end
    end
end

--[[
* Every server id currently "yours": slot 0 (you) unconditionally, plus your pet/avatar/automaton,
* which has no party slot of its own and is only reachable through your own entity's
* PetTargetIndex. Trusts are deliberately not special-cased: a trust only ever acts against
* something you are already acting against, so your own hit already covers whatever a trust's hit
* would have added -- checking trusts separately would be tracking a strict subset of what your own
* actions already produce.
*
* @param {userdata} party - the party memory manager.
* @return {table} set of server ids currently yours, keyed by id, valued true.
--]]
local function mineIds(party)
    local ids = {};

    if (party:GetMemberIsActive(0) == 1) then
        ids[party:GetMemberServerId(0)] = true;
    end

    local self_ent = GetEntity(party:GetMemberTargetIndex(0));
    if (self_ent ~= nil and self_ent.PetTargetIndex ~= 0) then
        local pet = GetEntity(self_ent.PetTargetIndex);
        if (pet ~= nil) then
            ids[pet.ServerId] = true;
        end
    end

    return ids;
end

--[[
* Minimal decode of an Action packet (0x0028): just enough to know who acted and which server ids
* they targeted. Bit-packed, not byte-aligned like /check's 0x0029, so it needs
* ashita.bits.unpack_be rather than struct.unpack -- the same primitive HXUI's ParseActionPacket
* (Ashita/addons/HXUI/helpers.lua) and Sidekick both already use for this exact packet.
*
* Every field between the actor id and the target list (the reserved bits, Type, Param/
* SpellGroup, Recast) and every field inside each target's own actions (Reaction, Animation,
* SpecialEffect, Knockback, Param, Message, Flags, and the optional additional-effect and
* spikes-effect blocks) is still read here even though none of their values are kept: 0x0028 is
* packed bit by bit, so there is no way to skip a field without decoding its width first. This
* project only wants "who acted" and "who they targeted" -- no Reaction filtering, since an
* attempted action counts whether or not it landed -- so those decoded values are discarded on
* purpose.
*
* @param {table} e - the packet_in event (needs e.data_raw and e.size).
* @return {number, table} the actor's server id, and an array of target server ids.
--]]
local function parseAction(e)
    local bit_offset = 40; -- header
    local max_bits    = e.size * 8;

    local function bits(n)
        if (bit_offset + n > max_bits) then
            max_bits = 0; -- malformed; every further read returns 0
            return 0;
        end
        local v = ashita.bits.unpack_be(e.data_raw, 0, bit_offset, n);
        bit_offset = bit_offset + n;
        return v;
    end

    local actor_id     = bits(32);
    local target_count = bits(6);
    bits(4); -- reserved
    local atype = bits(4);
    if (atype == 8 or atype == 9) then
        bits(16); bits(16); -- Param, SpellGroup
    else
        bits(32); -- Param
    end
    bits(32); -- Recast

    local targets = {};
    for _ = 1, target_count do
        local tid = bits(32); -- target server id
        if (max_bits == 0) then
            break; -- packet ran out mid-read; nothing after this point is real data
        end
        targets[#targets + 1] = tid;
        for _ = 1, bits(4) do -- action count
            bits(5); bits(12); bits(7); bits(3); bits(17); bits(10); bits(31); -- reaction..flags
            if (bits(1) == 1) then
                bits(10); bits(17); bits(10); -- additional effect
            end
            if (bits(1) == 1) then
                bits(10); bits(14); bits(10); -- spikes effect (Damage, Param, Message) -- narrower Param than the additional-effect block above (14 bits, not 17)
            end
        end
    end

    return actor_id, targets;
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
    entry = (ok and entry) or false;
    icon_cache[name] = entry;
    return entry and entry.id or nil;
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

local config_open = { false };

-- Sets the window's open state and persists it, so both the command toggle and ImGui's own close
-- button (X) leave config_visible agreeing with what is actually on screen across a reload.
local function setConfigOpen(open)
    config_open[1] = open;
    config.settings.config_visible = open;
    config.save();
end

-- Last error thrown out of the panel drawing, or nil. d3d_present draws the config window *before*
-- the panels, so a throw below it left the window truthfully reporting "Panel: shown" over a screen
-- with no panel on it, and Ashita's own log was the only place the reason existed. Kept here and
-- printed in the window, so the addon says why it drew nothing.
local draw_error = nil;

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

-- The color a straddling check tier's gradient shows at horizontal fraction `t` (0 = `a`, the low
-- tier; 1 = `b`, the high tier). Needed so the filled portion's right edge lines up with whatever
-- the full-width track already shows there (see drawBar) -- AddRectFilledMultiColor only
-- interpolates between the two stops it is given, not against a wider rect drawn underneath it.
local function lerpColor(a, b, t)
    return { r = a.r + (b.r - a.r) * t, g = a.g + (b.g - a.g) * t, b = a.b + (b.b - a.b) * t };
end

--[[
* Draws one bar: empty track, filled portion, and a border outline.
* Fill opacity comes from cfg.states[state].
*
* `bar_color2`, when given, turns the whole bar into a horizontal gradient from `bar_color` (left
* edge) to `bar_color2` (right edge) -- a straddling check tier's low and high colors -- fixed
* across the full bar width regardless of `frac`, so a target's HP draining just reveals less of
* the same low-to-high range rather than the range itself compressing into whatever sliver is left.
--]]
local function drawBar(draw_list, left, top, width, height, frac, state, bar_color, bar_color2, cfg, rounding)
    local states = cfg.states;
    local fill_w = width * frac;

    if (bar_color2 == nil) then
        draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(bar_color, states.empty), rounding);
        if (fill_w > 0) then
            draw_list:AddRectFilled({ left, top }, { left + fill_w, top + height }, packColor(bar_color, states[state]), rounding);
        end
    else
        local empty_l, empty_r = packColor(bar_color, states.empty), packColor(bar_color2, states.empty);
        draw_list:AddRectFilledMultiColor({ left, top }, { left + width, top + height }, empty_l, empty_r, empty_r, empty_l);

        if (fill_w > 0) then
            local edge = lerpColor(bar_color, bar_color2, frac);
            local fill_l, fill_r = packColor(bar_color, states[state]), packColor(edge, states[state]);
            draw_list:AddRectFilledMultiColor({ left, top }, { left + fill_w, top + height }, fill_l, fill_r, fill_r, fill_l);
        end
    end

    draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.bars.border_color), rounding);
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
-- `color` overrides the fill's rgb for a segment that carries one; the alpha still comes from
-- cfg.text.color, so the shared text opacity governs every string alike. Nothing sets it today --
-- the check tier used to, and now says its color on the HP bar instead -- but the segment shape
-- still carries the field, so the two segment drawers pass it through rather than dropping it.
local function drawText(draw_list, left, top, width, height, text, size, cfg, color)
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

    local fill = packColor(color or cfg.text.color, cfg.text.color.a);
    draw_list:AddText(font, size, { x, y }, fill, text);
    if (cfg.text.bold) then
        draw_list:AddText(font, size, { x + bx, y }, fill, text);
    end
end

-- `percent` (from stats.label) prints a % sign: a target at "42" reads as 42 HP left, not 42%.
local function barText(s, key)
    local value, percent = stats.label(s, key);
    return percent and ('%d%%'):fmt(value) or ('%d'):fmt(value);
end

--[[
* The text inside a bar.
*
* Sized off `height`, the bar's drawn height, so it tracks the configured height and the distance
* scale alike -- then shrunk again if that size is too wide for the bar. The second step exists for
* the level label: a number always fitted, but "Lv.14-17 WAR/MNK" is as long as the mob's job
* pairing makes it, and dropping it would leave the bar saying nothing at all. It cannot fall back
* on being read some other way -- the percent it replaced is still legible as the fill behind it,
* the level is not shown anywhere else on screen.
*
* Solved, not iterated: textWidth is linear in size apart from bold's fixed extra pixel, so the
* largest size that fits comes straight out of the ratio.
*
* A bar too *short* still drops its text rather than shrinking to mush -- that is the different
* failure (no glyph is legible at any width) and config.label_size already owns it. Per bar, so a
* 4px TP row can go quiet while the HP row above it still prints.
--]]
local function drawLabel(draw_list, left, top, width, height, text, cfg)
    local size = config.label_size(cfg, height);
    if (size == nil) then
        return;
    end

    local calc = imgui.CalcTextSize(text);
    if (calc > 0) then
        local bx = cfg.text.bold and 1 or 0;
        size = math.min(size, math.floor((width - bx) * imgui.GetFontSize() / calc));
    end

    if (size < 1) then
        return;
    end

    drawText(draw_list, left, top, width, height, text, size, cfg);
end

-- Panels with no mob reference (everything but a target) land on this rather than nil, so drawPanel
-- indexes left/right/rows instead of guarding each one. label/tag stay nil, same as mobinfo.panel's
-- own empty shape. Shared and never written to.
local NO_INFO = { left = {}, right = {}, rows = {} };

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
            drawText(draw_list, x, top, w, row, seg.alt, size, cfg, seg.color);
            x = x + w;
        end

        if (seg.text ~= nil) then
            local w = textWidth(seg.text, size, cfg);
            drawText(draw_list, x, top, w, row, seg.text, size, cfg, seg.color);
            x = x + w;
        end

        x = x + gap;
    end
end

-- `size` is the panel kind's own cfg.sizes entry; everything else about the panel is shared.
-- `scale` multiplies every pixel dimension, padding and rounding included -- a shrunk panel with a
-- full-size border swallows its own bars.
-- `tag` is the pre-formatted text for the box on the left ("P1".."P5", or a mob's level), or nil
-- for a panel that has none -- decided entirely by the caller (drawMember/drawTarget), not here.
-- `info` is mobinfo.panel's result -- the HP label segments, the two icon groups flanking the bar,
-- and any full-width rows under it. NO_INFO for every panel that is not a target.
-- `name` is a line to draw above the frame, or nil for none -- a party member whose own nameplate
-- this addon switched off, or a target's check tier/name/job line. Segments, not a string, so a
-- target's can carry mobinfo's aggro tint without a parameter of its own. `name_size` is its text
-- height; nil takes cfg.name_size, the stand-in plate's.
local function drawPanel(sx, sy, s, bars, size, scale, tag, info, name, name_size)
    local cfg = config.settings;
    info      = info or NO_INFO;

    -- Bars only. The reference lines hang under the frame rather than sitting inside it, so they
    -- cost the panel no height and the panel is the same shape with them as without.
    local height = config.panel_height(cfg, size, bars) * scale;

    -- The tag box comes out of the bars, not out of the panel: `width` is what was configured,
    -- so switching the tag on shifts the bars right and shortens them instead of growing the frame.
    local bw    = config.bar_width(cfg, size, tag ~= nil) * scale;
    local tag_w = config.slot_width(cfg, tag ~= nil) * scale;
    local pad   = cfg.panel.offset * scale;
    local gap   = cfg.gap * scale;

    local content  = bw + tag_w;
    local width    = size.width * scale;
    local left     = sx - width / 2;
    local top      = sy;
    local rounding = cfg.panel.rounding * scale;

    local draw_list = imgui.GetBackgroundDrawList();

    draw_list:AddRectFilled({ left, top }, { left + width, top + height }, packColor(cfg.panel.bg), rounding);
    draw_list:AddRect({ left, top }, { left + width, top + height }, packColor(cfg.panel.border_color), rounding);

    local content_left = sx - content / 2;
    local bar_left     = content_left + tag_w;
    local bar_top      = top + pad;
    local bar_rounding = cfg.bars.rounding * scale;

    -- The tag spans the bars' height rather than the top bar's, so it reads as one label against
    -- the whole stack. That is the panel's full inside now that the reference lines are outside it,
    -- so it is simply the height less the padding -- no block to subtract.
    -- Sized from its own setting (not from a bar), but through the same label_size, so it snaps to
    -- whole pixels and drops out when the distance scale makes it mush.
    if (tag ~= nil) then
        drawText(draw_list, content_left, bar_top, config.slot_box(cfg) * scale, height - 2 * pad,
                 tag, config.label_size(cfg, cfg.slot.size * scale), cfg);
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
                        frac, (frac >= 1) and 'full' or 'incomplete', bar_cfg.color, nil, cfg, bar_rounding);
            end
        else
            -- The target's HP bar fills in its check tier's color instead of the configured HP
            -- color, when there is one -- info.hp_color is nil for every other bar (mp/tp), every
            -- non-target panel (NO_INFO), and a target with Show Check off or no tier to report, so
            -- this never touches anything but the one bar it names. info.hp_color2 rides along the
            -- same way, only ever set alongside hp_color, to turn that one bar into a gradient when
            -- the mob's level range straddles a tier boundary (see mobinfo.check_text).
            local color  = (key == 'hp' and info.hp_color) or bar_cfg.color;
            local color2 = key == 'hp' and info.hp_color2 or nil;
            drawBar(draw_list, bar_left, bar_top, bw, h, s[key], 'full', color, color2, cfg, bar_rounding);
        end

        -- Label stays centered across the whole row, so TP prints over the middle bar. Every bar
        -- on every panel kind prints its own value and nothing else -- a target's check tier, name
        -- and job are a nameplate, and draw above the frame as one (see drawMobPanel).
        if (bar_cfg.label) then
            drawLabel(draw_list, bar_left, bar_top, bw, h, barText(s, key), cfg);
        end

        bar_top = bar_top + h + gap;
    end

    -- The name goes exactly where the plate this addon switched off used to be: one row above the
    -- frame, outside it, so it costs the panel no height and the panel is the same shape with a
    -- name as without -- the same deal the reference rows get under it. Same row for a target's
    -- tier/name/job line, which is the same thing by another route: a nameplate.
    --
    -- Sized off info_row, not a bar: that is the one rule here that bottoms out at text.min_size
    -- instead of shrinking away with the panel, and a name you cannot read is not a nameplate.
    -- Its own size goes in (cfg.name_size), so sizing the stand-in plates to taste does not drag
    -- a target's reference rows along with it.
    --
    -- It goes through drawInfoLine rather than drawText for the other half of that bargain -- a
    -- 15-character name is wider than a party panel, and drawText would drop a string that
    -- overflows its box, where a line simply overhangs both sides evenly.
    if (name ~= nil) then
        local name_row = config.info_row(cfg, scale, name_size or cfg.name_size);
        drawInfoLine(draw_list, left, top - gap - name_row, width, name_row,
                     name, math.floor(name_row), gap, cfg);
    end

    -- Mob reference, all of it outside the frame.
    --
    -- The row never goes away: it bottoms out at a legible size instead of dropping the way a bar
    -- label does (config.info_row). Floored for the font and the icon side, for the same reason
    -- label_size floors -- a size drifting by fractions as the camera moves resamples the same
    -- glyph every frame. `row` itself stays unfloored, so the floored size can never fail its own
    -- height check by a fraction.
    local row       = config.info_row(cfg, scale);
    local info_size = math.floor(row);

    -- The two icon groups flank the bar, one gap clear of each edge and centered on the panel's
    -- height: they are what you read *with* the bar, not under it, and beside it they cost the bar
    -- no width. Inside the frame they could not -- seven sense icons at the default size are wider
    -- than the whole target panel, so the bar they were meant to annotate would be squeezed to
    -- nothing by a mob that happens to notice everything.
    --
    -- Each group is handed a box exactly its own width, so drawInfoLine's centering lands it flush
    -- against that edge: the left group grows leftwards away from the panel, the right group
    -- rightwards, and neither shifts the other or the bar between them.
    local flank_top = top + (height - row) / 2;

    if (#info.left > 0) then
        local w = lineWidth(info.left, info_size, gap, cfg);
        drawInfoLine(draw_list, left - gap - w, flank_top, w, row, info.left, info_size, gap, cfg);
    end

    if (#info.right > 0) then
        local w = lineWidth(info.right, info_size, gap, cfg);
        drawInfoLine(draw_list, left + width + gap, flank_top, w, row, info.right, info_size, gap, cfg);
    end

    -- Rows hang under the panel, one gap below its bottom edge, each centered on the anchor. They
    -- are handed the panel's width to center *on*, not to fit within -- a resistance list has no
    -- natural width, and outside the frame there is nothing to overflow, so a long one simply
    -- overhangs both sides evenly instead of the panel stretching to swallow it (which made the
    -- frame jump between targets).
    local info_top = top + height + gap;

    for _, line in ipairs(info.rows) do
        drawInfoLine(draw_list, left, info_top, width, row, line, info_size, gap, cfg);
        info_top = info_top + row + gap;
    end
end

--[[
* Draws one panel over the entity at `index`. Silently skips entities that are out of zone
* (index 0) or off screen.
*
* @param {table} size - the panel kind's cfg.sizes entry (width + per-bar heights).
* @param {number} offset - world height nudge from the nameplate anchor, positive = down.
* @param {string|nil} tag - pre-formatted text for the tag box; nil for a panel with no tag.
* @param {table|nil} info - mobinfo.panel's result; nil for a panel with no mob reference.
* @param {table|nil} name - name line above the frame, as drawInfoLine segments; nil for none.
* @param {number|nil} name_size - that line's text height; nil for cfg.name_size.
--]]
local function drawAt(mm, index, s, bars, size, offset, tag, info, name, name_size, view, proj, vp)
    if (index == 0) then
        return false;
    end

    local ent = mm:GetEntity();

    -- Anchor on the bone the game hangs the nameplate from, so the offset from the plate holds on
    -- a mount, a Galka, or mid-jump -- and so the panel tracks the *model* horizontally rather
    -- than the feet. All three axes come from the anchor together or none do: falling back to the
    -- entity struct for one axis and the actor for the others mixes two positions that disagree
    -- while an entity moves. Falls back to feet when the skeleton is unreadable for a frame.
    local ax, ay, az = nameplate.anchor(ashita.memory, ent:GetActorPointer(index));
    local px = ax or ent:GetLocalPositionX(index);
    local py = ay or ent:GetLocalPositionY(index);
    local pz = (az or ent:GetLocalPositionZ(index)) + offset;

    -- Position struct is stored X, Z, Y - the game's Z is the D3D up-axis.
    local sx, sy, sz, depth = worldToScreen(px, pz, py, view, proj, vp.Width, vp.Height);

    if (sz >= 0 and sz <= 1 and sx >= 0 and sx <= vp.Width and sy >= 0 and sy <= vp.Height) then
        -- Scale comes from the anchor point, so the panel keeps its top edge pinned under the
        -- nameplate and grows or shrinks downward from there.
        drawPanel(sx, sy, s, bars, size, config.panel_scale(config.settings, depth), tag, info,
                  name, name_size);
        return true;
    end
    return false;
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

    -- No tag on your own panel: the panel over your own head is the one you never need told apart
    -- from the others. nil rather than a formatted string, so the box is not reserved either --
    -- your bars keep the full width instead of sitting beside a blank space. The enabled check
    -- moves here from drawPanel: slot_width now trusts whatever tag it is handed (see config.lua).
    local tag = nil;
    if (not mine and cfg.slot.enabled) then
        tag = ('P%d'):fmt(i);
    end

    -- The name only appears in place of a plate this addon took away, so it is gated on the same
    -- setting and the same slots the mask covers (1..5 -- slot 0's plate is `noname`'s to hide, so
    -- your own name is still up there and printing it again would just double it). Off, the plate
    -- says the name and the panel says the bars, which is the split the game already had.
    local name = nil;
    if (not mine and cfg.hide_party_names) then
        name = party:GetMemberName(i);
    end

    -- nil info: party members are not mobs, so there is nothing to look up for them.
    drawAt(mm, party:GetMemberTargetIndex(i), s,
           config.bars_for(party:GetMemberMainJob(i), party:GetMemberSubJob(i)),
           mine and cfg.sizes.self or cfg.sizes.party,
           mine and cfg.height_offset or cfg.party_height_offset,
           tag, nil, name and { { text = name } } or nil, nil, view, proj, vp);
end

-- HP is the only stat the client is told about an arbitrary entity, so any mob-reference panel is
-- always this one bar. Hoisted out of the frame loop rather than built per call.
local TARGET_BARS = { 'hp' };

-- Where the Floaties sessions on this PC swap pet numbers. Ashita's settings library has already
-- created this directory by the time anything draws, so there is nothing to mkdir. Resolved once at
-- load rather than per call: the install path is fixed for the process, and the two callers below
-- are both on the frame path (up to six times a frame between them).
local SHARE_DIR = ('%sconfig/addons/floaties/'):fmt(AshitaCore:GetInstallPath());

--[[
* Resolves one party slot's pet, or nil when that slot has no live one.
*
* Pets hold no party slot of their own -- they are reachable only through their owner's target
* index. This goes through the entity manager's accessor rather than the owner entity's
* PetTargetIndex field: it takes any owner index, so one call covers slot 0 and slots 1..5 alike.
*
* The inactive-slot check comes first because GetMemberTargetIndex returns 0 for an empty slot, and
* GetPetTargetIndex(0) then reads entity 0's pet field rather than answering "no pet" -- which a
* zone or a brief desync is enough to hit.
*
* @param {number} i - the *owner's* party slot, 0 .. 5.
* @return {number|nil} the pet's target index, and the pet entity -- or nil for neither.
--]]
local function livePet(mm, party, i)
    if (party:GetMemberIsActive(i) == 0) then
        return nil;
    end

    local index = mm:GetEntity():GetPetTargetIndex(party:GetMemberTargetIndex(i));
    local pet   = index ~= 0 and GetEntity(index) or nil;

    -- 0% is the corpse rule the target and enemy-list panels already follow: a dismissed or dead
    -- pet lingers in the entity table for a while. An empty bar over it reads as a live pet that is
    -- about to die rather than one that already has, and publishing it would put a full MP bar over
    -- a body on somebody else's box.
    if (pet == nil or pet.HPPercent == 0) then
        return nil;
    end

    return index, pet;
end

--[[
* Publishes our own pet's MP/TP for the other Floaties sessions on this PC (see lib/petshare.lua).
*
* Called from d3d_present rather than from drawPet, and ahead of the visibility gates, because what
* we publish is for somebody else's screen: switching off Show My Pet, or standing somewhere the
* gates hide panels, must not take the extra bars off the *other* box.
*
* Nothing is written while no pet is out -- petshare's staleness window is what retires the last
* line, so neither side needs a teardown path for a dismissed pet, a zone, a logout or a crash.
--]]
local function publishPet(mm, party)
    local _, pet = livePet(mm, party, 0);
    if (pet == nil) then
        return;
    end

    local player = mm:GetPlayer();
    petshare.publish(SHARE_DIR, party:GetMemberName(0), pet.ServerId,
                     player:GetPetMPPercent(), player:GetPetTP());
end

--[[
* Draws a party-sized panel over one party member's pet, when they have one out.
*
* Pets hold no party slot of their own -- they are reachable only through their owner's target
* index -- so this walks the same 0..5 the party panels do instead of getting a scan of its own.
*
* Only *your* pet publishes more than an HP percent: MP and TP come off the player block, which has
* room for exactly one pet, yours. Everyone else's gets what any arbitrary entity gets, one HP bar.
* So the bar set is decided here per owner rather than by the panel kind -- which is why pets share
* the party size table but not config.bars_for.
*
* No tag, unlike a party member's panel: a "P3" box over slot 3's pet would read as slot 3 itself.
* The name line follows the same rule the members' does -- it appears only in place of a plate this
* addon took away, so it is gated on Hide Party Nameplates, which now covers pets (see
* updateNameMask). Off, the plate says the name and the panel says the bars.
*
* @param {number} i - the *owner's* party slot, 0 .. 5.
--]]
local function drawPet(mm, party, i, view, proj, vp)
    local index, pet = livePet(mm, party, i);
    if (pet == nil) then
        return;
    end

    local cfg = config.settings;
    local s, bars;

    if (i == 0) then
        local player = mm:GetPlayer();
        s    = stats.read_pet(pet, player:GetPetMPPercent(), player:GetPetTP());
        bars = config.pet_bars(party:GetMemberMainJob(0));
    else
        -- Another member's pet is one HP percent as far as this client is concerned -- unless that
        -- member is a Floaties session on this same PC, in which case it has published the MP and
        -- TP its own player block gave it (see lib/petshare.lua). The id check is what keeps a
        -- newly swapped avatar from wearing the previous one's numbers for a poll.
        local sid, mp, tp;
        if (cfg.share_pet) then
            sid, mp, tp = petshare.get(SHARE_DIR, party:GetMemberName(i));
        end

        if (sid == pet.ServerId) then
            s    = stats.read_pet(pet, mp, tp);
            bars = config.pet_bars(party:GetMemberMainJob(i));
        else
            s    = stats.read_entity(pet);
            bars = TARGET_BARS;
        end
    end

    -- Your own pet gets its name here too, unlike your own panel: the mask covers every pet, yours
    -- included, so leaving this off slot 0 would take a name away and put nothing back.
    local name = cfg.hide_party_names and pet.Name or nil;

    drawAt(mm, index, s, bars, cfg.sizes.party, cfg.party_height_offset,
           nil, nil, name and { { text = name } } or nil, nil, view, proj, vp);
end

--[[
* Draws a target-style panel over one already-resolved entity: mob reference lookup, /check
* capture lookup, and the world-anchored draw. Shared by drawTarget (the current target) and
* drawClaimed (every mob you've personally hit, see lib/enemylist.lua) -- the two differ only in
* which index/entity they hand in, and everything about how the panel looks is identical between
* them by construction.
*
* @param {number} index - the entity's target index.
* @param {userdata} ent - entity from GetEntity(index). Never nil -- callers check first.
--]]
local function drawMobPanel(mm, index, ent, view, proj, vp)
    local s = stats.read_entity(ent);
    if (s == nil) then
        return false;
    end

    -- The reference is mob data, so it is looked up only for a mob -- a PC target passes the flag
    -- test in stats.targetable but has no entry, and looking one up by their name could only ever
    -- hit a mob that happens to share it. nil `res` yields the empty shape, so a PC target keeps
    -- the plain HP percent on its bar and gets no icons beside it.
    local res = nil;
    if (bit.band(ent.SpawnFlags, 0x10) ~= 0) then
        res = mobinfo.find(mob_db, index, ent.Name);
    end

    -- Main job level, not the sub's and not a level-synced display value: /check is decided by the
    -- level you fight at, which is what GetMainJobLevel reports (it already reads as the synced
    -- level while level sync is up). ent.Name is always known -- unlike everything else mobinfo
    -- draws, the label's name segment needs no mobdb entry.
    local info = mobinfo.panel(res, config.settings.mob, jobName, mm:GetPlayer():GetMainJobLevel(), ent.Name,
                                check_list[ent.ServerId]);

    -- The tier/name/job line goes *above* the frame, where a party member's stand-in nameplate
    -- goes, leaving the HP bar the plain percent every other bar on every other panel prints.
    -- Inside the bar that line was the panel's own width limit -- "EP-DC Tough Mist Lizard WAR/MNK"
    -- only ever fit by drawLabel shrinking it toward mush, and the percent had to be suppressed at
    -- full HP to make room at all. Above the frame drawInfoLine simply overhangs both sides evenly
    -- and holds at a legible size, so neither has to give way to the other any more.
    --
    -- Handed over as segments rather than flattened: mobinfo tints them all when the mob aggroes
    -- (cfg.mob.aggro_color), and drawInfoLine already draws a per-segment color.
    local name = (info.label ~= nil and #info.label > 0) and info.label or nil;

    local drawn = drawAt(mm, index, s, TARGET_BARS, config.settings.sizes.target,
                         config.settings.target_height_offset, info.tag, info, name,
                         config.settings.target_name_size, view, proj, vp);

    -- Only a panel that actually reached the screen puts a name up there, so only that one earns
    -- the client's plate being switched off (see named_mobs). Recorded unconditionally rather than
    -- behind hide_target_names -- updateNameMask drains this either way, and one table write is
    -- cheaper than reading the setting twice per frame per mob.
    if (drawn and name ~= nil) then
        named_mobs[index] = true;
    end

    return drawn;
end

--[[
* Draws a panel over the current target. target_index is already resolved and validated by
* updateGateState, so a rejected or absent target is just 0 here.
--]]
local function drawTarget(mm, view, proj, vp)
    local ent = target_index ~= 0 and GetEntity(target_index) or nil;
    if (ent == nil) then
        return;
    end
    drawMobPanel(mm, target_index, ent, view, proj, vp);
end

--[[
* Draws a panel over every mob currently in the enemy list (lib.enemylist) -- every mob you (or
* your pet/avatar/automaton) have personally hit or affected, per the packet_in handler's 0x0028
* case.
*
* Skips the entity currently at target_index only when the target panel is actually drawing it
* (show_target on) -- with Show Target off, the mob you're fighting still gets its panel from here
* instead of getting none at all. Pruning happens inline here rather than as a separate sweep: an
* entry that no longer resolves to a living mob is dropped the moment this loop notices, and one
* that fails to resolve to any index at all (fully despawned) is dropped outright here rather than
* re-paying a full entity-table scan for it (lib.enemylist's resolve_index fallback) every
* subsequent frame forever.
--]]
local function drawClaimed(mm, view, proj, vp)
    local em    = mm:GetEntity();
    local getId = function (i) return em:GetServerId(i); end;
    local party = mm:GetParty();
    local count = 0;

    for server_id in pairs(claimed_list) do
        local idx = enemylist.resolve_index(getId, server_id);

        if (idx == 0) then
            claimed_list[server_id] = nil;
        else
            local skip = config.settings.show_target and idx == target_index;
            local ent  = skip and nil or GetEntity(idx);

            enemylist.prune(claimed_list, ent);

            if (ent ~= nil and bit.band(ent.SpawnFlags, 0x10) ~= 0 and stats.targetable(ent, party)) then
                if (drawMobPanel(mm, idx, ent, view, proj, vp)) then
                    count = count + 1;
                    if (count >= config.settings.enemy_list_max) then
                        break;
                    end
                end
            end
        end
    end
end

--[[
* Every panel for one frame. Split out of d3d_present so the pcall guarding it can take arguments
* instead of a closure allocated per frame.
*
* @param {boolean} gated - whether the visibility gates currently pass. Self/party panels obey it;
*                          the target panel does not (see d3d_present).
--]]
local function drawPanels(mm, party, view, proj, vp, gated)
    if (gated) then
        -- Slot 0 is self; 1..5 are the rest of the party.
        for i = 0, (config.settings.show_party and 5 or 0) do
            drawMember(mm, party, i, view, proj, vp);
        end

        -- Pets walk those same slots on switches of their own: yours does not hang off Show Party
        -- Members (it is your pet, not the party's), and everyone else's is a separate switch
        -- because a party of summoners is six more panels -- see config.lua.
        if (config.settings.show_pet) then
            drawPet(mm, party, 0, view, proj, vp);
        end

        if (config.settings.show_party_pets) then
            for i = 1, 5 do
                drawPet(mm, party, i, view, proj, vp);
            end
        end
    end

    if (config.settings.show_target) then
        drawTarget(mm, view, proj, vp);
    end

    -- Ungated, same reasoning as the target panel: having hit something already answers "should
    -- this draw" -- gating it on your own idle/engaged/combat status would hide a mob you just
    -- pulled until your own status caught up.
    if (config.settings.show_enemy_list) then
        drawClaimed(mm, view, proj, vp);
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

    local was_open = config_open[1];
    if (imgui.Begin('Floaties Config', config_open)) then
        -- The settings gates, not the live conditions they test -- that readout moved into Debug
        -- below. One line: these three decide together (union, not intersection -- see
        -- config.visible), so reading them side by side is how "no gate enabled" jumps out.
        checkbox('Show In Combat', cfg, 'show_in_combat');
        imgui.SameLine();
        checkbox('Show While Engaged', cfg, 'show_while_engaged');
        imgui.SameLine();
        checkbox('Show While Idle', cfg, 'show_while_idle');

        imgui.Separator();

        -- Everything every panel kind draws with identically: geometry, the bar toggles, colors,
        -- alphas, rounding, and distance scaling. Target/Player/Party below only ever add a size
        -- or a kind-specific toggle on top of what is decided here.
        if (imgui.CollapsingHeader('General')) then
            slider(imgui.SliderInt, 'Panel Offset', cfg.panel, 'offset', 0, 20);
            colorEdit('Panel Background', cfg.panel.bg);
            colorEdit('Panel Border Color', cfg.panel.border_color);
            slider(imgui.SliderInt, 'Bar Gap', cfg, 'gap', 0, 10);

            -- "Bold" is a second fill stamped a pixel right, not a font weight (see M.label_size).
            checkbox('Bold Text', cfg.text, 'bold');
            for _, key in ipairs(config.bar_order) do
                imgui.SameLine();
                checkbox(('Show %s Text'):fmt(key:upper()), cfg.bars[key], 'label');
            end
            colorEdit('Text Color', cfg.text.color);
            colorEdit('Text Outline Color', cfg.text.outline_color);
            slider(imgui.SliderInt, 'Min Text Size', cfg.text, 'min_size', 1, 20);

            colorEdit3('Aggro Name Color', cfg.mob.aggro_color);
            colorEdit3('HP Color', cfg.bars.hp.color);
            colorEdit3('MP Color', cfg.bars.mp.color);
            colorEdit3('TP Color', cfg.bars.tp.color);
            colorEdit('Bar Border Color', cfg.bars.border_color);

            slider(imgui.SliderFloat, 'Full Alpha', cfg.states, 'full', 0, 1);
            slider(imgui.SliderFloat, 'Empty Alpha', cfg.states, 'empty', 0, 1);
            slider(imgui.SliderFloat, 'Incomplete Alpha', cfg.states, 'incomplete', 0, 1);

            -- 0 turns rounding off; there is no separate on/off checkbox for either.
            slider(imgui.SliderInt, 'Panel Rounding', cfg.panel, 'rounding', 0, 20);
            slider(imgui.SliderInt, 'Bar Rounding', cfg.bars, 'rounding', 0, 20);

            -- The reference depth does nothing while distance scaling is off, so it only appears
            -- with it -- same pattern as Party Slot Indicator's size below.
            checkbox('Scale With Distance', cfg, 'distance_scale');
            if (cfg.distance_scale) then
                slider(imgui.SliderFloat, 'Scale Reference Depth', cfg, 'scale_ref', 1, 30);
            end
        end

        -- Target, then Player (self), then Party -- most-glanced-at first, matching the size
        -- defaults' own ordering (config.lua's `sizes` comment).
        imgui.Separator();
        imgui.Text('Target Panel');
        checkbox('Show Target', cfg, 'show_target');
        slider(imgui.SliderFloat, 'Target Height Offset', cfg, 'target_height_offset', -4, 4);
        slider(imgui.SliderInt, 'Target Width', cfg.sizes.target, 'width', 40, 500);
        for _, key in ipairs(config.bar_order) do
            if (cfg.sizes.target[key] ~= nil) then
                slider(imgui.SliderInt, ('Target %s Height'):fmt(key:upper()), cfg.sizes.target, key, 4, 40);
            end
        end
        slider(imgui.SliderInt, 'Target Name Size', cfg, 'target_name_size', 8, 40);

        -- Target panel reference rows. The data line is the diagnostic: "loaded" with every box
        -- ticked and still nothing under the panel means this mob is not in mobdb's file, rather
        -- than mobdb not being installed at all.
        --
        -- Detection is listed first because it draws first: it owns the icon groups flanking the
        -- bar, and Level & Job feeds the tag box beside it and the name line above it (see
        -- mobinfo.panel).
        checkbox('Show Detection', cfg.mob, 'detect');
        checkbox('Show Level & Job', cfg.mob, 'level');
        checkbox('Show Check (TW/EP/DC/EM/T/VT/IT)', cfg.mob, 'check');
        checkbox('Show Weakness/Resist', cfg.mob, 'resist');
        slider(imgui.SliderInt, 'Info Text Size', cfg.mob, 'size', 8, 40);

        checkbox('Show Enemy List', cfg, 'show_enemy_list');
        slider(imgui.SliderInt, 'Enemy List Max', cfg, 'enemy_list_max', 1, 20);

        imgui.Separator();
        imgui.Text('Player Panel');
        slider(imgui.SliderFloat, 'Self Height Offset', cfg, 'height_offset', -4, 4);
        slider(imgui.SliderInt, 'Self Width', cfg.sizes.self, 'width', 40, 300);
        for _, key in ipairs(config.bar_order) do
            if (cfg.sizes.self[key] ~= nil) then
                slider(imgui.SliderInt, ('Self %s Height'):fmt(key:upper()), cfg.sizes.self, key, 4, 40);
            end
        end

        imgui.Separator();
        imgui.Text('Party Panel');
        checkbox('Show Party Members', cfg, 'show_party');

        -- Pets live under Party Panel because that is whose width, bar heights and height offset
        -- they draw with -- there is no Pet Panel section to put them in, on purpose.
        checkbox('Show My Pet', cfg, 'show_pet');
        imgui.SameLine();
        checkbox('Show Party Pets', cfg, 'show_party_pets');
        checkbox('Share Pet Info', cfg, 'share_pet');

        -- Independent of Show Party Members on purpose: hiding the plates without drawing panels is
        -- a legitimate (if odd) combination, and tying them would silently un-hide names the moment
        -- panels were switched off.
        checkbox('Hide Party Nameplates', cfg, 'hide_party_names');
        checkbox('Hide Target Nameplates', cfg, 'hide_target_names');
        slider(imgui.SliderInt, 'Party Name Size', cfg, 'name_size', 8, 40);
        slider(imgui.SliderFloat, 'Party Height Offset', cfg, 'party_height_offset', -4, 4);
        slider(imgui.SliderInt, 'Party Width', cfg.sizes.party, 'width', 40, 300);
        for _, key in ipairs(config.bar_order) do
            if (cfg.sizes.party[key] ~= nil) then
                slider(imgui.SliderInt, ('Party %s Height'):fmt(key:upper()), cfg.sizes.party, key, 4, 40);
            end
        end

        -- Size does nothing while the tag is off, so it only appears with it.
        checkbox('Party Slot Indicator', cfg.slot, 'enabled');
        if (cfg.slot.enabled) then
            slider(imgui.SliderInt, 'Slot Text Size', cfg.slot, 'size', 8, 40);
        end

        -- Diagnostics: gate/target state, the shown/hidden decisions, and the addon's own on/off
        -- switch. Collapsed by default and pinned to the bottom so it stays out of the way of the
        -- settings above it while still being one click from anyone chasing "why is nothing
        -- drawing" -- Enabled lives here too since that question always starts by checking it.
        imgui.Separator();
        if (imgui.CollapsingHeader('Debug')) then
            -- The master switch. It had no widget at all once, which is how it managed to be off
            -- and invisible at once -- every other persisted setting is reachable from this
            -- window, and this is the one that stops the addon drawing.
            checkbox('Enabled', cfg, 'enabled');

            -- Live gate state, so a gate that is not firing can be told apart from one that is
            -- firing when it should not. Green = the condition is true right now, red = false.
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
            -- Self/party only: the gates do not reach the target panel, so one "Panel: shown"
            -- covering both would be wrong half the time -- red while a target panel is plainly
            -- on screen.
            local shown = cfg.enabled and config.visible(cfg, gate_state);
            imgui.TextColored(shown and { 0.4, 1.0, 0.4, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
                              ('Self/party panels: %s'):fmt(shown and 'shown' or 'hidden'));

            -- Kept on the self/party line: both notes are about the gates, which is the decision
            -- that line reports. The target panel below answers to neither.
            if (not cfg.enabled) then
                imgui.SameLine();
                imgui.Text('-- addon switched off; tick Enabled above');
            elseif (not (cfg.show_in_combat or cfg.show_while_engaged or cfg.show_while_idle)) then
                imgui.SameLine();
                imgui.Text('-- no gate enabled, so nothing can enable it');
            end

            -- The target panel's own decision, in the same two colors, since it is now a separate one.
            local target_shown = cfg.enabled and cfg.show_target and target_index ~= 0;
            imgui.TextColored(target_shown and { 0.4, 1.0, 0.4, 1.0 } or { 1.0, 0.4, 0.4, 1.0 },
                              ('Target panel: %s'):fmt(target_shown and 'shown' or 'hidden'));

            -- "Panel: shown" over an empty screen means the draw threw, not that a gate is wrong. The
            -- message is the one thing that could tell them apart, and it used to be the thing that got
            -- swallowed -- see the pcall in d3d_present.
            if (draw_error ~= nil) then
                imgui.TextColored({ 1.0, 0.4, 0.4, 1.0 }, ('draw error: %s'):fmt(draw_error));
            end

            -- No icon state reported here: a missing PNG draws its `alt` word on the panel, so the
            -- lines reading as words *is* the diagnostic, and a counter in this window would only
            -- repeat what is already on screen.
            imgui.Text(('mob data: zone %d, %s'):fmt(mob_zone, mob_db ~= nil and 'loaded' or 'none'));

            local tracked = 0;
            for _ in pairs(claimed_list) do tracked = tracked + 1; end
            imgui.Text(('enemy list: %d tracked'):fmt(tracked));
        end
    end
    imgui.End();

    -- ImGui's own close button (X) writes config_open[1] straight to false, bypassing the
    -- /floaties toggle below -- catch that case here so closing the window that way still sticks
    -- across a reload, not just closing it via the command.
    if (was_open ~= config_open[1]) then
        setConfigOpen(config_open[1]);
    end
end

ashita.events.register('load', 'floaties_load', function ()
    config.load();
    config_open[1] = config.settings.config_visible;

    -- Loading mid-session has no zone packet to wait for.
    loadZone(AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0));

    -- FFXiMain.dll is packed on disk and only unpacked in memory, so targets.lua's signatures can
    -- only be confirmed at runtime. Say so loudly rather than letting the gate quietly never match.
    if (targets == nil) then
        print('[Floaties] lib/targets.lua failed to load -- "Show In Combat" will never match. Use "Show While Engaged" instead.');
    end
end);

-- Hidden nameplates are a live edit to the client's own entities, not addon state: unloading with
-- the bit still set leaves party members nameless with nothing left running to explain why, and no
-- way back short of a zone. Restore whatever is still masked on the way out.
ashita.events.register('unload', 'floaties_unload', function ()
    for index in pairs(masked) do
        setNameMask(index, false);
    end
    masked = {};

    -- The code patch outlives the addon otherwise -- a byte left changed in FFXiMain with nothing
    -- loaded that knows why.
    name_patch_on = false;
    patchNameClear(false);
end);

-- 0x00A is zone-in; the zone id sits at 0x30. Same hook and offset mobdb reloads its own data on.
-- 0x00B is zone-out. check_list is cleared on both, matching checker.lua's own zone handling: a
-- server id is only unique within one zone instance, so nothing recorded under the old one can be
-- trusted once that instance is gone.
ashita.events.register('packet_in', 'floaties_packet', function (e)
    if (e.id == 0x00A or e.id == 0x00B) then
        if (e.id == 0x00A) then
            loadZone(struct.unpack('H', e.data, 0x30 + 1));
        end
        checkinfo.clear(check_list);
        enemylist.clear(claimed_list);
        return;
    end

    -- Message Basic. Carries hundreds of unrelated client messages; checkinfo.record recognizes a
    -- /check response by its message/type codes and silently ignores everything else, so every
    -- field is unpacked unconditionally the same way checker.lua's own handler does.
    if (e.id == 0x0029) then
        local level   = struct.unpack('l', e.data, 0x0C + 1); -- Param 1 (Level)
        local ptype   = struct.unpack('L', e.data, 0x10 + 1); -- Param 2 (Check Type)
        local target  = struct.unpack('H', e.data, 0x16 + 1); -- Target index
        local message = struct.unpack('H', e.data, 0x18 + 1); -- Message (Defense / Evasion)

        checkinfo.record(check_list, GetEntity(target), level, ptype, message);
        return;
    end

    -- Action. Bit-packed, not byte-aligned like the two above -- see parseAction. Only actions
    -- whose actor is you or your pet/avatar/automaton ("mine") ever add anything: a trust's own
    -- actions are not checked (it only ever acts against something you're already acting against,
    -- so your own hit already covers it), and a party member landing a hit does not count either --
    -- only your own (and your pet's) actions do.
    if (e.id == 0x0028) then
        local actor_id, target_ids = parseAction(e);
        local mm    = AshitaCore:GetMemoryManager();
        local party = mm:GetParty();
        local mine  = mineIds(party);

        if (mine[actor_id]) then
            for _, tid in ipairs(target_ids) do
                local idx = enemylist.resolve_index(function (i) return mm:GetEntity():GetServerId(i); end, tid);
                local ent = idx ~= 0 and GetEntity(idx) or nil;
                if (ent ~= nil and bit.band(ent.SpawnFlags, 0x10) ~= 0) then
                    enemylist.record(claimed_list, ent);
                end
            end
        end
    end
end);

ashita.events.register('d3d_present', 'floaties_present', function ()
    local mm     = AshitaCore:GetMemoryManager();
    local player = mm:GetPlayer();
    local party  = mm:GetParty();

    -- Before every early return below, so the config window's status line keeps updating while
    -- the addon is disabled or the panel is gated off.
    updateGateState(mm, player, party);

    -- Same placement, same reason: this owns un-hiding as well as hiding, so it cannot sit behind
    -- a return that a disabled addon takes. It reads the master switch itself.
    updateNameMask(mm, party);

    drawConfigWindow();

    if (not config.settings.enabled) then
        return;
    end

    -- Not logged in / zoning: main job reads 0.
    if (player == nil or player:GetMainJob() == 0) then
        return;
    end

    -- Ahead of the gates on purpose -- see publishPet. Trapped for the same reason drawPanels is:
    -- a disk that will not take the write must not cost the frame its panels.
    if (config.settings.share_pet) then
        pcall(publishPet, mm, party);
    end

    -- Gated on your own status, not each member's, so the whole set shows/hides together.
    --
    -- The target panel is deliberately outside this: having something targeted *is* the answer to
    -- "should this draw", and running it through gates keyed on your own status meant a mob you
    -- had just clicked drew nothing until you engaged it -- the one moment the panel is for. It
    -- answers to `show_target` and a resolved target_index alone. The enemy list is outside it for
    -- the same reason: having hit something already answers the question, so it answers to
    -- `show_enemy_list` and a non-empty claimed_list alone.
    local gated   = config.visible(config.settings, gate_state);
    local target  = config.settings.show_target and target_index ~= 0;
    local claimed = config.settings.show_enemy_list and next(claimed_list) ~= nil;
    if (not gated and not target and not claimed) then
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
    local ok, err = pcall(drawPanels, mm, party, view, proj, vp, gated);
    draw_error = (not ok) and tostring(err) or nil;
end);

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------

ashita.events.register('command', 'floaties_command', function (e)
    local args = e.command:args();
    local cmd  = (args[1] or ''):lower();
    if (#args == 0 or (cmd ~= '/floaties' and cmd ~= '/float')) then
        return;
    end
    e.blocked = true;

    local sub = (args[2] or ''):lower();

    -- Bare `/floaties`/`/float`, and `config` for backward compatibility, both just raise the
    -- window -- the **Enabled** checkbox inside it is the only on/off switch now, so there is no
    -- separate toggle command to keep in sync with it.
    if (sub == '' or sub == 'config') then
        setConfigOpen(not config_open[1]);
        return;
    end

    -- One-shot print of the same state the config window's status line shows, for when you would
    -- rather watch the log across a fight than keep the window open.
    if (sub == 'bt') then
        print(('[Floaties] in_combat=%s engaged=%s idle=%s status=%d bt=%s target=%s'):fmt(
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
        print(('[Floaties] self height offset: %.2f (from the nameplate anchor, positive is down)'):fmt(config.settings.height_offset));
        return;
    end
end);
