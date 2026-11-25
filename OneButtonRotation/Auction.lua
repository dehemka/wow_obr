-- OneButtonRotation - Bonnes affaires de l'hôtel des ventes (logique, sans interface)
-- Scan complet (C_AuctionHouse.ReplicateItems, une fois toutes les 15 min), repérage des
-- enchères dont le rachat est inférieur au prix de revente chez un vendeur, puis achat à la
-- demande. Les fonctions d'achat du client (PlaceBid, StartCommoditiesPurchase) exigent un
-- clic ou une touche : AH.Buy / AH.BuyNext doivent être appelées depuis un OnClick ou un
-- raccourci, jamais depuis un timer ou un événement.
--
-- Déroulé d'un scan (chaque étape est une fonction, enchaînée par événements ou par
-- AH.Schedule pour rester testable hors jeu) :
--   StartScan → REPLICATE_ITEM_LIST_UPDATE → ProcessChunk (par paquets) → ResolvePrices
--   → (ITEM_DATA_LOAD_RESULT…) → FinishPrices → NextSearch (1 recherche à la fois, événements
--   ITEM_SEARCH_RESULTS_UPDATED / COMMODITY_SEARCH_RESULTS_UPDATED) → phase « done ».

local ADDON_NAME, ns = ...

local AH = {}
ns.Auction = AH

AH.SCAN_COOLDOWN  = 15 * 60 -- secondes entre deux scans complets (limite serveur)
AH.CHUNK          = 800     -- enchères dépouillées par passe (évite de figer le jeu)
AH.MAX_CANDIDATES = 60      -- objets re-cherchés après le scan (le client limite à 100 recherches/min)
AH.SEARCH_TIMEOUT = 4       -- secondes avant d'abandonner une recherche sans réponse
AH.PRICE_TIMEOUT  = 15      -- secondes max pour charger les prix vendeur manquants
AH.BUY_TIMEOUT    = 6       -- secondes avant de considérer un achat sans réponse comme échoué

