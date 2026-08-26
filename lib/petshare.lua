--[[
* Pet MP/TP shared between the Floaties sessions running on one PC.
*
* The client is told MP and TP for exactly one pet -- yours -- through the player block. Another
* party member's pet is just an entity, and an entity publishes nothing but an HP percent, so a
* second box's avatar draws one bar where its own session draws three. Each session writes its own
* pet's numbers to config/addons/floaties/pet_<CharName>.txt and reads the file belonging to each
* party member it is drawing a pet for, which closes that gap with no setup beyond both boxes
* running the addon. (Sidekick's lib/core/party_share.lua shares a roster the same way; this is the
* same idea with a much smaller payload.)
*
* HP is deliberately *not* in the file: the entity table already carries a live HP percent for
* anybody's pet, so sharing it would only add a way for the two to disagree.
*
* Lookup is keyed by character name rather than by scanning the directory, because the only pets
* Floaties draws hang off party slots 0..5 and the name of every one of those owners is already in
* hand. A session whose character is not in your party publishes a file nobody reads, which costs
* one write every M.POLL and nothing else.
*
* io/os are plain Lua, not Ashita, so everything here loads headless; only the directory is
* injected (Floaties.lua supplies it from GetInstallPath) -- see CLAUDE.md's headless boundary.
--]]

local M = {};

-- Seconds between file touches, publish and read alike. TP moves fast enough that a Sidekick-sized
-- 2 s poll would show a bar that visibly lags the other box's screen; a one-line file at 2 Hz is
-- nothing next to the per-frame work already happening around it.
M.POLL = 0.5;

-- Seconds a published line stays trusted. Covers the publisher quitting, zoning, losing its pet or
-- unloading the addon -- all of which simply stop the writes -- so no session has to clean up after
-- itself, and a file left behind by a crash cannot show a phantom MP bar. Wide enough that a
-- dropped frame or a stalled disk write never blinks the extra bars off.
M.MAX_AGE = 5;

local function path(dir, name)
    return string.format('%spet_%s.txt', dir, name);
end

--[[
* The published line: pet server id, MP percent, raw TP, and the wall-clock second it was written.
*
* Numeric fields only and the id first, so a torn read fails the pattern rather than parsing into
* something plausible. The stamp is what makes staleness detectable at all -- there is no portable
* way to read a file's mtime from Lua.
*
* @param {number} sid - the pet's server id, matched against the entity the reader is drawing.
* @param {number} mp - GetPetMPPercent(), 0 .. 100.
* @param {number} tp - GetPetTP(), 0 .. 3000.
* @param {number} stamp - os.time() at the moment of writing.
* @return {string} one line, newline terminated.
--]]
function M.line(sid, mp, tp, stamp)
    return string.format('%d %d %d %d\n', sid, mp, tp, stamp);
end

--[[
* Parses one published line, rejecting anything older than M.MAX_AGE.
*
* @param {string} text - a line read back from a pet file.
* @param {number} stamp - os.time() now.
* @return {number|nil} server id, MP percent, raw TP -- all nil when malformed or stale.
--]]
function M.parse(text, stamp)
    local sid, mp, tp, at = text:match('^(%d+) (%d+) (%d+) (%d+)');
    if (sid == nil or stamp - tonumber(at) > M.MAX_AGE) then
        return nil;
    end
    return tonumber(sid), tonumber(mp), tonumber(tp);
end

local last_publish = 0;

--[[
* Writes our own pet's numbers, no more than once per M.POLL.
*
* Straight overwrite, not Sidekick's write-temp-and-rename: a reader that catches a half-written
* line fails M.parse, falls back to the plain HP bar for that one frame and is whole again on the
* next poll. There is no state to corrupt, so the swap dance buys nothing here.
*
* @param {string} dir - the shared directory, trailing separator included.
* @param {string} name - our own character name.
* @param {number} sid - the pet's server id, so a reader can tell a swapped avatar from this one.
* @param {number} mp - the pet's MP percent, off our own player block.
* @param {number} tp - the pet's raw TP, off the same block.
--]]
function M.publish(dir, name, sid, mp, tp)
    local now = os.clock();
    if (now - last_publish < M.POLL) then
        return;
    end
    last_publish = now;

    local f = io.open(path(dir, name), 'w');
    if (f == nil) then
        return;
    end
    f:write(M.line(sid, mp, tp, os.time()));
    f:close();
end

-- [name] = { at = os.clock() of the read, sid, mp, tp }. Bounded by the party members whose pets
-- have been drawn, so there is nothing to evict.
local cache = {};

--[[
* One party member's published pet numbers, re-read no more than once per M.POLL.
*
* Called from the draw path, which runs every frame -- hence the cache: without it this is five
* file opens per frame rather than five per poll.
*
* The caller must check the returned id against the pet it is actually drawing. A member who swaps
* avatars leaves the old id in the file until the next write, and MP belonging to the wrong pet is
* worse than no MP bar at all.
*
* @param {string} dir - the shared directory, trailing separator included.
* @param {string} name - the party member's character name, which is what names their file.
* @return {number|nil} server id, MP percent, raw TP -- all nil with no file, or a stale one.
--]]
function M.get(dir, name)
    local now = os.clock();
    local c   = cache[name];

    if (c == nil or now - c.at >= M.POLL) then
        c = { at = now };
        local f = io.open(path(dir, name), 'r');
        if (f ~= nil) then
            c.sid, c.mp, c.tp = M.parse(f:read('*l') or '', os.time());
            f:close();
        end
        cache[name] = c;
    end

    return c.sid, c.mp, c.tp;
end

return M;
