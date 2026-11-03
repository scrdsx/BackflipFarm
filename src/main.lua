local UIS = game:GetService("UserInputService")
local UI = __import("ui")
local Farm = __import("farm")
local Loading = __import("loading")

-- re-run safe: tear down a previous instance
if getgenv then
	local g = getgenv()
	if g.__BackflipFarm then pcall(g.__BackflipFarm) end
end

Loading.run("Scrdsx Solutions", "Backflip Farm")

local win = UI.new({ Title = "Scrdsx Solutions", Subtitle = "Backflip Farm" })
local cfg, stats = Farm.Config, Farm.Stats

-- Farm tab
local tFarm = win:Tab("Farm")
tFarm:Toggle({ Name = "Autofarm", Default = false, Callback = function(v)
	Farm:SetEnabled(v)
	win:Notify(v and "Autofarm enabled" or "Autofarm disabled")
end })
tFarm:Slider({ Name = "Ride speed", Min = 15, Max = 120, Step = 1, Default = cfg.CruiseSpeed, Suffix = " st/s", Callback = function(v) cfg.CruiseSpeed = v end })
tFarm:Slider({ Name = "Distance between tricks", Min = 0, Max = 200, Step = 5, Default = cfg.FlipSpacing, Suffix = " st", Callback = function(v) cfg.FlipSpacing = v end })
tFarm:Toggle({ Name = "Wheelie before flip", Default = cfg.Wheelie, Callback = function(v) cfg.Wheelie = v end })
tFarm:Slider({ Name = "Wheelie hold time", Min = 0, Max = 2, Step = 0.05, Default = cfg.WheelieTime, Suffix = " s", Callback = function(v) cfg.WheelieTime = v end })
tFarm:Slider({ Name = "Wheelie angle", Min = 20, Max = 70, Step = 5, Default = cfg.WheeliePitch, Suffix = " deg", Callback = function(v) cfg.WheeliePitch = v end })
local jump = tFarm:Slider({ Name = "Jump power", Min = 30, Max = 140, Step = 5, Default = cfg.JumpVy, Callback = function(v) cfg.JumpVy = v end })
tFarm:Slider({ Name = "Max jump power", Min = 40, Max = 140, Step = 5, Default = cfg.MaxVy, Callback = function(v) cfg.MaxVy = v end })
tFarm:Slider({ Name = "Cooldown", Min = 0, Max = 3, Step = 0.1, Default = cfg.Cooldown, Suffix = " s", Callback = function(v) cfg.Cooldown = v end })
tFarm:Toggle({ Name = "Auto-raise jump on miss", Default = cfg.AutoRaise, Callback = function(v) cfg.AutoRaise = v end })

