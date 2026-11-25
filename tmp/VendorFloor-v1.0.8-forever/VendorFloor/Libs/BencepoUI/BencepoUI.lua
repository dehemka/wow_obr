-- BencepoUI-1.0
-- Copyright (c) 2026 Bencepo. All rights reserved.
--
-- Small shared toolkit for the settings windows of Bencepo's addons: a window of its
-- own that can be dragged anywhere and stays open while you play, so every change is
-- seen live. Flat look, one accent colour per addon. Every control reads and writes
-- through get/set functions, so it works with any saved table.
--
--   local win = LibStub("BencepoUI-1.0"):CreateWindow({ name = "MyAddonOptions", title = "MyAddon",
--       width = 500, height = 400, accent = { 0.3, 0.7, 1, 1 }, db = db, posKey = "optPos" })
--   win:Check(16, -60, "Label", "Tooltip", function() return db.x end, function(v) db.x = v end)
--   win:Toggle()

local UI = LibStub:NewLibrary("BencepoUI-1.0", 4)
if not UI then return end

local WHITE = "Interface\\Buttons\\WHITE8x8"
local BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }

local BASE = {
	bg = { 0.059, 0.075, 0.094, 0.97 },
	panel = { 0.110, 0.137, 0.173, 1 },
	line = { 0.157, 0.192, 0.235, 1 },
	well = { 0.043, 0.055, 0.071, 1 },
	text = { 0.902, 0.914, 0.933, 1 },
	muted = { 0.553, 0.592, 0.647, 1 },
	accent = { 0.878, 0.659, 0.227, 1 },
}

local function flat(f, bg, border)
	f:SetBackdrop(BACKDROP)
	f:SetBackdropColor(bg[1], bg[2], bg[3], bg[4] or 1)
	f:SetBackdropBorderColor(border[1], border[2], border[3], border[4] or 1)
end

local function tooltip(frame, title, text)
	if not title then return end
	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(title, 1, 1, 1)
		if text then GameTooltip:AddLine(text, nil, nil, nil, true) end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

local Window = {}

-- opts: name (global frame name, for Escape), title, subtitle, width, height, accent,
-- theme (colours as BASE), db and posKey (where the window's position is kept).
-- Popup with a link selected for Ctrl+C (addons cannot open a browser). One for all windows.
local linkPopup
function UI:ShowLink(T, title, url, note)
	T = T or BASE
	local f = linkPopup
	if not f then
		f = CreateFrame("Frame", "BencepoUILinkPopup", UIParent, "BackdropTemplate")
		f:SetSize(420, 96)
		f:SetFrameStrata("FULLSCREEN_DIALOG")
		f:SetToplevel(true)
		f:SetClampedToScreen(true)
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
		f:EnableMouse(true)
		tinsert(UISpecialFrames, "BencepoUILinkPopup")
		f.top = f:CreateTexture(nil, "ARTWORK")
		f.top:SetPoint("TOPLEFT", 1, -1)
		f.top:SetPoint("TOPRIGHT", -1, -1)
		f.top:SetHeight(2)
		f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		f.title:SetPoint("TOPLEFT", 14, -12)
		local close = CreateFrame("Button", nil, f, "BackdropTemplate")
		close:SetSize(20, 20)
		close:SetPoint("TOPRIGHT", -8, -8)
		f.close = close
		local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		x:SetPoint("CENTER", 0, 1)
		x:SetText("x")
		close:SetScript("OnClick", function() f:Hide() end)
		f.well = CreateFrame("Frame", nil, f, "BackdropTemplate")
		f.well:SetPoint("TOPLEFT", 14, -36)
		f.well:SetPoint("TOPRIGHT", -14, -36)
		f.well:SetHeight(24)
		local eb = CreateFrame("EditBox", nil, f.well)
		eb:SetPoint("TOPLEFT", 6, 0)
		eb:SetPoint("BOTTOMRIGHT", -6, 0)
		eb:SetFontObject(GameFontHighlight)
		eb:SetAutoFocus(false)
		-- read-only: typing puts the link back
		eb:SetScript("OnTextChanged", function(self)
			if self:GetText() ~= f.url then self:SetText(f.url); self:HighlightText() end
		end)
		eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
		eb:SetScript("OnMouseUp", function(self) self:HighlightText() end)
		eb:SetScript("OnEscapePressed", function() f:Hide() end)
		f.eb = eb
		f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		f.note:SetPoint("TOPLEFT", f.well, "BOTTOMLEFT", 0, -8)
		linkPopup = f
	end
	flat(f, T.bg, T.line)
	flat(f.close, T.panel, T.line)
	flat(f.well, T.well, T.line)
	f.top:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)
	f.title:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
	f.title:SetText(title or "")
	f.note:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	f.note:SetText(note or "Copy with Ctrl+C.")
	f.url = url
	f:Show()
	f.eb:SetText(url)
	f.eb:SetFocus()
	f.eb:HighlightText()
