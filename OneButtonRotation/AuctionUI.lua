-- OneButtonRotation - Onglet « Bonnes affaires » dans l'hôtel des ventes
-- Se greffe sur la fenêtre Blizzard (Blizzard_AuctionHouseUI, chargée à la demande) comme un
-- onglet supplémentaire, à la manière d'Auctionator : un mode d'affichage de plus dans
-- AuctionHouseFrameDisplayMode, un bouton d'onglet du même gabarit que ceux de Blizzard.
-- Toute la logique est dans Auction.lua (ns.Auction) ; ici, uniquement l'affichage.

local ADDON_NAME, ns = ...
local AH = ns.Auction
if not AH then return end

local ROWS = 14
local ROW_H = 22
local frame, tab
local rowButtons = {}
local offset = 0

local function Money(copper)
  if type(GetMoneyString) == "function" then
    local ok, s = pcall(GetMoneyString, math.floor(copper or 0), true)
    if ok and s then return s end
  end
  return AH.MoneyString(copper)
end

local function Label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
  fs:SetText(text or "")
  return fs
end

local function Button(parent, text, w, h, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h or 22)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function StatusText(row)
  if row.status == "bought" then return "|cff40ff40Acheté|r" end
  if row.status == "pending" then return "|cffffd100Achat…|r" end
  if row.status == "failed" then return "|cffff4040" .. (row.error or "échec") .. "|r" end
  return "|cff80c0ffAcheter|r"
end

