-- VendorFloor
-- Copyright (c) 2026 Bencepo. All rights reserved. See LICENSE.
--
-- Texts: English only. L["..."] returns its key, so every text is written in English
-- where it is used. VendorFloor is not translated.

local _, ns = ...

-- Item info lives in C_Item on current clients. The global is only a fallback for
-- clients without it, so the deprecated name is read in this one place.
---@diagnostic disable-next-line: deprecated
ns.GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
---@diagnostic disable-next-line: deprecated
ns.GetDetailedItemLevelInfo = (C_Item and C_Item.GetDetailedItemLevelInfo) or GetDetailedItemLevelInfo

local L = setmetatable({}, { __index = function(_, key) return key end })
ns.L = L
ns.COPPER = "c" -- abbreviation for copper in amounts ("50c")