end

function UI:CreateWindow(opts)
	local T = {}
	for k, v in pairs(BASE) do T[k] = (opts.theme and opts.theme[k]) or v end
	if opts.accent then T.accent = opts.accent end

	local win = CreateFrame("Frame", opts.name, UIParent, "BackdropTemplate")
	for k, f in pairs(Window) do win[k] = f end
	win.T, win.refreshers = T, {}
	-- opts.bugUrl adds a footer below the content with a "Report a bug" button
	local footer = opts.bugUrl and 32 or 0
	win:SetSize(opts.width or 500, (opts.height or 400) + footer)
	win:SetFrameStrata("DIALOG")
	win:SetToplevel(true)
	win:SetClampedToScreen(true)
	win:SetMovable(true)
	win:EnableMouse(true)
	win:RegisterForDrag("LeftButton")
	flat(win, T.bg, T.line)
	win:SetScript("OnDragStart", win.StartMoving)
	win:SetScript("OnDragStop", function(f)
		f:StopMovingOrSizing()
		if opts.db and opts.posKey then
			opts.db[opts.posKey] = { "TOPLEFT", "BOTTOMLEFT", f:GetLeft(), f:GetTop() }
		end
	end)
	local p = opts.db and opts.posKey and opts.db[opts.posKey]
	if type(p) == "table" and p[1] then
		win:SetPoint(p[1], UIParent, p[2], p[3], p[4])
	else
		win:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
	end
	if opts.name then tinsert(UISpecialFrames, opts.name) end

	-- accent line along the top
	local top = win:CreateTexture(nil, "ARTWORK")
	top:SetPoint("TOPLEFT", 1, -1)
	top:SetPoint("TOPRIGHT", -1, -1)
	top:SetHeight(2)
	top:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 1)

	local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 14, -12)
	title:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
	title:SetText(opts.title or "")
	local used = 14 + title:GetStringWidth() -- room the title row takes from the left
	if opts.subtitle then
		local sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
		sub:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
		sub:SetText(opts.subtitle)
		used = used + 8 + sub:GetStringWidth()
	end
	-- the hint gets what is left of the row: shortened when it does not fit, left out when
	-- there is hardly any room (it ran into the title and version before)
	local hint = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPRIGHT", -38, -15)
	hint:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	hint:SetJustifyH("RIGHT")
	hint:SetWordWrap(false)
	hint:SetText(opts.hint or "drag to move, changes apply live")
	local room = (opts.width or 500) - 38 - used - 16
	hint:SetWidth(math.max(room, 1))
	hint:SetShown(room >= 80)

	local close = CreateFrame("Button", nil, win, "BackdropTemplate")
	close:SetSize(22, 22)
	close:SetPoint("TOPRIGHT", -8, -8)
	flat(close, T.panel, T.line)
	local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	x:SetPoint("CENTER", 0, 1)
	x:SetText("x")
	close:SetScript("OnClick", function() win:Hide() end)
	close:SetScript("OnEnter", function() close:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1) end)
	close:SetScript("OnLeave", function() close:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1) end)

	if opts.bugUrl then
		local sep = win:CreateTexture(nil, "ARTWORK")
		sep:SetPoint("BOTTOMLEFT", 1, footer)
		sep:SetPoint("BOTTOMRIGHT", -1, footer)
		sep:SetHeight(1)
		sep:SetColorTexture(T.line[1], T.line[2], T.line[3], 1)
		local bug = win:Button("Report a bug", 110, function()
			UI:ShowLink(T, "Report a bug", opts.bugUrl, "Copy with Ctrl+C. No GitHub account? Comment on CurseForge.")
		end, "Shows the link to the bug reports to copy.")
		bug:SetPoint("BOTTOMRIGHT", -12, 5)
	end

	win:SetScript("OnShow", function(f)
		f:Refresh()
		if opts.onShow then opts.onShow() end
	end)
	win:SetScript("OnHide", function(f)
		if f.list then f.list:Hide() end
		if opts.onHide then opts.onHide() end
	end)
	win:Hide()
	return win