local function RefreshRows()
  local rows = AH.state.rows
  local maxOffset = math.max(0, #rows - ROWS)
  if offset > maxOffset then offset = maxOffset end
  for i, b in ipairs(rowButtons) do
    local row = rows[offset + i]
    b.row = row
    if row then
      local texture = select(5, C_Item.GetItemInfoInstant(row.itemID))
      b.icon:SetTexture(texture or 134400)
      local name = row.name or AH.ItemName(row.itemID) or ("Objet " .. row.itemID)
      row.name = name
      b.name:SetText(row.link and row.link:match("|h(.-)|h") or name)
      b.qty:SetText(row.qty)
      b.price:SetText(Money(row.price))
      b.vendor:SetText(Money(row.sellPrice * row.qty))
      b.profit:SetText("|cff40ff40+" .. Money(row.profit) .. "|r")
      b.state:SetText(StatusText(row))
      b:Show()
    else
      b:Hide()
    end
  end
  frame.pageText:SetText(#rows > 0 and string.format("%d – %d / %d", math.min(offset + 1, #rows), math.min(offset + ROWS, #rows), #rows) or "")
  frame.empty:SetShown(#rows == 0)
  if #rows == 0 then
    frame.empty:SetText(AH.state.phase == "done" and "Aucune enchère sous le prix vendeur dans ce scan." or "")
  end
end

local function RefreshButtons()
  local ok, why = AH.CanScan()
  local left = AH.ScanRemaining()
  if AH.IsScanning() then
    frame.scanBtn:SetText("Scan en cours…")
    frame.scanBtn:Disable()
  elseif left > 0 then
    frame.scanBtn:SetText("Scan dans " .. AH.ClockString(left))
    frame.scanBtn:Disable()
  else
    frame.scanBtn:SetText("Scanner l'hôtel des ventes")
    frame.scanBtn:SetEnabled(ok and true or false)
  end
  frame.scanBtn.tooltip = ok and "Scan complet : toutes les enchères, une fois toutes les 15 minutes." or why
  local nextRow = AH.NextRow()
  frame.nextBtn:SetEnabled(nextRow ~= nil and AH.state.open and not AH.state.pendingRow)
  frame.nextBtn:SetText(nextRow and ("Acheter le suivant (+" .. AH.MoneyString(nextRow.profit) .. ")") or "Acheter le suivant")
  frame.status:SetText(AH.StatusText())
end

function ns.AuctionUIRefresh()
  if not frame or not frame:IsShown() then return end
  RefreshButtons()
  RefreshRows()
end

local function BuildRow(parent, i)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(10, ROW_H)
  b:SetPoint("TOPLEFT", parent.header, "BOTTOMLEFT", 0, -((i - 1) * ROW_H))
  b:SetPoint("RIGHT", parent, "RIGHT", -8, 0)
  local hl = b:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.08)
  if i % 2 == 0 then
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(1, 1, 1, 0.04)
  end
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(18, 18)
  b.icon:SetPoint("LEFT", 4, 0)
  b.name = Label(b, "", "GameFontHighlightSmall")
  b.name:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
  b.name:SetWidth(230)
  b.name:SetJustifyH("LEFT")
  b.name:SetWordWrap(false)
  b.qty = Label(b, "", "GameFontHighlightSmall")
  b.qty:SetPoint("LEFT", b.name, "RIGHT", 6, 0)
  b.qty:SetWidth(36)
  b.qty:SetJustifyH("RIGHT")
  b.price = Label(b, "", "GameFontHighlightSmall")
  b.price:SetPoint("LEFT", b.qty, "RIGHT", 10, 0)
  b.price:SetWidth(110)
  b.price:SetJustifyH("RIGHT")
  b.vendor = Label(b, "", "GameFontHighlightSmall")
  b.vendor:SetPoint("LEFT", b.price, "RIGHT", 10, 0)
  b.vendor:SetWidth(110)
  b.vendor:SetJustifyH("RIGHT")
  b.profit = Label(b, "", "GameFontHighlightSmall")
  b.profit:SetPoint("LEFT", b.vendor, "RIGHT", 10, 0)
  b.profit:SetWidth(100)
  b.profit:SetJustifyH("RIGHT")
  b.state = Label(b, "", "GameFontHighlightSmall")
  b.state:SetPoint("LEFT", b.profit, "RIGHT", 10, 0)
  b.state:SetPoint("RIGHT", -4, 0)
  b.state:SetJustifyH("LEFT")
  b.state:SetWordWrap(false)
  -- Un clic = un achat : PlaceBid / StartCommoditiesPurchase exigent d'être appelés depuis le clic lui-même.
  b:SetScript("OnClick", function(self)
    if not self.row then return end
    local ok, msg = AH.Buy(self.row)
    if msg then AH.Print("%s", msg) end
    ns.AuctionUIRefresh()
  end)
  b:SetScript("OnEnter", function(self)
    if not self.row then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.row.link then GameTooltip:SetHyperlink(self.row.link) else GameTooltip:SetText(self.row.name or "?") end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(string.format("Rachat %s pour %d, revente vendeur %s : gain %s", AH.MoneyString(self.row.price),
      self.row.qty, AH.MoneyString(self.row.sellPrice * self.row.qty), AH.MoneyString(self.row.profit)), 1, 1, 1, true)
    GameTooltip:AddLine(self.row.kind == "commodity" and "Objet empilable : achat groupé de tout ce qui est sous le prix vendeur, prix revérifié par le serveur avant confirmation."
      or "Enchère unique : achat immédiat au prix affiché ; refusé si elle est déjà partie.", 0.8, 0.8, 0.8, true)
    GameTooltip:AddLine(self.row.status == "ready" and "|cff80c0ffClic : acheter|r" or StatusText(self.row), 1, 1, 1)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return b
end

local function Build(ahf)
  frame = CreateFrame("Frame", "OBRAuctionDealsFrame", ahf)
  -- Même emprise que l'onglet « Enchères » de Blizzard
  frame:SetPoint("LEFT", ahf, "LEFT", 5, 0)
  frame:SetPoint("RIGHT", ahf, "RIGHT", 0, 0)
  frame:SetPoint("TOP", ahf, "TOP", 0, -42)
  if ahf.MoneyFrameBorder then
    frame:SetPoint("BOTTOM", ahf.MoneyFrameBorder, "TOP", 0, 2)
  else
    frame:SetPoint("BOTTOM", ahf, "BOTTOM", 0, 30)
  end
  frame:Hide()
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    offset = math.max(0, offset - delta * 3)
    RefreshRows()
  end)

  frame.scanBtn = Button(frame, "Scanner l'hôtel des ventes", 200, 24, function()
    local ok, msg = AH.StartScan()
    AH.Print("%s", msg)
    ns.AuctionUIRefresh()
  end)
  frame.scanBtn:SetPoint("TOPLEFT", 8, -6)
  frame.scanBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(self.tooltip or "", 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.scanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame.nextBtn = Button(frame, "Acheter le suivant", 230, 24, function()
    local _, msg = AH.BuyNext()
    if msg then AH.Print("%s", msg) end
    ns.AuctionUIRefresh()
  end)
  frame.nextBtn:SetPoint("LEFT", frame.scanBtn, "RIGHT", 8, 0)

  frame.reportBtn = Button(frame, "Rapport (chat)", 120, 24, function() AH.Report() end)
  frame.reportBtn:SetPoint("LEFT", frame.nextBtn, "RIGHT", 8, 0)

  frame.status = Label(frame, "", "GameFontHighlightSmall")
  frame.status:SetPoint("TOPLEFT", frame.scanBtn, "BOTTOMLEFT", 2, -4)
  frame.status:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
  frame.status:SetJustifyH("LEFT")
  frame.status:SetHeight(14)

  -- En-tête de colonnes
  local header = CreateFrame("Frame", nil, frame)
  header:SetPoint("TOPLEFT", frame.status, "BOTTOMLEFT", -2, -6)
  header:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
  header:SetHeight(18)
  frame.header = header
  local function Head(text, anchorTo, w, justify, x)
    local fs = Label(header, text, "GameFontNormalSmall")
    if anchorTo then fs:SetPoint("LEFT", anchorTo, "RIGHT", x or 10, 0) else fs:SetPoint("LEFT", 28, 0) end
    if w then fs:SetWidth(w) end
    fs:SetJustifyH(justify or "LEFT")
    return fs
  end
  local hName = Head("Objet", nil, 230)
  local hQty = Head("Qté", hName, 36, "RIGHT", 6)
  local hPrice = Head("Rachat", hQty, 110, "RIGHT")
  local hVendor = Head("Vendeur", hPrice, 110, "RIGHT")
  local hProfit = Head("Gain", hVendor, 100, "RIGHT")
  Head("Clic = acheter", hProfit, nil, "LEFT")

  for i = 1, ROWS do rowButtons[i] = BuildRow(frame, i) end

  frame.empty = Label(frame, "", "GameFontDisable")
  frame.empty:SetPoint("TOP", header, "BOTTOM", 0, -40)
  frame.empty:Hide()

  frame.pageText = Label(frame, "", "GameFontDisableSmall")
  frame.pageText:SetPoint("BOTTOMRIGHT", -10, 4)
  local up = Button(frame, "▲", 24, 20, function() offset = math.max(0, offset - ROWS); RefreshRows() end)
  up:SetPoint("RIGHT", frame.pageText, "LEFT", -6, 0)
  local down = Button(frame, "▼", 24, 20, function() offset = offset + ROWS; RefreshRows() end)
  down:SetPoint("RIGHT", up, "LEFT", -2, 0)

  local hint = Label(frame, "Un clic sur une ligne achète (le jeu exige un clic ou une touche par achat : pas d'achat automatique). "
    .. "« Acheter le suivant » prend la meilleure affaire restante ; lie-le à un bouton dans Options > Raccourcis > AddOns. "
    .. "Gain minimal : /obr ah profit <cuivre>.", "GameFontDisableSmall")
  hint:SetPoint("BOTTOMLEFT", 10, 4)
  hint:SetPoint("RIGHT", down, "LEFT", -10, 0)
  hint:SetJustifyH("LEFT")
  hint:SetHeight(26)

  -- Compte à rebours du scan
  local acc = 0
  frame:SetScript("OnUpdate", function(_, elapsed)
    acc = acc + elapsed
    if acc >= 1 then acc = 0; RefreshButtons() end
  end)
  frame:SetScript("OnShow", function() offset = 0; ns.AuctionUIRefresh() end)
end

-- Appelé quand Blizzard_AuctionHouseUI est chargé (ADDON_LOADED) ou au login s'il l'est déjà
function ns.AuctionSetupTab()
  local ahf = _G.AuctionHouseFrame
  if not ahf or tab or not ahf.Tabs or not ahf.tabsForDisplayMode or not _G.AuctionHouseFrameDisplayMode then return false end
  Build(ahf)
  ahf.OBRDealsFrame = frame
  local mode = { "OBRDealsFrame" }
  AuctionHouseFrameDisplayMode.OBRDeals = mode

  tab = CreateFrame("Button", "OBRAuctionDealsTab", ahf, "AuctionHouseFrameDisplayModeTabTemplate")
  tab:SetText("Bonnes affaires")
  tab.displayMode = mode
  tab:SetPoint("LEFT", ahf.Tabs[#ahf.Tabs], "RIGHT", -15, 0)
  table.insert(ahf.Tabs, tab)
  ahf.tabsForDisplayMode[mode] = #ahf.Tabs
  if PanelTemplates_SetNumTabs then PanelTemplates_SetNumTabs(ahf, #ahf.Tabs) end
  if PanelTemplates_UpdateTabs then PanelTemplates_UpdateTabs(ahf) end

  if hooksecurefunc and ahf.UpdateTitle then
    hooksecurefunc(ahf, "UpdateTitle", function(self)
      if self.displayMode == mode and self.SetTitle then self:SetTitle("Hôtel des ventes – Bonnes affaires") end
    end)
  end
  return true
end

-- Si l'hôtel des ventes était déjà chargé avant nous (ordre de chargement), on se greffe tout de suite
if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then
  pcall(ns.AuctionSetupTab)
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", AuctionUI"
