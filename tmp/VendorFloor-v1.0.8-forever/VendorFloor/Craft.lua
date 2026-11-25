-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Crafting: which of your learned recipes make a profit right now?
-- Recipes are read when a profession window is open (the game only offers them then) and
-- kept per character. Prices come from VendorFloor's full scans (usual price) and from
-- merchants (what a merchant sells a reagent for, read when a merchant window is open).
-- Profit = what the product brings (auction house after the 5% cut, or a merchant,
-- whichever is more) minus the reagents (auction house or merchant, whichever is cheaper).

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local max = math.max
local AH_CUT = 0.95

local function DB() return ns.db end

local function CharKey()
	return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
end

---------------------------------------------------------------------------
-- Recipes (profession window open)
---------------------------------------------------------------------------

local function ScanRecipes()
	local db = DB()
	local T = C_TradeSkillUI
	if not (db and T and T.GetAllRecipeIDs and T.GetRecipeInfo and T.GetRecipeSchematic) then return end
	local ids = T.GetAllRecipeIDs()
	if type(ids) ~= "table" or #ids == 0 then return end
	local prof = "?"
	if T.GetBaseProfessionInfo then
		local info = T.GetBaseProfessionInfo()
		if type(info) == "table" then
			prof = (info.professionName ~= "" and info.professionName) or (info.parentProfessionName ~= "" and info.parentProfessionName) or prof
		end
	end
	local list = {}
	for _, id in ipairs(ids) do
		local info = T.GetRecipeInfo(id)
		if type(info) == "table" and info.learned then
			local ok, sch = pcall(T.GetRecipeSchematic, id, false)
			if ok and type(sch) == "table" and sch.outputItemID then
				local reagents = {}
				for _, slot in ipairs(sch.reagentSlotSchematics or {}) do
					local r = slot.reagents and slot.reagents[1]
					local basic = slot.reagentType == nil or (Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
					if r and r.itemID and basic and (slot.required ~= false) then
						reagents[#reagents + 1] = { r.itemID, slot.quantityRequired or 1 }
					end
				end
				if reagents[1] then
					local qty = ((sch.quantityMin or 1) + (sch.quantityMax or sch.quantityMin or 1)) / 2
					list[#list + 1] = { id = id, name = info.name, out = sch.outputItemID, qty = qty, r = reagents }
				end
			end
		end
	end
	if not list[1] then return end
	db.recipes = db.recipes or {}
	local char = CharKey()
	db.recipes[char] = db.recipes[char] or {}
	db.recipes[char][prof] = { at = time(), list = list }
	ns.craftDirty = true
	if ns.RefreshWindow then ns.RefreshWindow() end
end

---------------------------------------------------------------------------
-- Merchant prices of reagents (merchant window open)
---------------------------------------------------------------------------

local function ScanMerchant()
	local db = DB()
	-- GetMerchantItemInfo is the merchant API of this client (C_MerchantFrame is retail only).
	---@diagnostic disable-next-line: deprecated
	if not (db and GetMerchantNumItems and GetMerchantItemInfo and GetMerchantItemID) then return end
	db.vendorBuy = db.vendorBuy or {}
	for i = 1, GetMerchantNumItems() do
		---@diagnostic disable-next-line: deprecated
		local _, _, price, quantity, numAvailable, _, _, extendedCost = GetMerchantItemInfo(i)
		local itemID = GetMerchantItemID(i)
		-- only unlimited items for gold
		if itemID and price and price > 0 and not extendedCost and (numAvailable or -1) < 0 then
			db.vendorBuy[itemID] = price / max(quantity or 1, 1)
		end
	end
	ns.craftDirty = true
end

---------------------------------------------------------------------------
-- Profit
---------------------------------------------------------------------------

-- Cheapest way to get one unit: auction house (usual price) or merchant.
local function ReagentCost(itemID)
	local db = DB()
	-- buying: the cheapest listings (low price), else the usual price
	local pk = ns.PlainKey and ns.PlainKey(itemID)
	local market = pk and ((ns.LowValue and ns.LowValue(pk)) or (ns.MarketValue and ns.MarketValue(pk)))
	local vendor = db.vendorBuy and db.vendorBuy[itemID]
	if market and vendor then
		if vendor <= market then return vendor, "vendor" end
		return market, "ah"
	end
	if vendor then return vendor, "vendor" end
	if market then return market, "ah" end
	return nil
end

-- What one unit of the product brings: auction house after the cut, or a merchant.
local function ProductValue(itemID)
	-- selling: what a sale has to beat (low price), else 90% of the usual price
	local pk = ns.PlainKey and ns.PlainKey(itemID)
	local market = pk and ns.LowValue and ns.LowValue(pk)
	if not market and pk and ns.MarketValue then
		local med = ns.MarketValue(pk)
		market = med and med * 0.9
	end
	local sold = ns.SoldPrice and ns.SoldPrice(itemID)
	if sold and (not market or sold < market) then market = sold end
	local rate = ns.SellRate and ns.SellRate(itemID)
	if market and rate then market = market * max(rate, 0.3) end
	local sell = select(11, GetItemInfo(itemID)) or 0
	local ah = market and market * AH_CUT or nil
	if ah and ah >= sell then return ah, "ah" end
	if sell > 0 then return sell, "vendor" end
	return nil
end

-- Craft results, best first; results.char marks the character they belong to.
local results, missing = {}, 0

---@param a table
---@param b table
local function byProfit(a, b) return a.profit > b.profit end

-- All recipes of this character with a positive profit, best first.
function ns.CraftResults()
	if not ns.craftDirty and results.char == CharKey() then return results, missing end
	ns.craftDirty = false
	results, missing = { char = CharKey() }, 0
	local db = DB()
	local mine = db and db.recipes and db.recipes[CharKey()]
	if not mine then return results, missing end
	for prof, p in pairs(mine) do
		for _, rec in ipairs(p.list or {}) do
			local cost, ok, parts = 0, true, {}
			for _, r in ipairs(rec.r) do
				local unit, src = ReagentCost(r[1])
				if not unit then ok = false break end
				cost = cost + unit * r[2]
				parts[#parts + 1] = { id = r[1], qty = r[2], unit = unit, src = src }
			end
			local value, route = ProductValue(rec.out)
			if ok and value then
				local revenue = value * rec.qty
				local profit = revenue - cost
				if profit >= (db.minProfit or 1) then
					local name, link, _, _, _, _, _, _, _, icon = GetItemInfo(rec.out)
					results[#results + 1] = { prof = prof, recipe = rec.name, out = rec.out, qty = rec.qty, cost = cost,
						revenue = revenue, profit = profit, route = route, parts = parts, name = name or rec.name,
						link = link, icon = icon }
				end
			else
				missing = missing + 1
			end
		end
	end
	table.sort(results, byProfit)
	return results, missing
end

function ns.CraftProfessions()
	local db = DB()
	local mine = db and db.recipes and db.recipes[CharKey()]
	local names = {}
	for prof in pairs(mine or {}) do
		if prof ~= "" and prof ~= "?" then names[#names + 1] = prof end
	end
	table.sort(names)
	return names
end

-- Chat output for /vfloor craft.
function ns.PrintCraft()
	local list, miss = ns.CraftResults()
	local out = DEFAULT_CHAT_FRAME
	if not ns.CraftProfessions()[1] then
		out:AddMessage("|cff33ff99VendorFloor:|r " .. L["Open each profession window once so VendorFloor can read your recipes."])
		return
	end
	out:AddMessage("|cff33ff99VendorFloor:|r " .. L["%d crafts with profit (%d recipes without prices yet):"]:format(#list, miss))
	for i = 1, math.min(#list, 10) do
		local c = list[i]
		out:AddMessage(("  %s: %s %s, +%s"):format(c.prof, c.link or c.name, ns.Money(c.cost) .. " > " .. ns.Money(c.revenue),
			ns.Money(c.profit)))
	end
end

---------------------------------------------------------------------------
-- Events and the button in the profession window
---------------------------------------------------------------------------

local button

local function AddButton()
	local parent = ProfessionsFrame or TradeSkillFrame
	if button or not parent or not ns.FlatButton then return end
	button = ns.FlatButton(parent, 150, 24, "primary")
	-- above the window, never near "Create" / "Create All": below it the button lay over them,
	-- because the window's frame reaches further down than its art
	button:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", parent == TradeSkillFrame and -34 or 0, 4)
	button:SetText(L["Craft profits"])
	button:SetScript("OnClick", function()
		ScanRecipes()
		if ns.OpenTab then ns.OpenTab("craft") else ns.PrintCraft() end
	end)
	button:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:AddLine("VendorFloor")
		GameTooltip:AddLine(L["Shows which of your learned recipes make a profit, with prices from VendorFloor's full scans and from merchants."], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
	pcall(events.RegisterEvent, events, event)
end
local pending = false
events:SetScript("OnEvent", function(_, event)
	if not DB() then return end
	if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
		pcall(ScanMerchant)
		return
	end
	if event == "TRADE_SKILL_SHOW" then pcall(AddButton) end
	-- the list arrives in parts: read it once it has settled
	if not pending then
		pending = true
		C_Timer.After(1, function()
			pending = false
			pcall(ScanRecipes)
		end)
	end
end)
