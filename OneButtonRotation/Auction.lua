-- OneButtonRotation - Bonnes affaires de l'hôtel des ventes (logique, sans interface)
-- Scan complet (C_AuctionHouse.ReplicateItems, une fois toutes les 15 min), repérage des
-- enchères dont le rachat est inférieur au prix de revente chez un vendeur, puis achat à la
-- demande. Les fonctions d'achat du client (PlaceBid, StartCommoditiesPurchase) exigent un
-- clic ou une touche, et le serveur n'accepte qu'UN achat par clic (vérifié en jeu : plusieurs
-- PlaceBid dans le même clic, seul le premier passe). AH.Buy / AH.BuyNext doivent donc être
-- appelées depuis un OnClick ou un raccourci, une fois par geste, jamais depuis un timer.
--
-- Machine à états cadencée par AH.Tick(now) (dix fois par seconde en jeu, à la main dans
-- les tests). Phases : idle → sending (attente de la ligne, ReplicateItems est un message
-- « throttled ») → waiting (réponse du serveur) → arriving (la liste arrive par morceaux :
-- on attend qu'elle cesse de grossir) → reading (dépouillement par paquets, indices 0-based)
-- → loading (objets pas encore en cache) → done : la liste s'affiche aussitôt, une ligne
-- « à vérifier » par objet retenu. La vérification (une recherche par objet, pour obtenir les
-- identifiants d'enchère, environ une seconde chacune) se fait ensuite en arrière-plan pour
-- les meilleures lignes (ahPreverify, 10 par défaut), et à la demande au clic pour les autres.
-- Les particularités du client (indices 0-based, liste en morceaux, requêtes jetées quand la
-- ligne est occupée, comptes fantaisistes à plafonner par la taille de pile) viennent de
-- l'observation en jeu de l'addon VendorFloor, qui fait le même travail sur Forever.

local ADDON_NAME, ns = ...

local AH = {}
ns.Auction = AH

AH.SCAN_COOLDOWN  = 15 * 60 -- secondes entre deux scans complets (limite serveur)
AH.CHUNK          = 400     -- enchères dépouillées par tick
AH.MAX_CANDIDATES = 100     -- lignes affichées après le scan par défaut (/obr ah max <n>)
AH.PREVERIFY      = 10      -- lignes vérifiées d'avance en arrière-plan (/obr ah pre <n>)
AH.SEND_FORCE     = 10      -- secondes d'attente de la ligne avant d'envoyer quand même
AH.FULL_WAIT      = 90      -- secondes max d'attente de la réponse du scan complet
AH.FULL_REUSE     = 15      -- sans réponse après ce délai, on lit une liste déjà là (scan d'un autre addon)
AH.STABLE         = 2       -- secondes sans croissance avant de lire la liste
AH.LOAD_MAX       = 180     -- secondes max de chargement des objets inconnus du cache
AH.LOAD_STALL     = 20      -- secondes sans progrès avant d'abandonner le chargement
AH.SEARCH_TIMEOUT = 15      -- secondes avant d'abandonner une recherche sans réponse
AH.MAX_RESENDS    = 3       -- renvois d'une requête jetée par le client
AH.BUY_TIMEOUT    = 8       -- secondes avant de considérer un achat sans réponse comme échoué
AH.CONFIRM_GRACE  = 1.5     -- secondes laissées à la confirmation automatique d'un devis

local function Print(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  local out = DEFAULT_CHAT_FRAME or { AddMessage = function(_, s) print(s) end }
  out:AddMessage("|cff00ff88OBR|r |cffffd100HV|r " .. msg)
end
AH.Print = Print

function AH.Now() return (type(time) == "function" and time()) or os.time() end
function AH.Clock() return (type(GetTime) == "function" and GetTime()) or os.clock() end

local function API() return C_AuctionHouse end

local function GetInfo(item)
  if C_Item and C_Item.GetItemInfo then
    local ok, a, b, c, d, e, f, g, h, i, j, k = pcall(C_Item.GetItemInfo, item)
    if ok then return a, b, c, d, e, f, g, h, i, j, k end
  elseif type(GetItemInfo) == "function" then
    local ok, a, b, c, d, e, f, g, h, i, j, k = pcall(GetItemInfo, item)
    if ok then return a, b, c, d, e, f, g, h, i, j, k end
  end
  return nil
end

-------------------------------------------------------------------------------
-- État
-------------------------------------------------------------------------------
AH.state = {
  open = false,        -- hôtel des ventes ouvert
  phase = "idle",      -- idle | sending | waiting | arriving | reading | loading | searching | done
  rows = {},           -- affaires achetables, triées par gain décroissant
  stats = {},          -- compteurs du dernier scan
  report = { bought = 0, spent = 0, gain = 0, failed = 0, failures = {} },
  pending = {},        -- achats en attente de réponse : [ligne] = instant d'envoi
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
  local suffix = link:match("item:%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d+)")
  return tonumber(suffix) or 0
end

-- Prix de revente chez un vendeur (par unité) + nom, lien, icône ; nil si l'objet n'est pas en cache
function AH.SellPrice(item)
  local name, link, _, _, _, _, _, _, _, icon, sellPrice = GetInfo(item)
  if not name then return nil end
  return tonumber(sellPrice) or 0, name, link, icon
end

function AH.ItemName(itemID)
  local _, name = AH.SellPrice(itemID)
  return name
end

-- Nombre d'unités d'une enchère, plafonné à la taille de pile (certains comptes de la liste
-- complète sont faux : un sac « ×830 » pour un seul rachat)
function AH.Units(item, quantity)
  quantity = math.max(math.floor(tonumber(quantity) or 1), 1)
  local stack = select(8, GetInfo(item))
  if stack and stack > 0 and quantity > stack then quantity = stack end
  return quantity
end

-- Clé d'objet telle que l'hôtel des ventes la voit : l'équipement par niveau d'objet et
-- suffixe, le reste par identifiant seul. Retourne key, keyString
function AH.KeyFor(itemID, link)
  local api = API()
  local function make(id, lvl, suffix)
    if api and api.MakeItemKey then
      local ok, key = pcall(api.MakeItemKey, id, lvl or 0, suffix or 0, 0)
      if ok and key then return key end
    end
    return { itemID = id, itemLevel = lvl or 0, itemSuffix = suffix or 0, battlePetSpeciesID = 0 }
  end
  local equipLoc = select(9, GetInfo(link or itemID))
  if not (link and equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP_IGNORE") then
    return make(itemID), itemID .. ":0:0"
  end
  local level = 0
  if C_Item and C_Item.GetDetailedItemLevelInfo then
    local ok, lvl = pcall(C_Item.GetDetailedItemLevelInfo, link)
    if ok then level = tonumber(lvl) or 0 end
  elseif type(GetDetailedItemLevelInfo) == "function" then
    local ok, lvl = pcall(GetDetailedItemLevelInfo, link)
    if ok then level = tonumber(lvl) or 0 end
  end
  local suffix = AH.SuffixFromLink(link)
  return make(itemID, level, suffix), itemID .. ":" .. level .. ":" .. suffix
end

-- Libellé français d'une erreur Enum.AuctionHouseError
local ERRORS = {
  NotEnoughMoney = "pas assez d'argent", HigherBid = "quelqu'un a surenchéri", BidIncrement = "enchère trop basse",
  BidOwn = "c'est ta propre enchère", ItemNotFound = "enchère déjà partie", RestrictedAccountTrial = "compte restreint",
  HasRestriction = "compte restreint", IsBusy = "hôtel des ventes occupé, réessaie", Unavailable = "hôtel des ventes indisponible",
  ItemHasQuote = "un devis est déjà en cours", DatabaseError = "erreur interne de l'hôtel des ventes", DoubleBid = "achat déjà en cours",
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

local function MinProfit() return (ns.db and tonumber(ns.db.ahMinProfit)) or 0 end
local function MaxCandidates() return (ns.db and tonumber(ns.db.ahMaxCandidates)) or AH.MAX_CANDIDATES end
local function PreVerify() return (ns.db and tonumber(ns.db.ahPreverify)) or AH.PREVERIFY end

local function LineReady()
  local api = API()
  if api and api.IsThrottledMessageSystemReady then
    local ok, ready = pcall(api.IsThrottledMessageSystemReady)
    return ok and ready and true or false
  end
  return true
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
  return p ~= "idle" and p ~= "done"
end

-- Retourne true, ou false + raison
function AH.CanScan()
  if not AH.state.open then return false, "ouvre d'abord l'hôtel des ventes" end
  if AH.IsScanning() then return false, "scan en cours" end
  if next(AH.state.pending) then return false, "termine d'abord l'achat en cours" end
  local left = AH.ScanRemaining()
  if left > 0 then return false, "prochain scan complet dans " .. AH.ClockString(left) end
  if not (API() and API().ReplicateItems) then return false, "API ReplicateItems absente" end
  return true
end

-------------------------------------------------------------------------------
-- Cadence
-------------------------------------------------------------------------------
function AH.StartTicker()
  if AH.ticker or not (C_Timer and C_Timer.NewTicker) then return end
  AH.ticker = C_Timer.NewTicker(0.1, function() AH.Tick(AH.Clock()) end)
end

function AH.StopTicker()
  if AH.ticker and AH.ticker.Cancel then AH.ticker:Cancel() end
  AH.ticker = nil
end

-------------------------------------------------------------------------------
-- Scan
-------------------------------------------------------------------------------
local function BeginFull(phase, now)
  local st = AH.state
  st.phase = phase
  st.t0 = now
  st.sends = 0
  st.rows = {}
  st.items = {}       -- par clé : { key, keyString, itemID, link, name, vendor, minUnit, n }
  st.pendingIdx = {}  -- indices dont l'objet n'était pas en cache
  st.requested = {}
  st.count = 0
  st.index = 0
  st.playerName = (type(UnitName) == "function" and UnitName("player")) or nil
  st.stats = { started = AH.Now(), scanned = 0, keys = 0, candidates = 0, searched = 0, unresolved = 0, unloaded = 0 }
  st.verify = { queue = {}, current = nil }
  ResetReport()
end

function AH.StartScan()
  local ok, why = AH.CanScan()
  if not ok then return false, why end
  local now = AH.Clock()
  BeginFull("sending", now)
  AH.StartTicker()
  if LineReady() then AH.SendFull(now) end
  Changed()
  return true, "scan complet demandé, réponse du serveur en cours…"
end

-- Envoie la demande de liste complète (comptée : une demande jetée est renvoyée)
function AH.SendFull(now)
  local st = AH.state
  st.phase, st.t0, st.sends = "waiting", now, (st.sends or 0) + 1
  ns.db.ahLastScan = AH.Now()
  local ok, err = pcall(API().ReplicateItems)
  if not ok then AH.Finish("ReplicateItems a échoué : " .. tostring(err)) end
end

-- REPLICATE_ITEM_LIST_UPDATE
function AH.OnReplicate(now)
  local st = AH.state
  now = now or AH.Clock()
  if st.phase == "waiting" or st.phase == "sending" then
    st.phase, st.count, st.stableAt = "arriving", API().GetNumReplicateItems() or 0, now
  elseif not AH.IsScanning() and st.open and not next(st.pending) then
    -- scan complet lancé par un autre addon : sa liste est là, on la lit (et son verrou de 15 min est le nôtre)
    BeginFull("arriving", now)
    ns.db.ahLastScan = AH.Now()
    st.count, st.stableAt = API().GetNumReplicateItems() or 0, now
    AH.StartTicker()
  end
  Changed()
end

-- AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED : la requête a été jetée par le client
function AH.OnDropped(now)
  local st = AH.state
  now = now or AH.Clock()
  if st.phase == "waiting" and (st.sends or 0) < AH.MAX_RESENDS and now - st.t0 < AH.SEND_FORCE then
    st.phase, st.t0 = "sending", now
  elseif st.verify and st.verify.current and st.verify.sentAt then
    st.verify.sentAt = nil -- renvoyer la recherche courante
    st.verify.waitFrom = now
    st.verify.resends = (st.verify.resends or 0) + 1
  end
end

-- Une enchère de la liste, agrégée par objet. Retourne false si l'objet n'est pas en cache.
local function Record(index)
  local st = AH.state
  local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID, hasAll = API().GetReplicateItemInfo(index)
  if not itemID then return true end
  if hasAll == false then return false end
  buyout = tonumber(buyout) or 0
  if buyout <= 0 then return true end
  local link = API().GetReplicateItemLink and API().GetReplicateItemLink(index) or nil
  local vendor, name, itemLink = AH.SellPrice(link or itemID)
  if vendor == nil then return false end
  st.stats.scanned = st.stats.scanned + 1
  if vendor <= 0 or (owner and owner == st.playerName) then return true end
  local units = AH.Units(link or itemID, count)
  local unit = buyout / units
  if unit < 1 then return true end
  local gain = (vendor - unit) * units -- gain de cette enchère si on la revend au vendeur
  local key, ks = AH.KeyFor(itemID, link)
  local it = st.items[ks]
  if not it then
    it = { key = key, keyString = ks, itemID = itemID, link = link or itemLink, name = name, vendor = vendor, minUnit = unit,
           bestGain = gain, bestUnits = units, bestPrice = buyout, n = 0 }
    st.items[ks] = it
    st.stats.keys = st.stats.keys + 1
  else
    if unit < it.minUnit then it.minUnit = unit; it.link = link or it.link end
    if gain > it.bestGain then it.bestGain, it.bestUnits, it.bestPrice = gain, units, buyout end
  end
  it.n = it.n + 1
  return true
end

local function RequestLoad(index)
  local st = AH.state
  local itemID = select(17, API().GetReplicateItemInfo(index))
  if itemID and not st.requested[itemID] then
    st.requested[itemID] = true
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
  end
end

-- Choisit les objets dont le rachat unitaire minimal est sous le prix vendeur, puis lance les recherches
-- Fin du dépouillement : une ligne « à vérifier » par objet retenu (gain estimé d'après la liste
-- complète), classées par gain. La vérification se fait ensuite en arrière-plan (Tick).
local function BuildRows(now)
  local st = AH.state
  local candidates = {}
  local floor = math.max(1, MinProfit())
  for _, it in pairs(st.items) do
    if it.vendor > 0 and it.vendor - it.minUnit >= 1 and (it.bestGain or 0) >= floor then
      it.potential = it.bestGain
      table.insert(candidates, it)
    end
  end
  table.sort(candidates, function(x, y)
    if x.potential ~= y.potential then return x.potential > y.potential end
    return x.keyString < y.keyString
  end)
  st.stats.eligible = #candidates
  while #candidates > MaxCandidates() do table.remove(candidates) end
  st.stats.candidates = #candidates
  for _, it in ipairs(candidates) do
    table.insert(st.rows, {
      kind = "candidate", cand = it, itemID = it.itemID, link = it.link, name = it.name,
      qty = it.bestUnits or 1, price = it.bestPrice or 0, sellPrice = it.vendor, profit = it.bestGain, status = "unverified",
    })
  end
  st.items, st.pendingIdx = nil, nil
  st.verify = { queue = {}, current = nil }
  AH.Finish()
end

-- Gain minimal (cuivre) : réglage et application immédiate à la liste affichée
function AH.MinProfit() return MinProfit() end
function AH.SetMinProfit(copper)
  copper = math.max(0, math.floor(tonumber(copper) or 0))
  ns.db.ahMinProfit = copper
  AH.ApplyMinProfit()
  return copper
end

-- Retire les lignes (non réglées) dont le gain est sous le gain minimal ; les vérifications
-- futures l'appliquent déjà via MinProfit()
function AH.ApplyMinProfit()
  local st = AH.state
  local floor = math.max(1, MinProfit())
  local kept, removed = {}, 0
  local current = st.verify and st.verify.current
  for _, row in ipairs(st.rows) do
    local open = row.status == "unverified" or row.status == "queued" or row.status == "ready"
    if open and row ~= current and (row.profit or 0) < floor then
      removed = removed + 1
    else
      table.insert(kept, row)
    end
  end
  st.rows = kept
  if st.verify then
    local q = {}
    for _, row in ipairs(st.verify.queue) do if (row.profit or 0) >= floor then table.insert(q, row) end end
    st.verify.queue = q
  end
  st.stats.filtered = (st.stats.filtered or 0) + removed
  AH.SortRows()
  Changed()
  return removed
end

-- Nombre de lignes par état
function AH.Count(status)
  local n = 0
  for _, row in ipairs(AH.state.rows) do if row.status == status then n = n + 1 end end
  return n
end

-- Demande la vérification d'une ligne (clic : en tête de file)
function AH.Verify(row, front)
  local st = AH.state
  if not row or row.status ~= "unverified" or not st.verify then return false end
  row.status = "queued"
  row.note = nil
  if front then table.insert(st.verify.queue, 1, row) else table.insert(st.verify.queue, row) end
  Changed()
  return true
end

-- Prochaine ligne à vérifier : la file (clics) d'abord, puis les meilleures tant qu'il y a
-- moins de ahPreverify lignes prêtes
local function PickVerification()
  local st = AH.state
  local row = table.remove(st.verify.queue, 1)
  if row then return row end
  if AH.Count("ready") + AH.Count("quote") >= PreVerify() then return nil end
  for _, r in ipairs(st.rows) do
    if r.status == "unverified" and not r.note then return r end
  end
  return nil
end

local function StartVerification(row, now)
  local v = AH.state.verify
  v.current, v.sentAt, v.waitFrom, v.resends = row, nil, now, 0
  row.status = "verifying"
  AH.state.stats.searched = (AH.state.stats.searched or 0) + 1
  Changed()
end

-- Fin (ou abandon) de la vérification courante
local function EndVerification(now, failedNote)
  local st, v = AH.state, AH.state.verify
  local row = v.current
  v.current, v.sentAt = nil, nil
  if row and failedNote then
    row.status = "unverified"
    row.note = failedNote
    st.stats.unresolved = (st.stats.unresolved or 0) + 1
  end
  AH.SortRows()
  Changed()
end

local function SendSearch(now)
  local v = AH.state.verify
  local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
  local ok = pcall(API().SendSearchQuery, v.current.cand.key, { { sortOrder = order, reverseSort = false } }, true)
  v.sentAt = now
  if not ok then EndVerification(now, "recherche refusée") end
end

-- Un pas de la vérification en arrière-plan
local function VerifyTick(now)
  local st = AH.state
  local v = st.verify
  if not v or not st.open or AH.IsScanning() then return end
  if not v.current then
    local row = PickVerification()
    if not row then return end
    StartVerification(row, now)
  end
  if not v.sentAt then
    if (v.resends or 0) > AH.MAX_RESENDS then
      EndVerification(now, "requête jetée par le client")
    elseif LineReady() or now - (v.waitFrom or now) > AH.SEND_FORCE then
      SendSearch(now)
    end
  elseif now - v.sentAt > AH.SEARCH_TIMEOUT then
    EndVerification(now, "sans réponse, reclique pour réessayer")
  end
end

-- Tri : gain décroissant ; les lignes réglées (achetées, échouées) en bas
local ORDER = { quote = 0, ready = 1, verifying = 1, queued = 1, unverified = 1, pending = 1, quoting = 1, confirming = 1, bought = 2, failed = 3 }
function AH.SortRows()
  table.sort(AH.state.rows, function(a, b)
    local oa, ob = ORDER[a.status] or 1, ORDER[b.status] or 1
    if oa ~= ob then return oa < ob end
    if a.profit ~= b.profit then return a.profit > b.profit end
    return (a.name or "") < (b.name or "")
  end)
end

function AH.Finish(reason)
  local st = AH.state
  st.phase = "done"
  st.stats.finished = AH.Now()
  st.stats.reason = reason
  st.items, st.pendingIdx = nil, nil
  AH.SortRows()
  if reason then Print("Scan interrompu : %s", reason) end
  Changed()
end

-- Horloge du scan et des achats : à appeler dix fois par seconde
function AH.Tick(now)
  local st = AH.state
  now = now or AH.Clock()
  -- achats sans réponse
  for row, at in pairs(st.pending) do
    if row.status == "confirming" and not row.confirmClicked and now - at > AH.CONFIRM_GRACE then
      -- la confirmation automatique du devis n'a pas été acceptée : il faut un clic
      row.status = "quote"
      st.pending[row] = nil
      Changed()
    elseif now - at > AH.BUY_TIMEOUT then
      AH.FailRow(row, "pas de confirmation du serveur (enchère déjà partie ?)")
    end
  end
  local phase = st.phase
  if phase == "sending" then
    if LineReady() or now - st.t0 > AH.SEND_FORCE then AH.SendFull(now) end
  elseif phase == "waiting" then
    local n = API().GetNumReplicateItems and API().GetNumReplicateItems() or 0
    if now - st.t0 > AH.FULL_REUSE and n > 0 then
      st.phase, st.count, st.stableAt = "arriving", n, now
    elseif now - st.t0 > AH.FULL_WAIT then
      AH.Finish("pas de réponse de l'hôtel des ventes (un autre addon a peut-être déjà fait son scan complet)")
    end
  elseif phase == "arriving" then
    local n = API().GetNumReplicateItems() or 0
    if n ~= st.count then
      st.count, st.stableAt = n, now
    elseif now - st.stableAt > AH.STABLE then
      st.phase, st.index = "reading", 0
    end
  elseif phase == "reading" then
    local last = math.min(st.index + AH.CHUNK, st.count) - 1
    for i = st.index, last do
      if not Record(i) then
        table.insert(st.pendingIdx, i)
        RequestLoad(i)
      end
    end
    st.index = last + 1
    if st.index >= st.count then
      st.phase, st.loadT, st.progressT = "loading", now, now
    end
    Changed()
  elseif phase == "loading" then
    local still = {}
    for n, i in ipairs(st.pendingIdx) do
      if n > AH.CHUNK * 5 or not Record(i) then table.insert(still, i) end
    end
    if #still < #st.pendingIdx then st.progressT = now end
    st.pendingIdx = still
    if still[1] and now - st.loadT < AH.LOAD_MAX and now - st.progressT < AH.LOAD_STALL then
      Changed()
    else
      st.stats.unloaded = #still
      BuildRows(now)
    end
  elseif phase == "done" then
    VerifyTick(now)
  end
end

-- La ligne « à vérifier » de l'objet courant est remplacée par ses enchères réelles
local function ReplaceCandidate(row, newRows)
  local st = AH.state
  for i, r in ipairs(st.rows) do
    if r == row then table.remove(st.rows, i) break end
  end
  for _, r in ipairs(newRows) do table.insert(st.rows, r) end
  st.stats.verified = (st.stats.verified or 0) + 1
  if #newRows == 0 then st.stats.vanished = (st.stats.vanished or 0) + 1 end
end

-- ITEM_SEARCH_RESULTS_UPDATED(itemKey) : une ligne par enchère rentable
function AH.OnItemResults(itemKey, now)
  local st, v = AH.state, AH.state.verify
  local row = v and v.current
  local cand = row and row.cand
  if not cand or not v.sentAt then return end
  local itemID = type(itemKey) == "table" and itemKey.itemID or itemKey
  if itemID ~= cand.itemID then return end
  local api = API()
  local n = api.GetNumItemSearchResults(cand.key) or 0
  local found = {}
  for i = 1, n do
    local r = api.GetItemSearchResultInfo(cand.key, i)
    if r and r.auctionID and (tonumber(r.buyoutAmount) or 0) > 0 and not r.containsOwnerItem then
      local qty = AH.Units(r.itemLink or cand.link or cand.itemID, r.quantity)
      local price = tonumber(r.buyoutAmount)
      local profit = cand.vendor * qty - price
      if profit >= math.max(1, MinProfit()) then
        table.insert(found, {
          kind = "item", itemID = cand.itemID, link = r.itemLink or cand.link, name = cand.name or AH.ItemName(cand.itemID),
          auctionID = r.auctionID, qty = qty, price = price, sellPrice = cand.vendor, profit = profit, status = "ready",
        })
      end
    end
  end
  ReplaceCandidate(row, found)
  EndVerification(now)
end

-- COMMODITY_SEARCH_RESULTS_UPDATED(itemID) : une seule ligne regroupant tout ce qui est sous le prix vendeur
function AH.OnCommodityResults(itemID, now)
  local st, v = AH.state, AH.state.verify
  local row = v and v.current
  local cand = row and row.cand
  if not cand or not v.sentAt or itemID ~= cand.itemID then return end
  local api = API()
  local n = api.GetNumCommoditySearchResults(itemID) or 0
  local qty, cost = 0, 0
  for i = 1, n do
    local r = api.GetCommoditySearchResultInfo(itemID, i)
    if r and not r.containsOwnerItem then
      local unit = tonumber(r.unitPrice) or 0
      local q = tonumber(r.quantity) or 0
      if unit > 0 and unit < cand.vendor then
        qty = qty + q
        cost = cost + unit * q
      end
    end
  end
  local profit = cand.vendor * qty - cost
  local found = {}
  if qty > 0 and profit >= math.max(1, MinProfit()) then
    table.insert(found, {
      kind = "commodity", itemID = itemID, link = cand.link, name = cand.name or AH.ItemName(itemID),
      qty = qty, price = cost, maxTotal = cand.vendor * qty - math.max(1, MinProfit()),
      sellPrice = cand.vendor, profit = profit, status = "ready",
    })
  end
  ReplaceCandidate(row, found)
  EndVerification(now)
end

-------------------------------------------------------------------------------
-- Achat (à appeler depuis un clic ou un raccourci)
-------------------------------------------------------------------------------
function AH.FailRow(row, why)
  local st = AH.state
  row.status = "failed"
  row.error = why
  st.pending[row] = nil
  st.report.failed = st.report.failed + 1
  table.insert(st.report.failures, string.format("%s ×%d : %s", row.name or ("objet " .. row.itemID), row.qty, why))
  Changed()
end

local function Bought(row)
  local st = AH.state
  row.status = "bought"
  st.pending[row] = nil
  st.report.bought = st.report.bought + 1
  st.report.spent = st.report.spent + (row.paid or row.price)
  st.report.gain = st.report.gain + (row.sellPrice * row.qty - (row.paid or row.price))
  Changed()
end

local function CommodityInFlight()
  for row in pairs(AH.state.pending) do
    if row.kind == "commodity" then return true end
  end
  for _, row in ipairs(AH.state.rows) do
    if row.status == "quote" then return true end
  end
  return false
end

-- Achète une ligne (un seul achat en vol à la fois)
function AH.Buy(row)
  local st = AH.state
  if not row then return false, "aucune ligne" end
  if not st.open then return false, "l'hôtel des ventes est fermé" end
  local now = AH.Clock()
  if row.status == "quote" then
    -- devis reçu, confirmation automatique refusée : la confirmation vient de ce clic
    row.status = "confirming"
    row.confirmClicked = true
    st.pending[row] = now
    local ok, err = pcall(API().ConfirmCommoditiesPurchase, row.itemID, row.qty)
    if not ok then AH.FailRow(row, "confirmation refusée (" .. tostring(err) .. ")") return false, row.error end
    Changed()
    return true, string.format("confirmation de %s ×%d pour %s…", row.name or "?", row.qty, AH.MoneyString(row.paid or row.price))
  end
  if row.status == "unverified" then
    AH.Verify(row, true)
    return false, string.format("vérification de %s en cours : reclique dans une seconde pour acheter", row.name or "?")
  end
  if row.status == "queued" or row.status == "verifying" then return false, "vérification en cours, reclique dans une seconde" end
  if row.status ~= "ready" then return false, "ligne déjà traitée (" .. tostring(row.status) .. ")" end
  if next(st.pending) then return false, "un achat est déjà en cours, attends la réponse" end
  if row.kind == "commodity" and CommodityInFlight() then return false, "un devis d'objet empilable est déjà en cours" end
  local money = type(GetMoney) == "function" and GetMoney() or math.huge
  if money < row.price then
    AH.FailRow(row, "pas assez d'argent (" .. AH.MoneyString(row.price) .. ")")
    return false, "pas assez d'argent"
  end
  local ok, err
  if row.kind == "item" then
    row.status = "pending"
    ok, err = pcall(API().PlaceBid, row.auctionID, row.price)
  else
    row.status = "quoting"
    ok, err = pcall(API().StartCommoditiesPurchase, row.itemID, row.qty)
  end
  st.pending[row] = now
  if not ok then
    AH.FailRow(row, "appel refusé (" .. tostring(err) .. ") – l'achat doit venir d'un clic ou d'une touche")
    return false, row.error
  end
  Changed()
  return true, string.format("achat de %s ×%d pour %s…", row.name or "?", row.qty, AH.MoneyString(row.price))
end

-- Première affaire encore achetable : un devis à confirmer d'abord, sinon le meilleur gain
function AH.NextRow()
  for _, row in ipairs(AH.state.rows) do
    if row.status == "quote" then return row end
  end
  for _, row in ipairs(AH.state.rows) do
    if row.status == "ready" then return row end
  end
  return nil
end

function AH.BuyNext()
  local row = AH.NextRow()
  if not row then
    if #AH.state.rows == 0 then return false, "aucune affaire : lance un scan d'abord" end
    if next(AH.state.pending) then return false, "achat en cours, attends la réponse" end
    local v = AH.state.verify
    if v and v.current then return false, "vérification de " .. (v.current.name or "?") .. " en cours, réappuie dans une seconde" end
    for _, r in ipairs(AH.state.rows) do
      if r.status == "unverified" then
        AH.Verify(r, true)
        return false, string.format("vérification de %s lancée, réappuie dans une seconde", r.name or "?")
      end
    end
    return false, "plus rien à acheter : " .. AH.ReportLine()
  end
  if row.status == "ready" and next(AH.state.pending) then return false, "un achat est déjà en cours, attends la réponse" end
  return AH.Buy(row)
end

-- Événements d'achat
function AH.OnPurchaseCompleted(auctionID)
  for row in pairs(AH.state.pending) do
    if row.kind == "item" and row.auctionID == auctionID then Bought(row) return end
  end
end

function AH.OnAuctionError(code)
  local row = next(AH.state.pending)
  if row then AH.FailRow(row, AH.ErrorText(code)) end
end

-- COMMODITY_PRICE_UPDATED(unitPrice, totalPrice) : le serveur donne le prix réel avant confirmation
function AH.OnCommodityPrice(unitPrice, totalPrice, now)
  local row
  for r in pairs(AH.state.pending) do if r.kind == "commodity" and r.status == "quoting" then row = r end end
  if not row then return end
  totalPrice = tonumber(totalPrice) or 0
  if totalPrice <= row.maxTotal then
    row.paid = totalPrice
    row.status = "confirming"
    AH.state.pending[row] = now or AH.Clock()
    -- tentative sans clic ; si le client l'ignore, Tick repasse la ligne en « quote » (clic requis)
    pcall(API().ConfirmCommoditiesPurchase, row.itemID, row.qty)
    Changed()
  else
    pcall(API().CancelCommoditiesPurchase)
    AH.FailRow(row, "le prix a monté (" .. AH.MoneyString(totalPrice) .. " demandés)")
  end
end

local function PendingCommodity()
  for r in pairs(AH.state.pending) do if r.kind == "commodity" then return r end end
  for _, r in ipairs(AH.state.rows) do if r.status == "quote" then return r end end
  return nil
end

function AH.OnCommodityUnavailable()
  local row = PendingCommodity()
  if row then AH.FailRow(row, "plus disponible à ce prix") end
end

function AH.OnCommoditySucceeded()
  local row = PendingCommodity()
  if row then Bought(row) end
end

function AH.OnCommodityFailed()
  local row = PendingCommodity()
  if row then AH.FailRow(row, "achat refusé par le serveur") end
end

-------------------------------------------------------------------------------
-- Rapport
-------------------------------------------------------------------------------
function AH.ReportLine()
  local r = AH.state.report
  local left = AH.Count("ready") + AH.Count("quote")
  local unv = AH.Count("unverified") + AH.Count("queued") + AH.Count("verifying")
  return string.format("%d achat(s) pour %s, revente vendeur %s (gain %s), %d échec(s), %d prête(s)%s",
    r.bought, AH.MoneyString(r.spent), AH.MoneyString(r.spent + r.gain), AH.MoneyString(r.gain), r.failed, left,
    unv > 0 and (", " .. unv .. " à vérifier") or "")
end

function AH.ReportLines()
  local st, lines = AH.state, {}
  local s = st.stats or {}
  if s.started then
    table.insert(lines, string.format("Scan : %d enchères, %d objets distincts, %d objet(s) retenu(s)%s, %d vérifié(s)%s%s%s.",
      s.scanned or 0, s.keys or 0, s.candidates or 0,
      (s.eligible or 0) > (s.candidates or 0) and (" sur " .. s.eligible .. " possibles (/obr ah max)") or "",
      s.verified or 0,
      (s.vanished or 0) > 0 and (" dont " .. s.vanished .. " déjà parti(s)") or "",
      (s.unresolved or 0) > 0 and (", " .. s.unresolved .. " recherche(s) sans réponse") or "",
      (s.unloaded or 0) > 0 and (", " .. s.unloaded .. " enchère(s) d'objets non chargés") or ""))
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
  local p = st.phase
  if p == "sending" then return "Scan complet : attente de la ligne (une recherche est en cours)…" end
  if p == "waiting" then return "Scan complet demandé, attente du serveur…" end
  if p == "arriving" then return string.format("Réception de la liste : %d enchères…", st.count or 0) end
  if p == "reading" then return string.format("Dépouillement : %d / %d enchères", st.index or 0, st.count or 0) end
  if p == "loading" then return string.format("Chargement des objets inconnus : %d enchère(s) restante(s)", st.pendingIdx and #st.pendingIdx or 0) end
  if p == "done" then
    local v = st.verify
    local extra = v and v.current and (" – vérification : " .. (v.current.name or "?")) or ""
    return AH.ReportLine() .. extra
  end
  local left = AH.ScanRemaining()
  if not st.open then return "Ouvre l'hôtel des ventes pour scanner." end
  if left > 0 then return "Prochain scan complet possible dans " .. AH.ClockString(left) .. "." end
  return "Prêt : lance un scan complet (une fois toutes les 15 minutes)."
end

-------------------------------------------------------------------------------
-- Événements
-------------------------------------------------------------------------------
function AH.OnEvent(event, a1, a2, a3)
  local st = AH.state
  if event == "AUCTION_HOUSE_SHOW" then
    st.open = true
    -- Blizzard_AuctionHouseUI est chargé à la demande juste avant cet événement : on se greffe si ce n'est pas déjà fait
    if ns.AuctionSetupTab then pcall(ns.AuctionSetupTab) end
    AH.StartTicker()
    Changed()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    st.open = false
    for row in pairs(st.pending) do AH.FailRow(row, "hôtel des ventes fermé pendant l'achat") end
    for _, row in ipairs(st.rows) do if row.status == "quote" then AH.FailRow(row, "hôtel des ventes fermé avant la confirmation") end end
    if AH.IsScanning() then AH.Finish("hôtel des ventes fermé") end
    AH.StopTicker()
    Changed()
  elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
    AH.OnReplicate()
  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    AH.OnDropped()
  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
    AH.OnItemResults(a1)
  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_ADDED" then
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
  "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED", "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED",
  "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
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
    local _, msg = AH.StartScan()
    Print("%s", msg)
  elseif sub == "next" or sub == "suivant" or sub == "buy" then
    local _, msg = AH.BuyNext()
    Print("%s", msg)
  elseif sub == "report" or sub == "rapport" then
    AH.Report()
  elseif sub == "profit" or sub == "gain" then
    local n = tonumber(arg)
    if not n then Print("Usage : /obr ah profit <pièces de cuivre> (gain minimal par affaire, actuel %s)", AH.MoneyString(MinProfit())) return end
    AH.SetMinProfit(n)
    Print("Gain minimal par affaire : %s (les lignes en dessous sont retirées)", AH.MoneyString(ns.db.ahMinProfit))
  elseif sub == "max" then
    local n = tonumber(arg)
    if not n then Print("Usage : /obr ah max <n> (lignes affichées après le scan ; actuel %d)", MaxCandidates()) return end
    ns.db.ahMaxCandidates = math.max(1, math.min(300, math.floor(n)))
    Print("Lignes affichées après le scan : %d au maximum", ns.db.ahMaxCandidates)
  elseif sub == "pre" or sub == "verif" then
    local n = tonumber(arg)
    if not n then Print("Usage : /obr ah pre <n> (lignes vérifiées d'avance en arrière-plan, ~1 s chacune ; actuel %d)", PreVerify()) return end
    ns.db.ahPreverify = math.max(0, math.min(100, math.floor(n)))
    Print("Lignes vérifiées d'avance : %d", ns.db.ahPreverify)
  elseif sub == "reset" then
    ns.db.ahLastScan = nil
    Print("Verrou de scan effacé (le serveur garde le sien : si le scan ne répond pas, c'est lui).")
  else
    Print("%s", AH.StatusText())
    Print("Usage : /obr ah scan | next | rapport | profit <cuivre> | pre <n> | max <n> | reset. Onglet « Bonnes affaires » dans l'hôtel des ventes.")
  end
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Auction"
