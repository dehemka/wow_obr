-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Finds auction house listings priced below what a vendor pays and buys them on
-- click or key press. It sends only its own auction house queries and shows itself as
-- a tab of the auction house window; other auction addons keep working. Every purchase
-- needs a click or key press of its own.

local ADDON, ns = ...
-- Texts come from Locales.lua. Should it not have loaded (an outdated .toc), English is used.
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
ns.COPPER = ns.COPPER or "c"
local AH = C_AuctionHouse
local GetItemInfo = ns.GetItemInfo
local GetMetadata = C_AddOns and C_AddOns.GetAddOnMetadata
local floor, min, max = math.floor, math.min, math.max

local VERSION = GetMetadata and GetMetadata(ADDON, "Version") or ""
if VERSION == "" or VERSION:find("^@") then VERSION = "dev" end
ns.VERSION = VERSION

local PREFIX = "|cff33ff99VendorFloor:|r "
local ROWS, ROW_HEIGHT = 12, 22  -- rows shown (as many as fit the window, see AHT.Layout), row height
local SEND_TIMEOUT = 15
local BUY_SILENT = 5       -- seconds a purchase check waits before it tries the other item key or gives up
local keyStyle = {}        -- itemID -> "plain" when gear is only found with the plain item key
local CHECK_TIMEOUT = 3    -- seconds a check waits for the auction house before it tries again later
local CACHE_WAIT = 0.6     -- results the auction house already holds come without an event: read them after this
local FULL_COOLDOWN = 15 * 60  -- the auction house allows one full scan every 15 minutes
local FULL_WAIT = 90           -- seconds a full scan waits for the auction house to answer
local FULL_REUSE = 15          -- after this many seconds without an answer, read a list already there
local FULL_PER_TICK = 400      -- auctions read per tick (ten ticks a second)

local MARKET_DAYS = 14         -- days of price history kept per item (one value per day)
local AH_CUT = 0.95            -- what a sale on the auction house brings after the 5% cut
local MAX_CHECKS = 150         -- checks per round at most
local TABS = { "vendor", "de", "craft", "wish" }

local defaults = {
	minPercent = 0,       -- minimum profit in percent of the price (0: off)
	minSlot = 0,          -- minimum profit per auction, i.e. per bag slot, in copper (0: off)
	flash = true,         -- flash the taskbar icon on new finds while the game is in the background
	tab = "vendor",       -- the tab shown: vendor, de (disenchant) or craft
	minProfit = 100,      -- minimum profit per unit in copper (distance to the vendor price): 1 silver
	minProfitSilver = 1,  -- the same in silver, for the slider in the settings
	sound = true,         -- sound on a new find
	loop = false,         -- continuous mode: scan again after each round
	interval = 20,        -- seconds between two rounds
	spendLimit = 0,       -- gold that may be spent per session (0: no limit)
	keepSlots = 0,        -- bag slots to keep free, counting purchases still in the mail (0: off)
	tooltip = false,      -- VendorFloor's values in item tooltips
}
local db

local deals, order = {}, {}   -- confirmed finds: by key and as a sorted list
local queue, queued = {}, {}  -- finds still to be checked (list and by key)
local pendingInfo = {}        -- itemID -> browse results whose item data is still loading
local noOffer = {}            -- deal key -> { price, at }: checked, no buyout below vendor price (e.g. bid-only)
local NO_OFFER_KEEP = 30 * 60  -- seconds such a key is skipped while its browse price stays the same
local pendingBuys = {}        -- auctionID -> item purchase waiting for confirmation
local triedBids = {}          -- auctionID -> true: bought already, or the auction house refused it
local scan = { active = false, seen = 0, round = 0 }
local full = { active = false } -- the full scan (every auction at once)
local craft = {} -- price check of the crafting tab
local buy = {}                -- state of the find being checked or bought
local selected
local pendingSend, lastSend, sentAt, tries = nil, nil, nil, 0
local ahOpen = false
local offset = 0
local statusText = ""
local ui
local refreshSoon = false  -- the window is refreshed on the next tick

local StartScan, StopScan, Verify, ResetBuy, Refresh, ResultsReady, ReadResults, StartFull, NextRound, FullReady, StartCraftScan

-- The finds of the tab shown, in list order.
-- A find passes the minimum profit per unit and in percent. Both are a filter on the list,
-- so a change shows at once in both directions: raised, finds hide; lowered, they come back.
local function Shown(d)
	if d.mode == "wish" then return true end -- watchlist: your own price limit, no profit filter
	if d.mode == "de" and ns.CanDisenchant and not ns.CanDisenchant(d.id) then return false end
	if not (db and ns.Worth and d.price and d.vendor) or d.price <= 0 then return true end
	return ns.Worth(d.vendor, d.price)
end

local function View()
	local tab, list = db and db.tab or "vendor", {}
	for _, d in ipairs(order) do
		if (d.mode or "vendor") == tab and Shown(d) then list[#list + 1] = d end
	end
	if ns.SortList then ns.SortList(list) end
	return list
end

local function Print(msg)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. msg)
end
ns.Print = Print

local function Money(copper)
	copper = floor(copper or 0)
	local sign = ""
	if copper < 0 then sign, copper = "-", -copper end
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local text = sign
	if g > 0 then text = text .. ("|cffffd700%dg|r "):format(g) end
	if g > 0 or s > 0 then text = text .. ("|cffc7c7cf%ds|r "):format(s) end
	return text .. ("|cffeda55f%d%s|r"):format(c, ns.COPPER)
end
ns.Money = Money

-- Amount without colours, for the input field: "1g 20s 5c"
local function PlainMoney(copper)
	copper = floor(copper or 0)
	local g, s, c = floor(copper / 10000), floor(copper % 10000 / 100), copper % 100
	local parts = {}
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 or #parts == 0 then parts[#parts + 1] = c .. ns.COPPER end
	return table.concat(parts, " ")
end

-- Reads "5s", "1g 20s", "50c", "50k" or a bare number (copper). nil when nothing is readable.
local function ParseMoney(text)
	text = (text or ""):lower()
	local plain = tonumber(text)
	if plain then return floor(plain) end
	local total, found = 0, false
	for number, unit in text:gmatch("(%d+)%s*([gskc])") do
		local value = tonumber(number)
		if unit == "g" then value = value * 10000 elseif unit == "s" then value = value * 100 end
		total, found = total + value, true
	end
	return found and total or nil
end
ns.ParseMoney, ns.PlainMoney = ParseMoney, PlainMoney

