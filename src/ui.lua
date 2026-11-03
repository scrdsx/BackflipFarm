-- Black UI library: sidebar tabs, animated search bar, toggles, sliders, buttons, labels, toasts.
local TweenService = game:GetService("TweenService")
local UIS = game:GetService("UserInputService")
local Players = game:GetService("Players")

local T = {
	bg = Color3.fromRGB(8, 8, 8),
	panel = Color3.fromRGB(13, 13, 13),
	elem = Color3.fromRGB(19, 19, 19),
	hover = Color3.fromRGB(27, 27, 27),
	stroke = Color3.fromRGB(36, 36, 36),
	text = Color3.fromRGB(235, 235, 235),
	sub = Color3.fromRGB(118, 118, 118),
	accent = Color3.fromRGB(255, 255, 255),
	font = Enum.Font.GothamMedium,
	bold = Enum.Font.GothamBold,
}

local function tween(o, t, p, style, dir)
	local tw = TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quint, dir or Enum.EasingDirection.Out), p)
	tw:Play()
	return tw
end

local function new(class, props, children)
	local i = Instance.new(class)
	for k, v in pairs(props or {}) do i[k] = v end
	for _, c in ipairs(children or {}) do c.Parent = i end
	return i
end

local function corner(r) return new("UICorner", { CornerRadius = UDim.new(0, r) }) end
local function stroke(c, th) return new("UIStroke", { Color = c or T.stroke, Thickness = th or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }) end

local function label(text, size, color, font, align)
	return new("TextLabel", {
		BackgroundTransparency = 1, Text = text, TextSize = size or 13, TextColor3 = color or T.text,
		Font = font or T.font, TextXAlignment = align or Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd, -- long names get "..." instead of running over their neighbours
	})
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	ok, h = pcall(function() return game:GetService("CoreGui") end)
	if ok and h then return h end
	return Players.LocalPlayer:WaitForChild("PlayerGui")
end

local UI = {}
UI.__index = UI