local function Print(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  local out = DEFAULT_CHAT_FRAME or { AddMessage = function(_, s) print(s) end }
  out:AddMessage("|cff00ff88OBR|r |cffffd100HV|r " .. msg)
end
AH.Print = Print

function AH.Now() return (type(time) == "function" and time()) or os.time() end

-- Planification hors combat : C_Timer en jeu ; les tests appellent les étapes à la main.
function AH.Schedule(delay, fn)
  if C_Timer and C_Timer.After then C_Timer.After(delay, fn) end
end

-------------------------------------------------------------------------------
-- État
-------------------------------------------------------------------------------
AH.state = {
  open = false,        -- hôtel des ventes ouvert
  phase = "idle",      -- idle | replicate | process | prices | search | done
  rows = {},           -- affaires achetables, triées par gain décroissant
  stats = {},          -- compteurs du dernier scan
  report = { bought = 0, spent = 0, gain = 0, failed = 0, failures = {} },
}

local function Changed()
  if ns.AuctionUIRefresh then pcall(ns.AuctionUIRefresh) end
end

local function ResetReport()
  AH.state.report = { bought = 0, spent = 0, gain = 0, failed = 0, failures = {} }
end

-------------------------------------------------------------------------------
-- Utilitaires
-------------------------------------------------------------------------------
-- 123456 → « 12po 34pa 56pc » (texte brut, sans icônes)
function AH.MoneyString(copper)
  copper = math.floor(tonumber(copper) or 0)
  local neg = copper < 0
  if neg then copper = -copper end
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then table.insert(parts, g .. "po") end
  if s > 0 or g > 0 then table.insert(parts, s .. "pa") end
  table.insert(parts, c .. "pc")
  return (neg and "-" or "") .. table.concat(parts, " ")
end

-- « 12:34 » à partir de secondes
function AH.ClockString(seconds)
  seconds = math.max(0, math.floor(seconds or 0))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

-- Suffixe aléatoire (« du Singe ») d'un lien d'objet : item:ID:ench:g1:g2:g3:g4:SUFFIXE:...
function AH.SuffixFromLink(link)
  if type(link) ~= "string" then return 0 end
  local suffix = link:match("item:%d+:%-?%d*:%-?%d*:%-?%d*:%-?%d*:%-?%d*:(%-?%d+)")
  return tonumber(suffix) or 0
end

-- Prix de revente chez un vendeur (par unité) ou nil si l'objet n'est pas encore chargé
function AH.SellPrice(itemID)
  if C_Item and C_Item.GetItemInfo then
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(C_Item.GetItemInfo, itemID)
    if ok and name then return tonumber(sellPrice) or 0, name end
  elseif type(GetItemInfo) == "function" then
    local ok, name, _, _, _, _, _, _, _, _, _, sellPrice = pcall(GetItemInfo, itemID)
    if ok and name then return tonumber(sellPrice) or 0, name end
  end
  return nil
end

function AH.ItemName(itemID)
  local _, name = AH.SellPrice(itemID)
  return name
end

-- Libellé français d'une erreur Enum.AuctionHouseError
local ERRORS = {
  NotEnoughMoney = "pas assez d'argent", HigherBid = "quelqu'un a surenchéri", BidIncrement = "enchère trop basse",
  BidOwn = "c'est ta propre enchère", ItemNotFound = "enchère déjà partie", RestrictedAccountTrial = "compte restreint",
  HasRestriction = "compte restreint", IsBusy = "hôtel des ventes occupé, réessaie", Unavailable = "hôtel des ventes indisponible",
  ItemHasQuote = "un devis est déjà en cours", DatabaseError = "erreur serveur", DoubleBid = "achat déjà en cours",
  ItemNotAvailable = "plus disponible", NotEnoughItems = "plus assez d'exemplaires",
}
function AH.ErrorText(code)
  if Enum and Enum.AuctionHouseError then
    for name, value in pairs(Enum.AuctionHouseError) do
      if value == code then return ERRORS[name] or ("erreur " .. name) end
    end
  end
  return "erreur " .. tostring(code)
end

-------------------------------------------------------------------------------
-- Verrou de 15 minutes
-------------------------------------------------------------------------------
-- Secondes avant le prochain scan autorisé (0 = prêt)
function AH.ScanRemaining(now)
  local last = ns.db and ns.db.ahLastScan
  if not last then return 0 end
  return math.max(0, AH.SCAN_COOLDOWN - ((now or AH.Now()) - last))
end

function AH.IsScanning()
  local p = AH.state.phase
  return p == "replicate" or p == "process" or p == "prices" or p == "search"
end

-- Retourne true, ou false + raison
function AH.CanScan()
  if not AH.state.open then return false, "ouvre d'abord l'hôtel des ventes" end
  if AH.IsScanning() then return false, "scan en cours" end
  local left = AH.ScanRemaining()
  if left > 0 then return false, "prochain scan complet dans " .. AH.ClockString(left) end
  if not (C_AuctionHouse and C_AuctionHouse.ReplicateItems) then return false, "API ReplicateItems absente" end
  return true
end

-------------------------------------------------------------------------------
-- Scan
-------------------------------------------------------------------------------
function AH.StartScan()
  local ok, why = AH.CanScan()
  if not ok then return false, why end
  ns.db.ahLastScan = AH.Now()
  AH.state.phase = "replicate"
  AH.state.rows = {}
  AH.state.stats = { started = AH.Now(), scanned = 0, keys = 0, candidates = 0, searched = 0, unresolved = 0 }
  AH.state.agg = {}
  AH.state.index = 0
  AH.state.total = 0
  ResetReport()
  local okCall, err = pcall(C_AuctionHouse.ReplicateItems)
  if not okCall then
    AH.state.phase = "idle"
    return false, "ReplicateItems a échoué : " .. tostring(err)
  end
  Changed()
  return true, "scan complet demandé, réponse du serveur en cours…"
end

-- REPLICATE_ITEM_LIST_UPDATE : la liste complète est arrivée, on la dépouille par paquets
function AH.BeginProcessing()
  if AH.state.phase ~= "replicate" then return end
  AH.state.phase = "process"
  AH.state.total = C_AuctionHouse.GetNumReplicateItems() or 0
  AH.state.index = 0
  AH.state.agg = {}
  AH.state.playerName = UnitName and UnitName("player") or nil
  Changed()
  AH.ProcessChunk()
end

-- Une passe de dépouillement. Retourne true quand tout est lu.
function AH.ProcessChunk()
  if AH.state.phase ~= "process" then return true end
  local st, agg = AH.state, AH.state.agg
  local stop = math.min(st.total, st.index + AH.CHUNK)
  for i = st.index + 1, stop do
    local _, _, count, _, _, _, _, _, _, buyoutPrice, _, _, _, owner, _, _, itemID = C_AuctionHouse.GetReplicateItemInfo(i)
    count = tonumber(count) or 0
    buyoutPrice = tonumber(buyoutPrice) or 0
    if itemID and count > 0 and buyoutPrice > 0 and owner ~= st.playerName then
      local link = C_AuctionHouse.GetReplicateItemLink and C_AuctionHouse.GetReplicateItemLink(i) or nil
      local suffix = AH.SuffixFromLink(link)
      local key = itemID .. ":" .. suffix
      local unit = buyoutPrice / count
      local a = agg[key]
      if not a then
        a = { itemID = itemID, suffix = suffix, minUnit = unit, link = link, n = 0 }
        agg[key] = a
        st.stats.keys = st.stats.keys + 1
      elseif unit < a.minUnit then
        a.minUnit = unit
        a.link = link or a.link
      end
      a.n = a.n + 1
    end
  end
  st.index = stop
  st.stats.scanned = stop
  if stop < st.total then
    AH.Schedule(0, AH.ProcessChunk)
    return false
  end
  AH.ResolvePrices()
  return true
end

-- Prix vendeur de chaque objet vu ; demande le chargement de ceux qui manquent
function AH.ResolvePrices()
  local st = AH.state
  st.phase = "prices"
  st.pendingPrices = {}
  st.sellPrice = {}
  local pending = 0
  for _, a in pairs(st.agg) do
    if st.sellPrice[a.itemID] == nil and not st.pendingPrices[a.itemID] then
      local price = AH.SellPrice(a.itemID)
      if price then
        st.sellPrice[a.itemID] = price
      else
        st.pendingPrices[a.itemID] = true
        pending = pending + 1
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, a.itemID) end
      end
    end
  end
  st.pendingCount = pending
  Changed()
  if pending == 0 then
    AH.FinishPrices()
  else
    local token = {}
    st.priceToken = token
    AH.Schedule(AH.PRICE_TIMEOUT, function()
      if st.priceToken == token and st.phase == "prices" then AH.FinishPrices(true) end
    end)
  end
