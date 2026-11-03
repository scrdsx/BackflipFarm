-- Backflip autofarm logic. Server detects tricks from physics; TrickState reports air/landing/landed.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RS = game:GetService("ReplicatedStorage")

local lp = Players.LocalPlayer

local Farm = {
	Config = {
		MinSpeed = 8,     -- studs/s needed before a launch
		JumpVy = 70,      -- launch speed; airtime = 2*vy/g
		MaxVy = 140,      -- auto-raise ceiling
		Cooldown = 0.6,   -- seconds between flips
		LandGap = 3.5,    -- ray length counted as grounded
		AutoRaise = true, -- raise JumpVy when a flip fails to register
	},
	Stats = { earned = 0, flips = 0, fails = 0, last = "-", direction = "Back", status = "Idle" },
	Enabled = false,
	Changed = nil, -- callback fired when stats change
}

local conns = {}
local flipping, lastEnd, dir, attempt, pending = false, 0, 1, 0, false
local flipConn

local function changed() if Farm.Changed then Farm.Changed() end end
local function status(s) Farm.Stats.status = s; changed() end

local function seat()
	local c = lp.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local s = h and h.SeatPart
	if s and s:IsA("VehicleSeat") and h.Health > 0 and not c:GetAttribute("Ragdolled") then return s end
end

local function grounded(s)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = { lp.Character, s.Parent }
	return workspace:Raycast(s.Position, Vector3.new(0, -Farm.Config.LandGap, 0), p) ~= nil
end

local function backflip(s)
	local cfg = Farm.Config
	flipping, pending = true, true
	attempt += 1
	local myAttempt = attempt
	local airtime = 2 * cfg.JumpVy / workspace.Gravity
	local w = 2 * math.pi / (airtime * 0.85) * dir -- finish the turn before landing
	local v = s.AssemblyLinearVelocity
	s.AssemblyLinearVelocity = Vector3.new(v.X, cfg.JumpVy, v.Z)
	status("Flipping")
	local turned = 0
	flipConn = RunService.Heartbeat:Connect(function(dt)
		if not Farm.Enabled or not s.Parent or seat() ~= s then
			flipConn:Disconnect(); flipping = false; status("Idle"); return
		end
		-- positive spin about the right vector tips the nose up and back
		s.AssemblyAngularVelocity = s.CFrame.RightVector * w
		turned += math.abs(w) * dt
		if turned >= 2 * math.pi then
			flipConn:Disconnect()
			s.AssemblyAngularVelocity = Vector3.zero
			local look = s.CFrame.LookVector
			s.CFrame = CFrame.lookAt(s.Position, s.Position + Vector3.new(look.X, 0, look.Z).Unit) -- upright, keep yaw
			flipping = false
			lastEnd = os.clock()
			status("Landing")
			task.delay(4, function()
				if pending and attempt == myAttempt then
					pending = false
					Farm.Stats.fails += 1
					if cfg.AutoRaise then cfg.JumpVy = math.min(cfg.JumpVy + 10, cfg.MaxVy) end
					status("Missed, retrying")
				end
			end)
		end
	end)
end

table.insert(conns, RunService.Heartbeat:Connect(function()
	if not Farm.Enabled or flipping then return end
	local s = seat()
	if not s then
		if Farm.Stats.status ~= "Not on a ride" then status("Not on a ride") end
		return
	end
	if os.clock() - lastEnd < Farm.Config.Cooldown then return end
	if grounded(s) and s.AssemblyLinearVelocity.Magnitude >= Farm.Config.MinSpeed then
		backflip(s)
	elseif Farm.Stats.status == "Not on a ride" or Farm.Stats.status == "Idle" then
		status("Waiting for speed")
	end
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
	self.Enabled = v
	if not v then
		if flipConn then flipConn:Disconnect() end
		flipping = false
	end
	status(v and "Waiting for speed" or "Idle")
end

function Farm:Reset()
	self.Stats.earned, self.Stats.flips, self.Stats.fails, self.Stats.last = 0, 0, 0, "-"
	changed()
end

function Farm:Destroy()
	self:SetEnabled(false)
	for _, c in ipairs(conns) do c:Disconnect() end
end

return Farm