function UI.new(opts)
	opts = opts or {}
	local self = setmetatable({ tabs = {}, rows = {}, conns = {}, active = nil, visible = true, baseScale = 1 }, UI)

	local gui = new("ScreenGui", {
		Name = tostring(math.random(1e6, 9e6)), ResetOnSpawn = false, IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 999,
	})
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
	gui.Parent = guiParent()
	self.gui = gui

	local root = new("CanvasGroup", {
		Name = "Root", Size = UDim2.fromOffset(600, 390), AnchorPoint = Vector2.new(.5, .5),
		Position = UDim2.fromScale(.5, .5), BackgroundColor3 = T.bg, BorderSizePixel = 0, GroupTransparency = 1,
	}, { corner(12), stroke(T.stroke) })
	root.Parent = gui
	self.root = root
	self.scale = new("UIScale", { Scale = .9, Parent = root })

	-- top bar
	local top = new("Frame", { Size = UDim2.new(1, 0, 0, 52), BackgroundColor3 = T.panel, BorderSizePixel = 0, Parent = root })
	new("Frame", { Size = UDim2.new(1, 0, 0, 1), Position = UDim2.new(0, 0, 1, -1), BackgroundColor3 = T.stroke, BorderSizePixel = 0, Parent = top })
	local title = label(opts.Title or "Window", 15, T.text, T.bold)
	title.Position = UDim2.fromOffset(18, 9); title.Size = UDim2.fromOffset(200, 18); title.Parent = top
	local sub = label(opts.Subtitle or "", 11, T.sub)
	sub.Position = UDim2.fromOffset(18, 27); sub.Size = UDim2.fromOffset(200, 14); sub.Parent = top

	-- search bar (grows + brightens on focus)
	local sb = new("Frame", {
		AnchorPoint = Vector2.new(1, .5), Position = UDim2.new(1, -16, .5, 0), Size = UDim2.fromOffset(190, 30),
		BackgroundColor3 = T.elem, BorderSizePixel = 0, Parent = top,
	}, { corner(8) })
	local sbStroke = stroke(T.stroke); sbStroke.Parent = sb
	local box = new("TextBox", {
		BackgroundTransparency = 1, Size = UDim2.new(1, -44, 1, 0), Position = UDim2.fromOffset(12, 0),
		Text = "", PlaceholderText = "Search...", PlaceholderColor3 = T.sub, TextColor3 = T.text,
		Font = T.font, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, ClearTextOnFocus = false, Parent = sb,
	})
	local hint = new("Frame", {
		AnchorPoint = Vector2.new(1, .5), Position = UDim2.new(1, -8, .5, 0), Size = UDim2.fromOffset(18, 18),
		BackgroundColor3 = T.hover, BorderSizePixel = 0, Parent = sb,
	}, { corner(5) })
	local hintTxt = label("/", 11, T.sub, T.bold, Enum.TextXAlignment.Center)
	hintTxt.Size = UDim2.fromScale(1, 1); hintTxt.Parent = hint
	-- sliding underline that sweeps in on focus
	local sweep = new("Frame", {
		AnchorPoint = Vector2.new(.5, 1), Position = UDim2.new(.5, 0, 1, 0), Size = UDim2.new(0, 0, 0, 2),
		BackgroundColor3 = T.accent, BorderSizePixel = 0, Parent = sb,
	}, { corner(2) })
	self.searchBox = box

	box.Focused:Connect(function()
		tween(sb, .28, { Size = UDim2.fromOffset(270, 30) })
		tween(sbStroke, .2, { Color = Color3.fromRGB(110, 110, 110) })
		tween(sb, .2, { BackgroundColor3 = T.hover })
		tween(sweep, .35, { Size = UDim2.new(1, -16, 0, 2) })
		tween(hint, .2, { BackgroundTransparency = 1 }); tween(hintTxt, .2, { TextTransparency = 1 })
	end)
	box.FocusLost:Connect(function()
		tween(sbStroke, .2, { Color = T.stroke })
		tween(sb, .2, { BackgroundColor3 = T.elem })
		tween(sweep, .25, { Size = UDim2.new(0, 0, 0, 2) })
		if box.Text == "" then
			tween(sb, .28, { Size = UDim2.fromOffset(190, 30) })
			tween(hint, .2, { BackgroundTransparency = 0 }); tween(hintTxt, .2, { TextTransparency = 0 })
		end
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function() self:_search(box.Text) end)

	-- drag by top bar
	do
		local dragging, start, origin
		top.InputBegan:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
				local p, a, z = i.Position, sb.AbsolutePosition, sb.AbsoluteSize
				if p.X >= a.X and p.X <= a.X + z.X and p.Y >= a.Y and p.Y <= a.Y + z.Y then return end -- clicking the search bar
				dragging, start, origin = true, i.Position, root.Position
			end
		end)
		table.insert(self.conns, UIS.InputChanged:Connect(function(i)
			if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
				local d = i.Position - start
				root.Position = UDim2.new(origin.X.Scale, origin.X.Offset + d.X, origin.Y.Scale, origin.Y.Offset + d.Y)
			end
		end))
		table.insert(self.conns, UIS.InputEnded:Connect(function(i)
			if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end
		end))
	end

	-- sidebar
	local side = new("Frame", { Position = UDim2.fromOffset(0, 52), Size = UDim2.new(0, 150, 1, -52), BackgroundColor3 = T.panel, BorderSizePixel = 0, Parent = root })
	-- divider lives on root: inside side, its UIListLayout would give it the whole column and push the tabs away
	new("Frame", { Size = UDim2.new(0, 1, 1, -52), Position = UDim2.fromOffset(149, 52), BackgroundColor3 = T.stroke, BorderSizePixel = 0, Parent = root })
	new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder, Parent = side })
	new("UIPadding", { PaddingTop = UDim.new(0, 12), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 12), Parent = side })
	self.side = side
	self.indicator = new("Frame", {
		Size = UDim2.fromOffset(3, 18), Position = UDim2.fromOffset(0, 52 + 12 + 8), BackgroundColor3 = T.accent,
		BorderSizePixel = 0, ZIndex = 3, Parent = root, -- not in the sidebar: its UIListLayout would move it
	}, { corner(2) })
	self.indicator.Visible = false

	-- content (all pages live in one list; search shows every page, filtered)
	local content = new("ScrollingFrame", {
		Position = UDim2.fromOffset(150, 52), Size = UDim2.new(1, -150, 1, -52), BackgroundTransparency = 1, BorderSizePixel = 0,
		ScrollBarThickness = 3, ScrollBarImageColor3 = Color3.fromRGB(70, 70, 70), AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(), Parent = root,
	})
	new("UIListLayout", { Padding = UDim.new(0, 14), SortOrder = Enum.SortOrder.LayoutOrder, Parent = content })
	new("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 17), Parent = content })
	self.content = content

	-- toast holder
	self.toasts = new("Frame", {
		AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -18, 1, -18), Size = UDim2.fromOffset(240, 300),
		BackgroundTransparency = 1, Parent = gui,
	})
	new("UIListLayout", { Padding = UDim.new(0, 6), VerticalAlignment = Enum.VerticalAlignment.Bottom, HorizontalAlignment = Enum.HorizontalAlignment.Right, Parent = self.toasts })

	-- open animation
	tween(root, .45, { GroupTransparency = 0 })
	tween(self.scale, .5, { Scale = 1 }, Enum.EasingStyle.Back)
	return self