end

-- ITEM_DATA_LOAD_RESULT(itemID, success)
function AH.OnItemLoaded(itemID, success)
  local st = AH.state
  if st.phase ~= "prices" or not st.pendingPrices or not st.pendingPrices[itemID] then return end
  st.pendingPrices[itemID] = nil
  st.pendingCount = math.max(0, (st.pendingCount or 1) - 1)
  local price = success ~= false and AH.SellPrice(itemID) or nil
  st.sellPrice[itemID] = price or 0
  if st.pendingCount == 0 then AH.FinishPrices() end
end

-- Choisit les objets dont le rachat unitaire minimal est sous le prix vendeur, puis lance les recherches
function AH.FinishPrices(forced)
  local st = AH.state
  if st.phase ~= "prices" then return end
  st.priceToken = nil
  if forced then
    for itemID in pairs(st.pendingPrices or {}) do st.sellPrice[itemID] = st.sellPrice[itemID] or 0 end
    st.stats.unresolved = (st.stats.unresolved or 0) + (st.pendingCount or 0)
  end
  local candidates = {}
  for _, a in pairs(st.agg) do
    local sell = st.sellPrice[a.itemID] or 0
    if sell > 0 and a.minUnit < sell then
      a.sellPrice = sell
      a.potential = sell - a.minUnit
      table.insert(candidates, a)
    end
  end
  table.sort(candidates, function(x, y)
    if x.potential ~= y.potential then return x.potential > y.potential end
    return x.itemID < y.itemID
  end)
  while #candidates > AH.MAX_CANDIDATES do table.remove(candidates) end
  st.candidates = candidates
  st.stats.candidates = #candidates
  st.agg = nil
  st.phase = "search"
  Changed()
  AH.NextSearch()
