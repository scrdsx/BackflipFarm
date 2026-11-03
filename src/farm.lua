-- Self-driving backflip farm: rides a safe route (saved to file, or a straight shuttle), pops a held wheelie,
-- backflips out of it, levels the ride for landing, then carries on. The server detects tricks from physics;
-- TrickState reports the result.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local STEP = RunService.PreSimulation or RunService.Heartbeat

local lp = Players.LocalPlayer
local env = getgenv and getgenv() or _G
local ROUTE_FILE = "ScrdsxBackflipRoute.json"

local Farm = {
	Config = {
		CruiseSpeed = 70,    -- studs/s while riding the route
		JumpVy = 90,         -- launch speed; airtime = 2*vy/g
		MaxVy = 120,         -- auto-raise ceiling (higher = harder landing, may trigger the game's fall bail)
		FlipSpacing = 0,     -- studs ridden between tricks
		Cooldown = 0.15,      -- minimum seconds between tricks
		ShuttleLength = 160, -- studs, used when no route is saved
		TurnRate = 5,        -- rad/s steering at corners and ends
		LandGap = 10,        -- ray length counted as grounded (the seat sits well above the road)
		AutoRaise = true,    -- raise JumpVy when a flip fails to register
		AvoidObstacles = true,
		Wheelie = true,      -- hold a wheelie, then backflip out of it
		WheelieTime = 0.15,  -- seconds the wheelie is held before the flip
		WheeliePitch = 40,   -- degrees the nose is held at
		LoopRoute = true,    -- loop when the route's ends meet, otherwise ride it back and forth
		MaxRouteDist = 250,  -- refuse to drive if the route is farther than this from you
		UseRoads = true,     -- build the route from the game's road network (no recording needed)
	},
	Stats = { earned = 0, flips = 0, fails = 0, last = "-", direction = "Back", status = "Idle", points = 0, mode = "Shuttle", gate = "-", road = "-" },
	Enabled = false,
	Recording = false,
	Route = {},
	Changed = nil,
}

local conns = {}
local flipping, lastEnd, dir, attempt, pending = false, 0, 1, 0, false
local pts, idx, step, fwd, loop = {}, 1, 1, 1, false
local distSince, lastPos, blockedSince, lastRec, pathRetry = 0, nil, nil, nil, 0
local flipConn
local searching = false

local function changed() if Farm.Changed then Farm.Changed() end end
local function status(s) if Farm.Stats.status ~= s then Farm.Stats.status = s; changed() end end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end

-- route persistence ----------------------------------------------------------
local function saveRoute()
	pcall(function()
		local t = {}
		for i, p in ipairs(Farm.Route) do t[i] = { p.X, p.Y, p.Z } end
		writefile(ROUTE_FILE, HttpService:JSONEncode(t))
	end)
end

local function loadRoute()
	local ok, res = pcall(function()
		if isfile and isfile(ROUTE_FILE) then return HttpService:JSONDecode(readfile(ROUTE_FILE)) end
	end)
	if ok and type(res) == "table" then
		local r = {}
		for i, p in ipairs(res) do r[i] = Vector3.new(p[1], p[2], p[3]) end
		return r
	end
end

Farm.Route = env.__ScrdsxRoute or loadRoute() or {}
env.__ScrdsxRoute = Farm.Route
if #Farm.Route >= 2 then
	Farm.Stats.points = #Farm.Route
	Farm.Stats.mode = "Saved route (" .. #Farm.Route .. " pts)"
end

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
	if math.abs(s.AssemblyLinearVelocity.Y) > 6 then return false end -- already in the air
	return workspace:Raycast(s.Position, Vector3.new(0, -Farm.Config.LandGap, 0), rayParams(s)) ~= nil
end

-- anything solid within `dist` studs ahead (chest height)?
local function blocked(s, forward, dist)
	local hit = workspace:Raycast(s.Position + Vector3.new(0, 1.8, 0), forward * dist, rayParams(s))
	return hit ~= nil and hit.Instance.CanCollide
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

-- route walking --------------------------------------------------------------
local function nextIdx(i)
	if loop then return (i % #pts) + 1 end
	local n = i + step
	if n < 1 or n > #pts then return nil end
	return n
end

local function advance()
	local n = nextIdx(idx)
	if not n then step = -step; n = idx + step end
	idx = math.clamp(n, 1, #pts)
end

-- walk the route ahead of `pos` for `dist` studs: the point reached, distance walked, and whether the route ended first
local function lookahead(pos, dist)
	local cur, walked, i = pos, 0, idx
	for _ = 1, #pts + 2 do
		local p = pts[i]
		walked += flat(p - cur).Magnitude
		cur = p
		if walked >= dist then return cur, walked, false end
		local n = nextIdx(i)
		if not n then return cur, walked, true end
		i = n
	end
	return cur, walked, false
end

-- road network: the game's own RoadGraph module (Workspace.BezierRoads) can path between any two points
local roadCache
local function getRoads()
	if roadCache then return roadCache end
	if not workspace:FindFirstChild("BezierRoads") then return nil, "no Workspace.BezierRoads" end
	local ok, res = pcall(function()
		local RG = require(RS.Modules.Reusables.RoadGraph)
		local data = RG.sample()
		if #data.roads == 0 then error("BezierRoads has no roads") end
		return RG.new(data)
	end)
	if ok then roadCache = res; return res end
	return nil, "load failed: " .. tostring(res)
end

-- longest stretch of a path that stays within ~14 degrees of its heading (long straights suit the trick run)
local function straightness(path)
	local best, run, startDir = 0, 0, nil
	for i = 2, #path do
		local d = flat(path[i] - path[i - 1])
		local len = d.Magnitude
		if len > 0.5 then
			d = d.Unit
			if not startDir then
				startDir, run = d, len
			elseif startDir:Dot(d) > 0.97 then
				run += len
			else
				best = math.max(best, run)
				startDir, run = d, len
			end
		end
	end
	return math.max(best, run)
end

-- a long loop on the roads: start -> A -> B -> start, picked for long straight stretches
local function roadPath(pos)
	local g, why = getRoads()
	if not g then return nil, why end
	local near = g:closest(pos)
	if not near then return nil, "no road found" end
	if near.distance > Farm.Config.MaxRouteDist then
		return nil, ("nearest road is %d studs away"):format(near.distance)
	end
	local here = Vector2.new(pos.X, pos.Z)
	local cands = {}
	for _, p in ipairs(g.points) do
		local d = (p - here).Magnitude
		if d > 250 and d < 1500 then cands[#cands + 1] = p end
	end
	if #cands < 2 then return nil, "not enough road around you" end
	local function v3(p) return Vector3.new(p.X, 0, p.Y) end
	local function leg(a, b)
		local ok, path = pcall(function() return g:route(a, b) end)
		if ok and path and #path >= 2 then return path end
	end
	local best, bestScore
	for _ = 1, 10 do
		task.wait() -- spread the search over a few frames
		local A, B = cands[math.random(#cands)], cands[math.random(#cands)]
		if (A - B).Magnitude > 250 then
			local l1, l2, l3 = leg(pos, v3(A)), leg(v3(A), v3(B)), leg(v3(B), pos)
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
				local score = straightness(path) + length * 0.05
				if not bestScore or score > bestScore then best, bestScore = path, score end
			end
		end
	end
	if not best then return nil, "no road loop found" end
	return best
end

local function buildPath(s)
	local cfg = Farm.Config
	if cfg.UseRoads then
		local path, why = roadPath(s.Position)
		if path then
			pts = path
			loop, idx, step = true, 2, 1 -- one long loop on the roads
			Farm.Stats.mode = "Road loop (" .. #pts .. " pts)"
			Farm.Stats.points = #pts
			Farm.Stats.road = "ok"
			changed()
			return true
		end
		-- no silent fallback: riding some other route unseen is what we are avoiding
		if Farm.Stats.road ~= why then warn("[Scrdsx] road route failed: " .. tostring(why)) end -- once per reason
		Farm.Stats.road = why or "failed"
		status("Road route failed (see Route tab)")
		return false
	end
	local n = #Farm.Route
	if n >= 2 then
		local best, bd = 1, math.huge
		for i, p in ipairs(Farm.Route) do
			local d = flat(p - s.Position).Magnitude
			if d < bd then best, bd = i, d end
		end
		if bd > cfg.MaxRouteDist then
			status(("Too far from route (%d studs)"):format(bd))
			return false
		end
		pts = {}
		for i, p in ipairs(Farm.Route) do pts[i] = p end
		loop = cfg.LoopRoute and flat(pts[1] - pts[n]).Magnitude < 40
		idx, step = best, (best >= #pts and not loop) and -1 or 1
		Farm.Stats.mode = (loop and "Loop" or "Route") .. " (" .. n .. " pts)"
	else
		local f = flat(s.CFrame.LookVector) * fwd
		f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, -1)
		pts = { s.Position, s.Position + f * cfg.ShuttleLength }
		loop, idx, step = false, 2, -1 -- ride out to the far point, then back
		Farm.Stats.mode = "Shuttle"
	end
	Farm.Stats.points = #pts
	changed()
	return true
end

-- getting back on ------------------------------------------------------------
local lastSeatTry = 0
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
	local rides = workspace:FindFirstChild("Rides")
	if rides then
		for _, m in ipairs(rides:GetChildren()) do
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
	distSince, lastPos, blockedSince = 0, nil, nil
end

-- tricks ---------------------------------------------------------------------
local function endTrick(restore)
	restore()
	flipping = false
	lastEnd, distSince, lastPos = os.clock(), 0, nil
end

-- backflip: jump + spin at full ride speed, hold the ride level until it lands
local function backflip(s, ahead, restoreIn)
	local cfg = Farm.Config
	flipping, pending = true, true
	attempt += 1
	local myAttempt = attempt
	local airtime = 2 * cfg.JumpVy / workspace.Gravity
	local w = 2 * math.pi / (airtime * 0.6) * dir -- finish the turn well before landing
	local restore = restoreIn or releaseStabilizers(s.Parent)
	local hv = ahead * cfg.CruiseSpeed -- same speed as the ride
	s.AssemblyLinearVelocity = Vector3.new(hv.X, cfg.JumpVy, hv.Z)
	status("Flipping")

	local turned, t, landUntil = 0, 0, nil
	local prevUp = s.CFrame.UpVector
	flipConn = STEP:Connect(function(dt)
		dt = math.min(dt, 0.05)
		if not Farm.Enabled or not s.Parent or seat() ~= s then
			flipConn:Disconnect()
			restore()
			flipping = false
			status("Idle")
			return
		end
		t += dt
		if landUntil then
			-- landing assist: keep the ride level until it touches down
			s.AssemblyAngularVelocity = Vector3.zero
			local fl = flat(s.CFrame.LookVector)
			if fl.Magnitude > 0.05 then s.CFrame = CFrame.lookAt(s.Position, s.Position + fl.Unit) end
			if os.clock() > landUntil then
				flipConn:Disconnect()
				endTrick(restore)
				status("Landing")
				task.delay(6, function()
					if pending and attempt == myAttempt then
						pending = false
						Farm.Stats.fails += 1
						if cfg.AutoRaise then cfg.JumpVy = math.min(cfg.JumpVy + 5, cfg.MaxVy) end
						status("Missed, retrying")
					end
				end)
			end
			return
		end
		local right = s.CFrame.RightVector
		s.AssemblyAngularVelocity = right * w
		-- measure the real rotation about the right vector
		local up = s.CFrame.UpVector
		turned += math.abs(math.atan2(prevUp:Cross(up):Dot(right), prevUp:Dot(up)))
		prevUp = up
		-- stay on schedule: if physics turns it too slowly, rotate the missing part directly so the flip always completes
		local deficit = math.min(math.abs(w) * t, 2 * math.pi) - turned
		if deficit > 0.04 then s.CFrame = s.CFrame * CFrame.Angles(math.sign(w) * deficit * 0.6, 0, 0) end
		if turned >= 2 * math.pi or t > airtime + 0.6 then
			landUntil = os.clock() + math.max(0.2, airtime - t) + 0.12
		end
	end)
end

-- wheelie: nose up while riding at full speed, then straight into the backflip (no stopping)
local function wheelieThenFlip(s, ahead)
	local cfg = Farm.Config
	flipping = true
	status("Wheelie")
	local restore = releaseStabilizers(s.Parent)
	local hv = ahead * cfg.CruiseSpeed
	local target = math.rad(cfg.WheeliePitch)
	local t, held = 0, nil
	flipConn = STEP:Connect(function(dt)
		dt = math.min(dt, 0.05)
		if not Farm.Enabled or not s.Parent or seat() ~= s then
			flipConn:Disconnect()
			restore()
			flipping = false
			status("Idle")
			return
		end
		t += dt
		-- pitch measured in the same rotation direction the backflip will use
		local pitch = dir * math.asin(math.clamp(s.CFrame.LookVector.Y, -1, 1))
		local err = target * math.min(t / 0.25, 1) - pitch
		s.AssemblyAngularVelocity = s.CFrame.RightVector * dir * math.clamp(err * 10, -5, 5)
		local v = s.AssemblyLinearVelocity
		s.AssemblyLinearVelocity = Vector3.new(hv.X, v.Y, hv.Z) -- keep the ride speed
		if pitch > math.rad(80) then -- going over: abort, level out
			flipConn:Disconnect()
			s.AssemblyAngularVelocity = Vector3.zero
			local fl = flat(s.CFrame.LookVector)
			if fl.Magnitude > 0.05 then s.CFrame = CFrame.lookAt(s.Position, s.Position + fl.Unit) end
			endTrick(restore)
			status("Wheelie too steep, aborted")
			return
		end
		if pitch >= target * 0.8 then held = held or t end
		if (held and t - held >= cfg.WheelieTime) or t > 1.2 then
			flipConn:Disconnect()
			backflip(s, ahead, restore)
		end
	end)
end

local function startTrick(s, ahead)
	if Farm.Config.Wheelie then wheelieThenFlip(s, ahead) else backflip(s, ahead) end
end

-- driving --------------------------------------------------------------------
local function prevIdx()
	if loop then return ((idx - 2) % #pts) + 1 end
	return math.clamp(idx - step, 1, #pts)
end

-- pure pursuit: the point `L` studs ahead along the path, measured from where we are on it.
-- Steering at that point keeps the ride on the road instead of cutting corners between points.
local function pursuit(pos, L)
	local a, b = flat(pts[prevIdx()]), flat(pts[idx])
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = len2 > 0.01 and math.clamp(flat(pos - a):Dot(ab) / len2, 0, 1) or 1
	local cur = a + ab * t
	local rem, i = L, idx
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

local function drive(s, dt)
	local cfg = Farm.Config
	local pos = s.Position
	local target, along = pursuit(pos, math.clamp(cfg.CruiseSpeed * 0.8, 15, 60))
	if along >= 0.999 or flat(pts[idx] - pos).Magnitude < 6 then advance() end
	local to = flat(target - pos)
	if to.Magnitude < 1 then return end
	local want = to.Unit

	local f = flat(s.CFrame.LookVector) * fwd
	if f.Magnitude < 0.05 then return end
	f = f.Unit
	local ang = math.atan2(f:Cross(want).Y, f:Dot(want))
	local rot = math.clamp(ang * math.min(1, dt * 8), -cfg.TurnRate * dt, cfg.TurnRate * dt)
	local cf = s.CFrame
	s.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, rot, 0) * cf.Rotation
	local nf = flat(s.CFrame.LookVector) * fwd
	if nf.Magnitude < 0.05 then return end
	nf = nf.Unit

	-- obstacle ahead: stop and wait; a ping-pong route turns back, a loop waits then picks a fresh route
	if cfg.AvoidObstacles and blocked(s, nf, cfg.CruiseSpeed * 0.6 + 6) then
		blockedSince = blockedSince or os.clock()
		local v = s.AssemblyLinearVelocity
		s.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
		status("Blocked, waiting")
		if os.clock() - blockedSince > (loop and 5 or 0.8) then
			if loop then
				pts = {} -- new route from here
			else
				step = -step
				idx = math.clamp(idx + step, 1, #pts)
			end
			blockedSince = nil
		end
		return
	end
	blockedSince = nil

	-- same speed all the way; only slow for sharp corners
	local speed = cfg.CruiseSpeed * math.clamp(1 - math.abs(ang) / 1.4, 0.5, 1)
	local v = s.AssemblyLinearVelocity
	s.AssemblyLinearVelocity = Vector3.new(nf.X * speed, v.Y, nf.Z * speed)
	status("Riding")

	if lastPos then distSince += flat(pos - lastPos).Magnitude end
	lastPos = pos

	-- trick when far enough from the last one, with a straight, clear run for the wheelie + flight
	local airtime = 2 * cfg.JumpVy / workspace.Gravity
	local run = cfg.CruiseSpeed * airtime
	if cfg.Wheelie then run += cfg.CruiseSpeed * (0.4 + cfg.WheelieTime) end
	local gate
	if distSince < cfg.FlipSpacing then gate = ("riding %d/%d studs"):format(distSince, cfg.FlipSpacing)
	elseif math.abs(ang) >= 0.3 then gate = "turning"
	elseif os.clock() - lastEnd < cfg.Cooldown then gate = "cooldown"
	elseif not grounded(s) then gate = "not grounded"
	elseif cfg.AvoidObstacles and blocked(s, nf, run + 10) then gate = "obstacle ahead"
	end
	if not gate then
		local pt, walked, atEnd = lookahead(pos, run + 12)
		if atEnd and walked < run + 12 then gate = "end of route too close"
		elseif flat(pt - pos).Magnitude < walked * 0.9 then gate = "curve ahead" end
	end
	if Farm.Stats.gate ~= (gate or "go") then Farm.Stats.gate = gate or "go"; changed() end
	if not gate then startTrick(s, nf) end
end

table.insert(conns, STEP:Connect(function(dt)
	-- route recording works with the farm off: just ride the path you want
	if Farm.Recording then
		local s = seat()
		if s and (not lastRec or flat(s.Position - lastRec).Magnitude >= 6) then
			table.insert(Farm.Route, s.Position)
			lastRec = s.Position
			Farm.Stats.points = #Farm.Route
			changed()
		end
	end
	if not Farm.Enabled or flipping or Farm.Recording then return end
	local s = seat()
	if not s then reseat(); return end
	if #pts == 0 then
		if searching or os.clock() < pathRetry then return end
		searching = true
		status("Finding route...")
		task.spawn(function()
			local ok = buildPath(s)
			searching = false
			if not ok then pathRetry = os.clock() + 2 end
		end)
		return
	end
	drive(s, math.min(dt, 0.05))
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
	pts = {}
	if v then
		local s = seat()
		if s then
			-- which way is "forward"? use the current motion if the ride is moving
			local vel, look = flat(s.AssemblyLinearVelocity), flat(s.CFrame.LookVector)
			if vel.Magnitude > 5 and look.Magnitude > 0.05 then fwd = vel:Dot(look) >= 0 and 1 or -1 end
		end
		distSince, lastPos, blockedSince = 0, nil, nil
	else
		if flipConn then flipConn:Disconnect() end
		flipping = false
	end
	self.Enabled = v
	status(v and (seat() and "Riding" or "Get on your ride") or "Idle")
end

function Farm:SetRecording(v)
	self.Recording = v
	if v then
		self.Route = {}
		env.__ScrdsxRoute = self.Route
		lastRec = nil
		self.Stats.points = 0
		self.Stats.mode = "Recording..."
	elseif #self.Route < 2 then
		self:ClearRoute()
		return
	else
		saveRoute()
		pts = {} -- rebuild from the new route
		self.Stats.points = #self.Route
		self.Stats.mode = "Saved route (" .. #self.Route .. " pts)"
	end
	changed()
end

function Farm:ClearRoute()
	self.Route = {}
	env.__ScrdsxRoute = self.Route
	pts = {}
	pcall(function() if delfile and isfile and isfile(ROUTE_FILE) then delfile(ROUTE_FILE) end end)
	self.Stats.points, self.Stats.mode = 0, "Shuttle"
	changed()
end

-- fire one trick right now (for testing without waiting for the route)
function Farm:TestFlip()
	local s = seat()
	if not s or flipping then return end
	local nf = flat(s.CFrame.LookVector) * fwd
	nf = nf.Magnitude > 0.05 and nf.Unit or Vector3.new(0, 0, -1)
	self.Enabled = true
	startTrick(s, nf)
end

function Farm:RebuildPath() pts = {} end

function Farm:FlipDirection() dir = -dir; self.Stats.direction = dir == 1 and "Back" or "Front"; changed() end
function Farm:FlipForward() fwd = -fwd; pts = {} end

function Farm:Reset()
	self.Stats.earned, self.Stats.flips, self.Stats.fails, self.Stats.last = 0, 0, 0, "-"
	changed()
end

function Farm:Destroy()
	self:SetEnabled(false)
	self.Recording = false
	for _, c in ipairs(conns) do c:Disconnect() end
end

return Farm
