-- Backflip farm (v2). Rides a loop made of the straightest roads it can find, and as soon as the ride is on the
-- ground with a gentle stretch ahead it does a short wheelie into a backflip, lands, and goes again.
-- One step loop, one trick state machine. The server detects tricks from physics; TrickState reports the result.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local STEP = RunService.PreSimulation or RunService.Heartbeat -- run before physics: steering and velocity apply together
local lp = Players.LocalPlayer

local Farm = {
	Config = {
		CruiseSpeed = 70,    -- studs/s, also the speed through the air
		JumpVy = 85,         -- launch speed; airtime = 2*vy/g
		MaxVy = 120,         -- auto-raise ceiling
		Cooldown = 0.05,     -- seconds between landing and the next trick
		TurnRate = 5,        -- rad/s steering
		LandGap = 10,        -- ray length counted as grounded (the seat sits well above the road)
		AutoRaise = true,    -- raise JumpVy when a flip does not register
		AvoidObstacles = true,
		Wheelie = true,      -- short wheelie before the flip
		WheelieTime = 0.1,   -- seconds the wheelie is held
		WheeliePitch = 35,   -- degrees the nose is raised to
		MaxBend = 70,        -- degrees of route turning a trick may cover (the ride follows the route in the air)
		MaxRouteDist = 250,  -- studs: nearest road must be closer than this
		Loop = false,        -- false: ride the single straightest road back and forth; true: a loop through other roads
	},
	Stats = { earned = 0, flips = 0, fails = 0, last = "-", direction = "Back", status = "Idle", points = 0, mode = "-", gate = "-", road = "-" },
	Enabled = false,
	Changed = nil,
}

