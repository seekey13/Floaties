--[[
* Nameplate anchor -- the world point FFXI hangs an entity's nameplate from.
*
* The plate's screen position is computed inside FFXiMain.dll each frame and stored nowhere
* readable, but the actor's skeleton *is* walkable memory, and the client's own nameplate helper
* takes a bone index: bone 2. Reading that bone gives the same anchor without patching code, and
* keeps the panel's distance from the plate constant across races, mounts, sitting and jumping,
* all of which a fixed offset from the ground gets wrong.
*
* All three axes come from the actor object, not the entity struct: bone offsets are relative to
* the actor origin, so mixing them with the entity's own position drifts horizontally whenever the
* two disagree (the actor holds the *rendered* position; the entity struct can lag it by a frame
* during movement). A leaning or lunging model's head is also displaced from its feet, which a
* feet-derived X/Y misses entirely.
*
* `mem` is injected (ashita.memory in the addon, a fake table in test.lua) so the pointer walk can
* be checked headless.
--]]

local M = {};

-- Actor object + skeleton offsets, from targetlines/helpers.lua:63-85.
local ACTOR_X     = 0x678;
local ACTOR_Z     = 0x67C;  -- feet height, down-positive
local ACTOR_Y     = 0x680;
local SKELETON    = 0x6B8;  -- -> skeleton base pointer
local BONE_COUNT  = 0x32;   -- uint16, relative to the skeleton
local BONE_STRIDE = 0x1A;
local BONE_POS    = 0x0E;   -- bone position is X, Z, Y like every other position in this game

-- The bone the client itself anchors a nameplate to. Not the topmost bone: scanning for the
-- smallest Z picks up whatever the model happens to hold highest -- a greatsword on the back, a
-- raised wing, a hat -- and that bone *moves through the animation*, so the panel wandered.
-- ponytail: fixed, not a setting. If some model ever needs a different one, the per-panel
-- height_offset settings already cover the gap; only a genuinely different skeleton layout would
-- justify making this configurable.
local ANCHOR_BONE = 2;

-- A PC skeleton is ~60 bones. A count past this means the pointer walk landed on something that is
-- not a skeleton, so bail rather than computing a bone address out of arbitrary memory.
local MAX_BONES = 256;

--[[
* World position of an entity's nameplate anchor.
*
* @param {table} mem - ashita.memory, or anything with read_uint32/read_uint16/read_float.
* @param {number|nil} ptr - actor pointer from IEntity:GetActorPointer(index).
* @return {number,number,number}|nil x, y, z (z down-positive), or nil if the model has no
*         readable skeleton -- caller falls back to the entity's own position.
--]]
function M.anchor(mem, ptr)
    -- GetActorPointer hands back 0 for a despawned, zoning or invalid index, and every pointer in
    -- the chain below can be 0 for a frame during a model swap. One miss = one fallback frame.
    if (ptr == nil or ptr == 0) then return nil; end

    local base = mem.read_uint32(ptr + SKELETON);
    if (base == 0) then return nil; end

    local offset = mem.read_uint32(base + 0x0C);
    if (offset == 0) then return nil; end

    local skeleton = mem.read_uint32(offset);
    if (skeleton == 0) then return nil; end

    local bones = mem.read_uint16(skeleton + BONE_COUNT);
    if (bones <= ANCHOR_BONE or bones > MAX_BONES) then return nil; end

    local generators = skeleton + 0x30 + 0x04 + 0x1E * bones + 4;
    local bone = generators + ANCHOR_BONE * BONE_STRIDE + BONE_POS;

    local bx, bz, by = mem.read_float(bone), mem.read_float(bone + 4), mem.read_float(bone + 8);
    -- v ~= v is the NaN test: a half-written bone would drag the panel off screen for that frame.
    if (bx ~= bx or by ~= by or bz ~= bz) then return nil; end

    return mem.read_float(ptr + ACTOR_X) + bx,
           mem.read_float(ptr + ACTOR_Y) + by,
           mem.read_float(ptr + ACTOR_Z) + bz;
end

return M;