end

function UI:Tab(name)
	local idx = #self.tabs + 1
	local btn = new("TextButton", {
		Size = UDim2.new(1, 0, 0, 34), BackgroundColor3 = T.elem, BackgroundTransparency = 1, AutoButtonColor = false,
		Text = "", LayoutOrder = idx, Parent = self.side,
	}, { corner(8) })
	local txt = label(name, 13, T.sub)
	txt.Position = UDim2.fromOffset(14, 0); txt.Size = UDim2.new(1, -14, 1, 0); txt.Parent = btn

	local page = new("CanvasGroup", {
		Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
		LayoutOrder = idx, Visible = false, GroupTransparency = 1, Parent = self.content,
	})
	new("UIListLayout", { Padding = UDim.new(0, 7), SortOrder = Enum.SortOrder.LayoutOrder, Parent = page })
	local header = label(name:upper(), 11, T.sub, T.bold)
	header.Size = UDim2.new(1, 0, 0, 16); header.LayoutOrder = -1; header.Visible = false; header.Parent = page

	local tab = { name = name, btn = btn, txt = txt, page = page, header = header, win = self, index = idx }
	setmetatable(tab, { __index = UI.TabMethods })
	table.insert(self.tabs, tab)

	btn.MouseEnter:Connect(function() if self.active ~= tab then tween(btn, .15, { BackgroundTransparency = .6 }) end end)
	btn.MouseLeave:Connect(function() if self.active ~= tab then tween(btn, .15, { BackgroundTransparency = 1 }) end end)
	btn.MouseButton1Click:Connect(function()
		if self.searchBox.Text ~= "" then self.searchBox.Text = "" end
		self:Select(tab)
	end)
	if not self.active then self:Select(tab) end
	return tab
end

function UI:Select(tab)
	local prev = self.active
	self.active = tab
	for _, t in ipairs(self.tabs) do
		local on = t == tab
		tween(t.btn, .2, { BackgroundTransparency = on and 0 or 1 })
		tween(t.txt, .2, { TextColor3 = on and T.text or T.sub })
		if not on then t.page.Visible = false; t.page.GroupTransparency = 1 end
	end
	self.indicator.Visible = true
	tween(self.indicator, .3, { Position = UDim2.fromOffset(0, 52 + 12 + (tab.index - 1) * 38 + 8) }, Enum.EasingStyle.Back)
	tab.page.Visible = true
	tween(tab.page, .3, { GroupTransparency = 0 })
	self.content.CanvasPosition = Vector2.zero
end

function UI:_search(q)
	q = q:lower():gsub("^%s+", ""):gsub("%s+$", "")
	if q == "" then
		for _, t in ipairs(self.tabs) do
			t.header.Visible = false
			t.page.Visible = t == self.active
			t.page.GroupTransparency = t == self.active and 0 or 1
		end
		for _, r in ipairs(self.rows) do r.frame.Visible = true end
		return
	end
	local hits = {}
	for _, r in ipairs(self.rows) do
		local m = r.name:find(q, 1, true) ~= nil or r.tab.name:lower():find(q, 1, true) ~= nil
		r.frame.Visible = m
		if m then hits[r.tab] = true end
	end
	for _, t in ipairs(self.tabs) do
		local has = hits[t] == true
		t.header.Visible = has
		if has and not t.page.Visible then
			t.page.Visible = true
			t.page.GroupTransparency = 1
			tween(t.page, .25, { GroupTransparency = 0 })
		elseif not has then
			t.page.Visible = false
		end
	end
	self.content.CanvasPosition = Vector2.zero
end

function UI:Notify(text, seconds)
	local f = new("Frame", {
		Size = UDim2.fromOffset(0, 34), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = T.panel,
		BackgroundTransparency = 1, BorderSizePixel = 0, Parent = self.toasts,
	}, { corner(8), new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }) })
	local st = stroke(T.stroke); st.Transparency = 1; st.Parent = f
	local l = label(text, 13, T.text); l.AutomaticSize = Enum.AutomaticSize.X; l.Size = UDim2.fromOffset(0, 34); l.TextTransparency = 1; l.Parent = f
	tween(f, .3, { BackgroundTransparency = 0 }); tween(st, .3, { Transparency = 0 }); tween(l, .3, { TextTransparency = 0 })
	task.delay(seconds or 2.5, function()
		if not f.Parent then return end
		tween(f, .3, { BackgroundTransparency = 1 }); tween(st, .3, { Transparency = 1 }); tween(l, .3, { TextTransparency = 1 })
		task.wait(.35); f:Destroy()
	end)