local conns = {}
local pts, idx, vdir = {}, 1, nil   -- route points, next point, our travel direction (flat unit vector)
local loop, step, lo, hi = false, 1, 1, 1 -- loop route, or bounce between points lo..hi going `step` (+1/-1)
local fwd, dir = 1, 1               -- which way the seat faces; spin direction (1 = nose up and back)
local attempt, pending, pendingId = 0, false, 0
local lastEnd, lastIdxChange, blockedSince = 0, 0, nil
local searching, retryAt, lastWhy = false, 0, nil
local trick = nil
local lastSeatTry = 0
local roads -- { g = RoadGraph, k = intersection count, straight = ranked straight roads }

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
-- loop: wraps around. Bounce: nil when the next point would leave the stretch lo..hi (the ride turns around there)
local function nextIdx(i)
	if loop then return (i % #pts) + 1 end
	local n = i + step
	if n > hi or n < 1 then return nil end
	if n < lo and i >= lo then return nil end -- leaving the road at its near end (points before lo are the way in)
	return n
end
local function prevIdx()
	if loop then return ((idx - 2) % #pts) + 1 end
	return math.clamp(idx - step, 1, #pts)
end
local function advance()
	local n = nextIdx(idx)
	if not n then step = -step; n = nextIdx(idx) end -- end of the road: turn around
	idx = n or idx
	lastIdxChange = os.clock()
end

-- pure pursuit: the point `L` studs ahead along the route from where we are on it. Steering at it keeps the
-- ride on the road; the further off the line, the closer the aim point.
local function pursuit(pos, L)
	local a, b = flat(pts[prevIdx()]), flat(pts[idx])
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
		local a, b = flat(pts[prevIdx()]), flat(pts[idx])
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

-- roads: pick the loop with the most trickable (gentle) road ---------------------
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

-- longest stretch of a path that stays within ~14 degrees of its heading
local function straightness(path)
	local best, run, start = 0, 0, nil
	for i = 2, #path do
		local d = flat(path[i] - path[i - 1])
		local len = d.Magnitude
		if len > 0.5 then
			d = d.Unit
			if not start then
				start, run = d, len
			elseif start:Dot(d) > 0.97 then
				run += len
			else
				best = math.max(best, run)
				start, run = d, len
			end
		end
	end
	return math.max(best, run)
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

-- fraction of `b` that runs along `a` (a loop that retraces its own road scores high)
local function overlap(a, b)
	local hit, total = 0, 0
	for i = 1, #b, 2 do
		total += 1
		for j = 1, #a, 2 do
			if flat(b[i] - a[j]).Magnitude < 10 then hit += 1 break end
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

-- the single most trickable road near us, ridden back and forth. Returns the points and how to bounce on them.
local function findStraightRoad(pos, R)
	local cfg = Farm.Config
	local g = R.g
	local run, maxBend = runLength(), math.rad(cfg.MaxBend)
	if not R.vecs then
		R.vecs = {}
		for _, road in ipairs(R.data.roads) do
			local v = toVec(road.points)
			if #v >= 3 then R.vecs[#R.vecs + 1] = v end
		end
	end
	local best, bestScore, bestJ, bestDist
	for n, v in ipairs(R.vecs) do
		if n % 8 == 0 then task.wait() end -- spread the search over a few frames
		local j, dj = 1, math.huge
		for i, p in ipairs(v) do
			local d = flat(p - pos).Magnitude
			if d < dj then j, dj = i, d end
		end
		if dj <= math.max(cfg.MaxRouteDist, 600) then
			local score = trickable(v, run, maxBend) - dj * 0.5
			if not bestScore or score > bestScore then best, bestScore, bestJ, bestDist = v, score, j, dj end
		end
	end
	if not best or bestScore <= 0 then return nil, "no straight road near you" end

	local meta = { loop = false, lo = 1, hi = #best }
	local path
	if bestDist > 60 then
		-- ride there along the roads first, then bounce on the straight one
		local ok, leg = pcall(function() return g:route(pos, best[bestJ]) end)
		if not (ok and leg and #leg >= 2) then return nil, "cannot reach the straight road" end
		path = {}
		for _, p in ipairs(leg) do path[#path + 1] = p end
		meta.lo = #path + 1
		for _, p in ipairs(best) do path[#path + 1] = p end
		meta.hi, meta.idx, meta.step = #path, 2, 1
	else
		path = best
		-- start toward whichever end has more road ahead
		local fwdLen, backLen = 0, 0
		for i = bestJ, #best - 1 do fwdLen += flat(best[i + 1] - best[i]).Magnitude end
		for i = 2, bestJ do backLen += flat(best[i] - best[i - 1]).Magnitude end
		meta.step = fwdLen >= backLen and 1 or -1
		meta.idx = math.clamp(bestJ + meta.step, 1, #best)
	end
	local length = 0
	for i = 2, #best do length += flat(best[i] - best[i - 1]).Magnitude end
	meta.label = ("Straight road (%d studs)"):format(length)
	return path, meta
end

-- runs in its own thread (yields between candidates so the game never hitches)
local function findRoute(pos)
	local R, why = loadRoads()
	if not R then return nil, why end
	local g = R.g
	local near = g:closest(pos)
	if not near then return nil, "no road found" end
	if near.distance > Farm.Config.MaxRouteDist then
		return nil, ("nearest road is %d studs away"):format(near.distance)
	end
	if not Farm.Config.Loop then return findStraightRoad(pos, R) end

	if not R.straight then -- rank every road by its longest straight stretch, once
		local list = {}
		for _, road in ipairs(R.data.roads) do
			local v = toVec(road.points)
			if #v >= 3 then list[#list + 1] = { a = v[1], b = v[#v], run = straightness(v) } end
		end
		table.sort(list, function(x, y) return x.run > y.run end)
		R.straight = list
	end

	local here = flat(pos)
	local cands = {}
	for _, r in ipairs(R.straight) do
		if math.min(flat(r.a - pos).Magnitude, flat(r.b - pos).Magnitude) < 1500 then
			cands[#cands + 1] = r
			if #cands >= 12 then break end
		end
	end
	if #cands == 0 then return nil, "no straight roads near you" end

	local function leg(a, b)
		local ok, path = pcall(function() return g:route(a, b) end)
		if ok and path and #path >= 2 then return path end
	end

	local run, maxBend = runLength(), math.rad(Farm.Config.MaxBend)
	local best, bestScore
	for _, r in ipairs(cands) do
		for flip = 0, 1 do
			task.wait() -- spread the search over a few frames
			local A, B = r.a, r.b
			if flip == 1 then A, B = B, A end
			local l1, l2, l3 = leg(pos, A), leg(A, B), leg(B, pos)
			if l1 and l2 and l3 then
				local path, length = {}, 0
				for _, l in ipairs({ l1, l2, l3 }) do
					for i, p in ipairs(l) do
						if not (#path > 0 and i == 1) then -- legs share their joint point
							if #path > 0 then length += flat(p - path[#path]).Magnitude end
							path[#path + 1] = p
						end
					end
				end
				local score = trickable(path, run, maxBend)
					- overlap(l1, l3) * 3000 - overlap(l1, l2) * 1500 - uturns(path) * 4000
				if length > 400 and (not bestScore or score > bestScore) then best, bestScore = path, score end
			end
		end
	end
	if not best then return nil, "no good road loop found" end
	return best, { loop = true, idx = 2, label = "Road loop" }
end

local function startSearch(s)
	if searching or os.clock() < retryAt then return end
	searching = true
	status("Finding the straightest route...")
	local pos = s.Position
	task.spawn(function()
		local path, second = findRoute(pos)
		local why = type(second) == "string" and second or nil
		local meta = type(second) == "table" and second or {}
		searching = false
		if path and Farm.Enabled then
			pts, idx, vdir = path, meta.idx or 2, nil
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
				Farm.Stats.fails += 1
				if Farm.Config.AutoRaise then Farm.Config.JumpVy = math.min(Farm.Config.JumpVy + 5, Farm.Config.MaxVy) end
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
		local S = Farm.Stats
		if name == "Front Flip" then dir = -dir; S.direction = dir == 1 and "Back" or "Front" end -- spun the wrong way
		if name == "Backflip" or name == "Front Flip" then
			S.earned += cash or 0
			S.flips += 1
			S.last = ("%s +$%s"):format(name, tostring(cash))
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
	self.Stats.earned, self.Stats.flips, self.Stats.fails, self.Stats.last = 0, 0, 0, "-"
	changed()
end

function Farm:Destroy()
	self:SetEnabled(false)
	for _, c in ipairs(conns) do c:Disconnect() end
end

return Farm
