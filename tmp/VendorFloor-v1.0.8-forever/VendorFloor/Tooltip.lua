-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Optional (settings, off by default): VendorFloor's values in item tooltips. The
-- disenchant value of green and blue gear, the latest low auction price VendorFloor saw
-- and your watchlist limit. The vendor price is left out: the game and many addons show it.

local _, ns = ...
local L = ns.L or setmetatable({}, { __index = function(_, key) return key end })

local GOLD = { 0.88, 0.66, 0.23 }

local function AddLines(tip, link)
	local db = ns.db
	if not (db and db.tooltip and link and ns.Money) then return end
	if issecretvalue and issecretvalue(link) then return end -- hidden from addons
	local id = tonumber(link:match("item:(%d+)"))
	if not id then return end
	local lines = {}
	if ns.DisenchantValue then -- green and blue weapons and armor, when you can disenchant
		local ok, de = pcall(ns.DisenchantValue, link)
		if ok and de then lines[#lines + 1] = { L["Disenchant value"], "~" .. ns.Money(de) } end
	end
	if ns.PlainKey and ns.LowValue then
		local ok, low = pcall(function() return ns.LowValue(ns.PlainKey(id)) end)
		if ok and low then lines[#lines + 1] = { L["Auction house (low)"], ns.Money(low) } end
	end
	local want = db.wishlist and db.wishlist[id]
	if want then lines[#lines + 1] = { L["Watchlist limit"], ns.Money(want.max) } end
	if #lines == 0 then return end
	tip:AddLine("VendorFloor", GOLD[1], GOLD[2], GOLD[3])
	for _, l in ipairs(lines) do tip:AddDoubleLine(l[1], l[2], 0.8, 0.8, 0.8, 1, 1, 1) end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip)
		if not (tip and tip.GetItem) then return end
		local _, link = tip:GetItem()
		AddLines(tip, link)
	end)
else
	for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
		if tip then
			tip:HookScript("OnTooltipSetItem", function(self)
				local _, link = self:GetItem()
				AddLines(self, link)
			end)
		end
	end
end