end

local function MakeKey(itemID, suffix)
  if C_AuctionHouse and C_AuctionHouse.MakeItemKey then
    local ok, key = pcall(C_AuctionHouse.MakeItemKey, itemID, 0, suffix or 0, 0)
    if ok and key then return key end
  end
  return { itemID = itemID, itemLevel = 0, itemSuffix = suffix or 0, battlePetSpeciesID = 0 }
end

local function PriceSorts()
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  return { { sortOrder = order, reverseSort = false } }
end

-- Lance la recherche du prochain candidat, ou termine
function AH.NextSearch()
  local st = AH.state
  if st.phase ~= "search" then return end
  local cand = table.remove(st.candidates, 1)
  if not cand then
    st.current = nil
    st.phase = "done"
    st.stats.finished = AH.Now()
    AH.SortRows()
    Changed()
    return
  end
  st.current = cand
  st.stats.searched = st.stats.searched + 1
  local token = {}
  st.searchToken = token
  local ok = pcall(C_AuctionHouse.SendSearchQuery, MakeKey(cand.itemID, cand.suffix), PriceSorts(), false)
  if not ok then
    st.stats.unresolved = (st.stats.unresolved or 0) + 1
    return AH.NextSearch()
  end
  AH.Schedule(AH.SEARCH_TIMEOUT, function()
    if st.searchToken == token and st.phase == "search" and st.current == cand then
      st.stats.unresolved = (st.stats.unresolved or 0) + 1
      AH.NextSearch()
    end
  end)
end

local function MinProfit() return (ns.db and tonumber(ns.db.ahMinProfit)) or 0 end

-- ITEM_SEARCH_RESULTS_UPDATED(itemKey) : une ligne par enchère rentable
function AH.OnItemResults(itemKey)
  local st = AH.state
  local cand = st.current
  if st.phase ~= "search" or not cand then return end
  local itemID = type(itemKey) == "table" and itemKey.itemID or itemKey
  if itemID ~= cand.itemID then return end
  local n = C_AuctionHouse.GetNumItemSearchResults(itemKey) or 0
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.auctionID and (tonumber(r.buyoutAmount) or 0) > 0 and not r.containsOwnerItem then
      local qty = tonumber(r.quantity) or 1
      local price = tonumber(r.buyoutAmount)
      local profit = cand.sellPrice * qty - price
      if profit >= math.max(1, MinProfit()) then
        table.insert(st.rows, {
          kind = "item", itemID = cand.itemID, link = r.itemLink or cand.link, name = AH.ItemName(cand.itemID),
          auctionID = r.auctionID, qty = qty, price = price, sellPrice = cand.sellPrice, profit = profit, status = "ready",
        })
      end
    end
  end
  st.searchToken = nil
  AH.NextSearch()
end

