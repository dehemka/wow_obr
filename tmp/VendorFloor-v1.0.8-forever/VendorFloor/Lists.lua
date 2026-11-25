-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Two small windows in Blizzard's look, opened from the menu: the watchlist (items you
-- want at or below a price of your own) and the ignore list (items hidden with a
-- right-click). Both replace chat commands.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local floor, max, min = math.floor, math.max, math.min
local C_Container, C_Item = C_Container, C_Item

local ROW_H, ROWS = 24, 10

local function DB() return ns.db end

local function Money(copper)
	return ns.Money and ns.Money(copper) or tostring(floor(copper or 0))
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r " .. msg)
end

-- Item ID from a link, a number or the name of an item the client knows.
local function ItemID(text)
	text = strtrim(text or "")
	if text == "" then return nil end
	local id = tonumber(text:match("item:(%d+)") or text)
	if id then return id end
	local _, link = GetItemInfo(text)
	return link and tonumber(link:match("item:(%d+)"))
end

---------------------------------------------------------------------------
-- Name suggestions while typing: items VendorFloor has seen (auction prices, purchases,
-- lists) and items in your bags. The game cannot search all items by name, so the
-- index holds what the client knows; an item seen once in the auction house is in it.
---------------------------------------------------------------------------

local index, indexAt = {}, 0
local MAX_SUGGEST, MIN_CHARS = 8, 3
local building -- ids still to add while the index is built, a slice per frame