end

function Window:Toggle() self:SetShown(not self:IsShown()) end

-- Redraws every control from its get function.
function Window:Refresh()
	if not self:IsShown() then return end
	for i = 1, #self.refreshers do self.refreshers[i]() end
end

function Window:OnRefresh(fn) self.refreshers[#self.refreshers + 1] = fn end

local function changed(win, set, value)
	set(value)
	win:Refresh()
end

function Window:Header(x, y, text)
	local T = self.T
	local h = self:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	h:SetPoint("TOPLEFT", x, y)
	h:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
	h:SetText(text)
	return h
end

function Window:Text(x, y, text, width)
	local T = self.T
	local fs = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", x, y)
	if width then fs:SetWidth(width) end
	fs:SetJustifyH("LEFT")
	fs:SetTextColor(T.muted[1], T.muted[2], T.muted[3])
	fs:SetText(text)
	return fs
end

function Window:Check(x, y, label, tip, get, set)
	local T = self.T
	local b = CreateFrame("Button", nil, self, "BackdropTemplate")
	b:SetSize(16, 16)
	b:SetPoint("TOPLEFT", x, y)
	flat(b, T.well, T.line)
	local mark = b:CreateTexture(nil, "OVERLAY")
	mark:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
	mark:SetPoint("CENTER", 1, 0)
	mark:SetSize(20, 20)
	mark:SetVertexColor(T.accent[1], T.accent[2], T.accent[3])
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", b, "RIGHT", 8, 0)
	fs:SetText(label)
	b:SetHitRectInsets(0, -(fs:GetStringWidth() + 10), -3, -3)
	b:SetScript("OnClick", function() changed(self, set, not get()) end)
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1) end)
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1) end)
	tooltip(b, label, tip)
	self:OnRefresh(function() mark:SetShown(get() and true or false) end)
	return b
end

-- format: optional function(value) -> text shown right of the slider.
function Window:Slider(x, y, label, minV, maxV, step, get, set, tip, width, format)
	local T = self.T
	local title = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("TOPLEFT", x, y)
	title:SetTextColor(T.text[1], T.text[2], T.text[3])
	title:SetText(label)
	local s = CreateFrame("Slider", nil, self, "BackdropTemplate")
	s:SetOrientation("HORIZONTAL")
	s:SetSize(width or 170, 8)
	s:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	flat(s, T.well, T.line)
	s:SetThumbTexture(WHITE)
	local thumb = s:GetThumbTexture()
	thumb:SetSize(8, 16)
	thumb:SetVertexColor(T.accent[1], T.accent[2], T.accent[3])
	s:SetMinMaxValues(minV, maxV)
	s:SetValueStep(step)
	s:SetObeyStepOnDrag(true)
	s:SetHitRectInsets(-4, -4, -6, -6)
	local val = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	val:SetPoint("LEFT", s, "RIGHT", 10, 0)
	local function show(v) val:SetText(format and format(v) or tostring(v)) end
	local syncing = false
	s:SetScript("OnValueChanged", function(_, v)
		v = math.floor((v - minV) / step + 0.5) * step + minV
		show(v)
		if syncing or v == get() then return end
		set(v)
	end)
	-- the rest of the window only updates when the drag ends, so dragging stays smooth
	s:SetScript("OnMouseUp", function() self:Refresh() end)
	s:EnableMouseWheel(true)
	s:SetScript("OnMouseWheel", function(selfS, delta)
		selfS:SetValue(math.min(math.max(selfS:GetValue() + delta * step, minV), maxV))
		self:Refresh()
	end)
	tooltip(s, label, tip)
	self:OnRefresh(function()
		local v = tonumber(get()) or minV
		syncing = true
		s:SetValue(v)
		syncing = false
		show(v)
	end)
	return s
