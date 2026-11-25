-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- The disenchant basket: items bought on the disenchant tab wait in the bags until they are
-- disenchanted. One button (on the mail window, or its key binding) disenchants the next one:
-- one click per item, no cursor, no searching the bags. Every disenchant is still your own
-- click or key press, as the game requires.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local DISENCHANT = 13262
local BUTTON_NAME = "VendorFloorBasketButton"

local function DB() return ns.db end

local function SpellName()
	if C_Spell and C_Spell.GetSpellName then
		local name = C_Spell.GetSpellName(DISENCHANT)
		if name then return name end
	end
	if GetSpellInfo then
		local name = GetSpellInfo(DISENCHANT)
		if name then return name end
	end
	return L["Disenchant"]
end

local function Slots(bag)
	if not (C_Container and C_Container.GetContainerNumSlots) then return 0 end
	return C_Container.GetContainerNumSlots(bag) or 0
end

local function SlotInfo(bag, slot)
	local info = C_Container and C_Container.GetContainerItemInfo and C_Container.GetContainerItemInfo(bag, slot)
	if info then return info.itemID, info.stackCount or 1, info.isLocked, info.hyperlink end
	return nil
end

local function Bags() return ns.BAGS or { 0, 1, 2, 3, 4 } end

-- Basket items in the bags: list of { bag, slot, id, link }, at most as many as were bought.
local function Contents()
	local db = DB()
	local list = {}
	if not (db and db.deBasket and next(db.deBasket)) then return list end
	local left = {}
	for itemID, n in pairs(db.deBasket) do left[itemID] = n end
	for _, bag in ipairs(Bags()) do
		for slot = 1, Slots(bag) do
			local itemID, _, locked, link = SlotInfo(bag, slot)
			if itemID and (left[itemID] or 0) > 0 and not locked
				and (not ns.CanDisenchant or ns.CanDisenchant(itemID)) then
				left[itemID] = left[itemID] - 1
				list[#list + 1] = { bag = bag, slot = slot, id = itemID, link = link }
			end
		end
	end
	return list
end
ns.BasketContents = Contents

-- A unit leaves the basket when it is no longer in the bags or the mail: disenchanted
-- (with the button, by hand or by another addon), sold or traded.
local function Prune()
	local db = DB()
	if not (db and db.deBasket and next(db.deBasket)) then return end
	local inBags = {}
	for _, bag in ipairs(Bags()) do
		for slot = 1, Slots(bag) do
			local itemID, count = SlotInfo(bag, slot)
			if itemID then inBags[itemID] = (inBags[itemID] or 0) + (count or 1) end
		end
	end
	for itemID, n in pairs(db.deBasket) do
		local keep = (inBags[itemID] or 0) + ((db.debought and db.debought[itemID]) or 0)
		if keep <= 0 then
			db.deBasket[itemID] = nil
		elseif keep < n then
			db.deBasket[itemID] = keep
		end
	end
end

---------------------------------------------------------------------------
-- The button (secure: casting needs a click or key press)
---------------------------------------------------------------------------

local button

local function Clear()
	if not button or InCombatLockdown() then return end
	button:SetAttribute("type", nil)
	button:SetAttribute("spell", nil)
	button:SetAttribute("target-bag", nil)
	button:SetAttribute("target-slot", nil)
	button.target = nil
end

-- Out of combat right before the click: aim the button at the next basket item.
-- Aimed on press and on release alike: which of the two casts depends on the source
-- (mouse, key binding, /click macro) and the client, the game casts only once.
-- A spell with a bag slot as target, not a macro: a macro cannot run inside a /click macro.
local function Aim(self)
	if InCombatLockdown() then return end
	local target = Contents()[1]
	if not target then
		Clear()
		return
	end
	self.target = target
	self:SetAttribute("type", "spell")
	self:SetAttribute("spell", SpellName())
	self:SetAttribute("target-bag", target.bag)
	self:SetAttribute("target-slot", target.slot)
end

-- Can this character disenchant? (Enchanting learned, Disenchant in the spell book)
local ENCHANTING_SKILL_LINE = 333
local function KnowsDisenchant()
	-- the spell book API differs between clients: take whichever this one has
	local spellBook = C_SpellBook
	if spellBook and spellBook.IsSpellInSpellBook and spellBook.IsSpellInSpellBook(DISENCHANT) then return true end
	if GetProfessions and GetProfessionInfo then
		for _, index in pairs({ GetProfessions() }) do
			if index and select(7, GetProfessionInfo(index)) == ENCHANTING_SKILL_LINE then return true end
		end
	end
	-- a lookup by name only finds spells in the spell book (Forever may use its own spell ID)
	local name = SpellName()
	if C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(name) then return true end
	if GetSpellInfo and GetSpellInfo(name) then return true end
	return false
end

-- The basket window: shown when new basket items arrive in the bags, or when opened by hand
-- (menu entry or key binding). Hidden again when it is empty, unless opened by hand, or with x.
local holder
local state = { manual = false, auto = false, last = 0 }

local function SavePosition()
	local db = DB()
	if not (db and holder) then return end
	local point, _, relPoint, x, y = holder:GetPoint(1)
	if point then db.basketPos = { point, relPoint, x, y } end
end

local function Create()
	if button then return button end
	holder = CreateFrame("Frame", "VendorFloorBasketFrame", UIParent, "BackdropTemplate")
	holder:SetSize(190, 56)
	holder:SetFrameStrata("MEDIUM")
	holder:SetClampedToScreen(true)
	holder:SetMovable(true)
	holder:EnableMouse(true)
	holder:RegisterForDrag("LeftButton")
	holder:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
	holder:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() SavePosition() end)
	if ns.Flat then ns.Flat(holder) end
	local pos = DB() and DB().basketPos
	if pos then
		holder:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
	else
		holder:SetPoint("CENTER", UIParent, "CENTER", 320, 80)
	end
	local title = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	title:SetPoint("TOPLEFT", 8, -6)
	title:SetText(L["Disenchant basket"])
	local close = CreateFrame("Button", nil, holder)
	close:SetSize(16, 16)
	close:SetPoint("TOPRIGHT", -4, -3)
	local x = close:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	x:SetPoint("CENTER")
	x:SetText("x")
	close:SetFontString(x)
	close:SetScript("OnClick", function()
		state.manual, state.auto = false, false
		ns.UpdateBasket()
	end)

	local make = ns.FlatButton
	if make then
		button = make(holder, 174, 24, "primary", BUTTON_NAME, "SecureActionButtonTemplate")
	else
		button = CreateFrame("Button", BUTTON_NAME, holder, "SecureActionButtonTemplate, UIPanelButtonTemplate")
		button:SetSize(174, 24)
	end
	button:SetPoint("BOTTOM", 0, 8)
	button:RegisterForClicks("AnyUp", "AnyDown")
	-- cast on release for every source: a /click macro sends a release, whatever the
	-- "cast on key down" setting says
	button:SetAttribute("useOnKeyDown", false)
	button:SetText(L["Disenchant (%d)"]:format(0))
	button:SetScript("PreClick", Aim)
	button:SetScript("PostClick", function() C_Timer.After(0, Clear) end)
	button:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("VendorFloor")
		GameTooltip:AddLine(L["Disenchants the next item you bought on the disenchant tab: one click per item."], 1, 1, 1, true)
		local list = Contents()
		if list[1] then
			GameTooltip:AddLine(" ")
			local shown = {}
			for _, e in ipairs(list) do shown[e.id] = shown[e.id] or { link = e.link, n = 0 } shown[e.id].n = shown[e.id].n + 1 end
			local lines = 0
			for _, e in pairs(shown) do
				lines = lines + 1
				if lines > 12 then break end
				GameTooltip:AddLine(("%s ×%d"):format(e.link or "?", e.n))
			end
		end
		local key = GetBindingKey and GetBindingKey("CLICK " .. BUTTON_NAME .. ":LeftButton")
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(key and L["Key: %s"]:format(key) or L["Tip: set a key for it under Key Bindings > AddOns > VendorFloor."],
			0.6, 0.6, 0.6, true)
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(self) if GameTooltip:GetOwner() == self then GameTooltip:Hide() end end)
	holder:Hide()
	return button
