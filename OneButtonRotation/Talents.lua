-- OneButtonRotation - Suivi des talents : ordre des points niveau par niveau et état actuel

local _, ns = ...
local Print = ns.Print

-------------------------------------------------------------------------------
-- Lecture des talents du personnage
-------------------------------------------------------------------------------

-- Renvoie { ["nom en minuscules"] = { name=, rank=, maxRank=, spellID=, tab= }, ... }, nomAPI
-- ou nil si aucune API de talents n'est disponible sur ce client.
function ns.TalentRanks()
  local out, found = {}, 0
  local function add(name, rank, maxRank, spellID, tab)
    if type(name) ~= "string" or name == "" then return false end
    out[name:lower()] = { name = name, rank = tonumber(rank) or 0, maxRank = tonumber(maxRank) or 0, spellID = spellID, tab = tab }
    found = found + 1
    return true
  end
  local trees = ns.TalentTrees()
  local numTabs = (trees and #trees > 0) and #trees or 3

  local CSI = C_SpecializationInfo
  if CSI and type(CSI.GetTalentInfo) == "function" then
    local group
    if type(CSI.GetActiveSpecGroup) == "function" then
      local ok, g = pcall(CSI.GetActiveSpecGroup, false, false)
      if ok and type(g) == "number" then group = g end
    end
    -- 1) par index de talent dans l'arbre (Cata/MoP Classic, Forever)
    for tab = 1, numTabs do
      local misses = 0
      for i = 1, 60 do
        local ok, info = pcall(CSI.GetTalentInfo, { specializationIndex = tab, talentIndex = i, groupIndex = group })
        if ok and type(info) == "table" and add(info.name, info.rank, info.maxRank, info.spellID, tab) then
          misses = 0
        else
          misses = misses + 1
          if misses >= 3 then break end
        end
      end
    end
    -- 2) par ligne / colonne
    if found == 0 then
      for tab = 1, numTabs do
        for tier = 1, 11 do
          for col = 1, 4 do
            local ok, info = pcall(CSI.GetTalentInfo, { specializationIndex = tab, tier = tier, column = col, groupIndex = group })
            if ok and type(info) == "table" then add(info.name, info.rank, info.maxRank, info.spellID, tab) end
          end
        end
      end
    end
    if found > 0 then return out, "C_SpecializationInfo.GetTalentInfo" end
  end

  -- 3) API Classic Era : GetTalentInfo(tab, index) -> name, icon, tier, column, rank, maxRank
  if type(GetTalentInfo) == "function" then
    for tab = 1, numTabs do
      local n = 40
      if type(GetNumTalents) == "function" then
        local ok, num = pcall(GetNumTalents, tab)
        if ok and type(num) == "number" and num > 0 then n = num end
      end
      for i = 1, n do
        local ok, name, _, _, _, rank, maxRank = pcall(GetTalentInfo, tab, i)
        if ok and name then add(name, rank, maxRank, nil, tab) end
      end
    end
    if found > 0 then return out, "GetTalentInfo" end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Plan : ordre du guide confronté aux talents réellement pris
-------------------------------------------------------------------------------

-- Nom affiché d'un talent du build : nom du client si disponible, sinon nom anglais
function ns.TalentName(t)
  local name = ns.SpellName(t.id)
  if not name or name == "" then
    ns.RequestSpellData(t.id)
    return t.name, false
  end
  return name, true
end

