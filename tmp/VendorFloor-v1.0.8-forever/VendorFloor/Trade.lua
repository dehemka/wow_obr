-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- The rest of the trade: what VendorFloor bought is remembered (units and price paid),
-- taken out of the auction house mail and sold to a vendor, each on a button click.
-- The ledger counts buys, spending, sales and the profit that sales really made.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local floor, min, max = math.floor, math.min, math.max

local MAX_SELL = 80        -- stacks sold per click at most

-- Character bags plus the reagent bag (profession bag), where reagents from the mail land.
local BAGS = { 0, 1, 2, 3, 4 }
local REAGENT_BAG = (Enum and Enum.BagIndex and Enum.BagIndex.ReagentBag) or 5
if REAGENT_BAG and REAGENT_BAG > 4 then BAGS[#BAGS + 1] = REAGENT_BAG end
ns.BAGS = BAGS
local TAKE_INTERVAL = 0.4  -- seconds between two items taken from the mail

local session = { start = time(), buys = 0, spent = 0, value = 0, sold = 0, soldCost = 0 }
ns.session = session

local function DB() return ns.db end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99VendorFloor:|r " .. msg)
end

local function Money(copper)
	return ns.Money and ns.Money(copper) or tostring(floor(copper or 0))
end

local function SellPrice(itemID)
	local name, _, _, _, _, _, _, _, _, _, sell = GetItemInfo(itemID)
	if not name then return nil end
	return sell or 0
end

---------------------------------------------------------------------------
-- Ledger
---------------------------------------------------------------------------

local function Changed()
	if ns.OnLedgerChanged then ns.OnLedgerChanged() end
	if ns.UpdateTradeButtons then ns.UpdateTradeButtons() end
end

local function Add(t, field, amount) t[field] = (t[field] or 0) + amount end

local KEEP_DAYS = 120

-- Spending, sales and profit per calendar day (last 120 days).
local function Day()
	local db = DB()
	db.days = db.days or {}
	local key = date("%Y-%m-%d")
	local d = db.days[key]
	if not d then
		d = {}
		db.days[key] = d
		local keys = {}
		for k in pairs(db.days) do keys[#keys + 1] = k end
		if #keys > KEEP_DAYS then
			table.sort(keys)
			for i = 1, #keys - KEEP_DAYS do db.days[keys[i]] = nil end
		end
	end
	return d
end

-- Totals per item, for the best items and their holding time.
local function Item(itemID)
	local db = DB()
	db.items = db.items or {}
	local it = db.items[itemID]
	if not it then
		it = {}
		db.items[itemID] = it
	end
	if not it.name then it.name = GetItemInfo(itemID) end
	return it
end

-- A purchase: qty units of itemID for cost copper, worth value copper at a vendor.
-- Disenchant purchases are kept apart: they are not sold to a merchant, only the spending counts.
local function RecordOther(itemID, qty, cost)
	local db = DB()
	-- to be collected from the mail: units per item until they are taken out
	db.debought = db.debought or {}
	db.debought[itemID] = (db.debought[itemID] or 0) + qty
	-- the disenchant basket: units bought for disenchanting and not disenchanted yet
	db.deBasket = db.deBasket or {}
	db.deBasket[itemID] = (db.deBasket[itemID] or 0) + qty
	db.detotal = db.detotal or { buys = 0, spent = 0 }
	Add(db.detotal, "buys", 1)
	Add(db.detotal, "spent", cost or 0)
	Changed()
end

function ns.RecordBuy(itemID, qty, cost, value, mode)
	local db = DB()
	if not db or not itemID then return end
	qty = max(floor(qty or 1), 1)
	-- every purchase counts for the spending limit and the bag slots it will take
	Add(session, "allSpent", cost or 0)
	ns.mailSlots = (ns.mailSlots or 0) + (ns.SlotsFor and ns.SlotsFor(itemID, qty) or 1)
	if mode == "de" then
		RecordOther(itemID, qty, cost)
		return
	end
	if mode == "wish" then
		-- watchlist purchases are yours to keep: collected with the others, never sold
		db.debought = db.debought or {}
		db.debought[itemID] = (db.debought[itemID] or 0) + qty
		Changed()
		return
	end
	local b = db.bought[itemID] or { units = 0, cost = 0 }
	local now = time()
	-- average purchase time of the units held, for the holding time on sale
	b.ts = floor(((b.ts or now) * b.units + now * qty) / (b.units + qty))
	b.units, b.cost = b.units + qty, b.cost + (cost or 0)
	db.bought[itemID] = b
	for _, t in ipairs({ session, db.total, Day(), Item(itemID) }) do
		Add(t, "buys", 1)
		Add(t, "spent", cost or 0)
		Add(t, "value", value or 0)
	end
	Add(Item(itemID), "units", qty)
	Changed()
end

-- A sale: qty units of itemID for income copper. The cost is the average price paid.
function ns.RecordSale(itemID, qty, income)
	local db = DB()
	local b = db and db.bought[itemID]
	if not b or b.units <= 0 then return end
	qty = min(qty, b.units)
	local cost = b.cost / b.units * qty
	local held = b.ts and max(time() - b.ts, 0) or nil
	b.units, b.cost = b.units - qty, max(b.cost - cost, 0)
	if b.units <= 0 then db.bought[itemID] = nil end
	for _, t in ipairs({ session, db.total, Day(), Item(itemID) }) do
		Add(t, "sold", income)
		Add(t, "soldCost", cost)
	end
	local it = Item(itemID)
	Add(it, "soldUnits", qty)
	if held then
		Add(it, "heldSec", held * qty)
		Add(it, "heldUnits", qty)
	end
end

-- Units still to sell and what a vendor pays for them.
function ns.Unsold()
	local db = DB()
	local units, value = 0, 0
	if not db then return 0, 0 end
	for itemID, b in pairs(db.bought) do
		units = units + b.units
		value = value + (SellPrice(itemID) or 0) * b.units
	end
	return units, value
end

-- The ledger line for the window.
function ns.LedgerLine()
	local _, unsold = ns.Unsold()
	local profit = (session.sold or 0) - (session.soldCost or 0)
	local hours = max((time() - session.start) / 3600, 0.25)
	return L["Session: %d buys, spent %s, sold %s, profit %s (%s per hour), still to sell %s"]:format(session.buys,
		Money(session.spent), Money(session.sold), Money(profit), Money(profit / hours), Money(unsold))
end

function ns.TotalLine()
	local db = DB()
	if not (db and db.total) then return "" end
	local t = db.total
	local _, unsold = ns.Unsold()
	local line = L["Total: %d buys, spent %s, sold %s, profit %s, still to sell %s"]:format(t.buys or 0,
		Money(t.spent or 0), Money(t.sold or 0), Money((t.sold or 0) - (t.soldCost or 0)), Money(unsold))
	local de = db.detotal
	if de then
		line = line .. " | " .. L["Disenchant: %d buys, spent %s"]:format(de.buys or 0, Money(de.spent or 0))
	end
	return line
end


-- Read-only view of the ledger for other addons (LevelTrail reads it if installed).
-- Amounts in copper; days maps "YYYY-MM-DD" to { buys, spent, sold, soldCost }.
function VendorFloor_Ledger()
	local db = DB()
	if not db or not db.total then return nil end
	local t = db.total
	local units, unsold = ns.Unsold()
	local days = {}
	for k, d in pairs(db.days or {}) do
		days[k] = { buys = d.buys or 0, spent = d.spent or 0, sold = d.sold or 0, soldCost = floor(d.soldCost or 0) }
	end
	return { version = 1, buys = t.buys or 0, spent = t.spent or 0, sold = t.sold or 0,
		soldCost = floor(t.soldCost or 0), profit = floor((t.sold or 0) - (t.soldCost or 0)),
		unsoldUnits = units, unsoldValue = unsold, days = days }
end

function ns.ForgetPurchases()
	wipe(DB().bought)
	Changed()
end

---------------------------------------------------------------------------
-- Mail: take the bought items out of the auction house mail
---------------------------------------------------------------------------

local ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16

local function FreeSlots()
	local free = 0
	for _, bag in ipairs(BAGS) do
		local n = C_Container.GetContainerNumFreeSlots(bag) or 0
		free = free + (n or 0)
	end
	return free
end

-- Is this mail an auction house purchase? Without invoice data every mail counts.
local function IsPurchase(index)
	if not GetInboxInvoiceInfo then return true end
	local invoiceType = GetInboxInvoiceInfo(index)
	return invoiceType == nil or invoiceType == "buyer"
end

-- Items to collect from the mail: bought for the vendor tab, or for disenchanting.
local function Collectable(db, itemID)
	return db.bought[itemID] ~= nil or (db.debought and (db.debought[itemID] or 0) > 0)
end

-- The next attachment holding an item VendorFloor bought: mail index, attachment index.
local function NextMailItem()
	local db = DB()
	if not db or not GetInboxNumItems then return nil end
	for i = GetInboxNumItems(), 1, -1 do
		if IsPurchase(i) then
			for a = 1, ATTACHMENTS do
				local _, itemID = GetInboxItem(i, a)
				if itemID and Collectable(db, itemID) then return i, a end
			end
		end
	end
	return nil
end

local function MailCount()
	local db = DB()
	local n = 0
	if not db or not GetInboxNumItems then return 0 end
	for i = 1, GetInboxNumItems() do
		if IsPurchase(i) then
			for a = 1, ATTACHMENTS do
				local _, itemID, _, count = GetInboxItem(i, a)
				if itemID and Collectable(db, itemID) then n = n + (count or 1) end
			end
		end
	end
	return n
end

local mailButton, collecting, taken, nextTake = nil, false, 0, 0

local function StopCollecting(msg)
	collecting = false
	if msg then Print(msg) end
	if ns.UpdateTradeButtons then ns.UpdateTradeButtons() end
end

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(self)
	if not collecting then self:Hide() return end
	if GetTime() < nextTake then return end
	if FreeSlots() == 0 then
		self:Hide()
		StopCollecting(L["Bags full. Collected %d items."]:format(taken))
		return
	end
	local i, a = NextMailItem()
	if not (i and a) then
		self:Hide()
		StopCollecting(L["Collected %d items."]:format(taken))
		return
	end
	local _, itemID, _, count = GetInboxItem(i, a)
	local db = DB()
	if itemID and db.debought and db.debought[itemID] then
		local left = db.debought[itemID] - (count or 1)
		db.debought[itemID] = left > 0 and left or nil
	end
	TakeInboxItem(i, a)
	taken = taken + (count or 1)
	nextTake = GetTime() + TAKE_INTERVAL
end)

local function StartCollecting()
	if collecting then return end
	collecting, taken, nextTake = true, 0, 0
	driver:Show()
end

---------------------------------------------------------------------------
-- Merchant: sell the bought items, at most as many as were bought
---------------------------------------------------------------------------

local function ContainerItem(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if info then return info.itemID, info.stackCount or 1, info.isLocked end
	return nil
end

local function NumSlots(bag)
	return C_Container.GetContainerNumSlots(bag) or 0
end

local function UseItem(bag, slot)
	return C_Container.UseContainerItem(bag, slot)
end

-- Units in the bags that may be sold: a stack only when it is not bigger than what
-- VendorFloor bought of that item, so items of your own stay.
local function SellableUnits()
	local db = DB()
	local left, n = {}, 0
	if not db then return 0 end
	for itemID, b in pairs(db.bought) do left[itemID] = b.units end
	for _, bag in ipairs(BAGS) do
		for slot = 1, NumSlots(bag) do
			local itemID, count, locked = ContainerItem(bag, slot)
			if itemID and left[itemID] and not locked and count <= left[itemID] and (SellPrice(itemID) or 0) > 0 then
				left[itemID] = left[itemID] - count
				n = n + count
			end
		end
	end
	return n
end

-- Sales are counted from the bags, not from the button: whatever sells a bought item at a
-- merchant (this button, a junk seller addon, a right-click) lowers its count in the bags.
-- The counts are kept up to date outside the merchant, so a sale right when the merchant
-- opens is counted as well.
local bagCounts, merchantOpen = nil, false
-- Items handed to the merchant (right-click or dropped on the merchant window): only their
-- count going down is a sale. Splitting, destroying or moving items is not.
local handed = {}
local cursorItem
if C_Container and hooksecurefunc then
	if C_Container.UseContainerItem then
		hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
			if not merchantOpen then return end
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID then handed[info.itemID] = true end
		end)
	end
	if C_Container.PickupContainerItem then
		hooksecurefunc(C_Container, "PickupContainerItem", function(bag, slot)
			local info = merchantOpen and C_Container.GetContainerItemInfo(bag, slot)
			cursorItem = info and info.itemID or nil
		end)
	end
end
if hooksecurefunc and PickupMerchantItem then
	hooksecurefunc("PickupMerchantItem", function()
		if merchantOpen and cursorItem then handed[cursorItem] = true end
		cursorItem = nil
	end)
end

local function CountBought()
	local db = DB()
	local c = {}
	if not (db and next(db.bought)) then return c end
	for _, bag in ipairs(BAGS) do
		for slot = 1, NumSlots(bag) do
			local itemID, count = ContainerItem(bag, slot)
			if itemID and db.bought[itemID] then c[itemID] = (c[itemID] or 0) + (count or 1) end
		end
	end
	return c
end

local function TrackBags()
	local now = CountBought()
	if merchantOpen and bagCounts then
		local sold = false
		for itemID, before in pairs(bagCounts) do
			local gone = before - (now[itemID] or 0)
			local price = gone > 0 and handed[itemID] and SellPrice(itemID)
			if price and price > 0 then
				ns.RecordSale(itemID, gone, price * gone)
				sold = true
			end
		end
		if sold then now = CountBought() end
	end
	wipe(handed)
	bagCounts = now
end

local function Sell()
	local db = DB()
	if not db then return end
	local stacks, units, income, profit = 0, 0, 0, 0
	local left = {}
	for itemID, b in pairs(db.bought) do left[itemID] = b.units end
	for _, bag in ipairs(BAGS) do
		for slot = 1, NumSlots(bag) do
			if stacks >= MAX_SELL then break end
			local itemID, count, locked = ContainerItem(bag, slot)
			local price = itemID and SellPrice(itemID)
			if itemID and left[itemID] and not locked and count <= left[itemID] and price and price > 0 then
				UseItem(bag, slot)
				local bought = db.bought[itemID]
				profit = profit + price * count - (bought and bought.units > 0 and bought.cost / bought.units * count or 0)
				left[itemID] = left[itemID] - count
				stacks, units, income = stacks + 1, units + count, income + price * count
			end
		end
	end
	if stacks == 0 then
		Print(L["Nothing to sell."])
	else
		Print(L["Sold %d items for %s (profit %s)."]:format(units, Money(income), Money(profit)))
	end
	Changed()
end

---------------------------------------------------------------------------
-- Buttons on the mail and merchant windows
---------------------------------------------------------------------------

local sellButton

local function MakeButton(parent, onClick, tooltip, label)
	local b = ns.FlatButton and ns.FlatButton(parent, 170, 24, "primary") or CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(170, 24)
	b:SetText(label)
	-- MERCHANT_SHOW and MAIL_SHOW fire before their window is visible: refresh once it is
	parent:HookScript("OnShow", function() if ns.UpdateTradeButtons then ns.UpdateTradeButtons() end end)
	b:SetPoint("TOPLEFT", parent, "TOPRIGHT", 4, -30)
	b:SetScript("OnClick", onClick)
	b:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("VendorFloor")
		GameTooltip:AddLine(tooltip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:HookScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	return b
end

function ns.UpdateTradeButtons()
	if mailButton and mailButton:IsShown() then
		local n = MailCount()
		mailButton:SetText(L["Collect purchases (%d)"]:format(n))
		mailButton:SetEnabled(n > 0 and not collecting)
	end
	if sellButton and sellButton:IsShown() then
		local n = SellableUnits()
		sellButton:SetText(L["Sell purchases (%d)"]:format(n))
		sellButton:SetEnabled(n > 0)
	end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED", "MERCHANT_SHOW", "MERCHANT_CLOSED",
	"BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD" }) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event)
	if not DB() then return end
	if event == "MAIL_SHOW" then
		if not mailButton and MailFrame then
			mailButton = MakeButton(MailFrame, StartCollecting,
				L["VendorFloor takes the items it bought out of the auction house mail."], L["Collect purchases (%d)"]:format(0))
		end
		if mailButton then mailButton:Show() end
	elseif event == "MAIL_CLOSED" then
		if collecting then StopCollecting() end
		if mailButton then mailButton:Hide() end
	elseif event == "BAG_UPDATE_DELAYED" then
		-- sales are only counted at a merchant: no bag scan on every loot elsewhere
		if merchantOpen then TrackBags() end
	elseif event == "MERCHANT_SHOW" then
		-- the bags as they are when the merchant opens are the starting point for sales
		bagCounts = CountBought()
		merchantOpen = true
		if not sellButton and MerchantFrame then
			sellButton = MakeButton(MerchantFrame, Sell,
				L["Sells the items VendorFloor bought, at most as many as it bought."], L["Sell purchases (%d)"]:format(0))
		end
		if sellButton then sellButton:Show() end
	elseif event == "MERCHANT_CLOSED" then
		TrackBags()
		merchantOpen = false
		if sellButton then sellButton:Hide() end
	end
	ns.UpdateTradeButtons()
end)