end

function Window:Button(text, width, onClick, tip)
	local T = self.T
	local b = CreateFrame("Button", nil, self, "BackdropTemplate")
	b:SetSize(width or 100, 22)
	flat(b, T.panel, T.line)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER", 0, 0)
	b:SetFontString(fs)
	b:SetText(text)
	b:SetScript("OnClick", function()
		onClick()
		self:Refresh()
	end)
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1) end)
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1) end)
	tooltip(b, text, tip)
	return b
end

-- The open list of a dropdown, one per window.
local function listFrame(win)
	if win.list then return win.list end
	local T = win.T
	local list = CreateFrame("Frame", nil, win, "BackdropTemplate")
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:SetClampedToScreen(true)
	list:EnableMouse(true)
	flat(list, T.panel, T.accent)
	list.rows = {}
	list:Hide()
	win.list = list
	return list
end

-- items: list of { value, text }, or a function returning one.
function Window:Dropdown(x, y, label, width, items, get, set, tip)
	local T = self.T
	local title = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("TOPLEFT", x, y)
	title:SetTextColor(T.text[1], T.text[2], T.text[3])
	title:SetText(label)
	local b = CreateFrame("Button", nil, self, "BackdropTemplate")
	b:SetSize(width or 200, 22)
	b:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
	flat(b, T.well, T.line)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("LEFT", 8, 0)
	fs:SetPoint("RIGHT", -20, 0)
	fs:SetJustifyH("LEFT")
	local arrow = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	arrow:SetPoint("RIGHT", -7, 0)
	arrow:SetTextColor(T.accent[1], T.accent[2], T.accent[3])
	arrow:SetText("v")
	local function getItems() return type(items) == "function" and items() or items end

	b:SetScript("OnClick", function()
		local list = listFrame(self)
		if list:IsShown() and list.owner == b then list:Hide() return end
		list.owner = b
		local its, cur = getItems(), get()
		for i, it in ipairs(its) do
			local r = list.rows[i]
			if not r then
				r = CreateFrame("Button", nil, list)
				r:SetHeight(18)
				r.hl = r:CreateTexture(nil, "BACKGROUND")
				r.hl:SetAllPoints()
				r.hl:SetColorTexture(T.accent[1], T.accent[2], T.accent[3], 0.25)
				r.hl:Hide()
				r.fs = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
				r.fs:SetPoint("LEFT", 8, 0)
				r:SetScript("OnEnter", function() r.hl:Show() end)
				r:SetScript("OnLeave", function() r.hl:Hide() end)
				list.rows[i] = r
			end
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", 1, -4 - (i - 1) * 18)
			r:SetPoint("TOPRIGHT", -1, -4 - (i - 1) * 18)
			r.fs:SetText(it[2])
			if it[1] == cur then r.fs:SetTextColor(T.accent[1], T.accent[2], T.accent[3]) else r.fs:SetTextColor(T.text[1], T.text[2], T.text[3]) end
			r:SetScript("OnClick", function()
				list:Hide()
				changed(self, set, it[1])
			end)
			r:Show()
		end
		for i = #its + 1, #list.rows do list.rows[i]:Hide() end
		list:ClearAllPoints()
		list:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
		list:SetSize(math.max(b:GetWidth(), 160), #its * 18 + 8)
		list:Show()
	end)
	b:SetScript("OnEnter", function() b:SetBackdropBorderColor(T.accent[1], T.accent[2], T.accent[3], 1) end)
	b:SetScript("OnLeave", function() b:SetBackdropBorderColor(T.line[1], T.line[2], T.line[3], 1) end)
	tooltip(b, label, tip)
	self:OnRefresh(function()
		local cur, text = get(), ""
		for _, it in ipairs(getItems()) do
			if it[1] == cur then text = it[2] end
		end
		fs:SetText(text)
	end)
	return b
end