-- What happened during the last purchases: Menu > Purchase log, for bug reports.
ns.log = {}
function ns.Log(fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	ns.log[#ns.log + 1] = ("%s  %s"):format(date("%H:%M:%S"), ok and text or fmt)
	ns.logAt = GetTime()
	if #ns.log > 80 then table.remove(ns.log, 1) end
end

-- Forever's auction house shows "Internal auction error" with purchases that go through.
-- Right after our own bid that red line is taken off the screen; should the purchase really
-- fail, it is shown after all (Tick).
ns.hideDbErrorUntil = 0
function ns.ShowError(msg)
	if UIErrorsFrame and msg then UIErrorsFrame:AddMessage(msg, 1, 0.1, 0.1, 1) end
end
function ns.ExpectDbError() ns.hideDbErrorUntil = GetTime() + 1.5 end
if UIErrorsFrame and hooksecurefunc then
	local function OnErrorShown(_, msg)
		if issecretvalue and issecretvalue(msg) then return end
		if msg == ERR_AUCTION_DATABASE_ERROR and GetTime() < ns.hideDbErrorUntil then
			ns.hideDbErrorUntil = 0
			UIErrorsFrame:Clear()
		end
	end
	if UIErrorsFrame.AddExternalErrorMessage then hooksecurefunc(UIErrorsFrame, "AddExternalErrorMessage", OnErrorShown) end
	hooksecurefunc(UIErrorsFrame, "AddMessage", OnErrorShown)
end

local function SetStatus(msg)
	statusText = msg or ""
	if ui then ui.status:SetText(statusText) end
end

---------------------------------------------------------------------------
-- Queries: only one at a time, and only once the auction house is ready
---------------------------------------------------------------------------

local pendingAt = 0
local SEND_FORCE = 10 -- seconds a query waits for the throttle before it is sent anyway

local function Send(fn)
	pendingSend, lastSend, pendingAt = fn, fn, GetTime()
end

local PRICE_SORT = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
-- Have the commodity results of this item arrived? (APIs missing on a client: no)
local function CommodityReady(id)
	if AH.HasFullCommoditySearchResults and AH.HasFullCommoditySearchResults(id) then return true end
	return AH.GetCommoditySearchResultsQuantity and (AH.GetCommoditySearchResultsQuantity(id) or 0) > 0 or false
end

local SORTS = { { sortOrder = PRICE_SORT, reverseSort = false } }

-- The item list to read. The disenchant tab reads only green and blue weapons and armor.
local function BrowseQuery(mode)
	local qualities = { "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality",
		"EpicQuality", "LegendaryQuality", "ArtifactQuality" }
	local classes = {}
	if mode == "de" then
		qualities = { "UncommonQuality", "RareQuality" }
		classes = { { classID = 2 }, { classID = 4 } } -- weapons, armor
	end
	local filters = {}
	for _, name in ipairs(qualities) do
		local value = Enum.AuctionHouseFilter and Enum.AuctionHouseFilter[name]
		if value ~= nil then filters[#filters + 1] = value end
	end
	return { searchString = "", minLevel = 0, maxLevel = 0, filters = filters, itemClassFilters = classes, sorts = SORTS }
end

---------------------------------------------------------------------------
-- Finds
---------------------------------------------------------------------------

-- Finds of the disenchant tab get their own keys, so one item can be in two tabs.
local function DealKey(key, mode)
	local k = (key.itemID or 0) .. ":" .. (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0) .. ":" .. (key.battlePetSpeciesID or 0)
	if mode and mode ~= "vendor" then k = mode .. "|" .. k end
	return k
end

-- Disenchant finds are grouped by item: every level and suffix of an item disenchants
-- the same. The variants (their auction keys, cheapest first) are tried one by one.
local function GroupKey(key, mode)
	if mode == "de" then return "de|" .. (key.itemID or 0) end
	return DealKey(key, mode)
end

local function AddVariant(d, key, price)
	d.variants = d.variants or {}
	local dk = DealKey(key)
	for _, v in ipairs(d.variants) do
		if v.dk == dk then
			if price < v.price then v.price = price end
			return
		end
	end
	d.variants[#d.variants + 1] = { dk = dk, key = key, price = price }
	table.sort(d.variants, function(a, b) return a.price < b.price end)
	d.key, d.vi, d.triedPlain = d.variants[1].key, 1, nil
end

-- The next variant of a grouped find to search, after the current one had nothing.
local function NextVariant(d)
	if not (d.variants and (d.vi or 1) < #d.variants) then return false end
	d.vi = (d.vi or 1) + 1
	d.key, d.triedPlain = d.variants[d.vi].key, nil
	return true
end

-- The current finds are kept in the saved variables after every change (full scan, quick
-- scan, check, purchase), so the next visit starts with what is really still there.
local function SaveFinds()
	if not (db and ahOpen) then return end
	local keep = {}
	for _, g in ipairs(order) do
		keep[#keep + 1] = { k = g.k, key = g.key, plainKey = g.plainKey, id = g.id, vendor = g.vendor, price = g.price,
			count = g.count, profit = g.profit, listed = g.listed, name = g.name, link = g.link, icon = g.icon,
			mode = g.mode, commodity = g.commodity, variants = g.variants, vi = 1 }
	end
	db.lastFinds = { at = time(), list = keep }
end

local function RemoveDeal(d)
	d.dropped = true
	deals[d.k] = nil
	for i = #order, 1, -1 do
		if order[i] == d then table.remove(order, i) end
	end
	if selected == d then selected = nil end
	SaveFinds()
end

-- Best total profit first.
local function SortDeals()
	table.sort(order, function(a, b)
		local pa, pb = a.profit or 0, b.profit or 0
		if pa ~= pb then return pa > pb end
		return a.k < b.k
	end)
end

-- Vendor price per unit; nil while the item data is still loading.
local function VendorPrice(item)
	local name, link, _, _, _, _, _, _, _, icon, sell = GetItemInfo(item)
	if not name then return nil end
	return sell or 0, name, link, icon
end

-- Units per auction, capped at the item's stack size. Some auction house versions report
-- grouped or listed counts for single items (a bag "830×" for one buyout), which turned
-- one auction above the vendor price into hundreds of fake units below it.
local function Units(item, quantity)
	quantity = max(floor(quantity or 1), 1)
	local stack = select(8, GetItemInfo(item))
	if stack and stack > 0 and quantity > stack then quantity = stack end
	return quantity
end

local function IsIgnored(itemID)
	return db.ignore and db.ignore[itemID] and true or false
end

-- Is buying at unit worth it against target (what one unit brings)? The minimum per unit,
-- the minimum in percent of the price and, with count, the minimum for the whole auction
-- (one auction takes one bag slot).
local function Worth(target, unit, count)
	local gain = target - unit
	if unit < 1 or gain < db.minProfit then return false end
	if (db.minPercent or 0) > 0 and gain / unit * 100 < db.minPercent then return false end
	if count and (db.minSlot or 0) > 0 and gain * count < db.minSlot then return false end
	return true
end
ns.Worth = Worth

-- Worth it for this find: watchlist finds only need to stay within your price limit.
function ns.Fits(d, target, unit, count)
	if d and d.mode == "wish" then return unit >= 1 and unit <= target end
	return Worth(target, unit, count)
end

-- Spending limit and free bag slots (settings). Purchases arrive by mail: the slots they
-- will take count from the purchase on until the mailbox has been visited.
function ns.Budget(money)
	local limit = (db.spendLimit or 0) * 10000
	if limit <= 0 then return money end
	return max(0, min(money, limit - (ns.session and ns.session.allSpent or 0)))
end

function ns.FreeSlots()
	local free = 0
	local get = C_Container and C_Container.GetContainerNumFreeSlots
	if not get then return nil end
	for _, bag in ipairs(ns.BAGS or { 0, 1, 2, 3, 4 }) do free = free + (get(bag) or 0) end
	return free - (ns.mailSlots or 0)
end

-- nil when the purchase may go ahead, else the reason why not.
function ns.Guard(cost, slots)
	if (db.spendLimit or 0) > 0 and cost > ns.Budget(cost) then
		return L["Spending limit of this session reached (%s). Change it in the settings."]:format(Money(db.spendLimit * 10000))
	end
	local free = (db.keepSlots or 0) > 0 and ns.FreeSlots()
	if free and free - (slots or 1) < db.keepSlots then
		return L["Bags almost full: %d slots free (purchases in the mail counted), %d to keep free."]:format(max(free, 0), db.keepSlots)
	end
end

-- Bag slots an amount of an item takes.
function ns.SlotsFor(item, qty)
	local stack = select(8, GetItemInfo(item)) or 1
	return math.ceil(max(qty or 1, 1) / max(stack, 1))
end

local function IsGear(item)
	local equipLoc = select(9, GetItemInfo(item))
	return equipLoc ~= nil and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE"
end

-- Watch list: items that were found below the vendor price, with how often. Quick rounds
-- check the most frequent of them one by one instead of reading the whole item list.
local function Watch(itemID)
	if not itemID or IsGear(itemID) then return end
	db.watch = db.watch or {}
	local w = db.watch[itemID] or { hits = 0 }
	w.hits, w.last = w.hits + 1, time()
	db.watch[itemID] = w
end

-- Hot items: what your purchases really earned, per item, with the auction keys bought
-- (gear differs by item level and suffix). Quick rounds check these first.
-- db.hot[itemID] = { profit = copper, buys, last = time, keys = { "level:suffix", ... } }
local function HotEntry(itemID, key, mode)
	db.hot = db.hot or {}
	local h = db.hot[itemID] or { profit = 0, buys = 0, keys = {} }
	h.last, h.mode = time(), mode or h.mode
	if key then
		local ks = (key.itemLevel or 0) .. ":" .. (key.itemSuffix or 0)
		local known = false
		for _, k in ipairs(h.keys) do known = known or k == ks end
		if not known then
			table.insert(h.keys, 1, ks)
			h.keys[4] = nil -- the three variants seen last
		end
	end
	db.hot[itemID] = h
	return h
end

function ns.LearnBuy(itemID, key, cost, value, mode)
	if not itemID or mode == "wish" then return end
	local h = HotEntry(itemID, key, mode)
	h.profit, h.buys = h.profit + max((value or 0) - (cost or 0), 0), h.buys + 1
end

-- Finds teach more than purchases: an item found often, and above all one whose find is
-- gone again within two minutes (someone else bought it), is where the big profits are.
-- kind "found": a new find; "gone": a find vanished without your purchase.
function ns.LearnFind(d, kind)
	if not (d and d.id) or d.mode == "wish" then return end
	local h = HotEntry(d.id, d.key, d.mode or "vendor")
	if kind == "found" then
		h.finds = (h.finds or 0) + 1
		h.findProfit = (h.findProfit or 0) + max(d.profit or ((d.vendor or 0) - (d.price or 0)), 0)
	elseif kind == "gone" and d.foundAt and GetTime() - d.foundAt < 120 then
		h.fast = (h.fast or 0) + 1
	end
end

-- Weight of a hot item: what you earned (gold, purchases), how often it was found and what
-- the finds were worth, and most of all how often a find was gone within two minutes.
-- It fades over 30 days without news.
function ns.HotScore(h)
	local age = (time() - (h.last or 0)) / 86400
	if age > 30 then return 0 end
	local gold = (h.profit or 0) / 10000 * 2 + (h.findProfit or 0) / 10000
	return (gold + (h.buys or 0) + (h.finds or 0) * 0.5 + (h.fast or 0) * 3) * (1 - age / 30)
end

-- Once: the hot items are seeded from the ledger kept for the website (db.items: buys,
-- spent and vendor value per item), so the purchases made before this version count too.
-- Gear variants come from the auction prices VendorFloor saw for that item (db.lows).
function ns.SeedHot()
	if db.hotSeeded then return end
	db.hotSeeded = true
	db.hot = db.hot or {}
	local variants = {}
	for pk in pairs(db.lows or {}) do
		local id, level, suffix = tostring(pk):match("^(%d+):(%-?%d+):(%-?%d+)")
		id = tonumber(id)
		if id then
			variants[id] = variants[id] or {}
			if #variants[id] < 3 and (tonumber(level) or 0) > 0 then variants[id][#variants[id] + 1] = level .. ":" .. suffix end
		end
	end
	local now = time()
	for id, it in pairs(db.items or {}) do
		local id2 = tonumber(id)
		if id2 and (it.buys or 0) > 0 and not db.hot[id2] then
			db.hot[id2] = { profit = max((it.value or 0) - (it.spent or 0), 0), buys = it.buys, last = now,
				keys = variants[id2] or {}, mode = "vendor" }
		end
	end
end

-- Sound and taskbar flash for new finds: once per round, at most once a minute.
local lastAlert = 0
local function Alert()
	if GetTime() - lastAlert < 60 then return end
	lastAlert = GetTime()
	if db.sound then PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959) end
	if db.flash and FlashClientIcon then FlashClientIcon() end
end

-- Stackable goods sell at a fixed price per unit; single items can be bid-only.
-- nil when the item data is not there yet.
local function IsCommodity(key)
	local info = AH.GetItemKeyInfo and AH.GetItemKeyInfo(key)
	if info == nil then return nil end
	return info.isCommodity and true or false
end

-- Messages about a disenchant find name its disenchant value instead of the vendor price.
local function DeText(d, text)
	if d and d.mode == "de" then return (text:gsub("vendor pays %%s", "disenchanting brings about %%s")) end
	if d and d.mode == "wish" then return (text:gsub("vendor pays %%s", "your limit %%s")) end
	return text
end

-- Take the find into the list and announce it.
local newFinds = {} -- new finds per tab since the last round summary

local function Confirm(d, quiet)
	if d.dropped or deals[d.k] then return end
	deals[d.k] = d
	order[#order + 1] = d
	if quiet then return end
	-- No chat line per find: the round ends with one line of counts (and the window lists them).
	local mode = d.mode or "vendor"
	if mode == "vendor" then Watch(d.id) end
	newFinds[mode] = (newFinds[mode] or 0) + 1
	d.foundAt = GetTime()
	if ns.LearnFind then ns.LearnFind(d, "found") end
end

-- Every candidate is checked against its real auctions before it is listed: an item
-- may have bid-only auctions, and for stackable goods the check counts how many units
-- lie below the vendor price. Once per round.
local function Enqueue(d)
	if d.queuedRound == scan.round then return end
	d.queuedRound = scan.round
	queue[#queue + 1] = d
end

-- A browse result as a candidate of one tab (target: what one unit brings in that tab).
local function AddCandidate(result, mode, target, id, name, link, icon)
	local key, price = result.itemKey, result.minPrice
	local k = GroupKey(key, mode)
	local d = deals[k] or queued[k]
	if not d then
		d = { k = k }
		queued[k] = d
	end
	if d.fullAt and GetTime() - d.fullAt < FULL_COOLDOWN then
		d.stale = false -- seen and counted by the last full scan: no check needed
		return
	end
	-- Checked before without a buyout below the target (bid-only auctions show their bid
	-- as the browse price): skip it until a cheaper listing appears or the entry expires.
	local skip = noOffer[k]
	if skip and price >= skip.price and GetTime() - skip.at < NO_OFFER_KEEP and not deals[k] then
		queued[k] = nil
		return
	end
	if mode == "de" and d.queuedRound == scan.round then
		-- another level or suffix of an item already in this round's group
		AddVariant(d, key, price)
		d.listed = (d.listed or 0) + (result.totalQuantity or 0)
		if price < (d.browsePrice or price) then d.browsePrice = price end
		return
	end
	d.browsePrice, d.mode = price, mode
	d.key, d.id, d.vendor, d.listed = key, id, target, result.totalQuantity or 0
	if mode == "de" then
		d.variants = nil
		AddVariant(d, key, price)
	end
	d.name, d.link, d.icon, d.stale, d.dropped = name, link, icon, false, nil
	d.commodity = IsCommodity(key) == true
	if d.commodity then
		-- Stackable goods always sell at a fixed price: listed at once with the browse price,
		-- the check later only counts the units below the target.
		d.price = price
		if not d.count then d.profit = target - price end
		Confirm(d)
	else
		-- Single items can be bid-only auctions: listed only once the check finds a buyout.
		d.price = d.price or price
	end
	Enqueue(d)
end

-- One browse result, for both auction tabs: below the vendor price and below its
-- disenchant value.
local function Evaluate(result)
	local key = result.itemKey
	local id, price = key.itemID, result.minPrice
	if IsIgnored(id) then return end
	local vendor, name, link, icon = VendorPrice(id)
	if vendor == nil then
		pendingInfo[id] = pendingInfo[id] or {}
		table.insert(pendingInfo[id], result)
		if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
		return
	end
	-- each tab scans for itself: the vendor tab only for vendor finds, the disenchant tab only for gear
	if scan.mode ~= "de" then
		local want = db.wishlist and db.wishlist[id]
		if want and price <= want.max then AddCandidate(result, "wish", want.max, id, name, link, icon) end
		if vendor > 0 and Worth(vendor, price) then AddCandidate(result, "vendor", vendor, id, name, link, icon) end
		return
	end
	if ns.DisenchantValue then
		local de = ns.DisenchantValue(link or id)
		if de and Worth(de, price) then AddCandidate(result, "de", de, id, name, link, icon) end
	end
end

local function Process(results)
	if type(results) ~= "table" then return end
	for _, result in ipairs(results) do
		local key = result.itemKey
		if key and key.itemID and result.minPrice and result.minPrice > 0 then
			scan.seen = scan.seen + 1
			Evaluate(result)
		end
	end
end

-- Set the minimum distance to the vendor price (copper per unit). The list follows at once
-- (Shown filters it); finds below the minimum stay known and come back when it is lowered.
-- typing: true while the value comes from the input field, whose text is left alone.
local function SetMinProfit(copper, typing)
	db.minProfit = max(floor(copper), 1)
	db.minProfitSilver = floor(db.minProfit / 100)
	ns.craftDirty = true -- the crafting tab filters by the same minimum
	if ui and not typing then ui.profit:SetText(PlainMoney(db.minProfit)) end
	SetStatus(L["Minimum profit per unit: %s"]:format(Money(db.minProfit)))
	Refresh()
end

-- Hide an item for good (right-click on a row).
local function Ignore(d)
	db.ignore = db.ignore or {}
	db.ignore[d.id] = d.name or true
	RemoveDeal(d)
	for _, other in pairs(deals) do
		if other.id == d.id then RemoveDeal(other) end
	end
	Print(L["Hidden: %s. Menu > Ignore list shows it again."]:format(d.link or d.name or d.id))
	Refresh()
end

---------------------------------------------------------------------------
-- Ledger (Trade.lua keeps it): the window's line follows every change
---------------------------------------------------------------------------

ns.OnLedgerChanged = function()
	if ui and ns.LedgerLine then ui.ledger:SetText(ns.LedgerLine()) end
end

---------------------------------------------------------------------------
-- Scan: the whole auction house item list, page by page
---------------------------------------------------------------------------

-- Watchlist round: one search per watched item, checked against your price limit.
function ns.StartWish()
	if not ahOpen or buy.state or full.active then return false end
	scan.mode = "vendor"
	scan.round = scan.round + 1
	wipe(queue)
	wipe(queued)
	for id, want in pairs(db.wishlist or {}) do
		local _, name, link, icon = VendorPrice(id)
		local key = AH.MakeItemKey and AH.MakeItemKey(id)
		if key then
			local k = GroupKey(key, "wish")
			local d = deals[k] or { k = k }
			d.key, d.id, d.vendor, d.mode = key, id, want.max, "wish"
			d.name, d.link, d.icon, d.dropped = name or want.name, link, icon, nil
			d.price = d.price or want.max
			d.browsePrice = nil
			d.commodity = IsCommodity(key) == true
			queued[k] = d
			Enqueue(d)
		end
	end
	if not queue[1] then
		SetStatus(L["The watchlist is empty. Add items with \"Edit watchlist\"."])
		Refresh()
		return false
	end
	scan.checkTotal, scan.seen, scan.checked = #queue, 0, 0
	SetStatus(L["Watchlist: checking %d items …"]:format(#queue))
	Refresh()
	return true
end

StartScan = function()
	if not ahOpen then
		Print(L["The auction house must be open."])
		return
	end
	if db.tab == "wish" then
		ns.StartWish()
		return
	end
	if buy.state or full.active then return end
	scan.active, scan.seen, scan.nextAt, scan.lastAt = true, 0, nil, GetTime()
	scan.mode = db.tab == "de" and "de" or "vendor"
	scan.round = scan.round + 1
	tries = 0
	wipe(queue)
	wipe(queued)
	for _, d in ipairs(order) do
		if not (d.fullAt and GetTime() - d.fullAt < FULL_COOLDOWN) then d.stale = true end
	end
	local mode = scan.mode
	Send(function() AH.SendBrowseQuery(BrowseQuery(mode)) end)
	SetStatus(mode == "de" and L["Scanning green and blue weapons and armor …"] or L["Scanning …"])
	Refresh()
end

StopScan = function(msg)
	scan.active, scan.nextAt = false, nil
	pendingSend, sentAt = nil, nil
	if msg then SetStatus(msg) end
	Refresh()
end

-- Quick round: the items found below vendor price most often, one search each, instead of
-- reading the whole item list. Gear is left out (its auction key depends on level and suffix).
local function StartQuick()
	if not ahOpen or buy.state or full.active then return false end
	scan.mode = "vendor"
	-- candidates: { id, score, key (gear: the variant bought before), mode }
	local list, seen = {}, {}
	for itemID, h in pairs(db.hot or {}) do
		local score = ns.HotScore(h)
		if score > 0 and not IsIgnored(itemID) and (h.mode or "vendor") ~= "craft" then
			seen[itemID] = true
			if IsGear(itemID) then
				for _, ks in ipairs(h.keys or {}) do
					local level, suffix = ks:match("(%-?%d+):(%-?%d+)")
					list[#list + 1] = { id = itemID, score = score + 1000, level = tonumber(level), suffix = tonumber(suffix),
						mode = h.mode, hot = true }
				end
			else
				list[#list + 1] = { id = itemID, score = score + 1000, mode = h.mode, hot = true }
			end
		end
	end
	for itemID, w in pairs(db.watch or {}) do
		if not seen[itemID] and not IsIgnored(itemID) then list[#list + 1] = { id = itemID, score = w.hits or 0 } end
	end
	if #list < 5 then return false end
	table.sort(list, function(x, y) return x.score > y.score end)
	scan.round = scan.round + 1
	wipe(queue)
	wipe(queued)
	local now, hot = GetTime(), 0
	for i = 1, min(#list, 40) do -- a quick round checks 40 items, those that paid off first
		local c = list[i]
		local vendor, name, link, icon = VendorPrice(c.id)
		local key = AH.MakeItemKey and (c.level and AH.MakeItemKey(c.id, c.level, c.suffix) or AH.MakeItemKey(c.id))
		local mode = c.mode == "de" and "de" or "vendor"
		local value = mode == "de" and ns.DisenchantValue and ns.DisenchantValue(link or c.id) or vendor
		if value and value > 0 and key then
			local k = GroupKey(key, mode)
			local skip = noOffer[k]
			if not (skip and now - skip.at < NO_OFFER_KEEP / 3) then
				local d = deals[k] or { k = k }
				d.key, d.id, d.vendor, d.mode = key, c.id, value, mode
				d.name, d.link, d.icon, d.dropped = name, link, icon, nil
				d.price = d.price or value
				d.browsePrice = d.browsePrice or value
				d.commodity = IsCommodity(key) == true
				queued[k] = d
				Enqueue(d)
				if c.hot then hot = hot + 1 end
			end
		end
	end
	if not queue[1] then return false end
	scan.checkTotal, scan.seen, scan.checked = #queue, 0, 0
	SetStatus(L["Quick round: checking %d items, %d of them paid off before …"]:format(#queue, hot))
	Refresh()
	return true
end

-- Continuous mode follows the tab shown: the vendor tab alternates quick rounds and the
-- whole item list, the disenchant tab reads gear only, the crafting tab checks the prices
-- of its items. It never starts a full scan: the auction house ignores a full scan that
-- does not come from a click or a key, so the full scan button only lights up.
NextRound = function()
	scan.rounds = (scan.rounds or 0) + 1
	if db.tab == "craft" then
		if not StartCraftScan() then scan.nextAt = GetTime() + db.interval end
	elseif db.tab == "wish" then
		if not ns.StartWish() then scan.nextAt = GetTime() + db.interval end
	elseif db.tab == "de" then
		StartScan()
	elseif scan.rounds % 3 ~= 0 and StartQuick() then
		return
	else
		StartScan()
	end
end

local function RoundDone()
	local v, e, w = newFinds.vendor or 0, newFinds.de or 0, newFinds.wish or 0
	wipe(newFinds)
	SetStatus(L["Round done: %d items read. New: vendor %d, disenchant %d."]:format(scan.seen, v, e))
	if v + e > 0 then
		Print(L["New finds: vendor %d, disenchant %d."]:format(v, e))
		Alert()
	end
	if w > 0 then
		Print(L["Watchlist: %d items within your price limit."]:format(w))
		Alert()
	end
	if db.loop then scan.nextAt = GetTime() + db.interval end
end

local function FinishScan()
	scan.active, sentAt = false, nil
	for i = #order, 1, -1 do
		local d = order[i]
		if d.stale and d ~= buy.deal then RemoveDeal(d) end
	end
	table.sort(queue, function(a, b)
		if a.commodity ~= b.commodity then return not a.commodity end
		return (a.vendor - a.price) > (b.vendor - b.price)
	end)
	-- never more than MAX_CHECKS per round: the most promising first, the rest next round
	for i = #queue, MAX_CHECKS + 1, -1 do
		local d = table.remove(queue, i)
		d.queuedRound = nil
		if not deals[d.k] then queued[d.k] = nil end
	end
	scan.checkTotal, scan.checked = #queue, 0
	if queue[1] then
		SetStatus(L["%d items read. Checking %d candidates …"]:format(scan.seen, #queue))
	else
		RoundDone()
	end
	Refresh()
end

local function ContinueScan()
	sentAt, tries = nil, 0
	if AH.HasFullBrowseResults() then
		FinishScan()
	else
		Send(function() AH.RequestMoreBrowseResults() end)
		SetStatus(L["Scanning … %d items read, %d finds"]:format(scan.seen, #order + #queue))
		Refresh()
	end
end

---------------------------------------------------------------------------
-- Checking and buying: read the item's real auctions first
---------------------------------------------------------------------------

local function CancelQuote()
	if AH.CancelCommoditiesPurchase then pcall(AH.CancelCommoditiesPurchase) end
end

ResetBuy = function(msg)
	wipe(buy)
	if msg then SetStatus(msg) end
	-- after buying, scanning goes on almost at once
	if db.loop and ahOpen and ui and ui:IsShown() and not queue[1] then scan.nextAt = GetTime() + 1 end
	Refresh()
end

-- purpose "buy": the find was clicked and is to be bought.
-- purpose "check": the round checks whether the find is real.
Verify = function(d, purpose)
	if not ahOpen then return end
	if scan.active then StopScan() end
	purpose = purpose or "buy"
	if purpose == "buy" then scan.nextAt = nil end
	-- gear from full scans: use the key that worked for this item before
	if d.plainKey and not d.triedPlain and keyStyle[d.id] == "plain" then
		d.key, d.triedPlain = d.plainKey, true
	end
	local chain = buy.chain
	wipe(buy)
	buy.state, buy.deal, buy.t, buy.purpose, buy.chain = "verifying", d, GetTime(), purpose, purpose == "buy" and chain or nil
	tries = 0
	ns.Log("search %s (%s, key %s:%s:%s)", tostring(d.name), purpose, tostring(d.key and d.key.itemID), tostring(d.key and d.key.itemLevel), tostring(d.key and d.key.itemSuffix))
	Send(function() AH.SendSearchQuery(d.key, SORTS, true) end)
	if purpose == "check" then
		SetStatus(L["Checking: %s (%d left)"]:format(d.link or d.name or "?", #queue))
	else
		SetStatus(L["Checking %s …"]:format(d.link or d.name or "?"))
	end
	Refresh()
end

-- Result of a check: with real offers into the list, without them out of it.
-- offer: { unit = cheapest unit price, count = units below vendor price, profit = total profit }
local function FinishCheck(d, offer)
	if offer == false then
		-- no answer: try once more at the end of the queue, keep what is already listed
		-- An item search without any auctions left sends no answer at all; after the second
		-- silent check the find counts as gone and is skipped like one without a buyout.
		d.retries = (d.retries or 0) + 1
		if d.retries <= 1 then
			queue[#queue + 1] = d
		else
			d.retries = nil
			if d.browsePrice then noOffer[d.k] = { price = d.browsePrice, at = GetTime() } end
			queued[d.k] = nil
		end
		wipe(buy)
		if not queue[1] and not scan.active then RoundDone() end
		Refresh()
		return
	end
	d.retries = nil
	if offer then
		noOffer[d.k] = nil
		d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
		Confirm(d)
		SortDeals()
		SaveFinds()
	else
		if d.browsePrice then noOffer[d.k] = { price = d.browsePrice, at = GetTime() } end
		if deals[d.k] then
			ns.LearnFind(d, "gone")
			RemoveDeal(d)
		end
	end
	queued[d.k] = nil
	wipe(buy)
	if not queue[1] and not scan.active then RoundDone() end
	Refresh()
end

-- Stackable goods (one price per unit): how many units lie below the vendor price?
-- limit: the gold that may be spent (nil: no limit, for the check).
local function CommodityOffer(d, limit)
	local count, cost, first = 0, 0, nil
	for i = 1, (AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(d.id) or 0) do
		local info = AH.GetCommoditySearchResultInfo(d.id, i)
		if not info or not info.unitPrice or not ns.Fits(d, d.vendor, info.unitPrice) then break end
		local n = (info.quantity or 0) - (info.numOwnerItems or 0)
		if limit then n = min(n, floor((limit - cost) / info.unitPrice)) end
		local want = d.mode == "wish" and db.wishlist and db.wishlist[d.id]
		if want and (want.qty or 0) > 0 then n = min(n, want.qty - count) end
		if n > 0 then
			first = first or info.unitPrice
			count, cost = count + n, cost + n * info.unitPrice
		end
	end
	if count <= 0 or (d.mode ~= "wish" and (db.minSlot or 0) > 0 and count * d.vendor - cost < db.minSlot) then return nil end
	return { unit = first, count = count, cost = cost, profit = count * d.vendor - cost }
end

-- Single items: all auctions with a buyout below the vendor price.
-- Bid-only auctions (buyoutAmount 0) are left out. best: the cheapest of them per unit.
local function ItemOffer(d)
	local best, count, profit = nil, 0, 0
	for i = 1, AH.GetNumItemSearchResults(d.key) do
		local info = AH.GetItemSearchResultInfo(d.key, i)
		if info and info.auctionID and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem
			and not triedBids[info.auctionID] then
			local quantity = Units(info.itemLink or d.id, info.quantity)
			-- vendor finds compare each auction with its own vendor price, the other tabs with the find's value
			local vendor = (d.mode or "vendor") == "vendor" and info.itemLink and VendorPrice(info.itemLink) or d.vendor
			local unit = info.buyoutAmount / quantity
			if vendor and ns.Fits(d, vendor, unit, quantity) then
				count, profit = count + quantity, profit + (vendor - unit) * quantity
				if not best or unit < best.unit then
					best = { auctionID = info.auctionID, buyout = info.buyoutAmount, quantity = quantity,
						unit = unit, vendor = vendor, link = info.itemLink }
				end
			end
		end
	end
	if not best then return nil end
	return { unit = best.unit, count = count, profit = profit, best = best }
end

-- The complete list of a checked item is a fresh price for it, like in a full scan.
local function RecordCommodityPrices(d)
	if not ns.RecordListing then return end
	local a = {}
	for i = 1, (AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(d.id) or 0) do
		local info = AH.GetCommoditySearchResultInfo(d.id, i)
		if info and info.unitPrice and info.quantity then
			a[#a + 1] = { info.unitPrice, info.quantity, (info.numOwnerItems or 0) >= info.quantity or nil }
		end
	end
	ns.RecordListing(d.plainKey or d.id, a)
end

local function RecordItemPrices(d)
	if not ns.RecordListing then return end
	local a = {}
	for i = 1, AH.GetNumItemSearchResults(d.key) do
		local info = AH.GetItemSearchResultInfo(d.key, i)
		if info and info.buyoutAmount and info.buyoutAmount > 0 then
			local q = max(info.quantity or 1, 1)
			a[#a + 1] = { info.buyoutAmount / q, q, info.containsOwnerItem or nil }
		end
	end
	ns.RecordListing(d.plainKey or d.id, a)
end

local function ReadCommodity()
	local d = buy.deal
	pcall(RecordCommodityPrices, d)
	if buy.purpose == "check" then
		FinishCheck(d, CommodityOffer(d))
		return
	end
	local offer = CommodityOffer(d, ns.Budget(GetMoney()))
	if not offer then
		local any = CommodityOffer(d)
		if any then
			-- still there, only not affordable: the find stays, scanning goes on
			d.price, d.count, d.profit = any.unit, any.count, any.profit
			ResetBuy(L["Not enough gold for %s (%s per unit). Scanning goes on."]:format(d.link or d.name, Money(any.unit)))
			return
		end
		if not buy.chain then ns.LearnFind(d, "gone") end
		RemoveDeal(d)
		ns.Gone(L["Nothing below vendor price any more."])
		return
	end
	d.askedAgain = nil
	buy.state, buy.qty, buy.cost = "commodity_ready", offer.count, offer.cost
	SetStatus(L["%d× %s below vendor price, profit about %s."]:format(offer.count, d.link or d.name, Money(offer.profit)))
	Refresh()
end

local function ReadItem()
	local d = buy.deal
	pcall(RecordItemPrices, d)
	local offer = ItemOffer(d)
	-- the cheapest auction of a check is kept: a click within a few seconds buys it at once
	if offer then d.best, d.bestAt = offer.best, GetTime() else d.best = nil end
	if buy.purpose == "check" then
		FinishCheck(d, offer)
		return
	end
	if not offer then
		if NextVariant(d) then
			Verify(d, "buy")
			return
		end
		if d.plainKey and not d.triedPlain then
			-- the full scan built this key from the item link; the plain item key may be the one in use
			d.key, d.triedPlain = d.plainKey, true
			Verify(d, "buy")
			return
		end
		if not buy.chain then ns.LearnFind(d, "gone") end
		RemoveDeal(d)
		ns.Gone(L["Nothing below vendor price any more."])
		return
	end
	d.askedAgain = nil
	local best = offer.best
	ns.Log("offer %s: auction %s, %s for %d", tostring(d.name), tostring(best.auctionID), tostring(best.buyout), best.quantity)
	if d.triedPlain and d.plainKey then keyStyle[d.id] = "plain" end
	d.price, d.count, d.profit = offer.unit, offer.count, offer.profit
	if ns.Budget(GetMoney()) < best.buyout then
		-- not affordable: the find stays, and nothing waits for a click that cannot buy
		ResetBuy(L["Not enough gold for %s (%s). Scanning goes on."]:format(best.link or d.link or d.name, Money(best.buyout)))
		return
	end
	buy.state = "item_ready"
	buy.auctionID, buy.buyout, buy.qty, buy.vendor, buy.link = best.auctionID, best.buyout, best.quantity, best.vendor, best.link
	SetStatus(L[DeText(d, "%s ×%d for %s, vendor pays %s.")]:format(best.link or d.link or d.name, best.quantity,
		Money(best.buyout), Money(best.vendor * best.quantity)))
	Refresh()
end

-- Does the auction house already hold the results of the last query for this find?
-- It sends no event for results it had before, so they are read without one.
ResultsReady = function(d)
	if not d then return false end
	if d.commodity then
		return CommodityReady(d.id)
	end
	return AH.HasSearchResults(d.key) and (AH.HasFullItemSearchResults(d.key) or (AH.GetItemSearchResultsQuantity(d.key) or 0) > 0)
end

ReadResults = function()
	if buy.deal and buy.deal.commodity then ReadCommodity() else ReadItem() end
end

-- The buy button and the key binding. Runs only on a click or key press.
local function Action()
	local state = buy.state
	if not state then
		if selected then Verify(selected) end
		return
	end
	local d = buy.deal
	if state == "item_ready" then
		if GetMoney() < buy.buyout then
			ResetBuy(L["Not enough gold."])
			return
		end
		local stop = ns.Guard(buy.buyout, 1)
		if stop then
			ResetBuy(stop)
			return
		end
		ns.Log("PlaceBid %s @ %s (%s)", tostring(buy.auctionID), tostring(buy.buyout), tostring(d.name))
		ns.ExpectDbError()
		AH.PlaceBid(buy.auctionID, buy.buyout)
		-- an auction is bid on once: if it is still listed afterwards, the purchase failed
		-- ("Internal auction error") and the next check moves on instead of offering it again
		triedBids[buy.auctionID] = true
		-- bids never confirmed (refused or failed) are let go after two minutes
		for id, p in pairs(pendingBuys) do
			if GetTime() - p.at > 120 then pendingBuys[id] = nil end
		end
		pendingBuys[buy.auctionID] = { id = d.id, qty = buy.qty, cost = buy.buyout, value = buy.vendor * buy.qty,
			name = d.name, at = GetTime(), mode = d.mode or "vendor", key = d.key }
		Print(L[DeText(d, "Purchase sent: %s ×%d for %s (vendor pays %s).")]:format(buy.link or d.link or d.name, buy.qty,
			Money(buy.buyout), Money(buy.vendor * buy.qty)))
		buy.state, buy.t, buy.chain, buy.confirmed, buy.dbErrorAt = "bought", GetTime(), true, nil, nil
	elseif state == "commodity_ready" then
		local stop = ns.Guard(buy.cost or 0, ns.SlotsFor(d.id, buy.qty))
		if stop then
			ResetBuy(stop)
			return
		end
		if AH.StartCommoditiesPurchase then AH.StartCommoditiesPurchase(d.id, buy.qty) end
		buy.state, buy.t = "quoting", GetTime()
	elseif state == "quote_ok" then
		if AH.ConfirmCommoditiesPurchase then AH.ConfirmCommoditiesPurchase(d.id, buy.qty) end
		buy.state, buy.t = "confirming", GetTime()
	end
	Refresh()
end

local BUSY = { quoting = true, confirming = true, bought = true, failed = true }

-- Hot deals: a find checked a few seconds ago is bought on the first click, without a new
-- search. The auction keeps its buyout, so the price cannot have risen; should it be sold
-- by now, the next auction of the item is tried (PurchaseFailed).
local function BuyNow(d, prepareOnly)
	local b = d.best
	if d.commodity or not b or not d.bestAt or GetTime() - d.bestAt > 15 or triedBids[b.auctionID] then return false end
	wipe(buy)
	buy.state, buy.deal, buy.t, buy.purpose = "item_ready", d, GetTime(), "buy"
	buy.auctionID, buy.buyout, buy.qty, buy.vendor, buy.link = b.auctionID, b.buyout, b.quantity, b.vendor, b.link
	if prepareOnly then
		-- ready to buy: the next click places the bid without another search
		ns.Log("ready at once %s (checked %.1fs ago)", tostring(d.name), GetTime() - d.bestAt)
		SetStatus(L[DeText(d, "%s ×%d for %s, vendor pays %s.")]:format(b.link or d.link or d.name, b.quantity,
			Money(b.buyout), Money(b.vendor * b.quantity)))
		Refresh()
		return true
	end
	ns.Log("buy at once %s (checked %.1fs ago)", tostring(d.name), GetTime() - d.bestAt)
	Action()
	return buy.state == "bought"
end

local function Select(d, click)
	local state = buy.state
	if BUSY[state] or (state == "verifying" and buy.purpose == "buy") then return end
	if state == "quote_ok" then CancelQuote() end
	if buy.purpose == "check" and buy.deal then
		-- interrupt the round's check: that find is checked again afterwards
		table.insert(queue, 1, buy.deal)
		pendingSend, sentAt = nil, nil
	end
	if state ~= "quote_ok" and BuyNow(d, not click) then
		selected = d
		return
	end
	selected = d
	Verify(d, "buy")
end

-- Key binding "Buy next find" and /vfloor buy: each press does the next step.
-- First press checks the selected (or best) find, the next one buys it.
-- Stackable goods need one press more: quote, then confirm.
function VendorFloor_BuyNext()
	if not ahOpen then return end
	local state = buy.state
	if state == "item_ready" or state == "commodity_ready" or state == "quote_ok" then
		Action()
		return
	end
	if BUSY[state] or (state == "verifying" and buy.purpose == "buy") then return end
	local d = (selected and deals[selected.k] and Shown(selected) and selected) or View()[1]
	if d then Select(d, true) end
end

-- A confirmed purchase: more of this find below the vendor price? Else on to the next find.
-- Runs on the confirmation itself, no fixed wait.
function ns.AfterBuy()
	local d = buy.deal
	if not d then return end
	local left = (d.count or 0) - (buy.qty or 1)
	if not d.commodity and left <= 0 then
		RemoveDeal(d)
		ns.Gone(L["Bought."])
	else
		Verify(d, "buy")
	end
end

-- A find has nothing left to buy. Right after a purchase the next find of the list is
-- checked at once, so the next click buys it (as in TransmogSweep).
function ns.Gone(msg)
	local chain = buy.chain
	ResetBuy(msg)
	if not (chain and ahOpen and ui and ui:IsShown()) then return end
	local d = View()[1]
	if d then
		selected = d
		buy.chain = true -- a find that turns out gone moves on to the next one too
		Select(d)
	end
end

-- Text for a bug report: the find, the state of the purchase and the purchase log.
function ns.Diagnose(d)
	d = d or {}
	local t = {
		("VendorFloor %s, client %s"):format(ns.VERSION or "?", (GetBuildInfo())),
		("find: %s id=%s mode=%s commodity=%s"):format(tostring(d.name), tostring(d.id), tostring(d.mode), tostring(d.commodity)),
		("key: %s:%s:%s plainKey=%s triedPlain=%s"):format(tostring(d.key and d.key.itemID), tostring(d.key and d.key.itemLevel),
			tostring(d.key and d.key.itemSuffix), tostring(d.plainKey ~= nil), tostring(d.triedPlain)),
		("price=%s value=%s count=%s profit=%s"):format(tostring(d.price), tostring(d.vendor), tostring(d.count), tostring(d.profit)),
		("best auction: %s @ %s, checked %s s ago"):format(tostring(d.best and d.best.auctionID), tostring(d.best and d.best.buyout),
			d.bestAt and ("%.1f"):format(GetTime() - d.bestAt) or "-"),
		("purchase: state=%s purpose=%s since %s s, auction=%s confirmed=%s dbError=%s"):format(tostring(buy.state),
			tostring(buy.purpose), buy.t and ("%.0f"):format(GetTime() - buy.t) or "-", tostring(buy.auctionID),
			tostring(buy.confirmed), tostring(buy.dbErrorAt ~= nil)),
		("scan: active=%s queue=%d checked=%s/%s pendingSend=%s full=%s craft=%s loop=%s nextAt=%s"):format(tostring(scan.active),
			#queue, tostring(scan.checked), tostring(scan.checkTotal), tostring(pendingSend ~= nil), tostring(full.active),
			tostring(craft.active), tostring(db.loop), scan.nextAt and ("%.0f"):format(scan.nextAt - GetTime()) or "-"),
		"", "purchase log:",
	}
	for _, line in ipairs(ns.log) do t[#t + 1] = line end
	return table.concat(t, "\n")
end

-- A purchase the auction house refused: the next auction of the same item is tried.
function ns.PurchaseFailed(msg)
	local d = buy.deal
	ns.Log("purchase failed: %s (auction %s)", tostring(msg), tostring(buy.auctionID))
	if d then
		-- the auction house keeps listing auctions that are gone: three refusals and the find is dropped
		d.fails = (d.fails or 0) + 1
		if d.fails >= 3 then
			ns.Log("%s dropped after %d refused auctions", tostring(d.name), d.fails)
			RemoveDeal(d)
			ns.Gone(L["Nothing below vendor price any more."])
			return
		end
	end
	wipe(buy)
	buy.state, buy.deal, buy.t, buy.chain = "failed", d, GetTime(), true
	SetStatus(L["Purchase failed (%s). Trying the next auction …"]:format(msg or "?"))
	Refresh()
	C_Timer.After(0.5, function()
		if buy.state == "failed" and buy.deal == d then
			if deals[d.k] then Verify(d, "buy") else ns.Gone() end
		end
	end)
end

---------------------------------------------------------------------------
-- Full scan: every auction of the auction house at once (allowed every 15 minutes).
-- Each auction comes with its buyout, so the finds need no check: bid-only auctions,
-- own auctions and auctions above the vendor price are simply left out.
---------------------------------------------------------------------------

FullReady = function()
	return time() - (db.lastFull or 0) >= FULL_COOLDOWN
end

local function FullWait()
	return max(FULL_COOLDOWN - (time() - (db.lastFull or 0)), 0)
end

-- The item key the auction house uses for this item: gear by item level and suffix,
-- everything else by item ID alone.
local function KeyFor(itemID, link)
	local make = AH.MakeItemKey
	local plain = make and make(itemID) or { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
	local equipLoc = select(9, GetItemInfo(link or itemID))
	if not (link and equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE" and make) then
		return plain, nil
	end
	local level = ns.GetDetailedItemLevelInfo and ns.GetDetailedItemLevelInfo(link)
	local suffix = tonumber(link:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")) or 0
	return make(itemID, level or 0, suffix), plain
end

local function BeginFull(phase)
	if buy.purpose == "check" then wipe(buy) end
	pendingSend, sentAt = nil, nil
	wipe(full)
	full.active, full.phase, full.t0 = true, phase, GetTime()
	full.items, full.pending, full.player = {}, {}, UnitName("player")
	full.prevLast = db.lastFull
	db.lastFull = time()
end

-- Ask the auction house for every auction (counts the tries: a dropped one is sent again).
local function SendFull(now)
	full.phase, full.t0, full.sends = "waiting", now, (full.sends or 0) + 1
	AH.ReplicateItems()
end

StartFull = function()
	if not ahOpen then
		Print(L["The auction house must be open."])
		return
	end
	if full.active then return end
	if not FullReady() then
		SetStatus(L["The full scan is available every 15 minutes."])
		return
	end
	if buy.state and buy.purpose ~= "check" then
		SetStatus(L["Full scan: finish the purchase first."])
		return
	end
	-- the click wins over a running scan (continuous mode picks up again afterwards)
	if scan.active then StopScan() end
	wipe(queue)
	wipe(queued)
	-- The request is one of the auction house's throttled messages: sent while a search is
	-- still under way it is dropped without an answer. Send it now if the line is free,
	-- otherwise as soon as it is (FullTick).
	BeginFull("sending")
	if AH.IsThrottledMessageSystemReady() then SendFull(GetTime()) end
	SetStatus(L["Full scan: waiting for the auction house …"])
	Refresh()
end

-- A full scan started by another addon (its full scan or autoscan) uses up the
-- auction house's 15 minutes: the auction house then ignores ours. Its list is read instead.
function ns.ReadForeignFull()
	if not ahOpen or full.active or scan.active or (buy.state and buy.purpose ~= "check") then return end
	if not FullReady() then return end -- the list of our own scan, arriving late
	BeginFull("arriving")
	full.count, full.stableAt = AH.GetNumReplicateItems(), GetTime()
	SetStatus(L["Full scan: waiting for the auction house …"])
	Refresh()
end

-- One auction of the list, collected by item. Returns false when its item data has not
-- loaded yet. Every auction with a buyout is kept: the vendor tab needs the cheap ones, the
-- disenchant and crafting tabs the usual price of all of them.
local function FullRecord(index)
	local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID, hasAll = AH.GetReplicateItemInfo(index)
	if not itemID then return true end
	if not hasAll then return false end
	if not buyout or buyout <= 0 or IsIgnored(itemID) then return true end
	local link = AH.GetReplicateItemLink and AH.GetReplicateItemLink(index)
	local vendor, name, itemLink, icon = VendorPrice(link or itemID)
	if vendor == nil then return false end
	count = Units(link or itemID, count)
	local unit = buyout / count
	if unit < 1 then return true end
	local key, plain = KeyFor(itemID, link)
	local pk = DealKey(key)
	local it = full.items[pk]
	if not it then
		it = { key = key, plainKey = plain, id = itemID, vendor = vendor, name = name, link = link or itemLink,
			icon = icon, a = {} }
		full.items[pk] = it
	end
	it.a[#it.a + 1] = { unit, count, owner and owner == full.player or nil }
	return true
end

---------------------------------------------------------------------------
-- Prices: the usual price of an item is the median of its daily median prices
-- (last 14 days), each daily value the median unit price of all its auctions.
---------------------------------------------------------------------------

local function MedianOf(list)
	if not list[1] then return nil end
	table.sort(list)
	local n = #list
	if n % 2 == 1 then return list[(n + 1) / 2] end
	return (list[n / 2] + list[n / 2 + 1]) / 2
end

-- The unit price at which share (0..1) of the listed units is reached, weighted by count,
-- own auctions left out. a: auctions { unit, count, own }. Also returns how many auctions count.
local function ListingQuantile(a, share)
	local list, total = {}, 0
	for _, x in ipairs(a) do
		if not x[3] then
			list[#list + 1] = x
			total = total + x[2]
		end
	end
	if total == 0 then return nil, 0 end
	table.sort(list, function(p, q) return p[1] < q[1] end)
	local run = 0
	for _, x in ipairs(list) do
		run = run + x[2]
		if run >= total * share then return x[1], #list end
	end
	return list[#list][1], #list
end

-- ListingQuantile(a, 0.5) is the median. ListingLow: what the cheapest tenth of the listed
-- units costs, the price to buy at and about the price a sale has to beat.
local function ListingLow(a) return (ListingQuantile(a, 0.1)) end

-- Day number (days since 1970) as the key of the price history: short in the saved file.
local function Today() return floor(time() / 86400) end

local matCache = {} -- itemID -> value of a disenchant material (false: none); cleared on new prices

local function StorePrice(pk, value)
	db.prices = db.prices or {}
	local h = db.prices[pk] or {}
	h[Today()] = floor(value + 0.5)
	local keys = {}
	for d in pairs(h) do keys[#keys + 1] = d end
	if #keys > MARKET_DAYS then
		table.sort(keys)
		for i = 1, #keys - MARKET_DAYS do h[keys[i]] = nil end
	end
	db.prices[pk] = h
end

local function StoreLow(pk, value)
	if not value then return end
	db.lows = db.lows or {}
	db.lows[pk] = { floor(value + 0.5), time() }
end

-- Latest low price of a price key (from the last full scan or price check), or nil.
local function LowValue(pk)
	local l = db.lows and db.lows[pk]
	if l and time() - l[2] < 3 * 86400 then return l[1] end
	return nil
end
ns.LowValue = LowValue

-- Prices from a checked item's complete list of auctions (pk: price key or item ID).
function ns.RecordListing(pk, a)
	if type(pk) == "number" then pk = ns.PlainKey(pk) end
	local med = pk and #a > 0 and ListingQuantile(a, 0.5)
	if not med then return end
	StorePrice(pk, med)
	StoreLow(pk, ListingLow(a))
	wipe(matCache) -- disenchant values follow the new price
end

-- Usual price of a price key and on how many days it rests (nil without data).
local function MarketValue(pk)
	local h = db.prices and db.prices[pk]
	if not h then return nil, 0 end
	local list = {}
	for _, v in pairs(h) do list[#list + 1] = v end
	return MedianOf(list), #list
end
ns.MarketValue = MarketValue

local function PlainKey(itemID)
	return DealKey(AH.MakeItemKey and AH.MakeItemKey(itemID) or { itemID = itemID })
end
ns.PlainKey = PlainKey

---------------------------------------------------------------------------
-- Disenchanting: expected materials of green and blue weapons and armor by item level,
-- after the Classic tables (Forever may differ), valued at the materials' usual price.
---------------------------------------------------------------------------

local DUST = { strange = 10940, soul = 11083, vision = 11137, dream = 11176, illusion = 16204 }
local ESS = { lmagic = 10938, gmagic = 10939, lastral = 10998, gastral = 11082, lmystic = 11134, gmystic = 11135,
	lnether = 11174, gnether = 11175, leternal = 16202, geternal = 16203 }
local SHARD = { sglim = 10978, lglim = 11084, sglow = 11138, lglow = 11139, srad = 11177, lrad = 11178,
	sbril = 14343, lbril = 14344 }

-- WoW Forever disenchant table (wow-professions.com, Forever guide): rows by the level
-- required to equip the item (not its item level), the same row for green and blue.
-- up to required level, { dust, avg. count }, { essence, avg. count }, shard
local DE_ROWS = {
	{ 10, { DUST.strange, 1.5 }, { ESS.lmagic, 1.5 }, nil },
	{ 15, { DUST.strange, 2.5 }, { ESS.gmagic, 1.5 }, SHARD.sglim },
	{ 20, { DUST.strange, 5 }, { ESS.lastral, 1.5 }, SHARD.sglim },
	{ 25, { DUST.soul, 1.5 }, { ESS.gastral, 1.5 }, SHARD.lglim },
	{ 30, { DUST.soul, 3.5 }, { ESS.lmystic, 1.5 }, SHARD.sglow },
	{ 35, { DUST.vision, 1.5 }, { ESS.gmystic, 1.5 }, SHARD.lglow },
	{ 40, { DUST.vision, 3.5 }, { ESS.lnether, 1.5 }, SHARD.srad },
	{ 45, { DUST.dream, 1.5 }, { ESS.gnether, 1.5 }, SHARD.lrad },
	{ 50, { DUST.dream, 3.5 }, { ESS.leternal, 1.5 }, SHARD.sbril },
	{ 55, { DUST.illusion, 1.5 }, { ESS.geternal, 1.5 }, SHARD.lbril },
	{ 60, { DUST.illusion, 3.5 }, { ESS.geternal, 2 }, SHARD.lbril },
}
local SHARD_CHANCE = 0.04 -- green items: a shard in about 3-5% of cases

local function MatValue(itemID, live)
	if matCache[itemID] ~= nil then return matCache[itemID] or nil end
	-- materials are sold again: value them at what a sale has to beat (the low price), not the median
	local pk = PlainKey(itemID)
	local value = live and live[pk] and ListingLow(live[pk].a) or LowValue(pk)
	if not value then
		local med = MarketValue(pk)
		value = med and med * 0.9
	end
	-- your own sales: the price that really sold, and how much of what you post sells at all
	local sold = ns.SoldPrice and ns.SoldPrice(itemID)
	if sold and (not value or sold < value) then value = sold end
	local rate = ns.SellRate and ns.SellRate(itemID)
	if value and rate then value = value * max(rate, 0.3) end
	matCache[itemID] = value or false
	return value
end

---------------------------------------------------------------------------
-- Learned disenchant results: every disenchant the player does is recorded (item and
-- materials), and once there are enough of them they replace the table above.
-- db.deLearn[key] = { n = disenchants, m = { [material itemID] = units } }
-- keys: "i<itemID>" per item, "b<quality>:<classID>:<item level>" per kind of item.
---------------------------------------------------------------------------

-- Item ID of an ID or link (GetItemInfoInstant is not a global on every client)
local function ItemID(item)
	if type(item) == "number" then return item end
	if type(item) ~= "string" then return nil end
	return tonumber(item:match("item:(%d+)")) or tonumber(item)
end
local LEARN_ITEM, LEARN_KIND = 3, 5 -- disenchants needed before the results count
local deCast
-- Every disenchant material: loot made only of these after an item left the bags is a disenchant.
-- (Forever may use its own spell ID for Disenchant, so the spell is not checked.)
local DE_MATS = { [20725] = true, [22445] = true, [22446] = true, [22447] = true, [22448] = true, [22449] = true, [22450] = true }
for _, t in ipairs({ DUST, ESS, SHARD }) do
	for _, id in pairs(t) do DE_MATS[id] = true end
end

local function BagCounts()
	local counts = {}
	local CC = C_Container
	for bag = 0, 4 do
		local slots = CC and CC.GetContainerNumSlots and CC.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = CC.GetContainerItemInfo(bag, slot)
			if info and info.itemID then counts[info.itemID] = (counts[info.itemID] or 0) + (info.stackCount or 1) end
		end
	end
	return counts
end

local function LearnKeys(itemID)
	local _, _, quality, itemLevel, _, _, _, _, _, _, _, classID = GetItemInfo(itemID)
	if not quality then return "i" .. itemID end
	return "i" .. itemID, ("b%d:%d:%d"):format(quality, classID or 0, itemLevel or 0)
end

local function AddLearned(key, mats)
	if not key then return end
	db.deLearn = db.deLearn or {}
	local e = db.deLearn[key] or { n = 0, m = {} }
	e.n = e.n + 1
	for id, qty in pairs(mats) do e.m[id] = (e.m[id] or 0) + qty end
	db.deLearn[key] = e
end

-- The disenchanted item is the one missing from the bags when the materials show up.
local function DeDebug(fmt, ...)
	if db and db.deDebug then print("|cffe0a83aVendorFloor DE|r " .. fmt:format(...)) end
end

local function DeGear(id)
	local _, _, quality, _, _, _, _, _, _, _, _, classID = GetItemInfo(id)
	return (quality == 2 or quality == 3 or quality == 4) and (classID == 2 or classID == 4)
end

-- The disenchanted item: the gear item locked in the bags while the loot is open, or the
-- one missing from the bags compared with before the cast.
local function FindTarget(before, mats)
	local CC = C_Container
	for bag = 0, 4 do
		for slot = 1, (CC and CC.GetContainerNumSlots and CC.GetContainerNumSlots(bag) or 0) do
			local info = CC.GetContainerItemInfo(bag, slot)
			if info and info.isLocked and info.itemID and DeGear(info.itemID) then return info.itemID, "locked" end
		end
	end
	if not before then return nil end
	local now = BagCounts()
	for id, count in pairs(before) do
		if (now[id] or 0) < count and not mats[id] and DeGear(id) then return id, "gone" end
	end
end

local deLoot -- loot of a disenchant whose item is not known yet: { mats, before, at }

local function Learn(id, mats, how)
	local itemKey, kindKey = LearnKeys(id)
	AddLearned(itemKey, mats)
	AddLearned(kindKey, mats)
	deLoot = nil
	DeDebug("recorded %s (%s)", select(2, GetItemInfo(id)) or id, how)
end

local function RecordDisenchant()
	local before = deCast and deCast.bags
	deCast = nil
	local n = GetNumLootItems and GetNumLootItems() or 0
	local mats, any = {}, false
	for i = 1, n do
		local id = ItemID(GetLootSlotLink(i))
		local _, _, qty = GetLootSlotInfo(i)
		if id then
			if not DE_MATS[id] then
				DeDebug("loot is not from disenchanting (%s)", id)
				return
			end
			mats[id] = (mats[id] or 0) + (qty or 1)
			any = true
		end
	end
	if not any then
		DeDebug("loot window without items (%d slots)", n)
		return
	end
	local id, how = FindTarget(before, mats)
	if id then
		Learn(id, mats, how)
	else
		deLoot = { mats = mats, before = before, at = GetTime() }
		DeDebug("materials seen, waiting for the item to leave the bags (snapshot %s)", before and "yes" or "no")
	end
end

-- After the loot is taken the item is gone from the bags.
local function RetryPending()
	if not deLoot then return end
	if GetTime() - deLoot.at > 5 then
		DeDebug("gave up: disenchanted item not found")
		deLoot = nil
		return
	end
	local id, how = FindTarget(deLoot.before, deLoot.mats)
	if id then Learn(id, deLoot.mats, how) end
end

local deEvents = CreateFrame("Frame")
for _, event in ipairs({ "UNIT_SPELLCAST_SENT", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED", "LOOT_READY",
	"LOOT_OPENED", "LOOT_CLOSED", "BAG_UPDATE_DELAYED" }) do
	pcall(deEvents.RegisterEvent, deEvents, event)
end
-- Only a Disenchant cast needs the bag snapshot, so other casts (combat!) skip the bag scan.
-- Compared by name: Forever may use a spell ID of its own for it. When the cast cannot be
-- told apart (no name, a hidden value), the snapshot is taken as before.
local DE_SPELL_NAME = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(13262)
local function IsDisenchantCast(spellID)
	if InCombatLockdown() then return false end
	if not spellID then return false end
	-- without spell names (no C_Spell) the spell ID of Disenchant decides
	if not DE_SPELL_NAME then return spellID == 13262 end
	if issecretvalue and issecretvalue(spellID) then return true end
	local ok, name = pcall(C_Spell.GetSpellName, spellID)
	if not ok or name == nil or (issecretvalue and issecretvalue(name)) then return true end
	return name == DE_SPELL_NAME
end

-- UNIT_SPELLCAST_SENT: unit, target, castGUID, spellID; FAILED/INTERRUPTED: unit, castGUID, spellID
deEvents:SetScript("OnEvent", function(_, event, unit, _, a3, a4)
	if event == "LOOT_READY" or event == "LOOT_OPENED" then
		if deLoot then return end
		local fresh = deCast and GetTime() - deCast.at < 15
		DeDebug("%s, cast before: %s", event, fresh and tostring(deCast.spell) or "none")
		if fresh or event == "LOOT_READY" then RecordDisenchant() end
	elseif event == "LOOT_CLOSED" or event == "BAG_UPDATE_DELAYED" then
		RetryPending()
	elseif unit == "player" then
		if event == "UNIT_SPELLCAST_SENT" then
			deCast = { at = GetTime(), bags = IsDisenchantCast(a4) and BagCounts() or nil, spell = a4 }
		elseif deCast and a3 == deCast.spell then
			deCast = nil
		end
	end
end)

-- Average materials per disenchant from the player's own results, or nil if there are too few.
local function Learned(itemID)
	if not db.deLearn then return nil end
	local itemKey, kindKey = LearnKeys(itemID)
	local e = db.deLearn[itemKey]
	if not (e and e.n >= LEARN_ITEM) then
		e = kindKey and db.deLearn[kindKey]
		if not (e and e.n >= LEARN_KIND) then return nil end
	end
	return e
end

-- Gear that cannot be disenchanted: the wands enchanters make, plus every item the game
-- refused to disenchant for you (learned from the error message).
local NO_DE = { [11287] = true, [11288] = true, [11289] = true, [11290] = true }
local function CanDisenchant(id)
	return id and not NO_DE[id] and not (db.noDE and db.noDE[id])
end
ns.CanDisenchant = CanDisenchant

local deTarget -- item clicked while the Disenchant cursor was up
if C_Container and C_Container.UseContainerItem and hooksecurefunc then
	hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
		if SpellIsTargeting and SpellIsTargeting() then
			local info = C_Container.GetContainerItemInfo(bag, slot)
			deTarget = info and info.itemID
		end
	end)
end
local noDeFrame = CreateFrame("Frame")
noDeFrame:RegisterEvent("UI_ERROR_MESSAGE")
noDeFrame:SetScript("OnEvent", function(_, _, _, msg)
	if issecretvalue and issecretvalue(msg) then return end -- messages the game hides from addons (secret values)
	if deTarget and ERR_CANT_BE_DISENCHANTED and msg == ERR_CANT_BE_DISENCHANTED then
		db.noDE = db.noDE or {}
		db.noDE[deTarget] = true
		deTarget = nil
	end
end)

-- How many of your own disenchants the value of this item is based on (nil: general table).
function ns.DeLearnedCount(item)
	local id = ItemID(item)
	local e = id and Learned(id)
	return e and e.n
end

local function LearnedValue(e, live)
	local value, priced = 0, false
	for id, qty in pairs(e.m) do
		local price = MatValue(id, live)
		if price then
			value = value + qty / e.n * price
			priced = true
		end
	end
	return priced and value or nil
end

-- What disenchanting one of these items brings (after the auction house cut), or nil.
-- Green armor: 75% dust, 20% essence; green weapons the other way round; plus a small
-- chance of a shard. Blue items: the shard of their row.
local function DisenchantValue(item, live)
	local _, _, quality, _, minLevel, _, _, _, _, _, _, classID = GetItemInfo(item)
	if not (quality and (classID == 2 or classID == 4)) or (quality ~= 2 and quality ~= 3) then return nil end
	local id = ItemID(item)
	if not CanDisenchant(id) then return nil end
	local learned = id and Learned(id)
	if learned then
		local v = LearnedValue(learned, live)
		if v then return v * AH_CUT end
	end
	local level = max(minLevel or 1, 1)
	local row
	for _, r in ipairs(DE_ROWS) do
		if level <= r[1] then
			row = r
			break
		end
	end
	row = row or DE_ROWS[#DE_ROWS]
	local value
	if quality == 2 then
		local dust, ess = MatValue(row[2][1], live), MatValue(row[3][1], live)
		if not (dust and ess) then return nil end
		local pDust, pEss = 0.75, 0.20
		if classID == 2 then pDust, pEss = 0.20, 0.75 end
		value = pDust * row[2][2] * dust + pEss * row[3][2] * ess
		local shard = row[4] and MatValue(row[4], live)
		if shard then value = value + SHARD_CHANCE * shard end
	else
		value = row[4] and MatValue(row[4], live)
	end
	return value and value * AH_CUT or nil
end
ns.DisenchantValue = DisenchantValue

-- Your recorded disenchants as text lines, most disenchanted first.
function ns.DeLines(limit)
	local list, lines = {}, {}
	for key, e in pairs(db.deLearn or {}) do
		local id = tonumber(key:match("^i(%d+)$"))
		if id then list[#list + 1] = { id = id, e = e } end
	end
	table.sort(list, function(a, b) return a.e.n > b.e.n end)
	if #list == 0 then return { L["No disenchants recorded yet."] } end
	for i = 1, min(#list, limit or #list) do
		local x = list[i]
		local v = LearnedValue(x.e)
		lines[#lines + 1] = L["%s: %d× disenchanted, about %s each"]:format(ns.ItemLink(x.id), x.e.n,
			v and Money(v * AH_CUT) or "?")
	end
	return lines
end

local function FinishFull(failed)
	full.active = false
	if failed then
		-- an unanswered request did not use up the auction house's 15 minutes: allow a retry
		db.lastFull = full.prevLast
		SetStatus(L["Full scan: the auction house did not answer. Click \"Full scan\" to try again."])
		Refresh()
		return
	end
	-- 1. today's usual price of every item (for disenchant materials and crafting)
	wipe(matCache)
	for pk, it in pairs(full.items) do
		local med = ListingQuantile(it.a, 0.5)
		if med then
			StorePrice(pk, med)
			StoreLow(pk, ListingLow(it.a))
		end
	end
	-- 2. finds per tab
	local found, counts = {}, { vendor = 0, de = 0, wish = 0 }
	local function add(mode, pk, it, target, unit, count)
		local k = GroupKey(it.key, mode)
		local g = found[k]
		if not g then
			g = { k = k, key = it.key, plainKey = it.plainKey, id = it.id, vendor = target, price = unit, count = 0,
				profit = 0, listed = 0, name = it.name, link = it.link, icon = it.icon, mode = mode, pk = pk }
			found[k] = g
			counts[mode] = counts[mode] + 1
		end
		g.count, g.profit, g.listed = g.count + count, g.profit + (target - unit) * count, g.listed + 1
		if unit < g.price then g.price = unit end
		if mode == "de" then
			AddVariant(g, it.key, unit)
			-- the group shows the base item, not one of its variants
			local baseName, baseLink = GetItemInfo(it.id)
			g.name, g.link = baseName or g.name, baseLink or g.link
		end
	end
	for pk, it in pairs(full.items) do
		local de = DisenchantValue(it.link or it.id, full.items)
		for _, x in ipairs(it.a) do
			local unit, count, own = x[1], x[2], x[3]
			if not own then
				if it.vendor > 0 and Worth(it.vendor, unit, count) then add("vendor", pk, it, it.vendor, unit, count) end
				if de and Worth(de, unit, count) then add("de", pk, it, de, unit, count) end
				local want = db.wishlist and db.wishlist[it.id]
				if want and unit <= want.max then add("wish", pk, it, want.max, unit, count) end
			end
		end
	end
	-- 3. into the lists
	local now, new = GetTime(), 0
	for k, g in pairs(found) do
		g.commodity = IsCommodity(g.key) == true
		g.fullAt, g.stale = now, false
		if g.mode == "vendor" then Watch(g.id) end
		local d = deals[k]
		if d then
			d.price, d.count, d.profit, d.listed, d.fullAt, d.stale = g.price, g.count, g.profit, g.listed, now, false
			d.vendor, d.mode = g.vendor, g.mode
			if g.variants then d.variants, d.key, d.vi, d.triedPlain = g.variants, g.key, 1, nil end
			d.plainKey = d.plainKey or g.plainKey
		else
			Confirm(g, true)
			new = new + 1
		end
	end
	-- the full list is complete: what it did not show is gone
	for i = #order, 1, -1 do
		local d = order[i]
		if not found[d.k] and d ~= buy.deal then RemoveDeal(d) end
	end
	full.items = nil
	ns.craftDirty = true
	-- kept for the next visit: until the next full scan is allowed the finds come from here
	SortDeals()
	SaveFinds()
	SetStatus(L["Full scan done: %d auctions. Vendor %d, disenchant %d finds."]:format(full.count or 0,
		counts.vendor, counts.de))
	if new > 0 then
		Print(L["%d new finds (vendor %d, disenchant %d)."]:format(new, counts.vendor, counts.de))
		Alert()
	end
	if db.loop then scan.nextAt = GetTime() + 5 end
	Refresh()
end

---------------------------------------------------------------------------
-- Price check for the crafting tab: one search per reagent and product of your
-- recipes, their current median price goes into the price history.
---------------------------------------------------------------------------

local CRAFT_WAIT, CRAFT_TIMEOUT = 0.6, 3

local function CraftItems()
	local char = (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "")
	local mine = db.recipes and db.recipes[char]
	local seen, list = {}, {}
	local function add(id)
		if id and not seen[id] then
			seen[id] = true
			list[#list + 1] = id
		end
	end
	for _, p in pairs(mine or {}) do
		for _, rec in ipairs(p.list or {}) do
			add(rec.out)
			for _, r in ipairs(rec.r) do
				-- reagents a merchant sells are not looked up on the auction house
				if not (db.vendorBuy and db.vendorBuy[r[1]]) then add(r[1]) end
			end
		end
	end
	return list
end

StartCraftScan = function()
	if not ahOpen or buy.state or full.active or scan.active then return false end
	local list = CraftItems()
	if not list[1] then
		SetStatus(L["Open each profession window once so VendorFloor can read your recipes."])
		return false
	end
	wipe(craft)
	craft.active, craft.list, craft.i, craft.found = true, list, 0, 0
	scan.nextAt = nil
	SetStatus(L["Price check: %d reagents and products …"]:format(#list))
	Refresh()
	return true
end

local function StopCraftScan(msg)
	wipe(craft)
	if msg then SetStatus(msg) end
end

local function ReadCraftPrice(id)
	local key = AH.MakeItemKey and AH.MakeItemKey(id)
	local a = {}
	local n = AH.GetNumCommoditySearchResults and AH.GetNumCommoditySearchResults(id) or 0
	for i = 1, n do
		local info = AH.GetCommoditySearchResultInfo(id, i)
		-- commodity results count your own units (numOwnerItems) instead of flagging them
		if info and info.unitPrice then
			local q = (info.quantity or 0) - (info.numOwnerItems or 0)
			if q > 0 then a[#a + 1] = { info.unitPrice, q } end
		end
	end
	if not a[1] and key then
		for i = 1, (AH.GetNumItemSearchResults(key) or 0) do
			local info = AH.GetItemSearchResultInfo(key, i)
			if info and info.buyoutAmount and info.buyoutAmount > 0 and not info.containsOwnerItem then
				local q = max(info.quantity or 1, 1)
				a[#a + 1] = { info.buyoutAmount / q, q }
			end
		end
	end
	local med = ListingQuantile(a, 0.5)
	if med then
		local pk = PlainKey(id)
		StorePrice(pk, med)
		StoreLow(pk, ListingLow(a))
		wipe(matCache)
		craft.found = craft.found + 1
	end
end

local function CraftTick(now)
	if craft.cur then
		local id, key = craft.cur, craft.key
		local ready = CommodityReady(id)
			or (key and AH.HasSearchResults(key) and (AH.HasFullItemSearchResults(key) or (AH.GetItemSearchResultsQuantity(key) or 0) > 0))
		if ready and now - craft.t > CRAFT_WAIT then
			ReadCraftPrice(id)
			craft.cur = nil
		elseif now - craft.t > CRAFT_TIMEOUT then
			craft.cur = nil -- no auctions of it right now
		end
		return
	end
	craft.i = craft.i + 1
	local id = craft.list[craft.i]
	if not id then
		local found = craft.found
		local total = #craft.list
		StopCraftScan(L["Price check done: %d of %d items on the auction house."]:format(found, total))
		ns.craftDirty = true
		if db.loop then scan.nextAt = GetTime() + db.interval end
		Refresh()
		return
	end
	local key = AH.MakeItemKey and AH.MakeItemKey(id)
	craft.cur, craft.key, craft.t = id, key, now
	Send(function() AH.SendSearchQuery(key, SORTS, true) end)
	Refresh()
end

local function FullTick(now)
	if full.phase == "sending" then
		-- a search was still under way: wait for the line, at most 10 seconds
		if AH.IsThrottledMessageSystemReady() or now - full.t0 > 10 then SendFull(now) end
	elseif full.phase == "waiting" then
		-- no answer: the auction house may have ignored the request because another addon ran a
		-- full scan within the last 15 minutes. Its list is still there: read that one.
		local n = AH.GetNumReplicateItems()
		if now - full.t0 > FULL_REUSE and n and n > 0 then
			full.phase, full.count, full.stableAt = "arriving", n, now
		elseif now - full.t0 > FULL_WAIT then
			FinishFull(true)
		end
	elseif full.phase == "arriving" then
		-- the list can arrive in parts: read it once it has stopped growing for two seconds
		local n = AH.GetNumReplicateItems()
		if n ~= full.count then
			full.count, full.stableAt = n, now
		elseif now - full.stableAt > 2 then
			full.phase, full.index = "reading", 0
		end
	elseif full.phase == "reading" then
		local last = min(full.index + FULL_PER_TICK, full.count) - 1
		for i = full.index, last do
			if not FullRecord(i) then
				full.pending[#full.pending + 1] = i
				-- ask the client for each item once, not once per auction
				local itemID = select(17, AH.GetReplicateItemInfo(i))
				full.requested = full.requested or {}
				if itemID and not full.requested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
					full.requested[itemID] = true
					C_Item.RequestLoadItemDataByID(itemID)
				end
			end
		end
		full.index = last + 1
		SetStatus(L["Full scan: reading %d of %d auctions …"]:format(full.index, full.count))
		if full.index >= full.count then full.phase, full.loadT, full.progressT = "loading", now, now end
	elseif full.phase == "loading" then
		-- items the client had not loaded yet: up to 30 seconds more
		-- A client with an empty item cache (fresh install, or a client language played for the
		-- first time: the cache is per language) has to load almost every item. Keep waiting as
		-- long as items keep arriving: up to 3 minutes, but stop after 20 seconds without progress.
		local still = {}
		for n, i in ipairs(full.pending) do
			if n > FULL_PER_TICK * 5 or not FullRecord(i) then still[#still + 1] = i end
		end
		if #still < #full.pending then full.progressT = now end
		full.pending = still
		if still[1] and now - full.loadT < 180 and now - (full.progressT or full.loadT) < 20 then
			SetStatus(L["Full scan: loading item data (%d left) …"]:format(#still))
		else
			FinishFull()
		end
	end
	Refresh()
end

---------------------------------------------------------------------------
-- Clock: send queries, time-outs, the check queue, continuous mode
---------------------------------------------------------------------------

local function Tick()
	local now = GetTime()
	if refreshSoon then
		refreshSoon = false
		Refresh()
	end
	if full.active then
		FullTick(now)
		return
	end
	-- Watchdog: checks waiting and nothing happened for 30 s. The state goes to the purchase
	-- log, then whatever holds the queue is let go.
	if queue[1] and not craft.active and now - (ns.logAt or now) > 30 and now - (ns.dogAt or 0) > 30 then
		ns.dogAt = now
		ns.Log("watchdog: queue stuck, state=%s pendingSend=%s sentAt=%s scan=%s", tostring(buy.state),
			tostring(pendingSend ~= nil), sentAt and ("%.0f"):format(now - sentAt) or "-", tostring(scan.active))
		if buy.state ~= "quote_ok" and buy.state ~= "confirming" then wipe(buy) end
		if pendingSend and now - (pendingAt or now) > 10 then pendingSend = nil end
		if scan.active and not pendingSend and (not sentAt or now - sentAt > 30) then
			scan.active, sentAt = false, nil
		end
		return
	end
	if craft.active and not pendingSend then
		CraftTick(now)
		return
	end
	if pendingSend then
		-- The throttle can stay "not ready" after a purchase; send anyway after a while.
		-- A dropped query comes back through AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED.
		if AH.IsThrottledMessageSystemReady() or now - pendingAt > SEND_FORCE then
			local fn = pendingSend
			pendingSend, sentAt = nil, now
			fn()
		end
		return
	end
	-- A purchase search sent during a scan replaces the browse query: no more pages come.
	-- The scan ends there, the waiting checks go on and the next round starts after them.
	if scan.active and not buy.state and now - (scan.lastAt or now) > 8 then
		ns.Log("scan ended: no more pages for %.0f s (%d auctions read)", now - scan.lastAt, scan.seen or 0)
		StopScan()
		if not queue[1] and db.loop then scan.nextAt = now + db.interval end
		return
	end
	if scan.active and sentAt and now - sentAt > SEND_TIMEOUT then
		if tries < 3 and lastSend then
			tries = tries + 1
			pendingSend = lastSend
		else
			StopScan(L["The auction house is not responding. Scan stopped."])
		end
		return
	end
	local state = buy.state
	-- Watchdog: a find made ready to buy is let go after 20 s without a click, and anything
	-- else that has not moved for 20 s is reset, so the checks of the round, and in continuous
	-- mode the next round, go on.
	if state and (queue[1] or db.loop) and not scan.active then
		local waiting = state == "item_ready" or state == "commodity_ready"
		if (waiting and now - (buy.t or now) > 20) or (not waiting and state ~= "quote_ok" and state ~= "confirming"
			and now - (buy.t or now) > 20 and now - (ns.logAt or 0) > 20) then
			ns.Log("watchdog: %s for %s let go after %.0f s", tostring(state), tostring(buy.deal and buy.deal.name), now - (buy.t or now))
			wipe(buy)
			pendingSend, sentAt = nil, nil
			if db.loop and not queue[1] then scan.nextAt = now + 1 end
			Refresh()
			return
		end
	end
	if not state and not scan.active and queue[1] then
		local d = table.remove(queue, 1)
		if not d.dropped then
			scan.checked = (scan.checked or 0) + 1
			Verify(d, "check")
		end
		return
	end
	-- A check reads held results quickly. A purchase waits longer for fresh ones, so an
	-- auction bought a moment ago is not offered again from old results.
	local wait = buy.purpose == "check" and CACHE_WAIT or 2.5
	if state == "verifying" and sentAt and now - sentAt > wait and ResultsReady(buy.deal) then
		ReadResults()
		return
	end
	if state == "verifying" and buy.purpose == "check" and now - buy.t > CHECK_TIMEOUT then
		FinishCheck(buy.deal, false)
	elseif state == "verifying" and not pendingSend and now - buy.t > BUY_SILENT then
		-- No answer to a purchase check: the auction house sends none for a search without
		-- results. Gear from a full scan gets a second try with the plain item key, then it is gone.
		local d = buy.deal
		if d and not d.askedAgain then
			-- an empty answer is asked once more before the item counts as gone
			d.askedAgain = true
			ns.Log("no answer for %s, asking again", tostring(d.name))
			Verify(d, "buy")
		elseif d and NextVariant(d) then
			Verify(d, "buy")
		elseif d and d.plainKey and not d.triedPlain then
			d.key, d.triedPlain = d.plainKey, true
			Verify(d, "buy")
		else
			if d then
				if not buy.chain then ns.LearnFind(d, "gone") end
				RemoveDeal(d)
			end
			ns.Gone(L["Nothing below vendor price any more."])
		end
	elseif state == "verifying" and now - buy.t > SEND_TIMEOUT then
		ResetBuy(L["No answer while checking."])
	elseif state == "bought" and buy.dbErrorAt and not buy.confirmed and now - buy.dbErrorAt > 2 then
		-- "Internal auction error" and no confirmation after it: this time it was real
		ns.ShowError(ERR_AUCTION_DATABASE_ERROR)
		ns.PurchaseFailed(ERR_AUCTION_DATABASE_ERROR)
	elseif state == "bought" and not buy.confirmed and not buy.dbErrorAt and now - buy.t > 2 then
		Verify(buy.deal, "buy") -- no confirmation event: look whether it is still listed
	elseif (state == "quoting" or state == "confirming") and now - buy.t > 12 then
		CancelQuote()
		ResetBuy(L["No answer from the auction house."])
	elseif state == "quote_ok" and now - buy.t > 10 then
		CancelQuote()
		ResetBuy(L["Quote expired."])
	end
	if scan.nextAt and not scan.active and not buy.state and not queue[1] and now >= scan.nextAt then
		scan.nextAt = nil
		NextRound()
	end
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local TAB_HINT = {
	wish = "Items you want, at or below your price limit. Add them with \"Edit watchlist\" (shift-click an item into the field). \"Scan\" searches each watched item; normal and full scans fill this list too.",
	vendor = "Auctions below what a merchant pays. Scan, or a full scan every 15 minutes.",
	de = "Green and blue weapons and armor below what disenchanting them brings (WoW Forever disenchant tables and your own results, materials at the cheapest listings). \"Scan\" on this tab reads only green and blue weapons and armor; full scans fill it too. Needs Enchanting (any skill: Forever lets you disenchant everything from skill 1).",
	craft = "Your learned recipes that make a profit: product (auction house after the cut, or merchant) minus reagents (auction house or merchant, whichever is cheaper). Open each profession window once so VendorFloor can read your recipes. \"Prices\" looks up the current price of each reagent and product; full scans and merchants you visit add to it.",
}

-- Result list columns (built in BuildUI): price, value, profit and quantity per row.
function ns.RowColumns(row, price, value, profit, qty)
	row.price:SetText(price)
	row.value:SetText(value)
	row.profit:SetText(profit)
	row.qty:SetText(qty)
end

ns.HEADERS = {
	vendor = { L["Price"], L["Vendor price"], L["Profit"], L["Qty"] },
	de = { L["Price"], L["Disenchant value"], L["Profit"], L["Qty"] },
	craft = { L["Reagents"], L["Sells for"], L["Profit"], L["Via"] },
	wish = { L["Price"], L["Your limit"], L["Below limit"], L["Qty"] },
}
-- Scroll bar of the result list follows the offset.
function ns.UpdateScroll(total)
	local sb = ui and ui.scrollBar
	if not sb then return end
	local maxOffset = max(total - ROWS, 0)
	sb.updating = true
	sb:SetMinMaxValues(0, maxOffset)
	sb:SetValue(offset)
	sb.updating = false
	if sb.ScrollUpButton then sb.ScrollUpButton:SetEnabled(offset > 0) end
	if sb.ScrollDownButton then sb.ScrollDownButton:SetEnabled(offset < maxOffset) end
	if ui.editWish then ui.editWish:SetShown(db.tab == "wish") end
end

-- Sorting by a column header (click: sort, again: reverse). Unsorted: best profit first.
ns.SORT_FIELDS = {
	name = function(x) return (x.name or ""):lower() end,
	price = function(x) return x.price or x.cost or 0 end,
	value = function(x) return x.vendor or x.revenue or 0 end,
	profit = function(x) return x.profit or 0 end,
	qty = function(x) return x.count or (x.route == "ah" and 1 or 0) end,
}
function ns.SortList(list)
	local s = db and db.sort
	local get = s and ns.SORT_FIELDS[s.key]
	if not get then return end
	table.sort(list, function(a, b)
		local x, y = get(a), get(b)
		if x == y then return (a.profit or 0) > (b.profit or 0) end
		if s.desc then return x > y end
		return x < y
	end)
end

function ns.SortBy(key)
	local s = db.sort
	if s and s.key == key then
		s.desc = not s.desc
	else
		db.sort = { key = key, desc = key ~= "name" and key ~= "price" }
	end
	offset = 0
	Refresh()
end

function ns.ListHeader(tab)
	local h, t = ui and ui.hdr, ns.HEADERS[tab] or ns.HEADERS.vendor
	if not h then return end
	for key, cell in pairs(ui.hdrCells) do
		local on = db.sort and db.sort.key == key
		cell.arrow:SetShown(on and true or false)
		if on then cell.arrow:SetTexCoord(0, 0.5625, db.sort.desc and 0 or 1, db.sort.desc and 1 or 0) end
	end
	h.price:SetText(t[1])
	h.value:SetText(t[2])
	h.profit:SetText(t[3])
	h.qty:SetText(t[4])
	h.name:SetText(tab == "craft" and L["Recipe"] or L["Name"])
end

-- Crafting tab: rows show recipes instead of auctions.
local function RefreshCraft()
	local list, miss = {}, 0
	if ns.CraftResults then list, miss = ns.CraftResults() end
	ns.SortList(list)
	local maxOffset = max(#list - ROWS, 0)
	offset = max(min(offset, maxOffset), 0)
	ui.empty:SetShown(#list == 0)
	ui.empty:SetText(L[TAB_HINT.craft])
	for i = 1, ROWS do
		local row, c = ui.rows[i], list[i + offset]
		row.deal, row.craft = nil, c
		if c then
			row.icon:SetTexture(c.icon)
			row.name:SetText((c.link or c.name) .. (c.qty ~= 1 and (" ×" .. c.qty) or ""))
			ns.RowColumns(row, Money(c.cost), Money(c.revenue), "|cff6cc58c+" .. Money(c.profit) .. "|r",
				c.route == "ah" and L["AH"] or L["merchant"])
			row.mark:Hide()
			row:Show()
		else
			row:Hide()
		end
	end
	local profs = ns.CraftProfessions and ns.CraftProfessions() or {}
	local profText = table.concat(profs, ", ")
	ui.summary:SetText(#list == 0 and "" or profText == "" and L[#list == 1 and "1 craft with profit" or "%d crafts with profit"]:format(#list)
		or L[#list == 1 and "1 craft with profit · %s" or "%d crafts with profit · %s"]:format(#list, profText))
	ui.count:SetText(#list > ROWS and L["%d–%d of %d"]:format(offset + 1, min(offset + ROWS, #list), #list) or "")
	ns.UpdateScroll(#list)
	if miss > 0 and not craft.active then SetStatus(L["%d recipes have no prices yet (reagent or product never seen in a full scan)."]:format(miss)) end
	ui.action:SetText(L["Read recipes: open a profession window"])
	ui.action:SetEnabled(false)
	ui.loop:SetChecked(db.loop)
end

Refresh = function()
	if not ui then return end
	ns.ListHeader(db.tab)
	local view = View()
	local maxOffset = max(#view - ROWS, 0)
	offset = max(min(offset, maxOffset), 0)
	for _, mode in ipairs(TABS) do
		local n = 0
		if mode == "craft" then
			n = ns.CraftResults and #(ns.CraftResults()) or 0
		else
			for _, d in ipairs(order) do if (d.mode or "vendor") == mode and Shown(d) then n = n + 1 end end
		end
		local tab = ui.tabs[mode]
		tab:SetText(n > 0 and ("%s (%d)"):format(tab.label, n) or tab.label)
		tab:SetOn(db.tab == mode)
	end
	ui.empty:SetShown(#view == 0)
	ui.empty:SetText(full.active and L["Full scan running: every auction is read at once. The first finds appear in about a minute."]
		or L[TAB_HINT[db.tab] or TAB_HINT.vendor])
	for i = 1, ROWS do
		local row, d = ui.rows[i], view[i + offset]
		row.deal, row.craft = d, nil
		if d then
			row.icon:SetTexture(d.icon)
			row.name:SetText(d.link or d.name or ("item:" .. d.id))
			ns.RowColumns(row, Money(d.price), (d.mode == "de" and "~" or "") .. Money(d.vendor),
				"|cff6cc58c+" .. Money(d.profit or 0) .. "|r", d.count and (d.count .. "×") or "?")
			row.mark:SetShown(d == selected)
			row:Show()
		else
			row:Hide()
		end
	end
	local checking = buy.purpose == "check" or (queue[1] ~= nil and not buy.state)
	ns.UpdateFullButton()

	-- progress: full scan (auctions read), check phase (candidates checked), browsing (no total known)
	local fraction
	if full.active then
		fraction = full.phase == "reading" and full.count and full.count > 0 and full.index / full.count
			or full.phase == "loading" and 1 or 0
	elseif craft.active then
		fraction = craft.i / max(#craft.list, 1)
	elseif checking and ((scan.checked or 0) + #queue) > 0 then
		fraction = (scan.checked or 0) / ((scan.checked or 0) + #queue)
	elseif scan.active then
		fraction = 0
	end
	ui.bar:SetShown(fraction ~= nil)
	if fraction then
		fraction = max(0, min(1, fraction))
		ui.bar:SetValue(fraction)
		local label
		if full.active then
			label = full.phase == "reading" and L["Full scan %d%%"]:format(floor(fraction * 100))
				or full.phase == "loading" and L["Full scan: loading item data"]
				or L["Full scan: waiting for the auction house"]
		elseif craft.active then
			label = L["Prices %d of %d (%d%%)"]:format(craft.i, #craft.list, floor(fraction * 100))
		elseif checking and ((scan.checked or 0) + #queue) > 0 then
			label = L["Checking %d of %d (%d%%)"]:format(scan.checked or 0, (scan.checked or 0) + #queue, floor(fraction * 100))
		else
			label = L["Reading auctions: %d"]:format(scan.seen or 0)
		end
		ui.bar.text:SetText(label)
	end

	if db.tab == "craft" then
		RefreshCraft()
		return
	end

	-- summary: what the whole list of this tab would cost and bring
	local cost, profit = 0, 0
	for _, d in ipairs(view) do
		local n = d.count or 1
		cost, profit = cost + (d.price or 0) * n, profit + (d.profit or 0)
	end
	ui.summary:SetText(#view > 0 and (#view == 1 and L["1 find · cost %s · profit %s"]:format(Money(cost), Money(profit))
		or L["%d finds · cost %s · profit %s"]:format(#view, Money(cost), Money(profit))) or "")
	ui.loop:SetChecked(db.loop)
	ui.count:SetText(#view > ROWS and L["%d–%d of %d"]:format(offset + 1, min(offset + ROWS, #view), #view) or "")
	ns.UpdateScroll(#view)

	local state, text, enabled = buy.state, L["Click a find"], false
	if not state or buy.purpose == "check" then
		if selected and deals[selected.k] and Shown(selected) then text, enabled = L["Check"], true
		elseif view[1] then text, enabled = L["Check"], true end
	elseif state == "verifying" then
		text = L["Checking …"]
	elseif state == "item_ready" then
		text, enabled = L["Buy: %d× for %s"]:format(buy.qty, Money(buy.buyout)), true
	elseif state == "commodity_ready" then
		text, enabled = L["Get quote: %d× (about %s)"]:format(buy.qty, Money(buy.cost)), true
	elseif state == "quoting" then
		text = L["Getting quote …"]
	elseif state == "quote_ok" then
		text, enabled = L["Buy: %d× for %s"]:format(buy.qty, Money(buy.total)), true
	else
		text = L["Buying …"]
	end
	ui.action:SetText(text)
	ui.action:SetEnabled(enabled)
end

-- Scan button: "Stop" while a round runs, while finds are checked and while continuous
-- mode waits for the next round (with the seconds left), otherwise "Scan".
local function UpdateScanButton()
	local checking = buy.purpose == "check" or (queue[1] ~= nil and not buy.state)
	local waiting = scan.nextAt and not scan.active and not checking and not craft.active
	local running = scan.active or checking or waiting or craft.active
	if waiting then
		ui.scan:SetText(L["Stop (%d)"]:format(max(0, math.ceil(scan.nextAt - GetTime()))))
	elseif running then
		ui.scan:SetText(L["Stop"])
	else
		ui.scan:SetText(db.tab == "craft" and L["Prices"] or L["Scan"])
	end
	ui.scan:SetEnabled(not full.active and (running or not buy.state))
	-- while something runs the button is shown switched on
	ui.scan:SetOn(running)
end

-- The full scan button: its countdown runs once a second (the scan button's as well).
function ns.UpdateFullButton()
	if not ui then return end
	UpdateScanButton()
	if full.active then
		ui.full:SetText(L["Full scan"])
		ui.full:SetEnabled(false)
		if ui.full.SetOn then ui.full:SetOn(false) end
	elseif FullReady() then
		ui.full:SetText(L["Full scan"])
		ui.full:SetEnabled(not (buy.state and buy.purpose ~= "check"))
		-- ready: shown switched on, it has to be clicked (the auction house wants a click)
		if ui.full.SetOn then ui.full:SetOn(true) end
	else
		if ui.full.SetOn then ui.full:SetOn(false) end
		local wait = FullWait()
		ui.full:SetText(L["Full scan (%s)"]:format(("%d:%02d"):format(floor(wait / 60), wait % 60)))
		ui.full:SetEnabled(false)
	end
end

local function StopAll(msg)
	if buy.purpose == "check" then wipe(buy) end
	wipe(queue)
	wipe(queued)
	StopScan(msg)
end

-- Inside the auction house window VendorFloor is a tab of its own, added with LibAHTab
-- (the library Auctionator uses as well): tabs of all addons share one row and Blizzard's
-- tab list stays untouched, which would otherwise taint the bags. Selecting the tab
-- hides Blizzard's content; VendorFloor's panel fills the window.
-- (one table: the main chunk of this file is close to Lua's limit of 200 locals)
local AHT = {
	ID = "VendorFloor",
	inset = { 4, -24, -4, 27 },  -- left, top, right, bottom inside the auction house window
	tab = nil,                   -- our tab button (LibAHTab)
	hooked = {},                 -- other tab buttons whose clicks are hooked
	maxRows = 24,                -- rows built; a tall auction house window shows more of them
	top = 73,                    -- body: first list row below its top
	bottom = 74,                 -- body: room below the list (lines and the buy button)
	dialog = { bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32, insets = { left = 11, right = 12, top = 12, bottom = 11 } },
}

function AHT.Layout(f)
	f = f or ui
	if not f or not f.rows then return end
	ROWS = max(3, min(AHT.maxRows, floor((f.body:GetHeight() - AHT.top - AHT.bottom) / ROW_HEIGHT)))
	for i = ROWS + 1, AHT.maxRows do f.rows[i]:Hide() end
end

function AHT.Lib()
	return _G.LibStub and _G.LibStub("LibAHTab-1-0", true)
end

function AHT.Embedded()
	return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown() and AHT.Lib() ~= nil
end

local function PlaceWindow()
	ui:ClearAllPoints()
	local standalone = { ui.title, ui.version, ui.head, ui.close }
	if AHT.Embedded() then
		-- the auction house window draws frame, title and background: only the content here
		ui.embedded = true
		ui:SetParent(AuctionHouseFrame)
		ui:SetFrameStrata(AuctionHouseFrame:GetFrameStrata())
		ui:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 5)
		ui:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", AHT.inset[1], AHT.inset[2])
		ui:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", AHT.inset[3], AHT.inset[4])
		ui:SetBackdrop(nil)
		ui.body:ClearAllPoints()
		ui.body:SetAllPoints(ui)
		for _, r in ipairs(standalone) do r:Hide() end
	else
		-- away from the auction house (the crafting button of a profession window): a window of its own
		ui.embedded = false
		ui:SetParent(UIParent)
		ui:SetFrameStrata("HIGH")
		ui:SetSize(800, 42 + AHT.top + AHT.bottom + 12 * ROW_HEIGHT)
		ui.body:ClearAllPoints()
		ui.body:SetPoint("TOPLEFT", 12, -30)
		ui.body:SetPoint("BOTTOMRIGHT", -12, 12)
		if db.point then
			ui:SetPoint(db.point[1], UIParent, db.point[2], db.point[3], db.point[4])
		else
			ui:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
		end
		ui:SetBackdrop(AHT.dialog)
		for _, r in ipairs(standalone) do r:Show() end
	end
	AHT.Layout()
end

-- Clicks on any other tab (Blizzard's or another addon's) leave VendorFloor: the next
-- visit opens there again.
function AHT.HookOthers()
	local lib = AHT.Lib()
	local own = lib and lib.internalState and lib.internalState.Tabs or {}
	for _, list in ipairs({ AuctionHouseFrame.Tabs or {}, own }) do
		for _, tab in ipairs(list) do
			if tab ~= AHT.tab and not AHT.hooked[tab] then
				AHT.hooked[tab] = true
				tab:HookScript("OnClick", function() db.hidden = true end)
			end
		end
	end
end

-- Our tab, once per session (the auction house window lives on after closing).
function AHT.CreateTab()
	local lib = AHT.Lib()
	if not lib or not AuctionHouseFrame or not ui then return end
	if not AHT.tab then
		ui:SetParent(AuctionHouseFrame)
		if not lib:DoesIDExist(AHT.ID) then lib:CreateTab(AHT.ID, ui, "VendorFloor", "VendorFloor") end
		AHT.tab = lib:GetButton(AHT.ID)
		---@diagnostic disable-next-line: undefined-field, param-type-mismatch
		AHT.tab:HookScript("OnClick", function()
			db.hidden = false
			ns.ShowWindow()
		end)
		---@diagnostic disable-next-line: undefined-field, param-type-mismatch
		AHT.tab:HookScript("OnShow", AHT.SizeTab)
	end
	AHT.SizeTab()
	AHT.HookOthers()
end

-- "Small tab" (settings): as narrow as the text allows, like Auctionator's small tabs.
-- Unset, it follows Auctionator's setting when Auctionator is installed.
function AHT.SmallTab()
	if db.smallTab ~= nil then return db.smallTab end
	local A = _G["Auctionator"]
	local ok, small = pcall(function() return A.Config.Get(A.Config.Options.SMALL_TABS) end)
	return ok and small and true or false
end

function AHT.SizeTab()
	if not AHT.tab or not PanelTemplates_TabResize then return end
	if AHT.SmallTab() then
		PanelTemplates_TabResize(AHT.tab, 0, nil, 36)
	else
		PanelTemplates_TabResize(AHT.tab, 20, nil, 70)
	end
end
ns.SizeTab = AHT.SizeTab

---------------------------------------------------------------------------
-- Look: flat dark panels in the colours of bencepo.github.io
---------------------------------------------------------------------------

local WHITE = "Interface\\Buttons\\WHITE8X8"
local C = {
	bg = { 0.059, 0.075, 0.094, 0.97 },    -- #0f1318
	panel = { 0.110, 0.137, 0.173, 1 },    -- #1c232c
	line = { 0.157, 0.192, 0.235, 1 },     -- #28313c
	well = { 0.043, 0.055, 0.071, 1 },     -- #0b0e12
	gold = { 0.878, 0.659, 0.227, 1 },     -- #e0a83a
	goldDim = { 0.165, 0.141, 0.086, 1 },  -- #2a2416
	text = { 0.902, 0.914, 0.933, 1 },     -- #e6e9ee
	muted = { 0.553, 0.592, 0.647, 1 },    -- #8d97a5
	dark = { 0.102, 0.071, 0.020, 1 },     -- #1a1205
}
ns.C = C

local FLAT_BACKDROP = { bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 }
local function Flat(frame, bg, border)
	if not frame.SetBackdrop then Mixin(frame, BackdropTemplateMixin) end
	-- buttons restyle on every hover and state change: build the backdrop once, then only recolour
	if not frame.vfFlat then
		frame:SetBackdrop(FLAT_BACKDROP)
		frame.vfFlat = true
	end
	frame:SetBackdropColor(unpack(bg or C.panel))
	frame:SetBackdropBorderColor(unpack(border or C.line))
end
ns.Flat = Flat

-- A flat button. kind "primary": gold with dark text (the main action).
-- :SetOn(true) shows it switched on (gold border and text), e.g. while a scan runs.
local function FlatButton(parent, width, height, kind, name, template)
	if ns.blizzardSkin then
		-- Blizzard's red button; "on" (scan running, tab shown) keeps its highlight lit
		local b = CreateFrame("Button", name, parent, template and (template .. ", UIPanelButtonTemplate") or "UIPanelButtonTemplate")
		b:SetSize(width or 80, height or 22)
		b.kind, b.on = kind, false
		function b:Restyle() end
		function b:SetOn(on)
			self.on = on and true or false
			if self.on then self:LockHighlight() else self:UnlockHighlight() end
		end
		return b
	end
	local b = CreateFrame("Button", name, parent, template and (template .. ", BackdropTemplate") or "BackdropTemplate")
	b:SetSize(width or 80, height or 22)
	local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	fs:SetPoint("CENTER", 0, 0)
	b:SetFontString(fs)
	b.kind, b.on, b.hover = kind, false, false
	if kind == "primary" then
		fs:SetShadowOffset(0, 0)
		local font, size = fs:GetFont()
		if font then fs:SetFont(font, (size or 12) + 1, "") end
		-- dark text on gold: drop the colour codes of money amounts, they would vanish on gold
		local setText = b.SetText
		function b:SetText(text)
			if text then
				-- drop the money colours and force dark text: colour codes win over font colours
				text = "|cff1a1205" .. tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r"
			end
			setText(self, text)
		end
	end
	function b:Restyle()
		local enabled = self:IsEnabled()
		local bg, border, text
		if self.kind == "primary" then
			bg, border, text = C.gold, C.gold, C.dark
		elseif self.on then
			bg, border, text = C.goldDim, C.gold, C.gold
		else
			bg, border, text = C.panel, self.hover and C.gold or C.line, C.text
		end
		Flat(self, bg, border)
		fs:SetTextColor(unpack(text))
		self:SetAlpha(enabled and 1 or 0.45)
		if self.kind == "primary" and self.hover and enabled then self:SetBackdropColor(0.95, 0.75, 0.32, 1) end
	end
	function b:SetOn(on) self.on = on and true or false self:Restyle() end
	b:HookScript("OnEnter", function(self) self.hover = true self:Restyle() end)
	b:HookScript("OnLeave", function(self) self.hover = false self:Restyle() end)
	b:HookScript("OnEnable", function(self) self:Restyle() end)
	b:HookScript("OnDisable", function(self) self:Restyle() end)
	b:SetScript("OnMouseDown", function(self) if self:IsEnabled() then fs:SetPoint("CENTER", 0, -1) end end)
	b:SetScript("OnMouseUp", function() fs:SetPoint("CENTER", 0, 0) end)
	b:Restyle()
	return b
end
ns.FlatButton = FlatButton

-- A switch with a label (checked = on), with SetChecked/GetChecked like a check button.
local function FlatToggle(parent, label, width)
	local b = FlatButton(parent, width or 96, 24)
	b.checked = false
	function b:SetChecked(v) self.checked = v and true or false self:SetText((self.checked and "|TInterface\\RaidFrame\\ReadyCheck-Ready:12|t " or "") .. label) self:SetOn(self.checked) end
	function b:GetChecked() return self.checked end
	b:SetScript("PreClick", function(self) self:SetChecked(not self.checked) end)
	b:SetChecked(false)
	return b
end

local function BuildUI()
	if ui then return end
	ns.blizzardSkin = true -- buttons of the main window look like the auction house's own
	local f = CreateFrame("Frame", "VendorFloorFrame", UIParent, "BackdropTemplate")
	f:SetSize(580, 222 + ROWS * ROW_HEIGHT)
	f:SetFrameStrata("HIGH")
	f:SetMovable(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) if not self.embedded then self:StartMoving() end end)
	f:SetScript("OnDragStop", function(self)
		if self.embedded then return end
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		db.point = { point, relPoint, x, y }
	end)
	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(_, delta)
		offset = offset - delta * 3
		Refresh()
	end)
	f:SetScript("OnHide", function()
		if buy.state == "quoting" or buy.state == "quote_ok" then CancelQuote() end
		StopAll(L["Scan stopped."])
		wipe(buy)
		scan.nextAt = nil
	end)

	-- body: everything but the title row of the detached window. Inside the auction house
	-- it fills the window like Blizzard's own tabs: buttons on top, categories on the
	-- left, the result list with column headers on the right, the buy button bottom right.
	local body = CreateFrame("Frame", nil, f)
	---@diagnostic disable-next-line: undefined-field, param-type-mismatch
	body:SetAllPoints(f)
	body:SetScript("OnSizeChanged", function()
		AHT.Layout(f)
		if ui and ui:IsShown() then Refresh() end
	end)
	f.body = body
	local LEFT_W, LIST_X = 150, 160

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 12, -9)
	title:SetText("VendorFloor")
	title:SetTextColor(unpack(C.gold))
	local version = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	version:SetPoint("LEFT", title, "RIGHT", 6, -1)
	version:SetText(VERSION)
	local head = f:CreateTexture(nil, "ARTWORK")
	head:SetColorTexture(unpack(C.line))
	head:SetHeight(1)
	head:SetPoint("TOPLEFT", 1, -30)
	head:SetPoint("TOPRIGHT", -1, -30)
	f.title, f.version, f.head = title, version, head
	-- dark inset behind the list, like the auction house's result lists
	local function Inset()
		local ok, inset = pcall(CreateFrame, "Frame", nil, body, "InsetFrameTemplate")
		if not ok or not inset then
			inset = CreateFrame("Frame", nil, body, "BackdropTemplate")
			Flat(inset, { 0, 0, 0, 0.35 }, { 0.3, 0.3, 0.3, 0.8 })
		end
		inset:SetFrameLevel(body:GetFrameLevel())
		return inset
	end
	local catInset = Inset()
	catInset:SetPoint("TOPLEFT", 0, -46)
	catInset:SetPoint("BOTTOMRIGHT", body, "BOTTOMLEFT", LEFT_W, AHT.bottom - 4)
	local listInset = Inset()
	listInset:SetPoint("TOPLEFT", LIST_X - 4, -46)
	listInset:SetPoint("BOTTOMRIGHT", 0, AHT.bottom - 4)

	-- column headers of the result list like Blizzard's (relabelled per tab in ns.ListHeader);
	-- a click sorts by that column
	local COLS = { { "qty", 52 }, { "profit", 104 }, { "value", 112 }, { "price", 112 } }
	local hdr = CreateFrame("Frame", nil, body)
	hdr:SetPoint("TOPLEFT", LIST_X - 1, -49)
	hdr:SetPoint("RIGHT", body, "RIGHT", -25, 0)
	hdr:SetHeight(22)
	local TABS_TEX = "Interface\\FriendsFrame\\WhoFrame-ColumnTabs"
	local function HeaderCell(key, alignRight)
		local c = CreateFrame("Button", nil, hdr)
		c:SetHeight(22)
		local l = c:CreateTexture(nil, "BACKGROUND")
		l:SetTexture(TABS_TEX)
		l:SetTexCoord(0, 0.078125, 0, 0.75)
		l:SetSize(5, 22)
		l:SetPoint("TOPLEFT")
		local r = c:CreateTexture(nil, "BACKGROUND")
		r:SetTexture(TABS_TEX)
		r:SetTexCoord(0.90625, 0.96875, 0, 0.75)
		r:SetSize(4, 22)
		r:SetPoint("TOPRIGHT")
		local m = c:CreateTexture(nil, "BACKGROUND")
		m:SetTexture(TABS_TEX)
		m:SetTexCoord(0.078125, 0.90625, 0, 0.75)
		m:SetPoint("TOPLEFT", l, "TOPRIGHT")
		m:SetPoint("BOTTOMRIGHT", r, "BOTTOMLEFT")
		c:SetHighlightTexture("Interface\\PaperDollInfoFrame\\UI-Character-Tab-Highlight", "ADD")
		c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		c.arrow = c:CreateTexture(nil, "OVERLAY")
		c.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
		c.arrow:SetSize(9, 8)
		c.arrow:Hide()
		if alignRight then
			c.text:SetPoint("RIGHT", -8, 0)
			c.arrow:SetPoint("RIGHT", c.text, "LEFT", -3, 0)
		else
			c.text:SetPoint("LEFT", 26, 0)
			c.arrow:SetPoint("LEFT", c.text, "RIGHT", 3, 0)
		end
		c:SetScript("OnClick", function() ns.SortBy(key) end)
		return c
	end
	f.hdr, f.hdrCells = {}, {}
	local prevCell
	for _, col in ipairs(COLS) do
		local c = HeaderCell(col[1], true)
		c:SetWidth(col[2])
		if prevCell then c:SetPoint("RIGHT", prevCell, "LEFT", 0, 0) else c:SetPoint("RIGHT", hdr, "RIGHT", 0, 0) end
		f.hdr[col[1]], f.hdrCells[col[1]], prevCell = c.text, c, c
	end
	local nameCell = HeaderCell("name", false)
	nameCell:SetPoint("LEFT", hdr, "LEFT", 0, 0)
	nameCell:SetPoint("RIGHT", prevCell, "LEFT", 0, 0)
	f.hdr.name, f.hdrCells.name = nameCell.text, nameCell
	f.hdr.name:SetText(L["Name"])
	f.COLS = COLS

	local close = FlatButton(f, 22, 20)
	close:SetPoint("TOPRIGHT", -6, -5)
	close:SetText("x")
	close:SetScript("OnClick", function() f:Hide() end)
	f.close = close

	f.scan = FlatButton(body, 80, 22)
	f.scan:SetPoint("TOPLEFT", LIST_X, -12)
	f.scan:SetScript("OnClick", function()
		if craft.active then
			StopCraftScan(L["Scan stopped."])
			scan.nextAt = nil
			Refresh()
		elseif scan.active or scan.nextAt or buy.purpose == "check" or (queue[1] and not buy.state) then
			StopAll(L["Scan stopped."])
		elseif db.tab == "craft" then
			StartCraftScan()
		else
			StartScan()
		end
	end)

	-- full scan: every auction at once, allowed every 15 minutes
	f.full = FlatButton(body, 116, 22)
	f.full:SetPoint("LEFT", f.scan, "RIGHT", 6, 0)
	f.full:SetScript("OnClick", function() StartFull() end)
	f.full:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Full scan"])
		GameTooltip:AddLine(L["Reads every auction at once: complete, without checking each item."], 1, 1, 1, true)
		GameTooltip:AddLine(L["The full scan is available every 15 minutes."], 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	f.full:HookScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)

	local loop = FlatToggle(body, L["Continuous"], 116)
	loop:SetPoint("LEFT", f.full, "RIGHT", 6, 0)
	loop:SetChecked(db.loop)
	loop:SetScript("OnClick", function(self)
		db.loop = self:GetChecked() and true or false
		if not db.loop then scan.nextAt = nil end
	end)
	f.loop = loop

	f.count = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.count:SetPoint("BOTTOMRIGHT", -6, AHT.bottom + 2)

	-- Minimum profit per unit: how far below the vendor price an auction must be
	local profit = CreateFrame("EditBox", nil, body, "InputBoxTemplate")
	profit:SetFontObject("GameFontHighlight")
	profit:SetSize(LEFT_W - 28, 20)
	profit:SetPoint("TOPLEFT", 16, -176)
	profit:SetAutoFocus(false)
	profit:SetMaxLetters(16)
	profit:SetText(PlainMoney(db.minProfit))
	-- the list follows while you type; Enter or clicking elsewhere keeps the value, Escape undoes it
	profit:SetScript("OnEditFocusGained", function(self) self.before = db.minProfit end)
	-- every readable value is taken and saved at once (text set by the addon is the stored value, a no-op)
	profit:SetScript("OnTextChanged", function(self)
		local copper = ParseMoney(self:GetText())
		if copper and max(floor(copper), 1) ~= db.minProfit then SetMinProfit(copper, true) end
	end)
	-- a WoW input field keeps the keyboard when you click elsewhere: any click outside ends the input
	profit:RegisterEvent("GLOBAL_MOUSE_DOWN")
	profit:SetScript("OnEvent", function(self)
		if self:HasFocus() and not self:IsMouseOver() then self:ClearFocus() end
	end)
	profit:SetScript("OnEnterPressed", function(self)
		if not ParseMoney(self:GetText()) then
			SetStatus(L["Amount not recognised. Examples: 50%s, 5s, 1g 20s"]:format(ns.COPPER))
		end
		self:ClearFocus()
	end)
	profit:SetScript("OnEscapePressed", function(self)
		if self.before and self.before ~= db.minProfit then SetMinProfit(self.before, true) end
		self.before = nil
		self:ClearFocus()
	end)
	profit:SetScript("OnEditFocusLost", function(self)
		self.before = nil
		self:SetText(PlainMoney(db.minProfit))
	end)
	profit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Minimum profit per unit"])
		GameTooltip:AddLine(L["How far below the vendor price an auction must be."], 1, 1, 1, true)
		GameTooltip:AddLine(L["Examples: 50%s, 5s, 1g 20s. The list follows as you type."]:format(ns.COPPER), 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	profit:SetScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	f.profit = profit
	local profitText = body:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	profitText:SetPoint("BOTTOMLEFT", profit, "TOPLEFT", -4, 3)
	profitText:SetText(L["Min. profit/unit"])

	-- tabs: one list per kind of find, never mixed
	f.tabs = {}
	local labels = { vendor = L["Vendor"], de = L["Disenchant"], craft = L["Crafting"], wish = L["Watchlist"] }
	local nav = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("auctionhouse-nav-button")
	-- a category button like the auction house's list on the left (its atlas when the client has it)
	local function NavButton()
		if not nav then return FlatButton(body, LEFT_W - 12, 22) end
		local b = CreateFrame("Button", nil, body)
		b:SetSize(LEFT_W - 12, 22)
		b:SetNormalAtlas("auctionhouse-nav-button")
		b:SetHighlightAtlas("auctionhouse-nav-button-highlight")
		b.sel = b:CreateTexture(nil, "ARTWORK")
		b.sel:SetAtlas("auctionhouse-nav-button-select")
		b.sel:SetAllPoints()
		b.sel:Hide()
		local fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("LEFT", 10, 0)
		fs:SetPoint("RIGHT", -6, 0)
		fs:SetJustifyH("LEFT")
		b:SetFontString(fs)
		function b:SetOn(on)
			self.sel:SetShown(on)
			fs:SetFontObject(on and "GameFontHighlightSmall" or "GameFontNormalSmall")
		end
		return b
	end
	for i, mode in ipairs(TABS) do
		local tab = NavButton()
		tab.label = labels[mode]
		tab:SetPoint("TOPLEFT", 6, -52 - (i - 1) * 24)
		tab:SetScript("OnClick", function()
			db.tab, offset = mode, 0
			if selected and (selected.mode or "vendor") ~= mode then selected = nil end
			Refresh()
		end)
		f.tabs[mode] = tab
	end

	-- minimum profit in percent: click for more, right-click for less
	local PRESETS = { 0, 5, 10, 15, 20, 25, 35, 50 }
	local pct = FlatButton(body, LEFT_W - 12, 22)
	pct:SetPoint("TOPLEFT", 6, -204)
	pct:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local function ShowPct()
		local v = db.minPercent or 0
		pct:SetText(v > 0 and L["Min. profit %d%%"]:format(v) or L["Min. profit: any"])
		pct:SetOn(v > 0)
	end
	pct:SetScript("OnClick", function(self, button)
		local v, i = db.minPercent or 0, 1
		for k, p in ipairs(PRESETS) do if p <= v then i = k end end
		if button == "RightButton" then
			i = PRESETS[i] == v and i - 1 or i
			if i < 1 then i = 1 end
		else
			i = min(i + 1, #PRESETS)
		end
		db.minPercent = PRESETS[i]
		ShowPct()
		Refresh()
		if GameTooltip:GetOwner() == self then self:GetScript("OnEnter")(self) end
	end)
	pct:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Minimum profit in percent"])
		GameTooltip:AddLine(L["Finds below this profit (in percent of the price) are hidden, also the ones already listed."], 1, 1, 1, true)
		GameTooltip:AddLine(L["Click: more. Right-click: less."], 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	pct:SetScript("OnLeave", function(self)
		if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
	end)
	ShowPct()
	f.pct, f.ShowPct = pct, ShowPct

	-- watchlist and ignore list: windows of their own (Lists.lua)
	f.editWish = FlatButton(body, LEFT_W - 12, 22)
	f.editWish:SetPoint("TOPLEFT", 6, -238)
	f.editWish:SetText(L["Edit watchlist"])
	f.editWish:SetScript("OnClick", function() if ns.ToggleWishlist then ns.ToggleWishlist() end end)

	-- scroll bar of the result list, like Blizzard's
	local okSb, sb = pcall(CreateFrame, "Slider", "VendorFloorScrollBar", body, "UIPanelScrollBarTemplate")
	if not okSb or not sb then
		sb = CreateFrame("Slider", nil, body)
		sb:SetOrientation("VERTICAL")
		sb:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
	end
	sb:SetPoint("TOPRIGHT", body, "TOPRIGHT", -5, -AHT.top - 16)
	sb:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -5, AHT.bottom + 14)
	sb:SetWidth(16)
	sb:SetMinMaxValues(0, 0)
	sb:SetValueStep(1)
	if sb.SetObeyStepOnDrag then sb:SetObeyStepOnDrag(true) end
	sb.scrollStep = 3
	sb:SetScript("OnValueChanged", function(self, v)
		if self.updating then return end
		v = floor(v + 0.5)
		if v ~= offset then
			offset = v
			Refresh()
		end
	end)
	f.scrollBar = sb

	-- menu: everything that used to need a chat command
	local menuBtn = FlatButton(body, 80, 22)
	menuBtn:SetPoint("TOPRIGHT", -4, -12)
	menuBtn:SetText(L["Menu"])
	local menu = CreateFrame("Frame", nil, f, "BackdropTemplate")
	menu:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
	menu:SetBackdropColor(0, 0, 0, 0.92)
	menu:SetFrameStrata("DIALOG")
	menu:SetFixedFrameStrata(true) -- keep DIALOG when the panel moves into the auction house window
	menu:SetFrameLevel(50)
	menu:SetPoint("TOPRIGHT", menuBtn, "BOTTOMRIGHT", 0, -2)
	menu:Hide()
	local entries = {
		{ L["Statistics"], function() ns.ShowInfo(L["Statistics"], ns.StatsLines()) end },
		{ L["Your disenchants"], function() ns.ShowInfo(L["Your disenchants"], nil, ns.DeLines) end },
		{ L["Your auctions"], function() ns.ShowInfo(L["Your auctions"], nil, function() return ns.SalesLines and ns.SalesLines() or {} end) end },
		{ L["Export for the website"], function() ns.ShowExport() end },
		{ L["Disenchant basket"], function() if ns.ToggleBasket then ns.ToggleBasket() end end },
		{ L["Watchlist"], function() if ns.ToggleWishlist then ns.ToggleWishlist() end end },
		{ L["Ignore list"], function() if ns.ToggleIgnoreList then ns.ToggleIgnoreList() end end },
		{ L["Purchase log"], function() if ns.ShowCopy then ns.ShowCopy(L["VendorFloor: purchase log"], ns.Diagnose(buy.deal)) end end },
		{ L["Settings"], function() ns.ToggleSettings() end },
	}
	for i, e in ipairs(entries) do
		local b = FlatButton(menu, 190, 24)
		b:SetPoint("TOPLEFT", 6, -6 - (i - 1) * 28)
		b:SetText(e[1])
		b:SetScript("OnClick", function()
			menu:Hide()
			e[2]()
		end)
	end
	menu:SetSize(202, 12 + #entries * 28 - 4)
	menuBtn:SetScript("OnClick", function(self)
		-- Blizzard's own context menu where the client has it, else a small list of buttons
		if MenuUtil and MenuUtil.CreateContextMenu then
			MenuUtil.CreateContextMenu(self, function(_, root)
				for _, e in ipairs(entries) do root:CreateButton(e[1], function() e[2]() end) end
			end)
		else
			menu:SetShown(not menu:IsShown())
		end
	end)
	f:HookScript("OnHide", function() menu:Hide() end)

	-- progress bar under the buttons
	f.bar = CreateFrame("StatusBar", nil, body)
	f.bar:SetPoint("LEFT", loop, "RIGHT", 12, 0)
	f.bar:SetPoint("RIGHT", menuBtn, "LEFT", -12, 0)
	f.bar:SetHeight(16)
	f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	f.bar:SetStatusBarColor(0.85, 0.65, 0.15)
	f.bar:SetMinMaxValues(0, 1)
	f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
	f.bar.bg:SetAllPoints()
	f.bar.bg:SetColorTexture(0, 0, 0, 0.6)
	f.bar.text = f.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.bar.text:SetPoint("CENTER", 0, 0)
	local font = f.bar.text:GetFont()
	if font then f.bar.text:SetFont(font, 11, "OUTLINE") end
	f.bar:Hide()

	f.rows = {}
	for i = 1, AHT.maxRows do
		local row = CreateFrame("Button", nil, body)
		row:SetHeight(ROW_HEIGHT)
		row:SetPoint("TOPLEFT", LIST_X, -AHT.top - (i - 1) * ROW_HEIGHT)
		row:SetPoint("RIGHT", body, "RIGHT", -26, 0)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		if i % 2 == 0 then
			local zebra = row:CreateTexture(nil, "BACKGROUND", nil, -1)
			zebra:SetAllPoints()
			zebra:SetColorTexture(1, 1, 1, 0.025)
		end
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		hl:SetBlendMode("ADD")
		hl:SetAlpha(0.5)
		row.mark = row:CreateTexture(nil, "BACKGROUND")
		row.mark:SetAllPoints()
		row.mark:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
		row.mark:SetBlendMode("ADD")
		row.mark:SetVertexColor(1, 0.82, 0.3, 0.6)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(ROW_HEIGHT - 2, ROW_HEIGHT - 2)
		row.icon:SetPoint("LEFT", 2, 0)
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local rx, last = -6, nil
		for _, col in ipairs(COLS) do
			local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			fs:SetPoint("RIGHT", rx, 0)
			fs:SetWidth(col[2])
			fs:SetJustifyH("RIGHT")
			fs:SetWordWrap(false)
			row[col[1]], last = fs, fs
			rx = rx - col[2]
		end
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
		row.name:SetPoint("RIGHT", last, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row:SetScript("OnClick", function(self, button)
			if not self.deal then return end
			if button ~= "RightButton" and IsAltKeyDown() then
				-- Alt+click: everything about this find plus the purchase log, to copy into a bug report
				ns.ShowCopy(L["VendorFloor: bug report"], ns.Diagnose(self.deal))
				return
			end
			if button ~= "RightButton" then
				Select(self.deal, true)
				return
			end
			local d = self.deal
			-- a small menu instead of hiding at once: a stray right-click hid items for good
			if MenuUtil and MenuUtil.CreateContextMenu then
				MenuUtil.CreateContextMenu(self, function(_, root)
					root:CreateTitle(d.name or ("item:" .. d.id))
					root:CreateButton(L["Hide this item"], function() Ignore(d) end)
					if d.mode ~= "wish" then
						root:CreateButton(L["Add to watchlist"], function() if ns.WishPrefill then ns.WishPrefill(d.id, d.price) end end)
					end
				end)
			elseif IsShiftKeyDown() then
				Ignore(d)
			else
				SetStatus(L["Shift + right-click hides an item."])
			end
		end)
		row:SetScript("OnEnter", function(self)
			local c = self.craft
			if c then
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:SetHyperlink(c.link or ("item:" .. c.out))
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine(L["%s: %s"]:format(c.prof, c.recipe or ""), 0.88, 0.66, 0.23)
				for _, r in ipairs(c.parts) do
					local name = GetItemInfo(r.id) or ("item:" .. r.id)
					GameTooltip:AddDoubleLine(("%d× %s"):format(r.qty, name), ("%s (%s)"):format(Money(r.unit * r.qty),
						r.src == "ah" and L["AH"] or L["merchant"]), 1, 1, 1, 1, 1, 1)
				end
				GameTooltip:AddDoubleLine(L["Reagents"], Money(c.cost), 0.7, 0.7, 0.7, 1, 1, 1)
				GameTooltip:AddDoubleLine(c.route == "ah" and L["Sells on the AH for (after cut)"] or L["A merchant pays"], Money(c.revenue), 0.7, 0.7, 0.7, 1, 1, 1)
				GameTooltip:AddDoubleLine(L["Profit"], Money(c.profit), 0.25, 1, 0.25, 0.25, 1, 0.25)
				GameTooltip:Show()
				return
			end
			local d = self.deal
			if not d then return end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetHyperlink(d.link or ("item:" .. d.id))
			GameTooltip:AddLine(" ")
			if d.mode == "de" then
				GameTooltip:AddLine(L["Disenchanting brings about %s (estimate)"]:format(Money(d.vendor or 0)), 0.88, 0.66, 0.23)
				local n = ns.DeLearnedCount(d.link or d.id)
				GameTooltip:AddLine(n and L["Based on your own %d disenchants of this item."]:format(n)
					or L["Based on the general disenchant table (your own results count from 3 disenchants)."], 0.7, 0.7, 0.7, true)
			end
			if d.count and (d.mode or "vendor") ~= "vendor" then
				GameTooltip:AddLine(L["Below that: %d×, total profit %s"]:format(d.count, Money(d.profit or 0)), 0.25, 1, 0.25)
			elseif d.count then
				GameTooltip:AddLine(L["Below vendor price: %d×, total profit %s"]:format(d.count, Money(d.profit or 0)), 0.25, 1, 0.25)
			else
				GameTooltip:AddLine(L["Profit per unit %s, units not counted yet"]:format(Money(d.profit or 0)), 0.25, 1, 0.25)
			end
			GameTooltip:AddLine(L["Listed on the AH: %d"]:format(d.listed or 0), 0.7, 0.7, 0.7)
			GameTooltip:AddLine(L["Click: buy. Right-click: hide or add to the watchlist. Alt+click: bug report."], 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
		end)
		f.rows[i] = row
	end

	f.empty = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.empty:SetPoint("TOPLEFT", LIST_X + 20, -AHT.top - 14)
	f.empty:SetPoint("RIGHT", body, "RIGHT", -20, 0)
	f.empty:SetJustifyH("LEFT")
	f.empty:SetSpacing(3)

	f.action = FlatButton(body, 260, 24, "primary")
	f.action:SetPoint("BOTTOMRIGHT", -4, 6)
	f.action:SetScript("OnClick", VendorFloor_BuyNext)

	f.ledger = body:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.ledger:SetPoint("BOTTOMLEFT", 6, 30)
	f.ledger:SetPoint("RIGHT", f.action, "LEFT", -12, 0)
	f.ledger:SetJustifyH("LEFT")
	f.ledger:SetWordWrap(false)
	f.ledger:SetText(ns.LedgerLine and ns.LedgerLine() or "")

	f.summary = body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	f.summary:SetPoint("BOTTOMLEFT", 6, 48)
	f.summary:SetPoint("RIGHT", f.action, "LEFT", -12, 0)
	f.summary:SetJustifyH("LEFT")
	f.summary:SetWordWrap(false)

	f.status = body:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.status:SetPoint("BOTTOMLEFT", 6, 12)
	f.status:SetPoint("RIGHT", f.action, "LEFT", -12, 0)
	f.status:SetJustifyH("LEFT")
	f.status:SetWordWrap(false)
	f.status:SetText(statusText)



	local elapsed, second = 0, 0
	f:SetScript("OnUpdate", function(_, dt)
		elapsed, second = elapsed + dt, second + dt
		if second >= 1 then
			second = 0
			ns.UpdateFullButton()
		end
		if elapsed < 0.1 then return end
		elapsed = 0
		Tick()
	end)

	ns.blizzardSkin = false
	f:Hide()
	ui = f
end

-- A simple text window (statistics, your disenchants, your auctions).
local info
-- Item link for a text line; an item the client has not loaded yet is requested and the
-- open info window filled again once it arrives (else bare item IDs stayed in the list).
function ns.ItemLink(id)
	local link = select(2, GetItemInfo(id))
	if link then return link end
	ns.infoMissing = true
	if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
	return "item " .. tostring(id)
end

function ns.ShowInfo(titleText, lines, builder, attempt)
	if builder then
		ns.infoMissing = false
		lines = builder()
		if ns.infoMissing and (attempt or 0) < 5 then
			C_Timer.After(1, function()
				if info and info:IsShown() and info.title:GetText() == titleText then ns.ShowInfo(titleText, nil, builder, (attempt or 0) + 1) end
			end)
		end
	end
	if not info then
		info = CreateFrame("Frame", "VendorFloorInfoFrame", UIParent, "BackdropTemplate")
		info:SetSize(500, 400)
		info:SetPoint("CENTER")
		info:SetFrameStrata("DIALOG")
		info:SetBackdrop(AHT.dialog)
		info:SetMovable(true)
		info:EnableMouse(true)
		info:RegisterForDrag("LeftButton")
		info:SetScript("OnDragStart", info.StartMoving)
		info:SetScript("OnDragStop", info.StopMovingOrSizing)
		info.title = info:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		info.title:SetPoint("TOPLEFT", 20, -18)
		local close = CreateFrame("Button", nil, info, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", -6, -6)
		local sf = CreateFrame("ScrollFrame", nil, info, "UIPanelScrollFrameTemplate")
		sf:SetPoint("TOPLEFT", 20, -44)
		sf:SetPoint("BOTTOMRIGHT", -38, 18)
		local content = CreateFrame("Frame", nil, sf)
		content:SetSize(430, 10)
		sf:SetScrollChild(content)
		info.text = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		info.text:SetPoint("TOPLEFT")
		info.text:SetWidth(430)
		info.text:SetJustifyH("LEFT")
		info.text:SetSpacing(4)
		info.content = content
		tinsert(UISpecialFrames, "VendorFloorInfoFrame")
	end
	info.title:SetText(titleText)
	info.text:SetText(table.concat(lines, "\n"))
	info.content:SetHeight(info.text:GetStringHeight() + 10)
	info:Show()
end

function ns.StatsLines()
	local lines = {}
	if ns.TotalLine then lines[#lines + 1] = ns.TotalLine() end
	if ns.LedgerLine then lines[#lines + 1] = ns.LedgerLine() end
	return lines
end

local function ShowWindow()
	BuildUI()
	if AHT.Embedded() then AHT.CreateTab() end
	PlaceWindow()
	if statusText == "" then SetStatus(L["Ready. \"Scan\" reads the auction house item list."]) end
	if ui.embedded and AHT.tab then AHT.Lib():SetSelected(AHT.ID) else ui:Show() end
	Refresh()
end
ns.ShowWindow = ShowWindow

function ns.RefreshWindow()
	if ui and ui:IsShown() then Refresh() end
end

-- Open the window on a tab (the crafting button in the profession window uses it).
function ns.OpenTab(mode)
	db.tab, offset = mode, 0
	ShowWindow()
end

---------------------------------------------------------------------------
-- Settings: a window of its own (BencepoUI) that can be dragged anywhere and stays
-- open while you play. Options > AddOns > VendorFloor only points to it. No
-- predicates or proxy getters there: they would run addon code inside Blizzard's
-- options search.
---------------------------------------------------------------------------

local settingsWin

StaticPopupDialogs["VENDORFLOOR_FORGET"] = {
	text = L["Forget all purchases VendorFloor still counts as to sell? The ledger of past sales stays."],
	button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
	OnAccept = function()
		ns.ForgetPurchases()
		Print(L["Tracked purchases cleared."])
	end,
}
local function BuildSettings()
	local UI = _G.LibStub("BencepoUI-1.0")
	settingsWin = UI:CreateWindow({
		name = "VendorFloorSettingsFrame", title = L["VendorFloor %s"]:format(L["Settings"]),
		subtitle = ns.VERSION, width = 520, height = 410, theme = C, accent = C.gold,
		db = db, posKey = "settingsPoint", hint = L["drag to move, changes apply live"],
		bugUrl = "https://github.com/Bencepo/VendorFloor/issues/new/choose",
	})
	local w = settingsWin
	local function silver(v) return v .. " s" end
	local function percent(v) return v .. " %" end

	local X = 16
	w:Header(X, -48, L["Alerts"])
	w:Check(X, -72, L["Alert sound"], L["Play a sound when a new find appears."],
		function() return db.sound end, function(v) db.sound = v end)
	w:Check(X, -96, L["Flash the taskbar"], L["Flash the game's taskbar icon on new finds while the game is in the background."],
		function() return db.flash end, function(v) db.flash = v end)
	w:Header(X, -132, L["Scanning"])
	w:Check(X, -156, L["Continuous mode"], L["Scan again automatically after each round."],
		function() return db.loop end, function(v)
			db.loop = v
			if not v then scan.nextAt = nil end
			if ui then ui.loop:SetChecked(v and true or false) end
		end)
	w:Slider(X, -186, L["Pause between rounds (seconds)"], 1, 120, 1, function() return db.interval end,
		function(v) db.interval = v end, L["How long continuous mode waits before the next round."], 190,
		function(v) return v .. " s" end)

	X = 270
	w:Header(X, -48, L["Profit"])
	w:Slider(X, -72, L["Minimum profit per unit (silver)"], 0, 500, 1, function() return db.minProfitSilver end,
		function(v) SetMinProfit(v * 100) end,
		L["How far below the vendor price an auction must be. Finer amounts can be typed into the window."], 190, silver)
	w:Slider(X, -112, L["Minimum profit in percent"], 0, 100, 5, function() return db.minPercent end,
		function(v)
			db.minPercent = v
			if ui then ui.ShowPct() end
			ns.RefreshWindow()
		end, L["Profit in percent of the price, for every tab. 0 turns it off."], 190, percent)
	w:Slider(X, -152, L["Minimum profit per bag slot (silver)"], 0, 500, 5, function() return db.minSlotSilver or 0 end,
		function(v)
			db.minSlotSilver = v
			db.minSlot = v * 100
		end, L["Profit an auction must bring as a whole (one auction takes one bag slot). 0 turns it off."], 190, silver)

	w:Header(X, -192, L["Auction house"])
	w:Check(X, -216, L["Small tab"], L["Makes the VendorFloor tab in the auction house as narrow as its text, so more addon tabs fit in one row. Unset, it follows Auctionator's \"Small tabs\" setting."],
		function() return AHT.SmallTab() end, function(v)
			db.smallTab = v and true or false
			AHT.SizeTab()
		end)

	w:Check(X, -240, L["Values in item tooltips"], L["Adds disenchant value, latest auction price and your watchlist limit to item tooltips. Off by default: many addons show such values already."],
		function() return db.tooltip end, function(v) db.tooltip = v and true or false end)

	X = 16
	w:Header(X, -232, L["Limits"])
	w:Slider(X, -256, L["Spending limit per session (gold)"], 0, 1000, 10, function() return db.spendLimit or 0 end,
		function(v) db.spendLimit = v end, L["VendorFloor stops buying once this session's purchases reach it. 0 turns it off."], 190,
		function(v) return v > 0 and (v .. " g") or L["off"] end)
	w:Slider(X, -296, L["Keep bag slots free"], 0, 40, 1, function() return db.keepSlots or 0 end,
		function(v) db.keepSlots = v end, L["Stops buying when fewer bag slots would stay free. Purchases still in the mail count until you visit the mailbox. 0 turns it off."], 190,
		function(v) return v > 0 and tostring(v) or L["off"] end)

	w:Check(270, -264, L["Minimap button"], L["Shows VendorFloor's button at the minimap. The addon menu next to the minimap has it either way."],
		function() return not (db.minimap and db.minimap.hide) end, function(v)
			if v == (db.minimap and db.minimap.hide or false) then ns.ToggleMinimap() end
		end)
	local forget = w:Button(L["Forget unsold purchases"], 200, function() StaticPopup_Show("VENDORFLOOR_FORGET") end,
		L["Clears the purchases VendorFloor still counts as to sell, e.g. items you kept or sold elsewhere. Your ledger stays."])
	forget:SetPoint("TOPLEFT", 270, -300)

	w:Text(16, -350, L["Finer amounts and the other filters are set in the auction house window."], 480)
end

function ns.ToggleSettings()
	if not settingsWin then BuildSettings() end
	settingsWin:Toggle()
end

local function RegisterSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnCategory) then return end
	local category, layout = Settings.RegisterVerticalLayoutCategory("VendorFloor")
	if layout and CreateSettingsButtonInitializer then
		layout:AddInitializer(CreateSettingsButtonInitializer(L["VendorFloor has its own settings window"], L["Open"], function()
			if SettingsPanel and SettingsPanel:IsShown() then HideUIPanel(SettingsPanel) end
			if not settingsWin then BuildSettings() end
			settingsWin:Show()
		end, L["Opens the VendorFloor settings. The window can be dragged anywhere and stays open while you play."], true))
	end
	Settings.RegisterAddOnCategory(category)
	ns.category = category
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}

function handlers.ADDON_LOADED(name)
	if name ~= ADDON then return end
	VendorFloorDB = VendorFloorDB or {}
	db = VendorFloorDB
	for key, value in pairs(defaults) do
		if db[key] == nil then db[key] = value end
	end
	db.ignore = db.ignore or {}
	db.total = db.total or { buys = 0, spent = 0, value = 0 }
	db.total.sold, db.total.soldCost = db.total.sold or 0, db.total.soldCost or 0
	db.bought = db.bought or {}  -- itemID -> { units, cost }: bought and not sold yet
	pcall(ns.SeedHot)
	if db.deBasket == nil then
		-- the disenchant basket starts with the disenchant purchases still in the mail
		db.deBasket = {}
		for itemID, n in pairs(db.debought or {}) do db.deBasket[itemID] = n end
	end
	db.minSlotSilver = floor((db.minSlot or 0) / 100)
	if db.tab ~= "vendor" and db.tab ~= "de" and db.tab ~= "craft" and db.tab ~= "wish" then db.tab = "vendor" end
	ns.db = db
	local ok, err = pcall(RegisterSettings)
	if not ok then Print(tostring(err)) end
end

-- The finds as last seen (full scan, quick scans and checks; up to an hour old), so the tabs
-- are not empty until the next full scan is allowed. Each is checked again when clicked.
local function RestoreFinds()
	local last = db.lastFinds
	if not (last and last.list and time() - (last.at or 0) < 3600) then return end
	local age = time() - last.at
	local n = 0
	for _, g in ipairs(last.list) do
		if not deals[g.k] and not IsIgnored(g.id) and (g.mode == "vendor" or g.mode == "de") then
			local d = {}
			for field, value in pairs(g) do d[field] = value end
			d.fullAt, d.stale = GetTime() - age, false
			Confirm(d, true)
			n = n + 1
		end
	end
	if n > 0 then
		SortDeals()
		SetStatus(L["%d finds from the full scan %d min ago. They are checked when you click them."]:format(n, floor(age / 60)))
	end
end

function handlers.AUCTION_HOUSE_SHOW()
	ahOpen = true
	pcall(RestoreFinds)
	-- the auction house opens on the tab used last; wait for Blizzard to set up its own tab first
	local function Open()
		if not ahOpen or not AHT.Embedded() then return end
		BuildUI()
		AHT.CreateTab()
		if not db.hidden and not ui:IsShown() then ShowWindow() end
	end
	C_Timer.After(0, Open)
	C_Timer.After(0.3, Open) -- once more, should the auction house switch to its own tab late
end

function handlers.AUCTION_HOUSE_CLOSED()
	ahOpen = false
	StopCraftScan()
	-- the full scan's auction list can be large: let it go
	full.active, full.items, full.pending, full.requested = false, nil, nil, nil
	if buy.state == "quote_ok" or buy.state == "quoting" then CancelQuote() end
	wipe(buy)
	pendingSend, sentAt = nil, nil
	scan.active, scan.nextAt = false, nil
	if ui then ui:Hide() end
	-- prices change while the auction house is closed: start the next visit empty
	for i = #order, 1, -1 do RemoveDeal(order[i]) end
	wipe(queue)
	wipe(queued)
	wipe(pendingInfo)
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_UPDATED()
	if not scan.active then return end
	scan.lastAt = GetTime()
	Process(AH.GetBrowseResults())
	ContinueScan()
end

function handlers.AUCTION_HOUSE_BROWSE_RESULTS_ADDED(added)
	if not scan.active then return end
	scan.lastAt = GetTime()
	Process(added)
	ContinueScan()
end

function handlers.REPLICATE_ITEM_LIST_UPDATE()
	if full.active and full.phase == "waiting" then
		full.phase, full.count, full.stableAt = "arriving", AH.GetNumReplicateItems(), GetTime()
	elseif not full.active and not craft.active then
		ns.ReadForeignFull()
	end
end

function handlers.AUCTION_HOUSE_BROWSE_FAILURE()
	if scan.active then StopScan(L["The auction house rejected the query."]) end
end

function handlers.AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED()
	-- the full scan request was dropped: send it again (three tries)
	if full.active and full.phase == "waiting" and (full.sends or 0) < 3 and GetTime() - full.t0 < 10 then
		full.phase, full.t0 = "sending", GetTime()
		return
	end
	if lastSend and (scan.active or buy.state == "verifying") then pendingSend = lastSend end
end

function handlers.GET_ITEM_INFO_RECEIVED(id, success)
	local results = pendingInfo[id]
	if not results then return end
	pendingInfo[id] = nil
	if success and VendorPrice(id) ~= nil then
		for _, result in ipairs(results) do Evaluate(result) end
		refreshSoon = true -- hundreds of items can arrive during a scan: one refresh per tick
	end
end

handlers.ITEM_DATA_LOAD_RESULT = handlers.GET_ITEM_INFO_RECEIVED

function handlers.COMMODITY_SEARCH_RESULTS_UPDATED(id)
	if buy.state == "verifying" and buy.deal and buy.deal.id == id then
		buy.deal.commodity = true
		ReadCommodity()
	end
end
handlers.COMMODITY_SEARCH_RESULTS_ADDED = handlers.COMMODITY_SEARCH_RESULTS_UPDATED

function handlers.ITEM_SEARCH_RESULTS_UPDATED(key)
	if buy.state == "verifying" and buy.deal and type(key) == "table" and key.itemID == buy.deal.id then
		buy.deal.commodity = false
		ReadItem()
	end
end
handlers.ITEM_SEARCH_RESULTS_ADDED = handlers.ITEM_SEARCH_RESULTS_UPDATED

-- A confirmed item purchase: into the ledger, the watchlist and the hot items.
function ns.RecordPending(auctionID)
	local p = pendingBuys[auctionID]
	if not p then return end
	pendingBuys[auctionID] = nil
	ns.RecordBuy(p.id, p.qty, p.cost, p.value, p.mode)
	ns.WishBought(p.id, p.qty, p.mode)
	ns.LearnBuy(p.id, p.key, p.cost, p.value, p.mode)
end

function handlers.AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)
	ns.Log("purchase completed %s", tostring(auctionID))
	if buy.state == "bought" and buy.auctionID == auctionID then
		buy.confirmed = true
		C_Timer.After(0.2, function() if buy.state == "bought" and buy.confirmed and buy.auctionID == auctionID then ns.AfterBuy() end end)
	end
	ns.RecordPending(auctionID)
end

-- In case the client has no purchase event: the "You won an auction for ..." line.
local WON_PATTERN = ERR_AUCTION_WON_S and ("^" .. ERR_AUCTION_WON_S:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%s", "(.+)") .. "$")
function handlers.CHAT_MSG_SYSTEM(msg)
	if not (WON_PATTERN and msg) or issecretvalue and issecretvalue(msg) then return end -- secret: hidden from addons
	local name = msg:match(WON_PATTERN)
	if not name then return end
	for auctionID, p in pairs(pendingBuys) do
		if p.name == name and GetTime() - p.at < 60 then
			ns.RecordPending(auctionID)
			return
		end
	end
end

function handlers.COMMODITY_PRICE_UPDATED(_, total)
	if buy.state ~= "quoting" then return end
	local d = buy.deal
	if total and total <= buy.qty * (d.vendor - (d.mode == "wish" and 0 or db.minProfit)) then
		buy.state, buy.total, buy.t = "quote_ok", total, GetTime()
		SetStatus(L[DeText(d, "Quote: %d× for %s, vendor pays %s.")]:format(buy.qty, Money(total), Money(buy.qty * d.vendor)))
		Refresh()
	else
		CancelQuote()
		ResetBuy(L["The price has risen meanwhile. Not bought."])
	end
end

function handlers.COMMODITY_PRICE_UNAVAILABLE()
	if buy.state == "quoting" then ResetBuy(L["No quote received."]) end
end

function handlers.COMMODITY_PURCHASE_SUCCEEDED()
	if buy.state ~= "confirming" then return end
	local d = buy.deal
	Print(L[DeText(d, "Bought: %s ×%d for %s (vendor pays %s).")]:format(d.link or d.name, buy.qty, Money(buy.total),
		Money(buy.qty * d.vendor)))
	ns.RecordBuy(d.id, buy.qty, buy.total or 0, buy.qty * d.vendor, d.mode or "vendor")
	ns.WishBought(d.id, buy.qty, d.mode)
	ns.LearnBuy(d.id, d.key, buy.total or 0, buy.qty * d.vendor, d.mode or "vendor")
	RemoveDeal(d)
	buy.chain = true
	ns.Gone(L["Bought."])
end

-- An item purchase the auction house refused ("Internal auction error" and the like).
ns.AUCTION_ERRORS = {}
-- "Internal auction error" is left out: Forever's auction house sends it with purchases that
-- go through. It counts only if no confirmation follows within 2 seconds (Tick).
for _, key in ipairs({ "ERR_ITEM_NOT_FOUND", "ERR_AUCTION_HIGHER_BID", "ERR_AUCTION_MIN_BID",
	"ERR_AUCTION_BID_OWN", "ERR_NOT_ENOUGH_MONEY" }) do
	if _G[key] then ns.AUCTION_ERRORS[_G[key]] = true end
end
function handlers.UI_ERROR_MESSAGE(_, msg)
	if issecretvalue and issecretvalue(msg) then return end
	if buy.state ~= "bought" or not msg then return end
	if msg == ERR_AUCTION_DATABASE_ERROR then
		buy.dbErrorAt = buy.dbErrorAt or GetTime()
		ns.Log("internal auction error after bid %s", tostring(buy.auctionID))
	elseif ns.AUCTION_ERRORS[msg] then
		ns.PurchaseFailed(msg)
	end
end

-- the auction house's own error channel (the red message in its window)
function handlers.AUCTION_HOUSE_SHOW_ERROR(err)
	ns.Log("AH error %s", tostring(err))
	local dbError = Enum and Enum.AuctionHouseError and Enum.AuctionHouseError.DatabaseError or 10
	if buy.state ~= "bought" then return end
	if err == dbError then
		buy.dbErrorAt = buy.dbErrorAt or GetTime()
	else
		-- any other auction house error after our bid (e.g. 4: the auction is gone): next auction at once
		ns.PurchaseFailed(("auction house error %s"):format(tostring(err)))
	end
end

function handlers.COMMODITY_PURCHASE_FAILED()
	ns.Log("commodity purchase failed")
	if buy.state == "confirming" or buy.state == "quoting" then ResetBuy(L["Purchase failed."]) end
end

-- the mailbox was visited: purchases in the mail no longer count as taken bag slots
function handlers.MAIL_CLOSED()
	ns.mailSlots = 0
end

local events = CreateFrame("Frame")
for event in pairs(handlers) do
	pcall(events.RegisterEvent, events, event)
end
events:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then handler(...) end
end)

---------------------------------------------------------------------------
-- Key binding and /vfloor
---------------------------------------------------------------------------

BINDING_HEADER_VENDORFLOOR = "VendorFloor"
BINDING_NAME_VENDORFLOOR_BUYNEXT = L["Buy next find"]

local function Help()
	Print(L["VendorFloor %s: everything is in the auction house tab and its menu."]:format(VERSION))
	for _, line in ipairs({
		L["/vfloor – show or hide VendorFloor at the auction house"],
		L["/vfloor buy – check and buy the next find (also a key binding)"],
		L["/vfloor options – open the settings"],
	}) do
		DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
	end
end

SLASH_VENDORFLOOR1 = "/vfloor"
SLASH_VENDORFLOOR2 = "/vendorfloor"
SlashCmdList.VENDORFLOOR = function(msg)
	local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	local num, money = tonumber(arg), ParseMoney(arg)
	if cmd == "profit" and money then
		SetMinProfit(money)
		Print(L["Minimum profit per unit: %s"]:format(Money(db.minProfit)))
	elseif cmd == "interval" and num then
		db.interval = max(floor(num), 1)
		Print(L["Pause between rounds: %d seconds"]:format(db.interval))
	elseif cmd == "sound" then
		db.sound = not db.sound
		Print(L["Alert sound: %s"]:format(db.sound and L["on"] or L["off"]))
	elseif cmd == "buy" then
		VendorFloor_BuyNext()
	elseif cmd == "ignore" and arg == "clear" then
		wipe(db.ignore)
		Print(L["Ignore list cleared."])
	elseif cmd == "ignore" then
		local names = {}
		for id, name in pairs(db.ignore) do names[#names + 1] = type(name) == "string" and name or tostring(id) end
		table.sort(names)
		Print(#names > 0 and L["Ignore list: %s"]:format(table.concat(names, ", ")) or L["The ignore list is empty."])
	elseif cmd == "stats" then
		Print(ns.TotalLine())
	elseif cmd == "export" then
		ns.ShowExport()
	elseif cmd == "percent" and num then
		db.minPercent = max(floor(num), 0)
		Print(L["Minimum profit in percent: %d%%"]:format(db.minPercent))
		if ui then ui.ShowPct() Refresh() end
	elseif cmd == "slot" and money then
		db.minSlot = money
		db.minSlotSilver = floor(db.minSlot / 100)
		Print(L["Minimum profit per bag slot: %s"]:format(Money(db.minSlot)))
	elseif cmd == "flash" then
		db.flash = not db.flash
		Print(L["Taskbar flash: %s"]:format(db.flash and L["on"] or L["off"]))
	elseif cmd == "craft" then
		ns.PrintCraft()
	elseif cmd == "sales" then
		ns.PrintSales()
	elseif cmd == "de" and arg == "debug" then
		db.deDebug = not db.deDebug
		Print("disenchant debug: " .. (db.deDebug and "on" or "off"))
	elseif cmd == "de" then
		for _, line in ipairs(ns.DeLines(15)) do Print(line) end
	elseif cmd == "quick" then
		if not StartQuick() then Print(L["The watch list needs at least 5 items. They come from finds below vendor price."]) end
	elseif cmd == "debug" then
		Print(("scan.active=%s round=%d seen=%d queue=%d checkTotal=%s buy.state=%s purpose=%s pending=%s throttleReady=%s full.active=%s phase=%s nextAt=%s ah=%s"):format(
			tostring(scan.active), scan.round or 0, scan.seen or 0, #queue, tostring(scan.checkTotal), tostring(buy.state),
			tostring(buy.purpose), tostring(pendingSend ~= nil), tostring(AH.IsThrottledMessageSystemReady()),
			tostring(full.active), tostring(full.phase), tostring(scan.nextAt and floor(scan.nextAt - GetTime())), tostring(ahOpen)))
		Print(("full: sends=%s waiting=%ss replicate=%s lastFull=%ss ago"):format(tostring(full.sends),
			tostring(full.t0 and floor(GetTime() - full.t0)), tostring(AH.GetNumReplicateItems and AH.GetNumReplicateItems()),
			tostring(db.lastFull and time() - db.lastFull)))
	elseif cmd == "minimap" then
		Print(ns.ToggleMinimap() and L["Minimap button shown."] or L["Minimap button hidden."])
	elseif cmd == "full" then
		StartFull()
	elseif cmd == "forget" then
		ns.ForgetPurchases()
		Print(L["Tracked purchases cleared."])
	elseif cmd == "reset" then
		db.point = nil
		if ui and ui:IsShown() then PlaceWindow() end
		Print(L["Window position reset."])
	elseif cmd == "options" or cmd == "settings" then
		ns.ToggleSettings()
	elseif cmd == "" then
		if not ahOpen then
			Print(L["The auction house must be open."])
		elseif ui and ui:IsShown() then
			if ui.embedded then
				db.hidden = true
				if AuctionHouseFrameBuyTab then AuctionHouseFrameBuyTab:Click() else ui:Hide() end
			else
				db.hidden = true
				ui:Hide()
			end
		else
			db.hidden = false
			ShowWindow()
		end
	else
		Help()
	end
end

-- For the automated tests (tests/*_spec.lua, run with busted outside the game); unused in the game.
ns.test = {
	Init = function() handlers.ADDON_LOADED(ADDON) end,
	ParseMoney = ParseMoney, ListingMedian = function(a) return ListingQuantile(a, 0.5) end, ListingLow = ListingLow, Worth = Worth,
	Shown = Shown, ItemID = ItemID, AddLearned = AddLearned, ClearCache = function() wipe(matCache) end,
	IsDisenchantCast = IsDisenchantCast, StartFull = function() StartFull() end, NextRound = function() NextRound() end,
	FullTick = FullTick, Full = function() return full end, Scan = function() return scan end, handlers = handlers,
}
