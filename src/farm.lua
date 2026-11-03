-- Backflip farm (v3). Rides a continuous circuit built around the straightest road it can find (out along that
-- road, back by a different one), and every time the ride is on the ground with a gentle stretch ahead it does a
-- short wheelie into a backflip, lands, and goes again. One step loop, one trick state machine.
-- The server detects tricks from physics; TrickState reports the result.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local STEP = RunService.PreSimulation or RunService.Heartbeat -- run before physics: steering and velocity apply together
local lp = Players.LocalPlayer

local Farm = {
	Config = {
		CruiseSpeed = 50,    -- studs/s, also the speed through the air. A trick takes ~1.3s whatever the speed, so
		                     -- a lower speed needs less straight road per trick and tricks fit almost everywhere.
		JumpVy = 70,         -- launch speed; airtime = 2*vy/g (auto-tuned)
		MinVy = 45,          -- auto-tune floor
		MaxVy = 120,         -- auto-tune ceiling
		AutoTune = true,     -- find the lowest jump that still counts: lower after a streak, raise after a miss
		Cooldown = 0.05,     -- seconds between landing and the next trick
		TurnRate = 5,        -- rad/s steering
		LandGap = 10,        -- ray length counted as grounded (the seat sits well above the road)
		AvoidObstacles = true,
		Wheelie = true,      -- short wheelie before the flip
		WheelieTime = 0.05,  -- seconds the wheelie is held
		WheeliePitch = 35,   -- degrees the nose is raised to
		MaxBend = 70,        -- degrees of route turning a trick may cover (the ride follows the route in the air)
		MaxRouteDist = 250,  -- studs: nearest road must be closer than this
		Bounce = false,      -- true: ride the straightest road back and forth instead of a circuit
	},
	Stats = { earned = 0, flips = 0, fails = 0, last = "-", direction = "Back", status = "Idle", points = 0, mode = "-", gate = "-", road = "-", startedAt = 0 },
	Enabled = false,
	Changed = nil,
}

local conns = {}
local pts, idx, pidx, vdir = {}, 1, 1, nil -- route points, next point, previous point, our travel direction (flat unit)
local loop, step, lo, hi = false, 1, 1, 1  -- loop: wraps hi -> lo. Bounce: reverses at lo / hi going `step` (+1/-1)
local fwd, dir = 1, 1                      -- which way the seat faces; spin direction (1 = nose up and back)
local attempt, pending, pendingId, streak = 0, false, 0, 0
local lastEnd, lastIdxChange, blockedSince = 0, 0, nil
local searching, retryAt, lastWhy = false, 0, nil
local trick = nil
local lastSeatTry = 0
local roads -- { g = RoadGraph, k = intersection count, data = raw road data, vecs = road polylines }

local function changed() if Farm.Changed then Farm.Changed() end end
local function status(s) if Farm.Stats.status ~= s then Farm.Stats.status = s; changed() end end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- helpers --------------------------------------------------------------------
local function seat()
	local c = lp.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local s = h and h.SeatPart
	if s and s:IsA("VehicleSeat") and h.Health > 0 and not c:GetAttribute("Ragdolled") then return s end
end

local function rayParams(s)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = { lp.Character, s.Parent }
	return p
end

local function grounded(s)
	if math.abs(s.AssemblyLinearVelocity.Y) > 6 then return false end -- still moving up or down fast
	return workspace:Raycast(s.Position, Vector3.new(0, -Farm.Config.LandGap, 0), rayParams(s)) ~= nil
end

-- something steep and solid within `dist` studs ahead (ground and slopes do not count)
local function blocked(s, forward, dist)
	local hit = workspace:Raycast(s.Position + Vector3.new(0, 1.8, 0), forward * dist, rayParams(s))
	return hit ~= nil and hit.Instance.CanCollide and hit.Normal.Y < 0.6
end