-- Renvoie le plan ou nil, raison.
--   plan = { build=, specKey=, fallback=bool, level=, api=, approx=bool,
--            spent=, expected=, unspent=, nextEntry=, lateCount=, doneCount=,
--            entries = { { level=, key=, name=, rank=, max=, tree=, current=, status="done"|"late"|"next"|"todo", note= }, ... },
--            offBuild = { { name=, rank=, maxRank= }, ... } }
function ns.TalentPlan(class, specKey)
  class = class or ns.PlayerClass()
  local builds = ns.TalentBuilds and ns.TalentBuilds[class]
  if not builds then return nil, "aucun ordre de talents défini pour cette classe" end
  specKey = specKey or ns.CurrentSpec()
  local build, fallback = specKey and builds[specKey], false
  if not build then
    for _, s in ipairs(ns.SpecNames[class] or {}) do
      if builds[s.key] then build, specKey, fallback = builds[s.key], s.key, true; break end
    end
  end
  if not build then return nil, "aucun ordre de talents défini" end

  local level = ns.PlayerLevel()
  local ranks, api = ns.TalentRanks()
  local approx = (ranks == nil)

  -- Rang actuel de chaque talent du build
  local current, names = {}, {}
  for key, t in pairs(build.talents) do
    local name = ns.TalentName(t)
    names[key] = name
    local r = ranks and (ranks[name:lower()] or ranks[t.name:lower()])
    if r then
      current[key] = r.rank
    elseif ranks then
      current[key] = 0
    else
      -- Pas d'API de talents : au mieux, le sort du rang 1 est-il connu ?
      current[key] = ns.IsKnown(t.id) and 1 or 0
    end
  end

  local plan = { build = build, specKey = specKey, fallback = fallback, level = level, api = api, approx = approx,
                 entries = {}, offBuild = {}, doneCount = 0, lateCount = 0 }
  for _, o in ipairs(build.order) do
    local t = build.talents[o.talent]
    local e = { level = o.level, key = o.talent, name = names[o.talent], rank = o.rank, max = t.max, tree = t.tree,
                current = current[o.talent], note = o.note }
    if e.current >= o.rank then
      e.status = "done"; plan.doneCount = plan.doneCount + 1
    elseif not plan.nextEntry then
      e.status = "next"; plan.nextEntry = e
    elseif o.level <= level then
      e.status = "late"; plan.lateCount = plan.lateCount + 1
    else
      e.status = "todo"
    end
    table.insert(plan.entries, e)
  end
  -- Le prochain point est « en retard » s'il aurait déjà dû être placé
  if plan.nextEntry and plan.nextEntry.level <= level then plan.lateCount = plan.lateCount + 1 end

  -- Points dépensés / attendus
  local spent = 0
  local trees = ns.TalentTrees()
  if trees then
    for _, tr in ipairs(trees) do spent = spent + (tr.points or 0) end
  elseif ranks then
    for _, r in pairs(ranks) do spent = spent + r.rank end
  else
    spent = plan.doneCount
  end
  plan.spent = spent
  plan.expected = math.max(0, level - 9)
  plan.unspent = math.max(0, plan.expected - spent)

  -- Talents pris hors du build
  if ranks then
    local inBuild = {}
    for _, name in pairs(names) do inBuild[name:lower()] = true end
    for _, t in pairs(build.talents) do inBuild[t.name:lower()] = true end
    for lower, r in pairs(ranks) do
      if r.rank > 0 and not inBuild[lower] then table.insert(plan.offBuild, r) end
    end
    table.sort(plan.offBuild, function(a, b) return a.name < b.name end)
  end
  return plan
end

-- Résumé d'une entrée : « Suppression 3/5 »
function ns.TalentEntryLabel(e)
  return string.format("%s %d/%d", e.name, e.rank, e.max)
end

-- Rappel au level up : le talent à prendre
function ns.TalentReminder()
  local plan = ns.TalentPlan()
  if not plan or not plan.nextEntry then return end
  local e = plan.nextEntry
  if plan.unspent > 0 or e.level <= plan.level then
    Print("Point de talent à placer : %s%s (/obr talents pour la liste).", ns.TalentEntryLabel(e),
      plan.unspent > 1 and string.format(", %d points en attente", plan.unspent) or "")
  end
end

-- Rapport texte dans le chat
function ns.TalentReport()
  local plan, why = ns.TalentPlan()
  if not plan then Print("Talents : %s", tostring(why)) return end
  Print("Build %s – niveau %d, %d/%d points placés%s", plan.build.name, plan.level, plan.spent, plan.expected,
    plan.unspent > 0 and string.format(", |cffff4040%d à placer|r", plan.unspent) or "")
  if plan.nextEntry then Print("Prochain point : niveau %d, %s", plan.nextEntry.level, ns.TalentEntryLabel(plan.nextEntry)) end
  if #plan.offBuild > 0 then
    local parts = {}
    for _, r in ipairs(plan.offBuild) do table.insert(parts, string.format("%s %d/%d", r.name, r.rank, r.maxRank)) end
    Print("Hors build : %s", table.concat(parts, ", "))
  end
  if plan.approx then Print("(API de talents introuvable : état approximatif)") end
end

-------------------------------------------------------------------------------
-- Panneau (intégré à la page « Talents » de la fenêtre principale)
-------------------------------------------------------------------------------
local TREE_TAGS = { [2] = "Démono", [3] = "Destru" }
local panel

function ns.CreateTalentsPanel(parent)
  local p = CreateFrame("Frame", nil, parent)

  local header = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  header:SetPoint("TOPLEFT", 4, -4)
  header:SetPoint("RIGHT", -4, 0)
  header:SetJustifyH("LEFT")
  header:SetJustifyV("TOP")
  header:SetHeight(104)
  header:SetSpacing(2)
  p.header = header

  local legend = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  legend:SetPoint("TOPLEFT", 4, -112)
  legend:SetPoint("RIGHT", -4, 0)
  legend:SetJustifyH("LEFT")
  legend:SetText("|cff40ff40[x]|r pris   |cffffd100[>]|r prochain point   |cffff4040[!]|r en retard   |cff9d9d9d[ ]|r plus tard")

  local scroll = CreateFrame("ScrollFrame", nil, p, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 4, -130)
  scroll:SetPoint("BOTTOMRIGHT", -26, 32)
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(10, 10)
  local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  text:SetPoint("TOPLEFT")
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(3)
  scroll:SetScrollChild(child)
  scroll:SetScript("OnSizeChanged", function(_, w)
    child:SetWidth(w); text:SetWidth(w)
    child:SetHeight(math.max(10, text:GetStringHeight() + 10))
  end)
  p.scrollChild, p.text = child, text

  local chat = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  chat:SetSize(180, 22)
  chat:SetPoint("BOTTOMLEFT", 4, 4)
  chat:SetText("Résumé dans le chat")
  chat:SetScript("OnClick", function() ns.TalentReport() end)
  local refresh = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
  refresh:SetSize(120, 22)
  refresh:SetPoint("LEFT", chat, "RIGHT", 8, 0)
  refresh:SetText("Actualiser")
  refresh:SetScript("OnClick", function() p:Refresh() end)

  function p:Refresh() ns.RefreshTalentsPanel(p) end
  panel = p
  return p
