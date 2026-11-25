-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Own auction sales: what you post (hooked from the auction house, works with any auction addon),
-- when a buyer is found and what expires. From this VendorFloor learns how fast an item
-- sells, at what price it really sold, and how often it sells at all. Disenchant materials
-- and crafted items are then valued at the price that sold, times the share that sells.
-- Sales and expiries are read from the mailbox, also those while you were offline.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })
local GetItemInfo = ns.GetItemInfo
local floor, max, min = math.floor, math.max, math.min

local KEEP = 3 * 86400   -- posted auctions are forgotten after this (longest duration is 48 h)
local FRESH = 3 * 86400  -- a sold price counts this long
local MIN_ENDED = 3      -- ended auctions needed before the sell rate counts

local function DB() return ns.db end

-- db.sales[itemID] = { posts, units, sold = buyer messages, firstN = auctions with a sale,
--   firstSum = seconds from posting to the first buyer (summed), expired, price, priceAt }
local function Entry(db, id)
	db.sales = db.sales or {}
	local e = db.sales[id]
	if not e then
		e = { posts = 0, units = 0, sold = 0, firstN = 0, firstSum = 0, expired = 0 }
		db.sales[id] = e
	end
	return e
end

local function OnPost(loc, qty, unit)
	local db = DB()
	if not (db and loc and C_Item and C_Item.GetItemID) then return end
	local id = C_Item.GetItemID(loc)
	if not id then return end
	local name = GetItemInfo(id)
	if not name then return end
	local e = Entry(db, id)
	e.posts = e.posts + 1
	e.units = e.units + (qty or 1)
	db.open = db.open or {}
	db.open[#db.open + 1] = { id = id, name = name, unit = unit and floor(unit + 0.5), at = time() }
end

if C_AuctionHouse and hooksecurefunc then
	if C_AuctionHouse.PostCommodity then
		hooksecurefunc(C_AuctionHouse, "PostCommodity", function(loc, _, qty, unit)
			pcall(OnPost, loc, qty, unit)
		end)
	end
	if C_AuctionHouse.PostItem then
		hooksecurefunc(C_AuctionHouse, "PostItem", function(loc, _, qty, _, buyout)
			qty = qty or 1
			pcall(OnPost, loc, qty, buyout and buyout / max(qty, 1))
		end)
	end
end

-- "Auction expired: %s" -> Lua pattern with one capture
local function Pattern(fmt)
	if type(fmt) ~= "string" then return nil end
	-- "%s" and positional "%1$s" both become the capture
	local p = fmt:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%%d+%%%$s", "(.+)"):gsub("%%%%s", "(.+)")
	return "^" .. p .. "$"
end

-- The oldest posted auction of this name, preferring one without a buyer yet: a sold
-- auction stays listed until it ends, but a new buyer or an expiry belongs to the next one.
local function Oldest(db, name)
	local first, firstI
	for i, o in ipairs(db.open or {}) do
		if o.name == name then
			if not o.hit then return o, i end
			first, firstI = first or o, firstI or i
		end
	end
	return first, firstI
end

local function Purge(db)
	local now, keep = time(), {}
	for _, o in ipairs(db.open or {}) do
		if now - o.at < KEEP then keep[#keep + 1] = o end
	end
	db.open = keep
end

-- A sale or an expiry, matched to the oldest posted auction of that name.
local function Sold(db, name, unit, at)
	local o = Oldest(db, name)
	if not o then return end
	local e = Entry(db, o.id)
	e.sold = e.sold + 1
	if not o.hit then
		o.hit = true
		e.firstN = e.firstN + 1
		e.firstSum = e.firstSum + max(0, (at or time()) - o.at)
	end
	unit = unit or o.unit
	if unit then e.price, e.priceAt = unit, time() end
end

local function Expired(db, name)
	local o, i = Oldest(db, name)
	if not o then return end
	local e = Entry(db, o.id)
	if not o.hit then e.expired = e.expired + 1 end
	table.remove(db.open, i)
end

-- Sales and expiries are read from the mailbox: the chat lines about them are hidden from
-- addons now (secret values). Each sale sends a mail with an invoice (item, amount, price),
-- each expiry a mail "Auction expired: <item>". Mails stay in the inbox for a while, so
-- each one is counted once (key: subject, money and when it expires).
local EXPIRED_SUBJECT = Pattern(AUCTION_EXPIRED_MAIL_SUBJECT)
local MAIL_DAYS = 30
local function Secret(v) return issecretvalue and issecretvalue(v) end

local function ScanMail()
	local db = DB()
	if not (db and db.open and db.open[1] and GetInboxNumItems and GetInboxHeaderInfo) then return end
	db.seenMail = db.seenMail or {}
	local now = time()
	for i = 1, GetInboxNumItems() do
		local _, _, _, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
		if type(subject) == "string" and type(daysLeft) == "number" and not Secret(subject) and not Secret(daysLeft) then
			local expires = now + floor(daysLeft * 86400)
			local key = subject .. "|" .. tostring(money or 0) .. "|" .. floor(expires / 600)
			if not db.seenMail[key] then
				local inv = GetInboxInvoiceInfo and { GetInboxInvoiceInfo(i) } or {}
				local invoiceType, itemName, bid, count = inv[1], inv[2], inv[4], inv[11]
				if invoiceType == "seller" and type(itemName) == "string" and not Secret(itemName) then
					db.seenMail[key] = now
					local unit = bid and count and count > 0 and floor(bid / count + 0.5) or nil
					-- the money mail goes out about an hour after the sale
					Sold(db, itemName, unit, expires - MAIL_DAYS * 86400 - 3600)
				elseif EXPIRED_SUBJECT and subject:match(EXPIRED_SUBJECT) then
					db.seenMail[key] = now
					Expired(db, subject:match(EXPIRED_SUBJECT))
				end
			end
		end
	end
	for key, at in pairs(db.seenMail) do
		if now - at > (MAIL_DAYS + 1) * 86400 then db.seenMail[key] = nil end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("MAIL_INBOX_UPDATE")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		if DB() then Purge(DB()) end
	else
		pcall(ScanMail)
	end
end)

-- Unit price your last sale of this item went for (recent), or nil.
function ns.SoldPrice(id)
	local e = DB() and DB().sales and DB().sales[id]
	if e and e.price and time() - (e.priceAt or 0) < FRESH then return e.price end
end

-- Share of your ended auctions of this item that found a buyer, or nil if too few ended.
function ns.SellRate(id)
	local e = DB() and DB().sales and DB().sales[id]
	if not e then return nil end
	local ended = e.firstN + e.expired
	if ended < MIN_ENDED then return nil end
	return e.firstN / ended
end

local function Duration(sec)
	if sec < 3600 then return ("%d min"):format(max(floor(sec / 60 + 0.5), 1)) end
	return ("%.1f h"):format(sec / 3600)
end

function ns.SalesLines(limit)
	local db = DB()
	local list, lines = {}, {}
	for id, e in pairs(db and db.sales or {}) do list[#list + 1] = { id = id, e = e } end
	table.sort(list, function(a, b) return a.e.posts > b.e.posts end)
	if #list == 0 then
		return { L["No own auctions recorded yet. They are recorded from now on when you post."] }
	end
	for i = 1, min(#list, limit or #list) do
		local x, e = list[i], list[i].e
		local ended = e.firstN + e.expired
		lines[#lines + 1] = L["%s: posted %d×, sold %d of %d ended, first buyer after %s, last price %s"]:format(
			ns.ItemLink and ns.ItemLink(x.id) or select(2, GetItemInfo(x.id)) or x.id, e.posts, e.firstN, ended,
			e.firstN > 0 and Duration(e.firstSum / e.firstN) or "–",
			e.price and ns.Money(e.price) or "–")
	end
	return lines
end

function ns.PrintSales()
	for _, line in ipairs(ns.SalesLines(15)) do ns.Print(line) end
end

-- For the automated tests; unused in the game.
ns.salesTest = { Pattern = Pattern, OnPost = OnPost, ScanMail = ScanMail }
