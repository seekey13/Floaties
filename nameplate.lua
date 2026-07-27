--[[
* Nameplate anchor -- the world height FFXI hangs an entity's nameplate from.
*
* The plate's screen position is computed inside FFXiMain.dll each frame and stored nowhere
* readable, but it derives from the top of the rendered model, and the actor's skeleton *is*
* walkable memory: the highest bone (smallest Z -- height is down-positive) gives the same anchor
* without patching code. That is what keeps the panel's distance from the plate constant across
* races, mounts, sitting and jumping, all of which a fixed offset from the ground gets wrong.
*
* `mem` is injected (ashita.memory in the addon, a fake table in test.lua) so the pointer walk can
* be checked headless.
--]]

local M = {};

-- Actor object + skeleton offsets, from targetlines/helpers.lua:63-85.
local ACTOR_Z     = 0x67C;  -- feet height, down-positive
local SKELETON    = 0x6B8;  -- -> skeleton base pointer
local BONE_COUNT  = 0x32;   -- uint16, relative to the skeleton
local BONE_STRIDE = 0x1A;
local BONE_Z      = 0x0E + 0x4;   -- bone position is X, Z, Y like every other position in this game

-- A PC skeleton is ~60 bones. A count past this means the pointer walk landed on something that is
-- not a skeleton, so bail rather than reading a few thousand floats out of arbitrary memory.
local MAX_BONES = 256;

--[[
* World height of the top of an entity's model, i.e. where its nameplate hangs.
*
* @param {table} mem - ashita.memory, or anything with read_uint32/read_uint16/read_float.
* @param {number|nil} ptr - actor pointer from IEntity:GetActorPointer(index).
* @return {number|nil} height (down-positive), or nil if the model has no readable skeleton --
*                      caller falls back to the entity's own position.
--]]
function M.top(mem, ptr)
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
    if (bones == 0 or bones > MAX_BONES) then return nil; end

    local generators = skeleton + 0x30 + 0x04 + 0x1E * bones + 4;

    local top = nil;
    for b = 0, bones - 1 do
        local z = mem.read_float(generators + b * BONE_STRIDE + BONE_Z);
        -- z ~= z is the NaN test: a half-written bone reads as NaN and would poison the min.
        if (z == z and (top == nil or z < top)) then
            top = z;
        end
    end

    if (top == nil) then return nil; end

    -- Bone positions are relative to the actor origin.
    return mem.read_float(ptr + ACTOR_Z) + top;
end

return M;