end

function ns.RefreshTalentsPanel(p)
  p = p or panel
  if not p or not p:IsVisible() then return end
  local plan, why = ns.TalentPlan()
  if not plan then
    p.header:SetText("|cffff4040" .. tostring(why) .. "|r")
    p.text:SetText("")
    return
  end
  local class = ns.PlayerClass()
  local head = {}
  table.insert(head, string.format("|cffffd100%s|r", plan.build.name))
  if plan.fallback then
    table.insert(head, string.format("|cffff8000Spé actuelle sans ordre détaillé dans le guide : affichage du build %s.|r", ns.SpecLabel(class, plan.specKey)))
  end
  table.insert(head, string.format("Niveau %d  –  points placés : %d/%d%s", plan.level, plan.spent, plan.expected,
    plan.unspent > 0 and string.format("  –  |cffff4040%d à placer|r", plan.unspent) or ""))
  if plan.nextEntry then
    local e = plan.nextEntry
    table.insert(head, string.format("Prochain point : |cffffd100%s|r%s", ns.TalentEntryLabel(e),
      e.tree ~= 1 and (" (arbre " .. (TREE_TAGS[e.tree] or e.tree) .. ")") or ""))
    if e.note then table.insert(head, "|cff9d9d9d" .. e.note .. "|r") end
  else
    table.insert(head, "|cff40ff40Build complet.|r")
  end
  if plan.approx then table.insert(head, "|cffff8000API de talents introuvable : état approximatif (sort de rang 1 connu ou non).|r") end
  p.header:SetText(table.concat(head, "\n"))

  local lines = {}
  local MARK = { done = "|cff40ff40[x]|r ", next = "|cffffd100[>]|r ", late = "|cffff4040[!]|r ", todo = "|cff9d9d9d[ ]|r " }
  local COLOR = { done = "|cffa0d0a0", next = "|cffffd100", late = "|cffff6060", todo = "|cff9d9d9d" }
  for _, e in ipairs(plan.entries) do
    local tag = TREE_TAGS[e.tree] and ("  [" .. TREE_TAGS[e.tree] .. "]") or ""
    local here = (e.level == plan.level) and "  |cffffffff<- ton niveau|r" or ""
    local cur = ""
    if (e.status == "late" or e.status == "next") and e.current > 0 and e.current < e.rank then
      cur = string.format("  (tu as %d)", e.current)
    end
    table.insert(lines, string.format("%s%sNiv. %d   %s%s%s|r%s", MARK[e.status], COLOR[e.status], e.level,
      ns.TalentEntryLabel(e), tag, cur, here))
  end
  if #plan.offBuild > 0 then
    table.insert(lines, "")
    table.insert(lines, "|cffff8000Pris hors du build :|r")
    for _, r in ipairs(plan.offBuild) do
      table.insert(lines, string.format("|cffff8000    %s %d/%d|r", r.name, r.rank, r.maxRank))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "|cff9d9d9dSource : " .. plan.build.source .. "|r")
  p.text:SetText(table.concat(lines, "\n"))
  p.scrollChild:SetHeight(math.max(10, p.text:GetStringHeight() + 10))
end

-- Compatibilité : ouvre la fenêtre principale sur la page Talents
function ns.ToggleTalentsUI(force)
  if ns.ToggleUI then ns.ToggleUI(force ~= "close" and "talents" or nil) end
end

-- Rafraîchissement automatique quand les talents ou le niveau changent
local events = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_TALENT_UPDATE", "CHARACTER_POINTS_CHANGED", "PLAYER_LEVEL_UP", "ACTIVE_TALENT_GROUP_CHANGED", "SPELL_DATA_LOAD_RESULT" }) do
  pcall(events.RegisterEvent, events, ev)
end
local pending
events:SetScript("OnEvent", function()
  if not panel or not panel:IsVisible() or pending then return end
  pending = true
  C_Timer.After(1, function() pending = nil; ns.RefreshTalentsPanel() end)
end)

ns.loadedFiles = (ns.loadedFiles or "") .. ", Talents"
