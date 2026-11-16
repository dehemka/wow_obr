-- OneButtonRotation - Guide RestedXP (addon compagnon DMK_RXP)
-- Le guide personnel est dans un addon à part, DMK_RXP (généré par tools/gen_rxp_guide.sh, distribué
-- hors GitHub). Il expose la globale DMK_RXP { name, generated, size, text } et pose la chaîne dans
-- RXPString : RestedXP la lit à son chargement (GuideLoader.lua, LoadCachedGuides) et importe le guide
-- tout seul la première fois, puis réutilise son cache. Ici : état, import manuel et copie du texte.

local ADDON_NAME, ns = ...
local Print = ns.Print

-- "213|2295048190:AAAA...%|40000" -> nGuides, id, base (version de jeu RestedXP)
function ns.RXPHeader(str)
  if type(str) ~= "string" or str == "" then return nil end
  local head = str:sub(1, 64)
  local n, id = head:match("^(%d+)|(%-?%d+):")
  local base = str:sub(-16):match("|(%d+)$")
  if not n then return nil end
  return { nGuides = tonumber(n), id = tonumber(id), base = tonumber(base) }
end

local function RXP()
  local rxp = rawget(_G, "RXPGuides")
  if type(rxp) ~= "table" then return nil end
  return rxp
end

ns.RXP_COMPANION = "DMK_RXP"

-- Guide disponible : addon compagnon DMK_RXP (globale), ou ns.RestedXPGuide (tests / autre source)
function ns.RestedXPGuideData()
  local g = ns.RestedXPGuide
  if g == nil then
    local c = rawget(_G, ns.RXP_COMPANION)
    if type(c) == "table" then g = c end
  end
  if type(g) == "table" and type(g.text) == "string" and #g.text > 0 then return g end
  return nil
end

function ns.RestedXPStatus()
  local g = ns.RestedXPGuideData()
  local s = { hasGuide = g ~= nil }
  s.companionLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(ns.RXP_COMPANION) and true or false
  if s.hasGuide then
    s.name, s.size, s.generated = g.name, g.size or #g.text, g.generated
    local h = ns.RXPHeader(g.text)
    if h then s.nGuides, s.id, s.base = h.nGuides, h.id, h.base end
  end
  local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("RXPGuides")
  local rxp = RXP()
  s.rxpLoaded = (loaded or rxp) and true or false
  if rxp then
    s.rxpVersion = tonumber(rxp.version)
    if s.base and s.rxpVersion then s.compatible = s.base >= s.rxpVersion end
    local prof = rxp.db and rxp.db.profile
    if prof and s.id then
      s.imported = (prof.guideId == s.id and prof.guideLength == s.nGuides) and true or false
    end
  end
  return s
end

-- Demande à RestedXP de (ré)importer la chaîne embarquée. Retourne ok, message.
function ns.ImportRestedXP()
  local s = ns.RestedXPStatus()
  if not s.hasGuide then return false, "Aucun guide RestedXP : installe l'addon compagnon " .. ns.RXP_COMPANION .. "." end
  local rxp = RXP()
  if not rxp then return false, "RestedXP (RXPGuides) n'est pas chargé." end
  if s.compatible == false then
    return false, ("Guide prévu pour la version %d de RestedXP, tu as la %d : mets RestedXP à jour."):format(s.base, s.rxpVersion)
  end
  if s.imported then
    if rxp.guideImporter and rxp.guideImporter.Open then pcall(function() rxp.guideImporter:Open() end) end
    return true, "Ce guide est déjà importé dans RestedXP."
  end
  if InCombatLockdown and InCombatLockdown() then return false, "Pas en combat." end
  RXPString = ns.RestedXPGuideData().text
  if type(rxp.LoadCachedGuides) ~= "function" then
    return false, "Cette version de RestedXP n'expose pas LoadCachedGuides : passe par la copie du texte."
  end
  local ok, err = pcall(rxp.LoadCachedGuides)
  if not ok then return false, "Erreur RestedXP : " .. tostring(err) end
  return true, "Import lancé : RestedXP affiche sa fenêtre d'import et charge les guides."
end

function ns.OpenRestedXPImporter()
  local rxp = RXP()
  if rxp and rxp.guideImporter and rxp.guideImporter.Open then
    local ok = pcall(function() rxp.guideImporter:Open() end)
    if ok then return true end
  end
  return false
end

function ns.RestedXPReport()
  local s = ns.RestedXPStatus()
  if not s.hasGuide then Print("RestedXP : aucun guide, l'addon compagnon %s n'est pas installé.", ns.RXP_COMPANION) return end
  Print("RestedXP : guide « %s », %d guides, %.0f Ko, généré le %s.", s.name or "?", s.nGuides or 0, (s.size or 0) / 1024, s.generated or "?")
  Print("RestedXP %s%s%s.", s.rxpLoaded and "chargé" or "non chargé", s.rxpVersion and (" v" .. s.rxpVersion) or "",
    s.imported == true and ", guide déjà importé" or (s.imported == false and ", guide pas encore importé" or ""))
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", RestedXP"
