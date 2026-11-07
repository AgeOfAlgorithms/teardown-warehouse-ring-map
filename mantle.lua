-- Warehouse Ring mantling: Wraith Hunt's wh_mantle.lua (from Humans vs Clickers and Tall Order's movement.lua, verified
-- in-game there), plus a VAULT: a thin rail with floor beyond it (the ring's ropes, the crowd barriers) is crossed in
-- one go instead of balanced on. Included by ring.lua (#version 2), which calls the mantle* functions from its own
-- callbacks; it needs "script/include/player.lua" included first. Hooks the including script may define:
-- mantleBlocked(p) (true: no mantling for p now) and mantleQueryMask() (filters the next ray - the crowd's layer).
--
-- When a ledge's edge touches your body between the waist and your reach (its top between MANTLE_MIN_RISE and the
-- reach above your feet) while you move into it, you pull yourself up and over. Works in the air (catching a ledge
-- on a jump or while falling past it) and on the ground (walking into a waist-high edge, e.g. the ring's apron).
-- Hold CROUCH to let go / not mantle. Server, 60 Hz: probe rays from the feet up along the way you move, a ray down
-- onto the ledge top, headroom checks, then the player is driven by velocity: up the face, then over the edge
-- (centred on thin beams, or over a thin rail and down the far side).
-- Every client: the game's own jump-landing pose on the climber (its locomotion's override hook), a first-person dip.
--
-- The LEGACY mantle: Clamber (a separate global mod, Workshop 3835599376: ladders, climbable walls and its own mantle
-- with rail vaults) takes over when the host runs it (climbing.present, polled every second - another mod's init may
-- run after ours): this mantle is then off for the session and stays the fallback without it (the user: "switch to
-- legacy mantle if clamber mod is not detected"; Humans vs Clickers' way - it never sets climbing.off). ring.lua adds
-- the crowd's layer to climbing.raymask; Clamber's climbing.on.<p> counts as mantling (mantleActive) on every
-- machine. Both honour climbing.block.<p> (the Brawl game mode sets it for the knocked, the eliminated, the
-- countdown...): written by the mode, never by the map.

MANTLE_MIN_RISE = 0.35         -- lower ledges: the normal step-up / landing handles them
MANTLE_MIN_RISE_GROUND = 0.55
MANTLE_MAX_RISE = 1.4          -- ~ribcage of a 1.8 m human
MANTLE_REACH = 0.75            -- from the body axis (capsule radius ~0.35-0.4 + a hand's width)
MANTLE_MAX_FALL = 14           -- m/s: falling faster than this, no grab
MANTLE_UP_TIME = 0.16          -- s, plus MANTLE_UP_PER_M per metre of rise (slow enough to read as a climb)
MANTLE_UP_PER_M = 0.18
MANTLE_OVER_SPEED = 3.0
VAULT_LAND = 0.6              -- m past a rail's near face: where a vault comes down
MANTLE_CLIP = "jump_land"      -- reads as a pull-up (picked in-game for Tall Order, 2026-10-01)

-- how high player p can grab (the including script may override it after this file)
function mantleReach(p) return MANTLE_MAX_RISE end

local function mhlen(v) return math.sqrt(v[1] * v[1] + v[3] * v[3]) end

local function mray(p, origin, dir, dist, radius)
	QueryRequire("physical")
	QueryRejectPlayer(p)
	if mantleQueryMask then mantleQueryMask() end          -- (Warehouse Ring: not the crowd)
	return QueryRaycast(origin, dir, dist, radius or 0)
end

local function mFlying(p)
	local ok, f = pcall(GetPlayerParam, "flyMode", p)
	return ok and f == true
end

-- WASD relative to the view (horizontal unit vector), or nil
local function mWish(p)
	local tr = GetPlayerTransform(p)
	local fwd = TransformToParentVec(tr, Vec(0, 0, -1))
	local right = TransformToParentVec(tr, Vec(1, 0, 0))
	local w = Vec(0, 0, 0)
	if InputDown("up", p) then w = VecAdd(w, fwd) end
	if InputDown("down", p) then w = VecSub(w, fwd) end
	if InputDown("right", p) then w = VecAdd(w, right) end
	if InputDown("left", p) then w = VecSub(w, right) end
	w[2] = 0
	if VecLength(w) > 0.1 then return VecNormalize(w) end
	return nil
end

-- which way to probe for a ledge: where the player wants to go, else where they move
local function mMoveDir(p, v)
	local w = mWish(p)
	if w then return w, true end
	local hv = Vec(v[1], 0, v[3])
	if VecLength(hv) > 1.0 then return VecNormalize(hv), false end
	return nil, false
end

-- a grab-able ledge in direction dir within reach? {top=, dist=, thin=, rise=, over=, spot=, edge=} or nil
function mantleFindLedge(p, feet, dir, grounded, reach)
	local best = nil
	local h = 0.25
	while h <= reach - 0.02 do                               -- probe heights every 0.25 m up to the reach
		local hit, d, n = mray(p, VecAdd(feet, Vec(0, h, 0)), dir, MANTLE_REACH, 0.12)
		if hit and math.abs(n[2]) < 0.75 and (not best or d < best) then best = d end
		h = h + 0.25
	end
	if not best then return nil end
	local face = best + 0.12                                 -- the probe is a 0.12 m sphere: the face is that much further
	local above = reach + 0.7
	local tp = VecAdd(feet, VecAdd(VecScale(dir, face + 0.08), Vec(0, above, 0)))
	local hit, d, n = mray(p, tp, Vec(0, -1, 0), above - 0.1, 0)
	if not hit or d < 0.05 or n[2] < 0.6 then return nil end
	local top = tp[2] - d
	local rise = top - feet[2]
	if rise < (grounded and MANTLE_MIN_RISE_GROUND or MANTLE_MIN_RISE) or rise > reach then return nil end
	-- deep enough to stand on, or a thin beam to balance on?
	local tp2 = VecAdd(tp, VecScale(dir, 0.45))
	local hit2, d2 = mray(p, tp2, Vec(0, -1, 0), above + 0.3, 0)
	local thin = not (hit2 and math.abs((tp2[2] - d2) - top) < 0.2)
	local over = thin and face + 0.12 or face + 0.45        -- horizontal travel to the standing spot (thin: its middle)
	local vault = false
	if thin then                                             -- a rope or rail: vault it when there is floor beyond,
		local far = VecAdd(Vec(feet[1], top + 0.3, feet[3]), VecScale(dir, face + VAULT_LAND))   -- below its top
		local hf, df = mray(p, far, Vec(0, -1, 0), 3.0, 0)
		if hf and df > 0.4 then
			local floor = VecAdd(far, Vec(0, 0.3 - df, 0))
			if not mray(p, VecAdd(floor, Vec(0, 0.3, 0)), Vec(0, 1, 0), 1.5, 0.2) then
				vault, over = true, face + VAULT_LAND
			end
		end
	end
	-- room: the way up past the edge, the way over it, and a body's height above the spot
	if mray(p, VecAdd(feet, Vec(0, 1.75, 0)), Vec(0, 1, 0), rise + 0.15, 0.2) then return nil end
	for _, hh in ipairs({0.35, 1.0, 1.65}) do
		if mray(p, Vec(feet[1], top + hh, feet[3]), dir, over + 0.1, 0.15) then return nil end
	end
	local spot = VecAdd(Vec(feet[1], top, feet[3]), VecScale(dir, over))
	if mray(p, VecAdd(spot, Vec(0, 0.3, 0)), Vec(0, 1, 0), 1.5, 0.2) then return nil end
	local edge = VecAdd(Vec(feet[1], top, feet[3]), VecScale(dir, face))
	return {top = top, dist = best, thin = thin, vault = vault, rise = rise, over = over, spot = spot, edge = edge}
end

local M = {players = {}, n = 0, snd = nil}

function mantleServerInit()
	M.snd = {grab = {LoadSound("grab1.ogg"), LoadSound("grab3.ogg")}, land = {LoadSound("plastic/land2.ogg"), LoadSound("plastic/land5.ogg")}}
	shared.mantle = {}
end

local function publish()                                     -- (whole table: nested shared writes are unverified)
	local t = {}
	for p, m in pairs(M.players) do if m.pub then t[p] = m.pub end end
	shared.mantle = t
end

local function endMantle(p, m, cool, vel)
	m.active = false
	m.cool = cool
	m.pub = nil
	SetPlayerVelocity(vel, p)
	publish()
end

local function startMantle(p, m, l, dir, feet)
	m.active, m.phase, m.t, m.dir, m.l = true, 1, 0, dir, l
	M.n = M.n + 1
	m.pub = {n = M.n, dur = MANTLE_UP_TIME + MANTLE_UP_PER_M * l.rise + 0.22, edge = VecCopy(l.edge), dir = VecCopy(dir)}
	publish()
	if M.snd then PlaySound(M.snd.grab[math.random(1, 2)], l.edge, 0.8) end
end

local function driveMantle(p, m, feet, dt)
	local l = m.l
	m.t = m.t + dt
	local dir = m.dir
	if InputDown("crouch", p) then return endMantle(p, m, 0.4, Vec(0, 0, 0)) end
	if m.phase == 1 then
		local T = MANTLE_UP_TIME + MANTLE_UP_PER_M * l.rise
		local target = l.top + 0.07
		if feet[2] >= target - 0.02 then
			m.phase, m.t = 2, 0
		elseif m.t > T + 0.3 then
			return endMantle(p, m, 0.5, Vec(0, 0, 0))               -- blocked: let go
		else
			local vy = (target - feet[2]) / math.max(T - m.t, dt * 2)
			vy = math.max(1.5, math.min(9, vy))
			SetPlayerVelocity(VecAdd(VecScale(dir, 0.5), Vec(0, vy, 0)), p)
			return
		end
	end
	-- phase 2: over the edge to the standing spot
	local rem = VecDot(VecSub(l.spot, feet), dir)
	if rem < 0.04 or m.t > 0.45 then
		if M.snd then PlaySound(M.snd.land[math.random(1, 2)], feet, 0.5) end
		return endMantle(p, m, 0.2, VecScale(dir, l.vault and 1.6 or l.thin and 0 or 1.2))
	end
	local sp = math.min(MANTLE_OVER_SPEED, rem / 0.07)
	local vy = feet[2] < l.top + 0.02 and 1.2 or 0.3
	if l.vault then vy = feet[2] < l.top + 0.12 and 1.6 or 0.2 end      -- (the feet clear the rail on the way over)
	SetPlayerVelocity(VecAdd(VecScale(dir, sp), Vec(0, vy, 0)), p)
end

local CL = {seen = false, pollT = 0}

-- (server.update) Clamber found yet? Polled every second, seen for the session: then this mantle is off (true)
local function climbHandOver(dt)
	CL.pollT = CL.pollT - dt
	if not CL.seen and CL.pollT <= 0 then
		CL.pollT = 1
		if GetBool("climbing.present") then
			CL.seen = true
			shared.ringClimbing = true
			for p, m in pairs(M.players) do if m.active then endMantle(p, m, 0.2, GetPlayerVelocity(p)) end end
		end
	end
	return CL.seen
end

-- server.update (60 Hz)
function mantleServerUpdate(dt)
	if climbHandOver(dt) then return end
	for p in Players() do
		local m = M.players[p]
		if not m then m = {cool = 0}; M.players[p] = m end
		m.cool = m.cool - dt
		local feet = GetPlayerTransform(p).pos
		local v = GetPlayerVelocity(p)
		if mFlying(p) or GetPlayerHealth(p) <= 0 or (mantleBlocked and mantleBlocked(p)) or GetBool("climbing.block." .. p) then
			if m.active then endMantle(p, m, 0.2, v) end
		elseif m.active then
			driveMantle(p, m, feet, dt)
		else
			local grounded = IsPlayerGrounded(p)
			if m.cool <= 0 and GetPlayerVehicle(p) == 0 and not InputDown("crouch", p) then
				local dir, wished = mMoveDir(p, v)
				if dir and v[2] > -MANTLE_MAX_FALL then
					local into = VecDot(Vec(v[1], 0, v[3]), dir)
					local pushing = (wished and (not grounded or InputDown("up", p))) or (not grounded and into > 0.5)
					if pushing then
						local l = mantleFindLedge(p, feet, dir, grounded, mantleReach(p))
						if l then startMantle(p, m, l, dir, feet) end
					end
				end
			end
		end
	end
	for p in PlayersRemoved() do M.players[p] = nil end
end

-- is player p mantling (any machine)? (or climbing with Clamber)
function mantleActive(p)
	return (shared.mantle ~= nil and shared.mantle[p] ~= nil) or (shared.ringClimbing == true and GetBool("climbing.on." .. p))
end

local A = {}                                                  -- per player on this machine: {n, t0, on}

local function mProgress(p, d)
	local a = A[p]
	if not a or a.n ~= d.n then
		a = {n = d.n, t0 = GetTime()}
		A[p] = a
	end
	return math.max(0, math.min(1, (GetTime() - a.t0) / d.dur))
end

-- client.tick: the first-person pull-up dip (returns the camera offset; the caller may fold it into its own camera)
function mantleClientTick(applyCamera)
	local me = GetLocalPlayer()
	local d = shared.mantle and shared.mantle[me]
	if not d then return nil end
	local k = mProgress(me, d)
	local s = math.sin(math.pi * k)
	local off = Transform(Vec(0, -0.22 * s, 0), QuatEuler(-14 * s, 0, 4 * math.sin(2 * math.pi * k)))
	if applyCamera then SetPlayerCameraOffsetTransform(off) end
	return off
end

-- client.postUpdate: every climber's body plays the game's jump-landing pose through the locomotion's override hook
function mantleClientPostUpdate()
	for p, d in pairs(shared.mantle or {}) do
		local k = mProgress(p, d)
		local w = k < 0.8 and 1 or math.max(0, (1 - k) / 0.2)
		SetString("game.override.animation." .. p, MANTLE_CLIP)
		SetFloat("game.override.animation." .. p .. ".weight", w)
		A[p].on = true
	end
	for p, a in pairs(A) do
		if a.on and not (shared.mantle and shared.mantle[p]) then
			a.on = false
			SetString("game.override.animation." .. p, "")
			SetFloat("game.override.animation." .. p .. ".weight", 0)
		end
	end
end
