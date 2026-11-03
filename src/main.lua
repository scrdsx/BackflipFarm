local UIS = game:GetService("UserInputService")
local UI = require("ui")
local Farm = require("farm")
local Loading = require("loading")

-- re-run safe: tear down a previous instance
if getgenv then
	local g = getgenv()
	if g.__BackflipFarm then pcall(g.__BackflipFarm) end
end

Loading.run("Scrdsx Solutions", "Backflip Farm")

local win = UI.new({ Title = "Scrdsx Solutions", Subtitle = "Backflip Farm  |  RightShift hide  |  F6 farm  |  / search" })
local cfg, stats = Farm.Config, Farm.Stats

-- Farm tab
local tFarm = win:Tab("Farm")
local farmToggle = tFarm:Toggle({ Name = "Autofarm", Default = false, Callback = function(v)
	Farm:SetEnabled(v)
	win:Notify(v and "Autofarm enabled" or "Autofarm disabled")
end })
local jump = tFarm:Slider({ Name = "Jump power", Min = 30, Max = 140, Step = 5, Default = cfg.JumpVy, Callback = function(v) cfg.JumpVy = v end })
tFarm:Slider({ Name = "Max jump power", Min = 40, Max = 160, Step = 5, Default = cfg.MaxVy, Callback = function(v) cfg.MaxVy = v end })
tFarm:Slider({ Name = "Minimum speed", Min = 0, Max = 60, Step = 1, Default = cfg.MinSpeed, Suffix = " st/s", Callback = function(v) cfg.MinSpeed = v end })
tFarm:Slider({ Name = "Cooldown", Min = 0, Max = 3, Step = 0.1, Default = cfg.Cooldown, Suffix = " s", Callback = function(v) cfg.Cooldown = v end })
tFarm:Toggle({ Name = "Auto-raise jump on miss", Default = cfg.AutoRaise, Callback = function(v) cfg.AutoRaise = v end })

-- Stats tab
local tStats = win:Tab("Stats")
local lStatus = tStats:Label({ Name = "Status" })
local lEarned = tStats:Label({ Name = "Earned this session" })
local lFlips = tStats:Label({ Name = "Flips landed" })
local lFails = tStats:Label({ Name = "Missed attempts" })
local lLast = tStats:Label({ Name = "Last trick" })
local lDir = tStats:Label({ Name = "Spin direction" })
local lPower = tStats:Label({ Name = "Current jump power" })
tStats:Button({ Name = "Reset stats", Callback = function() Farm:Reset() end })

local function refresh()
	lStatus:Set(stats.status)
	lEarned:Set("$" .. stats.earned)
	lFlips:Set(stats.flips)
	lFails:Set(stats.fails)
	lLast:Set(stats.last)
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
tSet:Label({ Name = "Toggle farm", Value = "F6" })
tSet:Label({ Name = "Focus search", Value = "/" })

local function unload()
	Farm:Destroy()
	win:Destroy()
	Farm.Changed = nil
	if getgenv then getgenv().__BackflipFarm = nil end
end
tSet:Button({ Name = "Unload", Callback = unload })
if getgenv then getgenv().__BackflipFarm = unload end

local inputConn
inputConn = UIS.InputBegan:Connect(function(i, gp)
	if i.KeyCode == Enum.KeyCode.RightShift then
		win:Toggle()
	elseif not gp and i.KeyCode == Enum.KeyCode.F6 then
		farmToggle:Set(not farmToggle:Get())
	elseif not gp and i.KeyCode == Enum.KeyCode.Slash then
		win.searchBox:CaptureFocus()
		task.defer(function() win.searchBox.Text = "" end)
	end
end)
table.insert(win.conns, inputConn)

win:Notify("Scrdsx Solutions loaded")