-- Built once and kept for a few minutes, a slice per frame: thousands of auction prices
-- at once made the game stutter while typing.
local function BuildIndex(onDone)
	if building or (#index > 0 and GetTime() - indexAt < 300) then return end
	local db, seen, ids = DB(), {}, {}
	local function add(id) id = tonumber(id) if id and not seen[id] then seen[id] = true ids[#ids + 1] = id end end
	if db then
		for _, t in ipairs({ db.wishlist, db.ignore, db.bought, db.debought, db.deBasket }) do
			for id in pairs(t or {}) do add(id) end
		end
	end
	local slots = C_Container and C_Container.GetContainerNumSlots
	if slots then
		for _, bag in ipairs(ns.BAGS or { 0, 1, 2, 3, 4 }) do
			for slot = 1, slots(bag) or 0 do add(C_Container.GetContainerItemID(bag, slot)) end
		end
	end
	if db then for pk in pairs(db.lows or {}) do add(tostring(pk):match("(%d+):")) end end
	wipe(index)
	building = { ids = ids, at = 1, requests = 0 }
	local ticker
	ticker = C_Timer.NewTicker(0, function()
		local b = building
		for i = b.at, min(b.at + 199, #b.ids) do
			local id = b.ids[i]
			local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(id)
			if name then
				index[#index + 1] = { id = id, name = name, lower = name:lower(), link = link, icon = icon }
			elseif b.requests < 30 and C_Item and C_Item.RequestLoadItemDataByID then
				b.requests = b.requests + 1
				C_Item.RequestLoadItemDataByID(id)
			end
		end
		b.at = b.at + 200
		if b.at > #b.ids then
			ticker:Cancel()
			building, indexAt = nil, GetTime()
			if onDone then onDone() end
		end
	end)
end

-- Matches for the typed text: names starting with it first, then names containing it.
local function Matches(text)
	text = strtrim(text or ""):lower()
	if #text < MIN_CHARS or text:find("|H") then return {} end
	local first, inner = {}, {}
	for _, it in ipairs(index) do
		local at = it.lower:find(text, 1, true)
		if at == 1 then first[#first + 1] = it elseif at then inner[#inner + 1] = it end
	end
	local byName = function(a, b) return a.lower < b.lower end
	table.sort(first, byName)
	table.sort(inner, byName)
	for _, it in ipairs(inner) do first[#first + 1] = it end
	for i = #first, MAX_SUGGEST + 1, -1 do first[i] = nil end
	return first
end

-- Attaches a suggestion list to an item field. Up/Down choose, Tab or Enter take one.
local function Suggest(box)
	local list = CreateFrame("Frame", nil, box, "BackdropTemplate")
	list:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
	list:SetBackdropColor(0, 0, 0, 0.95)
	list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, 0)
	list:SetWidth(260)
	list:SetFrameStrata("FULLSCREEN_DIALOG")
	list:Hide()
	list.rows, list.items, list.sel = {}, {}, 1
	for i = 1, MAX_SUGGEST do
		local b = CreateFrame("Button", nil, list)
		b:SetHeight(18)
		b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 18)
		b:SetPoint("RIGHT", list, "RIGHT", -6, 0)
		b.icon = b:CreateTexture(nil, "ARTWORK")
		b.icon:SetSize(16, 16)
		b.icon:SetPoint("LEFT")
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", b.icon, "RIGHT", 4, 0)
		b.text:SetPoint("RIGHT")
		b.text:SetJustifyH("LEFT")
		b.hl = b:CreateTexture(nil, "BACKGROUND")
		b.hl:SetAllPoints()
		b.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		b.hl:SetBlendMode("ADD")
		b.hl:Hide()
		b:SetScript("OnEnter", function() list:Select(i) end)
		b:SetScript("OnClick", function() list:Take(i) end)
		list.rows[i] = b
	end
	function list:Select(i)
		self.sel = i
		for j, b in ipairs(self.rows) do b.hl:SetShown(j == i) end
	end
	function list:Take(i)
		local it = self.items[i or self.sel]
		if not it then return false end
		box.picking = true
		box:SetText(it.link or it.name)
		box.picking = false
		self:Hide()
		return true
	end
	function list:Update()
		self.items = Matches(box:GetText())
		for i, b in ipairs(self.rows) do
			local it = self.items[i]
			if it then
				b.icon:SetTexture(it.icon or 134400)
				b.text:SetText(it.link or it.name)
				b:Show()
			else
				b:Hide()
			end
		end
		self:SetHeight(12 + #self.items * 18)
		self:SetShown(#self.items > 0 and box:HasFocus())
		self:Select(1)
	end
	-- matches once typing pauses, not on every key
	box:HookScript("OnTextChanged", function(_, user)
		if not user or box.picking then return end
		list.pending = (list.pending or 0) + 1
		local n = list.pending
		C_Timer.After(0.2, function() if n == list.pending then list:Update() end end)
	end)
	box:HookScript("OnEditFocusGained", function() BuildIndex(function() if box:HasFocus() then list:Update() end end) end)
	box:HookScript("OnEditFocusLost", function() C_Timer.After(0.2, function() list:Hide() end) end)
	box:HookScript("OnTabPressed", function() if list:IsShown() then list:Take() end end)
	box:HookScript("OnArrowPressed", function(_, key)
		if not list:IsShown() then return end
		if key == "UP" then list:Select(max(1, list.sel - 1)) elseif key == "DOWN" then list:Select(min(#list.items, list.sel + 1)) end
	end)
	box:SetAltArrowKeyMode(false)
	box.suggest = list
	return list
end

-- Enter in an item field: takes the chosen suggestion first, else runs the action.
local function OnEnter(box, action)
	if box.suggest and box.suggest:IsShown() and box.suggest:Take() then return end
	action()
end

---------------------------------------------------------------------------
-- A list window: title, optional top area, rows with icon, text, detail and a remove button
---------------------------------------------------------------------------

local function ListWindow(name, title, topHeight)
	local ok, w = pcall(CreateFrame, "Frame", name, UIParent, "BasicFrameTemplateWithInset")
	if not ok or not w then
		w = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
		w:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
			insets = { left = 11, right = 12, top = 12, bottom = 11 } })
		local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -4, -4)
	end
	w:SetSize(420, 70 + topHeight + ROWS * ROW_H)
	w:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
	w:SetFrameStrata("DIALOG")
	w:SetToplevel(true)
	w:SetClampedToScreen(true)
	w:SetMovable(true)
	w:EnableMouse(true)
	w:RegisterForDrag("LeftButton")
	w:SetScript("OnDragStart", w.StartMoving)
	w:SetScript("OnDragStop", w.StopMovingOrSizing)
	local t = w.TitleText or w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	if not w.TitleText then t:SetPoint("TOP", 0, -16) end
	t:SetText(title)
	tinsert(UISpecialFrames, name) -- Escape closes it

	w.offset, w.rows = 0, {}
	local top = -30 - topHeight
	for i = 1, ROWS do
		local row = CreateFrame("Frame", nil, w)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", 14, top - (i - 1) * ROW_H)
		row:SetPoint("RIGHT", w, "RIGHT", -14, 0)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_H - 4, ROW_H - 4)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		row.remove = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.remove:SetSize(70, 20)
		row.remove:SetPoint("RIGHT", 0, 0)
		row.remove:SetText(L["Remove"])
		row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.detail:SetPoint("RIGHT", row.remove, "LEFT", -8, 0)
		row.detail:SetJustifyH("RIGHT")
		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.text:SetPoint("RIGHT", row.detail, "LEFT", -6, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		row:EnableMouse(true)
		row:SetScript("OnEnter", function(self)
			if not self.id then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink("item:" .. self.id)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		w.rows[i] = row
	end
	w.empty = w:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	w.empty:SetPoint("TOPLEFT", 20, top - 8)
	w.empty:SetPoint("RIGHT", w, "RIGHT", -20, 0)
	w.empty:SetJustifyH("LEFT")
	w.count = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	w.count:SetPoint("BOTTOMLEFT", 16, 14)
	w:EnableMouseWheel(true)
	w:SetScript("OnMouseWheel", function(self, delta)
		self.offset = self.offset - delta * 3
		self:Fill()
	end)

	-- items: { id, text, detail, remove = function }
	function w:Fill()
		local items = self:Items()
		self.offset = max(0, min(self.offset, max(#items - ROWS, 0)))
		for i, row in ipairs(self.rows) do
			local it = items[i + self.offset]
			row.id = it and it.id
			if it then
				local _, link, _, _, _, _, _, _, _, icon = GetItemInfo(it.id)
				row.icon:SetTexture(icon or 134400)
				row.text:SetText(link or it.text or ("item:" .. it.id))
				row.detail:SetText(it.detail or "")
				row.remove:SetScript("OnClick", function()
					it.remove()
					self:Fill()
					if ns.RefreshWindow then ns.RefreshWindow() end
				end)
				row:Show()
			else
				row:Hide()
			end
		end
		self.empty:SetShown(#items == 0)
		self.count:SetText(#items > ROWS and L["%d–%d of %d"]:format(self.offset + 1, min(self.offset + ROWS, #items), #items)
			or "")
	end
	w:SetScript("OnShow", function(self) self:Fill() end)
	w:Hide()
	return w
end

local function ByName(list)
	table.sort(list, function(a, b) return (a.text or ""):lower() < (b.text or ""):lower() end)
	return list
end

local function InputBox(parent, width, label)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width, 22)
	box:SetAutoFocus(false)
	box:SetFontObject("GameFontHighlight")
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("BOTTOMLEFT", box, "TOPLEFT", -4, 2)
	fs:SetText(label)
	box:SetScript("OnEscapePressed", box.ClearFocus)
	return box
end

---------------------------------------------------------------------------
-- Ignore list
---------------------------------------------------------------------------

local ignoreWin

function ns.ToggleIgnoreList()
	if not ignoreWin then
		ignoreWin = ListWindow("VendorFloorIgnoreFrame", L["VendorFloor: ignore list"], 58)
		ignoreWin.empty:SetText(L["No hidden items. Right-click a find in the list to hide that item."])
		function ignoreWin:Items()
			local db, list = DB(), {}
			for id, name in pairs(db and db.ignore or {}) do
				list[#list + 1] = { id = id, text = type(name) == "string" and name or GetItemInfo(id),
					remove = function() db.ignore[id] = nil end }
			end
			return ByName(list)
		end
		local box = InputBox(ignoreWin, 260, L["Item (shift-click, name or ID)"])
		box:SetPoint("TOPLEFT", 22, -54)
		Suggest(box)
		local hide = CreateFrame("Button", nil, ignoreWin, "UIPanelButtonTemplate")
		hide:SetSize(90, 22)
		hide:SetPoint("LEFT", box, "RIGHT", 8, 0)
		hide:SetText(L["Hide"])
		local function Hide()
			local db, id = DB(), ItemID(box:GetText())
			if not id then
				Print(L["Item not recognised. Shift-click it into the field, or type its exact name or ID."])
				return
			end
			db.ignore = db.ignore or {}
			db.ignore[id] = GetItemInfo(id) or true
			box:SetText("")
			box:ClearFocus()
			ignoreWin:Fill()
			if ns.RefreshWindow then ns.RefreshWindow() end
		end
		hide:SetScript("OnClick", Hide)
		box:SetScript("OnEnterPressed", function() OnEnter(box, Hide) end)
		ignoreWin.box = box
		local clear = CreateFrame("Button", nil, ignoreWin, "UIPanelButtonTemplate")
		clear:SetSize(120, 22)
		clear:SetPoint("BOTTOMRIGHT", -14, 10)
		clear:SetText(L["Show all again"])
		clear:SetScript("OnClick", function()
			local db = DB()
			if db then db.ignore = {} end
			ignoreWin:Fill()
			if ns.RefreshWindow then ns.RefreshWindow() end
		end)
	end
	ignoreWin:SetShown(not ignoreWin:IsShown())
end

---------------------------------------------------------------------------
-- Watchlist: itemID -> { max = copper per unit, qty = units still wanted (0: any), name }
---------------------------------------------------------------------------

local wishWin

local function WishDetail(want)
	local text = L["up to %s"]:format(Money(want.max))
	if (want.qty or 0) > 0 then text = text .. "  ·  " .. L["%d× wanted"]:format(want.qty) end
	return text
end

-- After a watchlist purchase: count down the units still wanted; done when none are left.
function ns.WishBought(itemID, qty, mode)
	local db = DB()
	if mode ~= "wish" or not (db and db.wishlist and db.wishlist[itemID]) then return end
	local want = db.wishlist[itemID]
	if (want.qty or 0) <= 0 then return end
	want.qty = want.qty - (qty or 1)
	if want.qty <= 0 then
		db.wishlist[itemID] = nil
		Print(L["Watchlist: %s complete, removed from the list."]:format(select(2, GetItemInfo(itemID)) or want.name or itemID))
	end
	if wishWin and wishWin:IsShown() then wishWin:Fill() end
end

-- Shift-click on an item puts its link into the focused item field.
local itemBox
local function InsertLink(link)
	for _, box in ipairs({ itemBox, ignoreWin and ignoreWin.box }) do
		if box and box:HasFocus() and link then
			box:SetText(link)
			return true
		end
	end
end
if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", InsertLink) end
if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", InsertLink) end

function ns.ToggleWishlist()
	if not wishWin then
		wishWin = ListWindow("VendorFloorWishlistFrame", L["VendorFloor: watchlist"], 58)
		wishWin.empty:SetText(L["Nothing watched yet. Shift-click an item into the field above, set your price limit and click \"Add\"."])
		function wishWin:Items()
			local db, list = DB(), {}
			for id, want in pairs(db and db.wishlist or {}) do
				list[#list + 1] = { id = id, text = want.name or GetItemInfo(id), detail = WishDetail(want),
					remove = function() db.wishlist[id] = nil end }
			end
			return ByName(list)
		end
		itemBox = InputBox(wishWin, 170, L["Item (shift-click, name or ID)"])
		itemBox:SetPoint("TOPLEFT", 22, -54)
		Suggest(itemBox)
		local priceBox = InputBox(wishWin, 90, L["Max. price/unit"])
		wishWin.priceBox = priceBox
		priceBox:SetPoint("LEFT", itemBox, "RIGHT", 12, 0)
		local qtyBox = InputBox(wishWin, 40, L["Units"])
		qtyBox:SetPoint("LEFT", priceBox, "RIGHT", 12, 0)
		qtyBox:SetNumeric(true)
		local add = CreateFrame("Button", nil, wishWin, "UIPanelButtonTemplate")
		add:SetSize(64, 22)
		add:SetPoint("LEFT", qtyBox, "RIGHT", 8, 0)
		add:SetText(L["Add"])
		add:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(L["Add to watchlist"])
			GameTooltip:AddLine(L["Price per unit, e.g. 50s or 1g 20s. Units: how many you want in total, empty for any number."], 1, 1, 1, true)
			GameTooltip:Show()
		end)
		add:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		local function Add()
			local db = DB()
			local id = ItemID(itemBox:GetText())
			local price = ns.ParseMoney and ns.ParseMoney(priceBox:GetText())
			if not id then
				Print(L["Item not recognised. Shift-click it into the field, or type its exact name or ID."])
				return
			end
			if not price or price < 1 then
				Print(L["Amount not recognised. Examples: 50%s, 5s, 1g 20s"]:format(ns.COPPER or "c"))
				return
			end
			db.wishlist = db.wishlist or {}
			db.wishlist[id] = { max = price, qty = tonumber(qtyBox:GetText()) or 0, name = GetItemInfo(id) }
			itemBox:SetText("")
			priceBox:SetText("")
			qtyBox:SetText("")
			itemBox:ClearFocus()
			priceBox:ClearFocus()
			qtyBox:ClearFocus()
			wishWin:Fill()
			if ns.RefreshWindow then ns.RefreshWindow() end
		end
		add:SetScript("OnClick", Add)
		itemBox:SetScript("OnEnterPressed", function() OnEnter(itemBox, Add) end)
		for _, box in ipairs({ priceBox, qtyBox }) do box:SetScript("OnEnterPressed", Add) end
	end
	wishWin:SetShown(not wishWin:IsShown())
end

-- From a find's right-click menu: the watchlist with the item and its price filled in.
function ns.WishPrefill(itemID, price)
	if not wishWin then ns.ToggleWishlist() end
	wishWin:Show()
	local _, link = GetItemInfo(itemID)
	itemBox:SetText(link or tostring(itemID))
	wishWin.priceBox:SetText(price and ns.PlainMoney and ns.PlainMoney(price) or "")
	wishWin.priceBox:SetFocus()
end

---------------------------------------------------------------------------
-- A text to copy (Ctrl+C), e.g. the purchase log for a bug report
---------------------------------------------------------------------------

local copyWin
function ns.ShowCopy(title, text)
	if not copyWin then
		local ok, w = pcall(CreateFrame, "Frame", "VendorFloorCopyFrame", UIParent, "BasicFrameTemplateWithInset")
		if not ok or not w then
			w = CreateFrame("Frame", "VendorFloorCopyFrame", UIParent, "BackdropTemplate")
			w:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
				edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 32,
				insets = { left = 11, right = 12, top = 12, bottom = 11 } })
			local close = CreateFrame("Button", nil, w, "UIPanelCloseButton")
			close:SetPoint("TOPRIGHT", -4, -4)
		end
		w:SetSize(560, 400)
		w:SetPoint("CENTER")
		w:SetFrameStrata("DIALOG")
		w:SetMovable(true)
		w:EnableMouse(true)
		w:RegisterForDrag("LeftButton")
		w:SetScript("OnDragStart", w.StartMoving)
		w:SetScript("OnDragStop", w.StopMovingOrSizing)
		w.title = w.TitleText or w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		if not w.TitleText then w.title:SetPoint("TOP", 0, -16) end
		local hint = w:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("BOTTOMLEFT", 16, 12)
		hint:SetText(L["Ctrl+C copies the text. Paste it into your bug report."])
		local sf = CreateFrame("ScrollFrame", nil, w, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 16, -32)
		sf:SetPoint("BOTTOMRIGHT", -34, 30)
		local box = CreateFrame("EditBox", nil, sf)
		box:SetMultiLine(true)
		box:SetFontObject("GameFontHighlightSmall")
		box:SetWidth(500)
		box:SetAutoFocus(false)
		box:SetScript("OnEscapePressed", function() w:Hide() end)
		-- read-only: typing puts the text back
		box:SetScript("OnTextChanged", function(b, user) if user then b:SetText(w.text or "") b:HighlightText() end end)
		sf:SetScrollChild(box)
		w.box = box
		tinsert(UISpecialFrames, "VendorFloorCopyFrame")
		copyWin = w
	end
	copyWin.title:SetText(title)
	copyWin.text = text ~= "" and text or L["Nothing logged yet. Buy something first."]
	copyWin.box:SetText(copyWin.text)
	copyWin:Show()
	copyWin.box:SetFocus()
	copyWin.box:HighlightText()
end