end

function UI:SetVisible(v)
	self.visible = v
	if v then
		self.root.Visible = true
		tween(self.root, .3, { GroupTransparency = 0 }); tween(self.scale, .35, { Scale = self.baseScale }, Enum.EasingStyle.Back)
	else
		tween(self.root, .2, { GroupTransparency = 1 }); tween(self.scale, .2, { Scale = self.baseScale * .93 })
		task.delay(.22, function() if not self.visible then self.root.Visible = false end end)
	end
end
function UI:Toggle() self:SetVisible(not self.visible) end

function UI:SetScale(s)
	self.baseScale = s
	tween(self.scale, .2, { Scale = s })
end

function UI:Destroy()
	for _, c in ipairs(self.conns) do c:Disconnect() end
	self.gui:Destroy()
end

-- components --------------------------------------------------------------
local M = {}
UI.TabMethods = M

local function row(tab, name, height)
	local f = new("Frame", { Size = UDim2.new(1, 0, 0, height or 40), BackgroundColor3 = T.elem, BorderSizePixel = 0, Parent = tab.page }, { corner(9), stroke(T.stroke) })
	f.MouseEnter:Connect(function() tween(f, .15, { BackgroundColor3 = T.hover }) end)
	f.MouseLeave:Connect(function() tween(f, .15, { BackgroundColor3 = T.elem }) end)
	table.insert(tab.win.rows, { frame = f, name = name:lower(), tab = tab })
	return f
end

function M:Label(o)
	local f = row(self, o.Name, 34)
	local n = label(o.Name, 13, T.sub); n.Position = UDim2.fromOffset(14, 0); n.Size = UDim2.new(.5, -14, 1, 0); n.Parent = f
	local v = label(tostring(o.Value or "-"), 13, T.text, T.bold, Enum.TextXAlignment.Right)
	v.Position = UDim2.new(.5, 0, 0, 0); v.Size = UDim2.new(.5, -14, 1, 0); v.Parent = f
	return { Set = function(_, x) v.Text = tostring(x) end }
end

function M:Button(o)
	local f = row(self, o.Name, 38)
	local b = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = o.Name, TextColor3 = T.text, Font = T.font, TextSize = 13, AutoButtonColor = false, Parent = f })
	b.MouseButton1Click:Connect(function()
		tween(f, .08, { BackgroundColor3 = Color3.fromRGB(55, 55, 55) })
		task.delay(.08, function() tween(f, .3, { BackgroundColor3 = T.hover }) end)
		if o.Callback then task.spawn(o.Callback) end
	end)
end

function M:Toggle(o)
	local f = row(self, o.Name, 40)
	local n = label(o.Name, 13, T.text); n.Position = UDim2.fromOffset(14, 0); n.Size = UDim2.new(1, -80, 1, 0); n.Parent = f
	local sw = new("Frame", { AnchorPoint = Vector2.new(1, .5), Position = UDim2.new(1, -14, .5, 0), Size = UDim2.fromOffset(38, 20), BackgroundColor3 = Color3.fromRGB(34, 34, 34), BorderSizePixel = 0, Parent = f }, { corner(10) })
	local knob = new("Frame", { AnchorPoint = Vector2.new(0, .5), Position = UDim2.new(0, 3, .5, 0), Size = UDim2.fromOffset(14, 14), BackgroundColor3 = T.sub, BorderSizePixel = 0, Parent = sw }, { corner(7) })
	local state = false
	local obj = {}
	local function apply(v, silent)
		state = v
		tween(sw, .22, { BackgroundColor3 = v and T.accent or Color3.fromRGB(34, 34, 34) })
		tween(knob, .22, { Position = v and UDim2.new(1, -17, .5, 0) or UDim2.new(0, 3, .5, 0), BackgroundColor3 = v and Color3.fromRGB(8, 8, 8) or T.sub }, Enum.EasingStyle.Back)
		if not silent and o.Callback then task.spawn(o.Callback, v) end
	end
	function obj:Set(v, silent) apply(v, silent) end
	function obj:Get() return state end
	local hit = new("TextButton", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Text = "", Parent = f })
	hit.MouseButton1Click:Connect(function() apply(not state) end)
	apply(o.Default == true, true)
	return obj
end

