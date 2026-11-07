#version 2
-- Warehouse Ring: the crowd, its hype, mantling into the ring, respawns after a knockout.
--
-- Server: watches "playerhurt" / "playerdied" in the ring and raises the crowd's HYPE (0 = idle murmur, 1 = roaring,
-- up to HYPE_MAX on a knockout): a hit adds by its damage, a combo (COMBO_HITS hits by one fighter on one victim, at
-- most COMBO_GAP s apart) adds more, a knockout sends it to the top. It decays back to its resting level: a murmur
-- (HYPE_BASE) while someone is in the ring and something happened in the last QUIET_AFTER s (a hit, a knockout, a
-- round start, someone climbing in), else 0 - a quiet hall (the user: "when nothing is happening ... the crowd should be
-- quiet"). Published in shared.crowd with the last event (kind, number, where), which the clients turn into sound
-- and motion.
-- A knocked-out player stands up beside the ring after RESPAWN_TIME s - unless the Brawl game mode runs
-- (registry brawl.active: it owns respawns then). The Brawl mode's events (brawl.event.*: round start / end, a
-- knocked fighter getting up) cheer. No bell (the user asked to remove it).
-- The fight area for Brawl: registry brawl.area = the ring inside the ropes (Brawl's API; see brawl/PROJECT.md).
--
-- Every client: spawns its own crowd (static bodies from crowd_data.lua, not physical: collide='false', layer 128)
-- and makes them hop - more of them, higher and wilder with the hype - and plays the crowd's loops and roars. Each
-- spectator holds three poses (a body each, only one visible): arms down / crossed / on the
-- hips while calm (the user: "put down their arms when they're not cheering"), a cheer while standing excited, and
-- while hopping the two cheers swap on every landing (pumping arms).

#include "script/include/player.lua"
#include "mantle.lua"
#include "crowd_data.lua"

RING_H = 1.2                  -- canvas top (m); the ring is centred on the origin
ROPES = 3.95                  -- rope line (half size of the canvas inside the ropes; tools/make_level.py ROPE_LINE)
RING_ZONE = 4.75              -- a hit counts for the crowd when the victim's feet are within this half size ...
RING_ZONE_Y = 0.6             -- ... and above RING_H - this
HYPE_BASE = 0.12              -- the murmur while there is a fight on (see QUIET_AFTER)
HYPE_MAX = 1.6
HYPE_DECAY = 0.09             -- per second, toward the resting level (slower when wild)
QUIET_AFTER = 25              -- s without action (or with nobody in the ring): the hall falls quiet
HIT_HYPE = 0.16               -- per hit, plus HIT_DAMAGE_HYPE x the damage (health is 0..1)
HIT_DAMAGE_HYPE = 1.3
COMBO_HITS, COMBO_GAP, COMBO_HYPE = 3, 1.5, 0.3
KO_HYPE = HYPE_MAX
RESPAWN_TIME = 4.0
CROWD_LAYER = 128
SPAWNS = {{0, 7.2, 180}, {7.2, 0, -90}, {-7.2, 0, 90}, {0, -7.2, 0}}   -- x, z, yaw: beside the ring, facing it (yaw 0 faces +z)

------------------------------------------------------------------------------------------------------------- server

function server.init()
	mantleServerInit()
	srv = {hype = 0, rest = 0, lastAction = -999, inside = {}, ev = 0, kind = "", at = Vec(0, RING_H, 0), combos = {}, respawn = {}, pubAt = 0,
		brawlSeen = GetInt("brawl.event.last")}
	-- the Brawl game mode's fight area (its API: a box from the canvas up, inside the ropes)
	SetString("brawl.area", string.format("box %.2f %.2f %.2f %.2f %.2f %.2f", -ROPES, RING_H - 0.3, -ROPES, ROPES, RING_H + 3.5, ROPES))
	publish()
end

function inRing(pos)
	return math.abs(pos[1]) < RING_ZONE and math.abs(pos[3]) < RING_ZONE and pos[2] > RING_H - RING_ZONE_Y
end

function event(kind, at, boost)
	srv.lastAction = GetTime()
	srv.ev = srv.ev + 1
	srv.kind = kind
	srv.at = at or Vec(0, RING_H, 0)
	srv.boost = boost or 0
	publish()
end

function publish()
	shared.crowd = {hype = srv.hype, ev = srv.ev, kind = srv.kind, boost = srv.boost or 0,
		x = srv.at[1], y = srv.at[2], z = srv.at[3]}
	srv.pubAt = GetTime()
end

function server.tick(dt)
	local now = GetTime()
	for i = 1, GetEventCount("playerhurt") do
		local victim, before, after, attacker = GetEvent("playerhurt", i)
		local dmg = (before or 0) - (after or 0)
		local pos = GetPlayerTransform(victim).pos
		if dmg > 0.004 and inRing(pos) then
			srv.hype = math.min(HYPE_MAX, srv.hype + HIT_HYPE + HIT_DAMAGE_HYPE * dmg)
			local key = tostring(attacker or 0) .. ">" .. tostring(victim)
			local c = srv.combos[key]
			if c and now - c.t <= COMBO_GAP then c.n = c.n + 1 else c = {n = 1}; srv.combos[key] = c end
			c.t = now
			if (attacker or 0) ~= 0 and c.n >= COMBO_HITS then
				srv.hype = math.min(HYPE_MAX, srv.hype + COMBO_HYPE)
				event("combo", pos, c.n)
			else
				event(dmg >= 0.2 and "bighit" or "hit", pos, dmg)
			end
		end
	end
	for i = 1, GetEventCount("playerdied") do
		local victim = GetEvent("playerdied", i)
		local pos = GetPlayerTransform(victim).pos
		if inRing(pos) then
			srv.hype = KO_HYPE
			event("ko", pos)
		end
		if not GetBool("brawl.active") then srv.respawn[victim] = now + RESPAWN_TIME end
	end
	-- the Brawl game mode's events (its event ring, written fields first, counter last): round start / end, get-ups
	local last = GetInt("brawl.event.last")
	while srv.brawlSeen < last do
		srv.brawlSeen = srv.brawlSeen + 1
		local kind = GetString("brawl.event." .. (srv.brawlSeen % 16) .. ".kind")
		if kind == "round_start" then
			srv.hype = math.max(srv.hype, 0.8); event("roundstart")
		elseif kind == "round_end" then
			srv.hype = math.max(srv.hype, 1.2); event("final")
		elseif kind == "getup" then                                     -- (back on their feet: a cheer)
			srv.hype = math.min(HYPE_MAX, srv.hype + 0.3); event("bighit", Vec(0, RING_H, 0), 0.3)
		end
	end
	-- knocked out (no game mode): stand up beside the ring
	for p, at in pairs(srv.respawn) do
		if now >= at then
			srv.respawn[p] = nil
			if GetBool("brawl.active") then
				-- the mode took over meanwhile
			elseif GetPlayerHealth(p) <= 0 then
				local s = SPAWNS[math.random(1, #SPAWNS)]
				RespawnPlayerAtTransform(Transform(Vec(s[1], 0.1, s[2]), QuatEuler(0, s[3], 0)), p)
			end
		end
	end
	for p in PlayersRemoved() do srv.respawn[p] = nil; srv.inside[p] = nil end
	-- the resting level: a murmur while someone is in the ring and there was action (or an entrance) lately
	local occupied = false
	for p in Players() do
		local inside = GetPlayerHealth(p) > 0 and inRing(GetPlayerTransform(p).pos)
		if inside and not srv.inside[p] then srv.lastAction = now end         -- (climbing in counts as action)
		srv.inside[p] = inside
		occupied = occupied or inside
	end
	srv.rest = (occupied and now - srv.lastAction < QUIET_AFTER) and HYPE_BASE or 0
	-- decay (slower while it is wild, so a knockout's roar lasts a while)
	local rate = srv.hype > 1 and HYPE_DECAY * 0.6 or HYPE_DECAY
	if srv.hype > srv.rest then
		srv.hype = math.max(srv.rest, srv.hype - rate * dt)
	else
		srv.hype = math.min(srv.rest, srv.hype + 0.05 * dt)               -- (the murmur rises slowly)
	end
	for k, c in pairs(srv.combos) do
		if now - c.t > COMBO_GAP then srv.combos[k] = nil end
	end
	if now - srv.pubAt > 0.1 then publish() end
end

function server.update(dt)
	mantleServerUpdate(dt)
end

function mantleQueryMask() QueryCollisionMask(255 - CROWD_LAYER) end

------------------------------------------------------------------------------------------------------------- client

LOOPS = {                     -- crowd loops: one per stand (alternating takes), at the stand's middle
	{"MOD/snd/crowd_loop_a.ogg", Vec(0, 1.5, 12.6)}, {"MOD/snd/crowd_loop_b.ogg", Vec(12.6, 1.5, 0)},
	{"MOD/snd/crowd_loop_a.ogg", Vec(0, 1.5, -12.6)}, {"MOD/snd/crowd_loop_b.ogg", Vec(-12.6, 1.5, 0)}}
STANDS = {Vec(0, 1.5, 12.6), Vec(12.6, 1.5, 0), Vec(0, 1.5, -12.6), Vec(-12.6, 1.5, 0)}
LOOP_MAX = 0.096              -- the crowd loops' volume when wildest (each of four stands; the user: quieter, six times -
SHOT_VOL = 0.11               --  "even single punch cheering is too loud": 0.245 / 0.28 -> -30 %, then "about 25%
                              --  across the board" twice; the last: "I think we're set") / the roars' and chants' scale
PEAK_FROM = 0.35              -- the loud end compressed (the user: "too loud when they're at their loudest", then after
PEAK_RATIO = 4                --  listening "when hype is high, volume is too loud"): above this share of the full
                              --  volume it rises PEAK_RATIO times slower (full -> 51 %); the murmur and a single
                              --  hit's cheer are under it. (A ramped cut of 60 % wasn't monotonic: high hype came
                              --  out quieter than medium.)

function client.init()
	crowd = {}
	cl = {hype = 0, ev = (shared.crowd and shared.crowd.ev) or 0, t = 0, roar = 0}
	for _, row in ipairs(CROWD) do
		local f, x, y, z, r = row[1], row[2], row[3], row[4], row[5]
		local pos = Vec(x, y, z)
		local yaw = math.deg(math.atan2(x, z)) + (r - 0.5) * 24            -- face the ring (-z toward the centre)
		local rot = QuatEuler(0, yaw, 0)
		-- each pose its own body: three overlapping shapes in ONE static body lost their shared voxels (the engine
		-- culls a shape's voxels covered by another shape of the body: hidden, the poses showed floating hands and
		-- body pieces - seen in-game; 'nomerge' didn't help)
		local poses = {}
		for k, file in ipairs(CROWD_PERSONS[f]) do
			local made = Spawn("<body tags='crowd'><vox file='MOD/vox/crowd/" .. file .. "' scale='0.5' collide='false'/></body>",
				Transform(pos, rot), true)
			for _, e in ipairs(made) do
				if GetEntityType(e) == "body" then
					local sh = GetBodyShapes(e)[1]
					if sh then
						SetShapeCollisionFilter(sh, CROWD_LAYER, 0)
						SetTag(sh, "invisible")
						poses[k] = {body = e, shape = sh}
					end
					break
				end
			end
		end
		if poses[1] then
			local s = {pos = pos, yaw = yaw, r = r, poses = poses, pose = 0, at = Transform(pos, rot),
				rate = 1.6 + 0.8 * ((r * 7.31) % 1),       -- hops per second
				keen = (r * 3.77) % 1,                     -- 0 = jumps at the smallest thing, 1 = only when wild
				phase = (r * 11.3) % 1, hopping = false}
			showPose(s, 1)
			crowd[#crowd + 1] = s
		end
	end
	snd = {
		hit = {LoadSound("MOD/snd/crowd_hit0.ogg"), LoadSound("MOD/snd/crowd_hit1.ogg")},
		combo = LoadSound("MOD/snd/crowd_combo.ogg"),
		ko = LoadSound("MOD/snd/crowd_ko.ogg"),
		loops = {},
	}
	for i, l in ipairs(LOOPS) do snd.loops[i] = LoadLoop(l[1]) end
end

-- one spectator's pose: 1 idle, 2 / 3 the cheers (a body each; the hidden ones tagged invisible and left where they
-- were: only the shown one is moved)
function showPose(s, k)
	if s.pose == k or not s.poses[k] then return end
	if s.poses[s.pose] then SetTag(s.poses[s.pose].shape, "invisible") end
	local p = s.poses[k]
	SetBodyTransform(p.body, s.at)
	RemoveTag(p.shape, "invisible")
	s.pose = k
end

-- move a spectator (its shown pose)
function placeSpectator(s, t)
	s.at = t
	SetBodyTransform(s.poses[s.pose].body, t)
end

-- the crowd's excitement on this machine: follows the server's hype (fast up, slow down)
function crowdLevel(dt)
	local target = (shared.crowd and shared.crowd.hype) or 0
	local k = target > cl.hype and 6 or 1.5
	cl.hype = cl.hype + (target - cl.hype) * math.min(1, k * dt)
	return cl.hype
end

-- the volume after the compressor: x = a share of the full volume (0..1); up to PEAK_FROM unchanged, above it
-- rising PEAK_RATIO times slower (still rising: louder moments stay louder)
function tamed(x)
	if x <= PEAK_FROM then return x end
	return PEAK_FROM + (x - PEAK_FROM) / PEAK_RATIO
end

local function shot(h, pos, share, pitch) PlaySound(h, pos, SHOT_VOL * tamed(share), false, pitch or 1) end

function playEvent(c)
	local at = Vec(c.x, c.y, c.z)
	local kind = c.kind
	if kind == "hit" or kind == "bighit" then
		local v = math.min(1, 0.4 + 1.6 * (c.boost or 0))
		local h = snd.hit[(kind == "bighit") and 2 or 1]
		for i = 1, 2 do shot(h, STANDS[math.random(1, 4)], v, 0.92 + 0.16 * math.random()) end
		cl.roar = math.max(cl.roar, kind == "bighit" and 0.6 or 0.35)
	elseif kind == "combo" then
		for i = 1, 2 do shot(snd.combo, STANDS[i * 2 - 1 + math.random(0, 1)], 0.9) end
		shot(snd.hit[2], STANDS[math.random(1, 4)], 0.9, 1.05)
		cl.roar = math.max(cl.roar, 0.8)
	elseif kind == "ko" then
		for i = 1, 4 do shot(snd.ko, STANDS[i], 1, 0.95 + 0.1 * math.random()) end
		cl.roar = 1.0
	elseif kind == "roundstart" then
		for i = 1, 2 do shot(snd.hit[1], STANDS[i * 2], 0.8) end
		cl.roar = math.max(cl.roar, 0.5)
	elseif kind == "final" then
		for i = 1, 4 do shot(snd.ko, STANDS[i], 0.8) end
		cl.roar = 1.0
	end
end

function client.tick(dt)
	mantleClientTick(true)
	local c = shared.crowd
	if c and c.ev ~= cl.ev then
		if c.ev > cl.ev then playEvent(c) end
		cl.ev = c.ev
	end
	cl.roar = math.max(0, cl.roar - dt * 0.5)
	local h = crowdLevel(dt)
	local a = math.min(HYPE_MAX, h + cl.roar * 0.6)                -- (a fresh event jolts them at once)
	-- the loops: near silence at rest, a murmur while a fight is on, a roar when wild (at most LOOP_MAX, compressed)
	local vol = LOOP_MAX * tamed(0.04 + 0.6 * math.min(1, a) + 0.36 * math.max(0, a - 1) / (HYPE_MAX - 1))
	if vol > 0.01 then
		for i, l in ipairs(LOOPS) do PlayLoop(snd.loops[i], l[2], vol) end
	end
	animateCrowd(dt, a)
end

-- hops: a spectator jumps while the excitement is above their keenness; height, pace and (when wild, a > 1) a
-- twist and a lean grow with it. A hop that is under way is finished before they settle. Poses: hopping, the two
-- cheers swap at every landing; standing, a cheer when the excitement is near their keenness, else the idle pose.
function animateCrowd(dt, a)
	local share = 0.7 * math.min(1, a) + 0.3 * math.max(0, a - 1) / (HYPE_MAX - 1)
	local band = 0.2 * math.min(1, a / 0.5)                          -- (standing cheerers: none in a quiet hall)
	local height = 0.1 + 0.22 * a
	local pace = 0.8 + 0.3 * a
	local wild = math.max(0, a - 1) / (HYPE_MAX - 1)
	cl.t = cl.t + dt
	for _, s in ipairs(crowd) do
		local want = s.keen < share
		if want or s.hopping then
			local before = s.phase % 1
			s.phase = s.phase + dt * s.rate * pace
			local now = s.phase % 1
			if not want and now < before then                         -- landed: settle
				s.hopping = false
				placeSpectator(s, Transform(s.pos, QuatEuler(0, s.yaw, 0)))
				showPose(s, s.keen < share + band and 2 or 1)
			else
				if not s.hopping then showPose(s, 2)
				elseif now < before then showPose(s, s.pose == 2 and 3 or 2) end   -- (landed: the other cheer)
				s.hopping = true
				local up = height * (0.7 + 0.6 * s.r) * math.sin(math.pi * now)
				local twist = wild * 22 * math.sin(cl.t * 3.1 + s.r * 20)
				local lean = wild * 9 * math.sin(cl.t * 4.3 + s.r * 13)
				placeSpectator(s, Transform(VecAdd(s.pos, Vec(0, up, 0)), QuatEuler(lean, s.yaw + twist, 0)))
			end
		else
			showPose(s, s.keen < share + band and 2 or 1)                -- standing: a cheer when almost keen enough
		end
	end
end

function client.postUpdate()
	mantleClientPostUpdate()
end