-- COMMODITY_SEARCH_RESULTS_UPDATED(itemID) : une seule ligne regroupant tout ce qui est sous le prix vendeur
function AH.OnCommodityResults(itemID)
  local st = AH.state
  local cand = st.current
  if st.phase ~= "search" or not cand or itemID ~= cand.itemID then return end
  local n = C_AuctionHouse.GetNumCommoditySearchResults(itemID) or 0
  local qty, cost, maxUnit = 0, 0, 0
  for i = 1, n do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r and not r.containsOwnerItem then
      local unit = tonumber(r.unitPrice) or 0
      if unit > 0 and unit < cand.sellPrice then
        qty = qty + (tonumber(r.quantity) or 0)
        cost = cost + unit * (tonumber(r.quantity) or 0)
        maxUnit = math.max(maxUnit, unit)
      end
    end
  end
  local profit = cand.sellPrice * qty - cost
  if qty > 0 and profit >= math.max(1, MinProfit()) then
    table.insert(st.rows, {
      kind = "commodity", itemID = itemID, link = cand.link, name = AH.ItemName(itemID),
      qty = qty, price = cost, maxTotal = cand.sellPrice * qty - math.max(1, MinProfit()),
      sellPrice = cand.sellPrice, profit = profit, status = "ready",
    })
  end
  st.searchToken = nil
  AH.NextSearch()
end

function AH.SortRows()
  table.sort(AH.state.rows, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return (a.name or "") < (b.name or "")
  end)
end

-------------------------------------------------------------------------------
-- Achat (à appeler depuis un clic ou un raccourci)
-------------------------------------------------------------------------------
local function Fail(row, why)
  local st = AH.state
  row.status = "failed"
  row.error = why
  st.pendingRow = nil
  st.report.failed = st.report.failed + 1
  table.insert(st.report.failures, string.format("%s ×%d : %s", row.name or ("objet " .. row.itemID), row.qty, why))
  Changed()
end

local function Bought(row)
  local st = AH.state
  row.status = "bought"
  st.pendingRow = nil
  st.report.bought = st.report.bought + 1
  st.report.spent = st.report.spent + (row.paid or row.price)
  st.report.gain = st.report.gain + (row.sellPrice * row.qty - (row.paid or row.price))
  Changed()
end

function AH.Buy(row)
  local st = AH.state
  if not row then return false, "aucune ligne" end
  if not st.open then return false, "l'hôtel des ventes est fermé" end
  if row.status ~= "ready" then return false, "ligne déjà traitée (" .. tostring(row.status) .. ")" end
  if st.pendingRow then return false, "un achat est déjà en cours, attends la réponse" end
  local money = type(GetMoney) == "function" and GetMoney() or math.huge
  if money < row.price then
    Fail(row, "pas assez d'argent (" .. AH.MoneyString(row.price) .. ")")
    return false, "pas assez d'argent"
  end
  row.status = "pending"
  st.pendingRow = row
  local token = {}
  row.token = token
  local ok, err
  if row.kind == "item" then
    ok, err = pcall(C_AuctionHouse.PlaceBid, row.auctionID, row.price)
  else
    ok, err = pcall(C_AuctionHouse.StartCommoditiesPurchase, row.itemID, row.qty)
  end
  if not ok then
    Fail(row, "appel refusé (" .. tostring(err) .. ") – l'achat doit venir d'un clic ou d'une touche")
    return false, row.error
  end
  Changed()
  AH.Schedule(AH.BUY_TIMEOUT, function()
    if row.status == "pending" and row.token == token then Fail(row, "pas de réponse du serveur") end
  end)
  return true, string.format("achat de %s ×%d pour %s…", row.name or "?", row.qty, AH.MoneyString(row.price))
end

-- Première affaire encore achetable, par gain décroissant
function AH.NextRow()
  for _, row in ipairs(AH.state.rows) do
    if row.status == "ready" then return row end
  end
  return nil
end

function AH.BuyNext()
  if AH.state.pendingRow then return false, "un achat est déjà en cours" end
  local row = AH.NextRow()
  if not row then
    if #AH.state.rows == 0 then return false, "aucune affaire : lance un scan d'abord" end
    return false, "plus rien à acheter : " .. AH.ReportLine()
  end
  return AH.Buy(row)
end

-- Événements d'achat
function AH.OnPurchaseCompleted(auctionID)
  local row = AH.state.pendingRow
  if row and row.kind == "item" and row.auctionID == auctionID then Bought(row) end