-- the ride's stabilizers fight our spin: release them for the trick, restore afterwards
local function releaseStabilizers(model)
	local saved = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BodyGyro") then
			saved[#saved + 1] = { d, "MaxTorque", d.MaxTorque }
			d.MaxTorque = Vector3.zero
		elseif d:IsA("AlignOrientation") then
			saved[#saved + 1] = { d, "Enabled", d.Enabled }
			d.Enabled = false
		end
	end
	return function()
		for _, r in ipairs(saved) do pcall(function() r[1][r[2]] = r[3] end) end
	end
end

-- after a bail or dismount: find our ride, move next to it and sit / press its prompt
local function reseat()
	if os.clock() - lastSeatTry < 2 then return end
	lastSeatTry = os.clock()
	local c = lp.Character
	local hrp = c and c:FindFirstChild("HumanoidRootPart")
	local h = c and c:FindFirstChildOfClass("Humanoid")
	if not (hrp and h) or h.Health <= 0 then status("Waiting to respawn"); return end
	if c:GetAttribute("Ragdolled") then status("Recovering from bail"); return end
	local ride
	local folder = workspace:FindFirstChild("Rides")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:GetAttribute("OwnerUserId") == lp.UserId or m.Name == "Ride_" .. lp.Name then ride = m break end
		end
	end
	local ds = ride and ride:FindFirstChild("DriveSeat")
	if not ds then status("No ride found: spawn it"); return end
	status("Getting back on")
	hrp.CFrame = ds.CFrame * CFrame.new(0, 3, 0)
	pcall(function() ds:Sit(h) end)
	if fireproximityprompt then
		for _, d in ipairs(ride:GetDescendants()) do
			if d:IsA("ProximityPrompt") then pcall(fireproximityprompt, d) end
		end
	end
	vdir, blockedSince = nil, nil
end

-- route following ------------------------------------------------------------
-- loop: wraps hi -> lo (points before lo are the way in). Bounce: nil when the next point would leave lo..hi.
local function nextIdx(i)
	if loop then
		if i >= hi then return lo end
		return i + 1
	end
	local n = i + step
	if n > hi or n < 1 then return nil end
	if n < lo and i >= lo then return nil end
	return n
end

local function advance()
	local n = nextIdx(idx)
	if not n then -- bounce: end of the road, turn around
		step = -step
		pidx = idx
		n = nextIdx(idx)
	else
		pidx = idx
	end
	idx = n or idx
	lastIdxChange = os.clock()
end

-- pure pursuit: the point `L` studs ahead along the route from where we are on it. Steering at it keeps the
-- ride on the road; the further off the line, the closer the aim point.
local function pursuit(pos, L)
	local a, b = flat(pts[pidx]), flat(pts[idx])
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = len2 > 0.01 and math.clamp(flat(pos - a):Dot(ab) / len2, 0, 1) or 1
	local cur = a + ab * t
	local rem, i = math.max(10, L - flat(pos - cur).Magnitude * 1.2), idx
	for _ = 1, #pts + 2 do
		local seg = flat(pts[i]) - cur
		local d = seg.Magnitude
		if d >= rem then return cur + (d > 0.01 and seg.Unit * rem or Vector3.zero), t end
		rem -= d
		cur = flat(pts[i])
		local n = nextIdx(i)
		if not n then return cur, t end
		i = n
	end
	return cur, t
end

-- move along the route and turn vdir toward it at a limited rate; returns the heading error (nil: nothing to steer at)
local function updateDirection(pos, dt)
	local cfg = Farm.Config
	for _ = 1, 80 do -- after a trick the ride is well past where idx points: skip ahead first
		local a, b = flat(pts[pidx]), flat(pts[idx])
		local ab = b - a
		local len2 = ab:Dot(ab)
		if (len2 > 0.01 and flat(pos - a):Dot(ab) / len2 or 1) >= 1 then advance() else break end
	end
	local target, along = pursuit(pos, math.clamp(cfg.CruiseSpeed * 0.8, 15, 60))
	if along >= 0.999 or flat(pts[idx] - pos).Magnitude < 6 then advance() end
	local to = flat(target - pos)
	if to.Magnitude < 1 or not vdir then return nil end
	local want = to.Unit
	local ang = math.atan2(vdir:Cross(want).Y, vdir:Dot(want))
	local rot = math.clamp(ang * math.min(1, dt * 8), -cfg.TurnRate * dt, cfg.TurnRate * dt)
	vdir = (CFrame.Angles(0, rot, 0) * vdir).Unit
	return ang
end

-- total turning over the next `dist` studs of route (radians) and the distance actually covered
local function bendAhead(pos, dist)
	local cur, walked, i = pos, 0, idx
	local prev, total = vdir, 0
	for _ = 1, #pts + 2 do
		local seg = flat(pts[i] - cur)
		local len = seg.Magnitude
		if len > 0.5 then
			local d = seg.Unit
			if prev then total += math.acos(math.clamp(prev:Dot(d), -1, 1)) end
			prev = d
			walked += len
			if walked >= dist then break end
		end
		cur = pts[i]
		local n = nextIdx(i)
		if not n then break end
		i = n
	end
	return total, walked
end

-- roads: build a circuit around the most trickable road ------------------------
local function loadRoads()
	if roads then return roads end
	if not workspace:FindFirstChild("BezierRoads") then return nil, "no Workspace.BezierRoads" end
	local ok, res = pcall(function()
		local RG = require(RS.Modules.Reusables.RoadGraph)
		local data = RG.sample()
		if #data.roads == 0 then error("BezierRoads has no roads") end
		local k = 0
		for _ in pairs(data.intersections) do k += 1 end
		return { g = RG.new(data), k = k, data = data }
	end)
	if not ok then return nil, "load failed: " .. tostring(res) end
	roads = res
	return roads
end

local function toVec(list)
	local out = {}
	for i = 1, #list - 1, 2 do out[#out + 1] = Vector3.new(list[i], 0, list[i + 1]) end
	return out
end

local function pathLength(path)
	local n = 0
	for i = 2, #path do n += flat(path[i] - path[i - 1]).Magnitude end
	return n
end

-- studs of the path from which a trick of length `run` fits (bend over the next `run` studs <= maxBend)
local function trickable(path, run, maxBend)
	local total = 0
	for i = 1, #path - 1 do
		local seg = flat(path[i + 1] - path[i]).Magnitude
		local bend, walked, prev = 0, 0, nil
		for j = i, #path - 1 do
			local d = flat(path[j + 1] - path[j])
			local len = d.Magnitude
			if len > 0.5 then
				d = d.Unit
				if prev then bend += math.acos(math.clamp(prev:Dot(d), -1, 1)) end
				prev = d
				walked += len
				if walked >= run then break end
			end
		end
		if walked >= run and bend <= maxBend then total += seg end
	end
	return total
end

local function uturns(path)
	local n = 0
	for i = 3, #path do
		local a, b = flat(path[i - 1] - path[i - 2]), flat(path[i] - path[i - 1])
		if a.Magnitude > 1 and b.Magnitude > 1 and a.Unit:Dot(b.Unit) < -0.5 then n += 1 end
	end
	return n
end

-- fraction of `b` that runs along `a` (a return path that retraces the road scores high)
local function overlap(a, b)
	local hit, total = 0, 0
	for i = 1, #b, 2 do
		total += 1
		for j = 1, #a, 2 do
			if flat(b[i] - a[j]).Magnitude < 12 then hit += 1 break end
		end
	end
	return total > 0 and hit / total or 0
end

local function runLength()
	local cfg = Farm.Config
	local run = cfg.CruiseSpeed * 2 * cfg.JumpVy / workspace.Gravity
	if cfg.Wheelie then run += cfg.CruiseSpeed * (0.3 + cfg.WheelieTime) end
	return run
end

local function prepRoads(R)
	if R.vecs then return end
	R.vecs = {}
	for ri, road in ipairs(R.data.roads) do
		local v = toVec(road.points)
		if #v >= 3 then R.vecs[#R.vecs + 1] = { v = v, ri = ri } end
	end
end

-- make the graph temporarily dislike road `ri`, so a route back avoids it. Graph points: intersections first,
-- then each road's points in order. Returns a function that puts the weights back.
local function penalizeRoad(R, ri, factor)
	local edges = R.g.edges
	local base = R.k
	for q = 1, ri - 1 do base += #R.data.roads[q].points / 2 end
	local n = #R.data.roads[ri].points / 2
	local saved = {}
	for i = base + 1, base + n - 1 do
		local w = edges[i] and edges[i][i + 1]
		if w then
			saved[#saved + 1] = { i, w }
			edges[i][i + 1] = w * factor
			edges[i + 1][i] = w * factor
		end
	end
	return function()
		for _, r in ipairs(saved) do
			edges[r[1]][r[1] + 1] = r[2]
			edges[r[1] + 1][r[1]] = r[2]
		end
	end
end

local function leg(g, a, b)
	local ok, path = pcall(function() return g:route(a, b) end)
	if ok and path and #path >= 2 then return path end
end

-- ride the single most trickable road back and forth (fallback, or when Bounce is on)
local function findBounce(pos, R)
	local cfg = Farm.Config
	prepRoads(R)
	local run, maxBend = runLength(), math.rad(cfg.MaxBend)
	local best, bestScore, bestJ, bestDist
	for n, r in ipairs(R.vecs) do
		if n % 8 == 0 then task.wait() end
		local j, dj = 1, math.huge
		for i, p in ipairs(r.v) do
			local d = flat(p - pos).Magnitude
			if d < dj then j, dj = i, d end
		end
		if dj <= math.max(cfg.MaxRouteDist, 600) then
			local score = trickable(r.v, run, maxBend) - dj * 0.5
			if not bestScore or score > bestScore then best, bestScore, bestJ, bestDist = r.v, score, j, dj end
		end
	end
	if not best or bestScore <= 0 then return nil, "no straight road near you" end
	local meta = { loop = false, lo = 1, hi = #best, label = ("Back and forth (%d studs)"):format(pathLength(best)) }
	local path
	if bestDist > 60 then
		local e = leg(R.g, pos, best[bestJ])
		if not e then return nil, "cannot reach the straight road" end
		path = {}
		for _, p in ipairs(e) do path[#path + 1] = p end
		meta.lo = #path + 1
		for _, p in ipairs(best) do path[#path + 1] = p end
		meta.hi, meta.idx, meta.pidx, meta.step = #path, 2, 1, 1
	else
		path = best
		local fwdLen, backLen = 0, 0
		for i = bestJ, #best - 1 do fwdLen += flat(best[i + 1] - best[i]).Magnitude end
		for i = 2, bestJ do backLen += flat(best[i] - best[i - 1]).Magnitude end
		meta.step = fwdLen >= backLen and 1 or -1
		meta.idx = math.clamp(bestJ + meta.step, 1, #best)
		meta.pidx = bestJ
	end
	return path, meta
end

-- a circuit: out along a trickable road, back by a different way, round and round
local function findCircuit(pos, R)
	local cfg = Farm.Config
	local g = R.g
	prepRoads(R)
	local run, maxBend = runLength(), math.rad(cfg.MaxBend)

	local ranked = {}
	for n, r in ipairs(R.vecs) do
		if n % 16 == 0 then task.wait() end
		local near = math.huge
		for _, p in ipairs(r.v) do near = math.min(near, flat(p - pos).Magnitude) end
		if near < 1500 then
			local t = trickable(r.v, run, maxBend)
			if t > 0 then ranked[#ranked + 1] = { r = r, t = t } end
		end
	end
	table.sort(ranked, function(x, y) return x.t > y.t end)

	local best, bestScore, bestDesc
	for k = 1, math.min(10, #ranked) do
		local r = ranked[k].r
		for flip = 0, 1 do
			task.wait() -- spread the search over a few frames
			local v = r.v
			if flip == 1 then
				v = {}
				for i = #r.v, 1, -1 do v[#v + 1] = r.v[i] end
			end
			local restore = penalizeRoad(R, r.ri, 60)
			local back = leg(g, v[#v], v[1])
			restore()
			if back and overlap(v, back) < 0.3 then
				local L = {}
				for _, p in ipairs(v) do L[#L + 1] = p end
				for i = 2, #back - 1 do L[#L + 1] = back[i] end -- the ends duplicate the road's own ends
				local len = pathLength(L)
				if len > 350 and uturns(L) == 0 then
					local tr = trickable(L, run, maxBend)
					local score = tr / len * 1000 + tr * 0.1
					if not bestScore or score > bestScore then best, bestScore, bestDesc = L, score, { len = len, frac = tr / len } end
				end
			end
		end
	end
	if not best then return nil, "no good circuit found" end

	-- join the circuit: start at the point nearest to us, riding there along the roads first if it is far
	local j, dj = 1, math.huge
	for i, p in ipairs(best) do
		local d = flat(p - pos).Magnitude
		if d < dj then j, dj = i, d end
	end
	local entry = {}
	if dj > 60 then
		local e = leg(g, pos, best[j])
		if not e then return nil, "cannot reach the circuit" end
		for i = 1, #e - 1 do entry[#entry + 1] = e[i] end
	end
	local path = {}
	for _, p in ipairs(entry) do path[#path + 1] = p end
	for i = 0, #best - 1 do path[#path + 1] = best[((j - 1 + i) % #best) + 1] end -- circuit rotated to start at j
	return path, {
		loop = true, lo = #entry + 1, hi = #path, idx = math.min(2, #path), pidx = 1,
		label = ("Circuit (%d studs, %d%% trickable)"):format(bestDesc.len, bestDesc.frac * 100),
	}
end

-- runs in its own thread (yields between candidates so the game never hitches)
local function findRoute(pos)
	local R, why = loadRoads()
	if not R then return nil, why end
	local near = R.g:closest(pos)
	if not near then return nil, "no road found" end
	if near.distance > Farm.Config.MaxRouteDist then
		return nil, ("nearest road is %d studs away"):format(near.distance)
	end
	if not Farm.Config.Bounce then
		local path, meta = findCircuit(pos, R)
		if path then return path, meta end
	end
	return findBounce(pos, R)
end

local function startSearch(s)
	if searching or os.clock() < retryAt then return end
	searching = true
	status("Finding the best route...")
	local pos = s.Position
	task.spawn(function()
		local path, second = findRoute(pos)
		local why = type(second) == "string" and second or nil
		local meta = type(second) == "table" and second or {}
		searching = false
		if path and Farm.Enabled then
			pts, idx, pidx, vdir = path, meta.idx or 2, meta.pidx or 1, nil
			loop, step, lo, hi = meta.loop == true, meta.step or 1, meta.lo or 1, meta.hi or #path
			lastIdxChange = os.clock()
			Farm.Stats.mode = meta.label or "Road"
			Farm.Stats.points = #path
			Farm.Stats.road = "ok"
			status("Riding")
		elseif not path then
			if lastWhy ~= why then warn("[Scrdsx] road route failed: " .. tostring(why)) end
			lastWhy = why
			Farm.Stats.road = why or "failed"
			status("Road route failed (see Route tab)")
			retryAt = os.clock() + 3
		end
		changed()
	end)
end

-- tricks ---------------------------------------------------------------------
local function finishTrick()
	local T = trick
	trick = nil
	T.restore()
	lastEnd = os.clock()
	status("Riding")
	if T.launched then
		local id = T.id
		task.delay(6, function() -- the server reports "landed"; if it never does, count a miss
			if pending and pendingId == id then
				pending = false
				local cfg = Farm.Config
				Farm.Stats.fails += 1
				streak = 0
				if cfg.AutoTune then cfg.JumpVy = math.min(cfg.JumpVy + 10, cfg.MaxVy) end
				status("Missed, retrying")
			end
		end)
	end
end

local function abortTrick()
	if trick then pcall(trick.restore); trick = nil end
end

-- jump + spin: leave the ground at the ride's speed along the route
local function launch(s)
	local cfg = Farm.Config
	local T = trick
	T.phase, T.t, T.turned, T.launched = "spin", 0, 0, true
	T.prevUp = s.CFrame.UpVector
	T.airtime = 2 * cfg.JumpVy / workspace.Gravity
	T.w = 2 * math.pi / (T.airtime * 0.6) * dir -- finish the turn well before landing
	T.launchAt = os.clock()
	pending, pendingId = true, T.id
	s.AssemblyLinearVelocity = Vector3.new(vdir.X * cfg.CruiseSpeed, cfg.JumpVy, vdir.Z * cfg.CruiseSpeed)
	status("Flipping")
end

local function startTrick(s)
	local cfg = Farm.Config
	if not vdir then
		local f = flat(s.CFrame.LookVector) * fwd
		vdir = f.Magnitude > 0.05 and f.Unit or Vector3.new(0, 0, -1)
	end
	attempt += 1
	trick = { id = attempt, phase = cfg.Wheelie and "wheelie" or "spin", t = 0, restore = releaseStabilizers(s.Parent) }
	if trick.phase == "spin" then launch(s) else status("Wheelie") end
end

local function stepTrick(s, dt)
	local cfg = Farm.Config
	local T = trick
	T.t += dt
	if not vdir then -- the route was reset mid-trick: keep the current heading
		local f = flat(s.CFrame.LookVector) * fwd
		vdir = f.Magnitude > 0.05 and f.Unit or Vector3.new(0, 0, -1)
	end
	if #pts > 0 then updateDirection(s.Position, dt) end -- the ride keeps following the route, in the air too
	local d = vdir
	local vy = s.AssemblyLinearVelocity.Y
	local function horizontal() s.AssemblyLinearVelocity = Vector3.new(d.X * cfg.CruiseSpeed, vy, d.Z * cfg.CruiseSpeed) end

	if T.phase == "wheelie" then
		-- hold the nose up at a set angle (measured in the same rotation direction the flip will use)
		local pitch = dir * math.asin(math.clamp(s.CFrame.LookVector.Y, -1, 1))
		local target = math.rad(cfg.WheeliePitch)
		local err = target * math.min(T.t / 0.2, 1) - pitch
		s.AssemblyAngularVelocity = s.CFrame.RightVector * dir * math.clamp(err * 10, -5, 5)
		horizontal()
		if pitch > math.rad(80) then -- going over: abort and level out
			s.AssemblyAngularVelocity = Vector3.zero
			s.CFrame = CFrame.lookAt(s.Position, s.Position + d * fwd)
			T.restore()
			trick = nil
			lastEnd = os.clock()
			status("Wheelie too steep, aborted")
			return
		end
		if pitch >= target * 0.8 then T.held = T.held or T.t end
		if (T.held and T.t - T.held >= cfg.WheelieTime) or T.t > 1.0 then launch(s) end
		return
	end

	if T.phase == "spin" then
		horizontal()
		local right = s.CFrame.RightVector
		s.AssemblyAngularVelocity = right * T.w
		-- measure the real rotation about the right vector
		local up = s.CFrame.UpVector
		T.turned += math.abs(math.atan2(T.prevUp:Cross(up):Dot(right), T.prevUp:Dot(up)))
		T.prevUp = up
		-- stay on schedule: if physics turns it too slowly, rotate the missing part directly so the flip always completes
		local deficit = math.min(math.abs(T.w) * T.t, 2 * math.pi) - T.turned
		if deficit > 0.04 then s.CFrame = s.CFrame * CFrame.Angles(math.sign(T.w) * deficit * 0.6, 0, 0) end
		if T.turned >= 2 * math.pi or T.t > T.airtime + 0.6 then T.phase = "land" end
		return
	end

	-- landing: hold the ride level, facing along the route, until it touches down
	horizontal()
	s.AssemblyAngularVelocity = Vector3.zero
	s.CFrame = CFrame.lookAt(s.Position, s.Position + d * fwd)
	local now = os.clock()
	if now >= T.launchAt + T.airtime + 0.1 or (now > T.launchAt + 0.5 and grounded(s)) then finishTrick() end
end

-- riding ---------------------------------------------------------------------
local function stepRide(s, dt)
	local cfg = Farm.Config
	local pos = s.Position
	if os.clock() - lastIdxChange > 8 then -- no progress along the route: circling or stuck
		lastIdxChange = os.clock()
		pts = {}
		status("Stuck, picking a new route")
		return
	end
	if not vdir then
		local f = flat(s.CFrame.LookVector) * fwd
		if f.Magnitude < 0.05 then return end
		vdir = f.Unit
	end
	local ang = updateDirection(pos, dt)
	if not ang then return end

	-- face the ride along its direction of travel (yaw only; pitch and roll are left alone)
	local cf = s.CFrame
	local look = flat(cf.LookVector) * fwd
	if look.Magnitude > 0.05 then
		local dyaw = math.atan2(look.Unit:Cross(vdir).Y, look.Unit:Dot(vdir))
		s.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, dyaw, 0) * cf.Rotation
	end

	-- something right ahead: stop and wait; after a while pick a fresh route
	if cfg.AvoidObstacles and blocked(s, vdir, cfg.CruiseSpeed * 0.6 + 6) then
		blockedSince = blockedSince or os.clock()
		local v = s.AssemblyLinearVelocity
		s.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
		status("Blocked, waiting")
		if os.clock() - blockedSince > 5 then pts = {}; blockedSince = nil end
		return
	end
	blockedSince = nil

	-- same speed all the way; only slow for sharp corners
	local speed = cfg.CruiseSpeed * math.clamp(1 - math.abs(ang) / 1.4, 0.5, 1)
	local v = s.AssemblyLinearVelocity
	s.AssemblyLinearVelocity = Vector3.new(vdir.X * speed, v.Y, vdir.Z * speed)
	status("Riding")

	-- a trick as soon as the ride is on the ground and the route ahead is not a sharp corner
	local run = runLength()
	local gate
	if math.abs(ang) >= 0.6 then gate = "turning"
	elseif os.clock() - lastEnd < cfg.Cooldown then gate = "cooldown"
	elseif not grounded(s) then gate = "not grounded"
	else
		local bend, walked = bendAhead(pos, run + 10)
		if walked < run + 10 then gate = "end of road, turning around"
		elseif bend > math.rad(cfg.MaxBend) then gate = "corner ahead, waiting" end
	end
	if Farm.Stats.gate ~= (gate or "go") then Farm.Stats.gate = gate or "go"; changed() end
	if not gate then startTrick(s) end
end

table.insert(conns, STEP:Connect(function(dt)
	if not Farm.Enabled and not trick then return end -- a test flip runs with the farm off
	dt = math.min(dt, 0.05)
	local s = seat()
	if not s then
		abortTrick()
		if Farm.Enabled then reseat() end
		return
	end
	if trick then stepTrick(s, dt); return end
	if #pts == 0 then startSearch(s); return end
	stepRide(s, dt)
end))

task.spawn(function()
	local ev = RS:WaitForChild("Remotes"):WaitForChild("Tricks"):WaitForChild("TrickState")
	table.insert(conns, ev.OnClientEvent:Connect(function(state, name, cash)
		if state ~= "landed" then return end
		pending = false
		local S, cfg = Farm.Stats, Farm.Config
		if name == "Front Flip" then dir = -dir; S.direction = dir == 1 and "Back" or "Front" end -- spun the wrong way
		if name == "Backflip" or name == "Front Flip" then
			S.earned += cash or 0
			S.flips += 1
			S.last = ("%s +$%s"):format(name, tostring(cash))
			streak += 1
			if cfg.AutoTune and streak >= 6 then -- a clean streak: try a lower, faster jump
				cfg.JumpVy = math.max(cfg.JumpVy - 5, cfg.MinVy)
				streak = 0
			end
		end
		changed()
	end))
end)

-- API ------------------------------------------------------------------------
function Farm:SetEnabled(v)
	abortTrick()
	pts, vdir, blockedSince = {}, nil, nil
	if v then
		local s = seat()
		if s then
			-- which way is "forward"? use the current motion if the ride is moving
			local vel, look = flat(s.AssemblyLinearVelocity), flat(s.CFrame.LookVector)
			if vel.Magnitude > 5 and look.Magnitude > 0.05 then fwd = vel:Dot(look) >= 0 and 1 or -1 end
		end
		lastEnd = 0
		if self.Stats.startedAt == 0 then self.Stats.startedAt = os.clock() end
	end
	self.Enabled = v
	status(v and (seat() and "Riding" or "Get on your ride") or "Idle")
end

function Farm:RebuildPath() pts, vdir = {}, nil end

-- fire one trick right now (for testing the spin without waiting for the route)
function Farm:TestFlip()
	local s = seat()
	if not s or trick then return end
	startTrick(s)
end

function Farm:FlipDirection() dir = -dir; self.Stats.direction = dir == 1 and "Back" or "Front"; changed() end
function Farm:FlipForward() fwd = -fwd; vdir = nil end

function Farm:Reset()
	local S = self.Stats
	S.earned, S.flips, S.fails, S.last = 0, 0, 0, "-"
	S.startedAt = self.Enabled and os.clock() or 0
	changed()
end

function Farm:Destroy()
	self:SetEnabled(false)
	for _, c in ipairs(conns) do c:Disconnect() end
end

return Farm