end

function ns.UpdateBasket()
	if not button or InCombatLockdown() then return end
	local n = #Contents()
	if n > state.last then state.auto = true end -- new basket items arrived in the bags
	if n == 0 then state.auto = false end
	state.last = n
	button:SetText(L["Disenchant (%d)"]:format(n))
	button:SetEnabled(n > 0)
	holder:SetShown(KnowsDisenchant() and (state.manual or state.auto))
end

-- Menu entry: open or close the basket by hand.
function ns.ToggleBasket()
	if InCombatLockdown() then return end
	Create()
	if holder:IsShown() then
		state.manual, state.auto = false, false
	else
		state.manual = true
		if not KnowsDisenchant() then
			print("|cffd9a441VendorFloor|r: " .. L["This character cannot disenchant."])
		end
	end
	ns.UpdateBasket()
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "PLAYER_LOGIN", "MAIL_CLOSED", "BAG_UPDATE_DELAYED", "PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED", "LOOT_CLOSED", "SPELLS_CHANGED", "SKILL_LINES_CHANGED" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
	if not DB() then return end
	if event == "PLAYER_LOGIN" then
		Create()
		if not InCombatLockdown() then Prune() end
		state.last = #Contents() -- items already in the bags at login do not open the window
		return
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- the bags may change in combat: no click may hit an item it was not aimed at
		Clear()
		return
	elseif (event == "BAG_UPDATE_DELAYED" or event == "MAIL_CLOSED") and not (event == "BAG_UPDATE_DELAYED" and MailFrame and MailFrame:IsShown()) then
		-- while the mail is open, items arrive one by one: pruning waits until it is closed
		Prune()
	end
	Create()
	ns.UpdateBasket()
end)

_G["BINDING_NAME_CLICK " .. BUTTON_NAME .. ":LeftButton"] = L["Disenchant next basket item"]