end

function AH.OnAuctionError(code)
  local row = AH.state.pendingRow
  if row and row.status == "pending" then Fail(row, AH.ErrorText(code)) end
end

-- COMMODITY_PRICE_UPDATED(unitPrice, totalPrice) : le serveur donne le prix réel avant confirmation
function AH.OnCommodityPrice(unitPrice, totalPrice)
  local row = AH.state.pendingRow
  if not row or row.kind ~= "commodity" or row.status ~= "pending" then return end
  totalPrice = tonumber(totalPrice) or 0
  if totalPrice <= row.maxTotal then
    row.paid = totalPrice
    pcall(C_AuctionHouse.ConfirmCommoditiesPurchase, row.itemID, row.qty)
  else
    pcall(C_AuctionHouse.CancelCommoditiesPurchase)
    Fail(row, "le prix a monté (" .. AH.MoneyString(totalPrice) .. " demandés)")
  end
end

function AH.OnCommodityUnavailable()
  local row = AH.state.pendingRow
  if row and row.kind == "commodity" then Fail(row, "plus disponible à ce prix") end
end

function AH.OnCommoditySucceeded()
  local row = AH.state.pendingRow
  if row and row.kind == "commodity" then Bought(row) end
end

function AH.OnCommodityFailed()
  local row = AH.state.pendingRow
  if row and row.kind == "commodity" then Fail(row, "achat refusé par le serveur") end
end

-------------------------------------------------------------------------------
-- Rapport
-------------------------------------------------------------------------------
function AH.ReportLine()
  local r = AH.state.report
  local left = 0
  for _, row in ipairs(AH.state.rows) do if row.status == "ready" then left = left + 1 end end
  return string.format("%d achat(s) pour %s, revente vendeur %s (gain %s), %d échec(s), %d en attente",
    r.bought, AH.MoneyString(r.spent), AH.MoneyString(r.spent + r.gain), AH.MoneyString(r.gain), r.failed, left)
end

function AH.ReportLines()
  local st, lines = AH.state, {}
  local s = st.stats or {}
  if s.scanned then
    table.insert(lines, string.format("Scan : %d enchères, %d objets distincts, %d candidats, %d affaire(s) trouvée(s)%s.",
      s.scanned or 0, s.keys or 0, s.candidates or 0, #st.rows,
      (s.unresolved or 0) > 0 and (", " .. s.unresolved .. " sans réponse") or ""))
  else
    table.insert(lines, "Aucun scan effectué.")
  end
  table.insert(lines, AH.ReportLine())
  for _, row in ipairs(st.rows) do
    if row.status == "bought" then
      table.insert(lines, string.format("  ✔ %s ×%d : payé %s, revente %s", row.name or "?", row.qty,
        AH.MoneyString(row.paid or row.price), AH.MoneyString(row.sellPrice * row.qty)))
    end
  end
  for _, f in ipairs(st.report.failures) do table.insert(lines, "  ✘ " .. f) end
  return lines
end

function AH.Report()
  for _, l in ipairs(AH.ReportLines()) do Print("%s", l) end
end

-- Texte d'état court pour la fenêtre
function AH.StatusText()
  local st, s = AH.state, AH.state.stats or {}
  if st.phase == "replicate" then return "Scan complet demandé, attente du serveur…" end
  if st.phase == "process" then return string.format("Dépouillement : %d / %d enchères", s.scanned or 0, st.total or 0) end
  if st.phase == "prices" then return string.format("Prix vendeur : %d objet(s) à charger", st.pendingCount or 0) end
  if st.phase == "search" then return string.format("Vérification des affaires : %d / %d", s.searched or 0, s.candidates or 0) end
  if st.phase == "done" then return AH.ReportLine() end
  local left = AH.ScanRemaining()
  if not st.open then return "Ouvre l'hôtel des ventes pour scanner." end
  if left > 0 then return "Prochain scan complet possible dans " .. AH.ClockString(left) .. "." end
  return "Prêt : lance un scan complet (une fois toutes les 15 minutes)."