function M:Slider(o)
	local f = row(self, o.Name, 54)
	local n = label(o.Name, 13, T.text); n.Position = UDim2.fromOffset(14, 8); n.Size = UDim2.new(.6, 0, 0, 16); n.Parent = f
	local val = label("", 13, T.sub, T.bold, Enum.TextXAlignment.Right); val.Position = UDim2.new(.5, 0, 0, 8); val.Size = UDim2.new(.5, -14, 0, 16); val.Parent = f
	local track = new("Frame", { Position = UDim2.new(0, 14, 0, 36), Size = UDim2.new(1, -28, 0, 4), BackgroundColor3 = Color3.fromRGB(34, 34, 34), BorderSizePixel = 0, Parent = f }, { corner(2) })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = T.accent, BorderSizePixel = 0, Parent = track }, { corner(2) })
	local knob = new("Frame", { AnchorPoint = Vector2.new(.5, .5), Position = UDim2.fromScale(0, .5), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = T.accent, BorderSizePixel = 0, Parent = track }, { corner(6) })
	local min, max, step = o.Min, o.Max, o.Step or 1
	local value
	local obj = {}
	local function set(v, silent)
		v = math.clamp(math.floor((v - min) / step + .5) * step + min, min, max)
		value = v
		local p = (v - min) / (max - min)
		tween(fill, .1, { Size = UDim2.fromScale(p, 1) }); tween(knob, .1, { Position = UDim2.fromScale(p, .5) })
		val.Text = (step < 1 and string.format("%.2f", v) or tostring(v)) .. (o.Suffix or "")
		if not silent and o.Callback then task.spawn(o.Callback, v) end
	end
	function obj:Set(v, silent) set(v, silent) end
	function obj:Get() return value end
	local dragging = false
	local function fromInput(i) set(min + math.clamp((i.Position.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1) * (max - min)) end
	local hit = new("TextButton", { Position = UDim2.fromOffset(0, 26), Size = UDim2.new(1, 0, 0, 26), BackgroundTransparency = 1, Text = "", Parent = f })
	hit.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
			dragging = true; tween(knob, .15, { Size = UDim2.fromOffset(15, 15) }); fromInput(i)
		end
	end)
	table.insert(self.win.conns, UIS.InputChanged:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then fromInput(i) end
	end))
	table.insert(self.win.conns, UIS.InputEnded:Connect(function(i)
		if dragging and (i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch) then
			dragging = false; tween(knob, .15, { Size = UDim2.fromOffset(12, 12) })
		end
	end))
	set(o.Default or min, true)
	return obj
end

-- click, then press a key to bind it (Escape clears). Callback(key) gets an Enum.KeyCode or nil.
function M:Keybind(o)
	local f = row(self, o.Name, 40)
	local n = label(o.Name, 13, T.text); n.Position = UDim2.fromOffset(14, 0); n.Size = UDim2.new(1, -150, 1, 0); n.Parent = f
	local btn = new("TextButton", {
		AnchorPoint = Vector2.new(1, .5), Position = UDim2.new(1, -10, .5, 0), Size = UDim2.fromOffset(120, 26),
		BackgroundColor3 = T.hover, BorderSizePixel = 0, AutoButtonColor = false, Text = "", Parent = f,
	}, { corner(6), stroke(T.stroke) })
	local txt = label("", 12, T.text, T.bold, Enum.TextXAlignment.Center); txt.Size = UDim2.fromScale(1, 1); txt.Parent = btn
	local key, listening, conn = o.Default, false, nil
	local obj = {}
	local function show()
		txt.Text = listening and "Press a key..." or (key and key.Name or "None")
		tween(txt, .15, { TextColor3 = listening and T.accent or T.text })
	end
	function obj:Get() return key end
	-- still "listening" for a moment after a bind, so the key you just chose does not also fire its action
	function obj:IsListening() return listening or os.clock() - (obj.boundAt or 0) < 0.25 end
	function obj:Set(k) key = k; show() end
	btn.MouseButton1Click:Connect(function()
		if listening then return end
		listening = true
		show()
		conn = UIS.InputBegan:Connect(function(i)
			if i.UserInputType ~= Enum.UserInputType.Keyboard then return end
			conn:Disconnect()
			key = (i.KeyCode ~= Enum.KeyCode.Escape) and i.KeyCode or nil
			listening = false
			obj.boundAt = os.clock()
			show()
			if o.Callback then task.spawn(o.Callback, key) end
		end)
		table.insert(self.win.conns, conn)
	end)
	show()
	return obj
end

UI.Theme = T
return UI