-- Route tab
local tRoute = win:Tab("Route")
local lMode = tRoute:Label({ Name = "Route mode" })
local lPts = tRoute:Label({ Name = "Route points" })
local lRoad = tRoute:Label({ Name = "Road status" })
tRoute:Toggle({ Name = "Auto road route (no recording)", Default = cfg.UseRoads, Callback = function(v)
	cfg.UseRoads = v
	Farm:RebuildPath()
end })
tRoute:Button({ Name = "Pick a new road route", Callback = function() Farm:RebuildPath() end })
tRoute:Toggle({ Name = "Record route (ride it yourself)", Default = false, Callback = function(v)
	Farm:SetRecording(v)
	win:Notify(v and "Recording: ride your safe path" or ("Route saved: " .. #Farm.Route .. " points"))
end })
tRoute:Button({ Name = "Delete saved route (use straight shuttle)", Callback = function()
	Farm:ClearRoute()
	win:Notify("Route cleared")
end })
tRoute:Slider({ Name = "Shuttle length", Min = 60, Max = 400, Step = 10, Default = cfg.ShuttleLength, Suffix = " st", Callback = function(v) cfg.ShuttleLength = v end })
tRoute:Slider({ Name = "Turn rate", Min = 1, Max = 6, Step = 0.5, Default = cfg.TurnRate, Callback = function(v) cfg.TurnRate = v end })
tRoute:Toggle({ Name = "Loop when route ends meet", Default = cfg.LoopRoute, Callback = function(v) cfg.LoopRoute = v end })
tRoute:Slider({ Name = "Max distance from route", Min = 50, Max = 800, Step = 10, Default = cfg.MaxRouteDist, Suffix = " st", Callback = function(v) cfg.MaxRouteDist = v end })
tRoute:Slider({ Name = "Road width allowed", Min = 6, Max = 30, Step = 1, Default = cfg.RoadHalfWidth, Suffix = " st", Callback = function(v) cfg.RoadHalfWidth = v end })
tRoute:Toggle({ Name = "Stop for obstacles", Default = cfg.AvoidObstacles, Callback = function(v) cfg.AvoidObstacles = v end })
tRoute:Button({ Name = "Swap ride forward/back", Callback = function()
	Farm:FlipForward()
	win:Notify("Forward direction swapped")
end })
tRoute:Button({ Name = "Test flip now (while riding)", Callback = function() Farm:TestFlip() end })
tRoute:Button({ Name = "Swap flip direction", Callback = function() Farm:FlipDirection() end })

-- Stats tab
local tStats = win:Tab("Stats")
local lStatus = tStats:Label({ Name = "Status" })
local lEarned = tStats:Label({ Name = "Earned this session" })
local lFlips = tStats:Label({ Name = "Flips landed" })
local lFails = tStats:Label({ Name = "Missed attempts" })
local lLast = tStats:Label({ Name = "Last trick" })
local lGate = tStats:Label({ Name = "Next flip" })
local lDir = tStats:Label({ Name = "Spin direction" })
local lPower = tStats:Label({ Name = "Current jump power" })
tStats:Button({ Name = "Reset stats", Callback = function() Farm:Reset() end })

local function refresh()
	lMode:Set(stats.mode)
	lPts:Set(stats.points)
	lRoad:Set(stats.road)
	lStatus:Set(stats.status)
	lEarned:Set("$" .. stats.earned)
	lFlips:Set(stats.flips)
	lFails:Set(stats.fails)
	lLast:Set(stats.last)
	lGate:Set(stats.gate)
	lDir:Set(stats.direction)
	lPower:Set(cfg.JumpVy)
	jump:Set(cfg.JumpVy, true) -- keep the slider in sync with auto-raise
end
Farm.Changed = refresh
refresh()

-- Settings tab
local tSet = win:Tab("Settings")
tSet:Slider({ Name = "UI scale", Min = 0.7, Max = 1.4, Step = 0.05, Default = 1, Callback = function(v) win:SetScale(v) end })
tSet:Label({ Name = "Toggle UI", Value = "RightShift" })
tSet:Label({ Name = "Focus search", Value = "/" })

local env = getgenv and getgenv() or _G
local alive = true
local function unload()
	alive = false
	Farm:Destroy()
	win:Destroy()
	Farm.Changed = nil
	if getgenv then getgenv().__BackflipFarm = nil end
end
tSet:Label({ Name = "Version", Value = tostring(env.ScrdsxVersion or "?") .. " (" .. tostring(env.ScrdsxCommit or "?") .. ")" })
tSet:Button({ Name = "Update now (reload latest)", Callback = function()
	if not env.ScrdsxReload then win:Notify("Reload not available"); return end
	local reload = env.ScrdsxReload
	unload()
	task.spawn(reload)
end })
tSet:Button({ Name = "Unload", Callback = unload })
if getgenv then getgenv().__BackflipFarm = unload end

table.insert(win.conns, UIS.InputBegan:Connect(function(i, gp)
	if i.KeyCode == Enum.KeyCode.RightShift then
		win:Toggle()
	elseif not gp and i.KeyCode == Enum.KeyCode.Slash then
		win.searchBox:CaptureFocus()
		task.defer(function() win.searchBox.Text = "" end)
	end
end))

win:Notify("Scrdsx Solutions loaded  v" .. tostring(env.ScrdsxVersion or "?"))

-- update watcher: tells you when a newer version is published
task.spawn(function()
	local told = env.ScrdsxVersion
	task.wait(10)
	while alive and env.ScrdsxFetchVersion do
		local ok, latest = pcall(env.ScrdsxFetchVersion)
		if ok and latest ~= "" and latest ~= env.ScrdsxVersion and latest ~= told then
			told = latest
			win:Notify("Update available: v" .. latest .. "  (Settings > Update now)", 12)
		end
		task.wait(60)
	end
end)
