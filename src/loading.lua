-- Clean black loading screen: letter-by-letter title, thin progress line, real readiness checks.
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local Loading = {}

local function tween(o, t, p, style, dir)
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), p)
	tw:Play()
	return tw
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	ok, h = pcall(function() return game:GetService("CoreGui") end)
	if ok and h then return h end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

-- wait for cond() up to timeout seconds; returns whether it became true
local function waitFor(cond, timeout)
	local t = os.clock()
	while not cond() do
		if os.clock() - t > timeout then return false end
		task.wait(.05)
	end
	return true
end

function Loading.run(title, subtitle)
	local gui = Instance.new("ScreenGui")
	gui.Name = tostring(math.random(1e6, 9e6)); gui.ResetOnSpawn = false; gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = guiParent()

	local bg = Instance.new("Frame")
	bg.Size = UDim2.fromScale(1, 1); bg.BackgroundColor3 = Color3.fromRGB(5, 5, 5); bg.BackgroundTransparency = 1
	bg.BorderSizePixel = 0; bg.Parent = gui
	tween(bg, .5, { BackgroundTransparency = 0 })

	-- title: one label per letter so they can stagger in
	local row = Instance.new("Frame")
	row.AnchorPoint = Vector2.new(.5, .5); row.Position = UDim2.new(.5, 0, .5, -22); row.Size = UDim2.fromOffset(0, 40)
	row.AutomaticSize = Enum.AutomaticSize.X; row.BackgroundTransparency = 1; row.Parent = bg
	local lay = Instance.new("UIListLayout")
	lay.FillDirection = Enum.FillDirection.Horizontal; lay.Padding = UDim.new(0, 3)
	lay.HorizontalAlignment = Enum.HorizontalAlignment.Center; lay.Parent = row

	local letters = {}
	for i = 1, #title do
		local ch = title:sub(i, i)
		local l = Instance.new("TextLabel")
		l.BackgroundTransparency = 1; l.Text = ch; l.Font = Enum.Font.GothamBold; l.TextSize = 32
		l.TextColor3 = Color3.fromRGB(240, 240, 240); l.TextTransparency = 1; l.LayoutOrder = i
		l.Size = UDim2.fromOffset(ch == " " and 12 or 0, 40); l.AutomaticSize = ch == " " and Enum.AutomaticSize.None or Enum.AutomaticSize.X
		l.Parent = row
		letters[i] = l
	end
	for i, l in ipairs(letters) do
		task.delay(.35 + i * .045, function()
			tween(l, .5, { TextTransparency = 0 })
		end)
	end

	local sub = Instance.new("TextLabel")
	sub.AnchorPoint = Vector2.new(.5, .5); sub.Position = UDim2.new(.5, 0, .5, 14); sub.Size = UDim2.fromOffset(300, 16)
	sub.BackgroundTransparency = 1; sub.Text = subtitle or ""; sub.Font = Enum.Font.GothamMedium; sub.TextSize = 12
	sub.TextColor3 = Color3.fromRGB(110, 110, 110); sub.TextTransparency = 1; sub.Parent = bg
	task.delay(1.1, function() tween(sub, .6, { TextTransparency = 0 }) end)

	-- progress line
	local track = Instance.new("Frame")
	track.AnchorPoint = Vector2.new(.5, .5); track.Position = UDim2.new(.5, 0, .5, 62); track.Size = UDim2.fromOffset(0, 2)
	track.BackgroundColor3 = Color3.fromRGB(28, 28, 28); track.BorderSizePixel = 0; track.Parent = bg
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1); fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255); fill.BorderSizePixel = 0; fill.Parent = track
	task.delay(.9, function() tween(track, .6, { Size = UDim2.fromOffset(240, 2) }) end)

	local status = Instance.new("TextLabel")
	status.AnchorPoint = Vector2.new(.5, .5); status.Position = UDim2.new(.5, 0, .5, 84); status.Size = UDim2.fromOffset(300, 14)
	status.BackgroundTransparency = 1; status.Text = ""; status.Font = Enum.Font.Gotham; status.TextSize = 11
	status.TextColor3 = Color3.fromRGB(85, 85, 85); status.Parent = bg

	task.wait(1.3) -- let the intro play

	local lp = Players.LocalPlayer
	local steps = {
		{ "Waiting for game", function() return game:IsLoaded() end, 15 },
		{ "Finding your character", function() return lp.Character ~= nil end, 10 },
		{ "Loading interface", function() return lp:FindFirstChild("PlayerGui") ~= nil end, 10 },
		{ "Linking trick system", function()
			local r = RS:FindFirstChild("Remotes")
			local t = r and r:FindFirstChild("Tricks")
			return t ~= nil and t:FindFirstChild("TrickState") ~= nil
		end, 10 },
	}
	for i, s in ipairs(steps) do
		status.Text = s[1] .. "..."
		waitFor(s[2], s[3])
		tween(fill, .35, { Size = UDim2.fromScale(i / (#steps + 1), 1) })
		task.wait(.25)
	end
	status.Text = "Ready"
	tween(fill, .4, { Size = UDim2.fromScale(1, 1) })
	task.wait(.6)

	-- fade out everything
	for _, l in ipairs(letters) do tween(l, .4, { TextTransparency = 1 }) end
	tween(sub, .4, { TextTransparency = 1 }); tween(status, .4, { TextTransparency = 1 })
	tween(fill, .4, { BackgroundTransparency = 1 }); tween(track, .4, { BackgroundTransparency = 1 })
	task.wait(.35)
	tween(bg, .5, { BackgroundTransparency = 1 })
	task.delay(.55, function() gui:Destroy() end)
end

return Loading
