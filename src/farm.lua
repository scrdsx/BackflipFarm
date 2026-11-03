-- Self-driving backflip farm: rides a safe route (recorded, or a straight shuttle), backflips every
-- FlipSpacing studs, repeats. The server detects tricks from physics; TrickState reports the result.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer
local env = getgenv and getgenv() or _G

local Farm = {
	Config = {
		CruiseSpeed = 40,    -- studs/s while riding the route
		JumpVy = 80,         -- launch speed; airtime = 2*vy/g
		MaxVy = 110,         -- auto-raise ceiling (higher = harder landing, may trigger the game's fall bail)
		FlipSpacing = 45,    -- studs ridden between flips
		Cooldown = 0.4,      -- minimum seconds between flips
		ShuttleLength = 140, -- studs, used when no route is recorded
		TurnRate = 3,        -- rad/s steering at corners and ends
		LandGap = 3.5,       -- ray length counted as grounded
		AutoRaise = true,    -- raise JumpVy when a flip fails to register
		AvoidObstacles = true,
	},
	Stats = { earned = 0, flips = 0, fails = 0, last = "-", direction = "Back", status = "Idle", points = 0, mode = "Shuttle" },
	Enabled = false,
	Recording = false,
	Route = env.__ScrdsxRoute or {},
	Changed = nil,
}

local conns = {}
local flipping, lastEnd, dir, attempt, pending = false, 0, 1, 0, false
local pts, idx, step, fwd = {}, 1, 1, 1
local distSince, lastPos, blockedSince, lastRec = 0, nil, nil, nil
local flipConn

local function changed() if Farm.Changed then Farm.Changed() end end
local function status(s) if Farm.Stats.status ~= s then Farm.Stats.status = s; changed() end end
local function flat(v) return Vector3.new(v.X, 0, v.Z) end

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
	return workspace:Raycast(s.Position, Vector3.new(0, -Farm.Config.LandGap, 0), rayParams(s)) ~= nil
end

-- anything solid within `dist` studs ahead (chest height)?
local function blocked(s, forward, dist)
	local hit = workspace:Raycast(s.Position + Vector3.new(0, 1.8, 0), forward * dist, rayParams(s))
	return hit ~= nil and hit.Instance.CanCollide
end

-- the ride's stabilizers fight our spin: release them for the flip, restore afterwards
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

local function buildPath(s)
	local n = #Farm.Route
	if n >= 2 then
		pts = {}
		for i, p in ipairs(Farm.Route) do pts[i] = p end
		local best, bd = 1, math.huge
		for i, p in ipairs(pts) do
			local d = flat(p - s.Position).Magnitude
			if d < bd then best, bd = i, d end
		end
		idx, step = best, (best >= #pts) and -1 or 1
		Farm.Stats.mode = "Route (" .. n .. " pts)"
	else
		local f = flat(s.CFrame.LookVector) * fwd
		f = f.Magnitude > 0.01 and f.Unit or Vector3.new(0, 0, -1)
		pts = { s.Position, s.Position + f * Farm.Config.ShuttleLength }
		idx, step = 2, -1 -- ride out to the far point, then back
		Farm.Stats.mode = "Shuttle"
	end
	Farm.Stats.points = #pts
end

local function advance()
	local nxt = idx + step
	if nxt < 1 or nxt > #pts then
		step = -step
		nxt = idx + step
	end
	idx = math.clamp(nxt, 1, #pts)
end

local function backflip(s, ahead)
	local cfg = Farm.Config
	flipping, pending = true, true
	attempt += 1
	local myAttempt = attempt
	local airtime = 2 * cfg.JumpVy / workspace.Gravity
	local w = 2 * math.pi / (airtime * 0.85) * dir -- finish the turn before landing
	local restore = releaseStabilizers(s.Parent)
	local hv = ahead * cfg.CruiseSpeed * 0.7 -- slower over the jump = shorter flight
	s.AssemblyLinearVelocity = Vector3.new(hv.X, cfg.JumpVy, hv.Z)
	status("Flipping")

	local turned, t, cfMode = 0, 0, false
	local prevUp = s.CFrame.UpVector
	flipConn = RunService.Heartbeat:Connect(function(dt)
		dt = math.min(dt, 0.05)
		if not Farm.Enabled or not s.Parent or seat() ~= s then
			flipConn:Disconnect()
			restore()
			flipping = false
			status("Idle")
			return
		end
		t += dt
		local right = s.CFrame.RightVector
		if cfMode then
			s.AssemblyAngularVelocity = Vector3.zero
			s.CFrame = s.CFrame * CFrame.Angles(w * dt, 0, 0)
		else
			s.AssemblyAngularVelocity = right * w
		end
		-- measure the real rotation about the right vector
		local up = s.CFrame.UpVector
		turned += math.abs(math.atan2(prevUp:Cross(up):Dot(right), prevUp:Dot(up)))
		prevUp = up
		if not cfMode and t > 0.25 and turned < 0.3 then cfMode = true end -- physics isn't turning it: drive the CFrame
		if turned >= 2 * math.pi * 0.98 or t > airtime + 0.6 then
			flipConn:Disconnect()
			s.AssemblyAngularVelocity = Vector3.zero
			local fl = flat(s.CFrame.LookVector)
			if fl.Magnitude > 0.05 then
				s.CFrame = CFrame.lookAt(s.Position, s.Position + fl.Unit) -- upright, keep yaw
			end
			restore()
			flipping = false
			lastEnd, distSince, lastPos = os.clock(), 0, nil
			status("Landing")
			task.delay(4, function()
				if pending and attempt == myAttempt then
					pending = false
					Farm.Stats.fails += 1
					if cfg.AutoRaise then cfg.JumpVy = math.min(cfg.JumpVy + 5, cfg.MaxVy) end
					status("Missed, retrying")
				end
			end)
		end
	end)
end

local function drive(s, dt)
	local cfg = Farm.Config
	local pos = s.Position
	local to = flat(pts[idx] - pos)
	if to.Magnitude < 8 then advance(); return end
	local want = to.Unit

	local f = flat(s.CFrame.LookVector) * fwd
	if f.Magnitude < 0.05 then return end
	f = f.Unit
	local ang = math.atan2(f:Cross(want).Y, f:Dot(want))
	local rot = math.clamp(ang, -cfg.TurnRate * dt, cfg.TurnRate * dt)
	local cf = s.CFrame
	s.CFrame = CFrame.new(cf.Position) * CFrame.Angles(0, rot, 0) * cf.Rotation
	local nf = flat(s.CFrame.LookVector) * fwd
	if nf.Magnitude < 0.05 then return end
	nf = nf.Unit

	-- obstacle ahead: stop; after a moment turn back along the route
	if cfg.AvoidObstacles and blocked(s, nf, cfg.CruiseSpeed * 0.6 + 6) then
		blockedSince = blockedSince or os.clock()
		local v = s.AssemblyLinearVelocity
		s.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
		status("Blocked, turning back")
		if os.clock() - blockedSince > 0.8 then
			step = -step
			idx = math.clamp(idx + step, 1, #pts)
			blockedSince = nil
		end
		return
	end
	blockedSince = nil

	local speed = cfg.CruiseSpeed * math.clamp(1 - math.abs(ang) / 1.2, 0.35, 1)
	local v = s.AssemblyLinearVelocity
	s.AssemblyLinearVelocity = Vector3.new(nf.X * speed, v.Y, nf.Z * speed)
	status("Riding")

	if lastPos then distSince += flat(pos - lastPos).Magnitude end
	lastPos = pos

	-- flip when far enough from the last one, with room to land before the next turn
	local airtime = 2 * cfg.JumpVy / workspace.Gravity
	local flight = cfg.CruiseSpeed * 0.7 * airtime
	if distSince >= cfg.FlipSpacing and math.abs(ang) < 0.3 and to.Magnitude > flight + 12
		and os.clock() - lastEnd >= cfg.Cooldown and grounded(s)
		and not (cfg.AvoidObstacles and blocked(s, nf, flight + 10)) then
		backflip(s, nf)
	end
end

table.insert(conns, RunService.Heartbeat:Connect(function(dt)
	-- route recording works with the farm off: just ride the path you want
	if Farm.Recording then
		local s = seat()
		if s and (not lastRec or flat(s.Position - lastRec).Magnitude >= 6) then
			table.insert(Farm.Route, s.Position)
			lastRec = s.Position
			env.__ScrdsxRoute = Farm.Route
			Farm.Stats.points = #Farm.Route
			changed()
		end
	end
	if not Farm.Enabled or flipping then return end
	local s = seat()
	if not s then status("Get on your ride"); return end
	if #pts == 0 then buildPath(s) end
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

function Farm:SetEnabled(v)
	if v then
		pts = {}
		local s = seat()
		if s then
			-- which way is "forward"? use the current motion if the ride is moving
			local vel, look = flat(s.AssemblyLinearVelocity), flat(s.CFrame.LookVector)
			if vel.Magnitude > 5 and look.Magnitude > 0.05 then fwd = vel:Dot(look) >= 0 and 1 or -1 end
			buildPath(s)
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
	elseif #self.Route < 2 then
		self:ClearRoute()
		return
	end
	changed()
end

function Farm:ClearRoute()
	self.Route = {}
	env.__ScrdsxRoute = self.Route
	self.Stats.points, self.Stats.mode = 0, "Shuttle"
	changed()
end

function Farm:FlipDirection() dir = -dir; self.Stats.direction = dir == 1 and "Back" or "Front"; changed() end
function Farm:FlipForward() fwd = -fwd end

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