end

-------------------------------------------------------------------------------
-- Événements
-------------------------------------------------------------------------------
function AH.OnEvent(event, a1, a2, a3)
  if event == "AUCTION_HOUSE_SHOW" then
    AH.state.open = true
    -- Blizzard_AuctionHouseUI est chargé à la demande juste avant cet événement : on se greffe si ce n'est pas déjà fait
    if ns.AuctionSetupTab then pcall(ns.AuctionSetupTab) end
    Changed()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    AH.state.open = false
    local row = AH.state.pendingRow
    if row and row.status == "pending" then Fail(row, "hôtel des ventes fermé pendant l'achat") end
    if AH.IsScanning() then
      AH.state.phase = "done"
      AH.SortRows()
    end
    Changed()
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    AH.BeginProcessing()
  elseif event == "ITEM_DATA_LOAD_RESULT" then
    AH.OnItemLoaded(a1, a2)
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    AH.OnItemResults(a1)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    AH.OnCommodityResults(a1)
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
    AH.OnPurchaseCompleted(a1)
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" then
    AH.OnAuctionError(a1)
  elseif event == "COMMODITY_PRICE_UPDATED" then
    AH.OnCommodityPrice(a1, a2)
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    AH.OnCommodityUnavailable()
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    AH.OnCommoditySucceeded()
  elseif event == "COMMODITY_PURCHASE_FAILED" then
    AH.OnCommodityFailed()
  elseif event == "ADDON_LOADED" and a1 == "Blizzard_AuctionHouseUI" then
    if ns.AuctionSetupTab then pcall(ns.AuctionSetupTab) end
  end
end

AH.EVENTS = {
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE", "ITEM_DATA_LOAD_RESULT",
  "ITEM_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_UPDATED", "AUCTION_HOUSE_PURCHASE_COMPLETED",
  "AUCTION_HOUSE_SHOW_ERROR", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED", "ADDON_LOADED",
}

do
  local frame = CreateFrame("Frame")
  for _, ev in ipairs(AH.EVENTS) do pcall(frame.RegisterEvent, frame, ev) end
  frame:SetScript("OnEvent", function(_, event, ...) AH.OnEvent(event, ...) end)
  AH.frame = frame
end

-- Raccourci clavier / manette « Acheter la prochaine affaire »
function OneButtonRotation_AuctionBuyNext()
  local ok, msg = AH.BuyNext()
  if msg then Print("%s", msg) end
  return ok
end

-------------------------------------------------------------------------------
-- Commande /obr ah
-------------------------------------------------------------------------------
function AH.HandleCommand(rest)
  local sub, arg = (rest or ""):match("^(%S*)%s*(.*)$")
  sub = (sub or ""):lower()
  if sub == "scan" then
    local ok, msg = AH.StartScan()
    Print("%s", msg)
  elseif sub == "next" or sub == "suivant" or sub == "buy" then
    local _, msg = AH.BuyNext()
    Print("%s", msg)
  elseif sub == "report" or sub == "rapport" then
    AH.Report()
  elseif sub == "profit" or sub == "gain" then
    local n = tonumber(arg)
    if not n then Print("Usage : /obr ah profit <pièces de cuivre> (gain minimal par affaire, actuel %s)", AH.MoneyString(MinProfit())) return end
    ns.db.ahMinProfit = math.max(0, math.floor(n))
    Print("Gain minimal par affaire : %s", AH.MoneyString(ns.db.ahMinProfit))
  elseif sub == "reset" then
    ns.db.ahLastScan = nil
    Print("Verrou de scan effacé (le serveur garde le sien : si le scan ne répond pas, c'est lui).")
  else
    Print("%s", AH.StatusText())
    Print("Usage : /obr ah scan | next | rapport | profit <cuivre> | reset. Onglet « Bonnes affaires » dans l'hôtel des ventes.")
  end
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Auction"
