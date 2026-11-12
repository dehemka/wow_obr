-- OneButtonRotation - Macro
-- Résolution des sorts, choix de la phase, construction et application des macros.

local ADDON_NAME, ns = ...
local Print = ns.Print

local MACRO_MAX = 255
local MACRO_NAME_MAX = 16
local QUESTION_MARK_ICON = 134400 -- INV_MISC_QUESTIONMARK (fileID)
local RANGED_SLOT = 18

-------------------------------------------------------------------------------
-- Sorts
-------------------------------------------------------------------------------
function ns.SpellName(spellID)
  if C_Spell and C_Spell.GetSpellName then
    local ok, name = pcall(C_Spell.GetSpellName, spellID)
    if ok and name then return name end
  end
  if C_Spell and C_Spell.GetSpellInfo then
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and type(info) == "table" and info.name then return info.name end
  end
  if type(GetSpellInfo) == "function" then
    local ok, name = pcall(GetSpellInfo, spellID)
    if ok and name then return name end
  end
  return nil
end

-- Sous-titre du sort (« Rang 2 » sur Forever, nil sur un client sans rangs)
function ns.SpellSubtext(spellID)
  if C_Spell and C_Spell.GetSpellSubtext then
    local ok, sub = pcall(C_Spell.GetSpellSubtext, spellID)
    if ok and sub and sub ~= "" then return sub end
  end
  if type(GetSpellSubtext) == "function" then
    local ok, sub = pcall(GetSpellSubtext, spellID)
    if ok and sub and sub ~= "" then return sub end
  end
  return nil
end

-- Numéro de rang extrait d'un sous-titre (« Rang 3 », « Rank 3 »), 1 si absent
function ns.RankNumber(subtext)
  if not subtext then return 1 end
  return tonumber(subtext:match("(%d+)")) or 1
end

-- Le joueur connaît-il ce sort (n'importe quel rang) ?
function ns.IsKnown(spellID)
  local checks = { IsPlayerSpell, IsSpellKnown, IsSpellKnownOrOverridesKnown,
                   C_SpellBook and C_SpellBook.IsSpellKnown, C_SpellBook and C_SpellBook.IsSpellInSpellBook }
  for _, fn in ipairs(checks) do
    if type(fn) == "function" then
      local ok, res = pcall(fn, spellID)
      if ok and res then return true end
    end
  end
  -- Recherche par nom : le nom est commun à tous les rangs d'un sort
  local name = ns.SpellName(spellID)
  if name then
    if C_SpellBook and C_SpellBook.FindSpellBookSlotForSpell then
      local ok, slot = pcall(C_SpellBook.FindSpellBookSlotForSpell, spellID)
      if ok and slot then return true end
    end
    if C_Spell and C_Spell.GetSpellInfo then
      local ok, info = pcall(C_Spell.GetSpellInfo, name)
      if ok and type(info) == "table" and info.spellID then return true end
    elseif type(GetSpellInfo) == "function" then
      local ok, n = pcall(GetSpellInfo, name)
      if ok and n then return true end
    end
  end
  return false
end

-- Le client moderne ne connaît le nom d'un sort que si ses données sont chargées (sort du
-- grimoire, ou déjà affiché). Pour les autres il faut les demander : la réponse arrive via
-- l'événement SPELL_DATA_LOAD_RESULT, après quoi on regénère.
function ns.SpellExists(spellID)
  if C_Spell and C_Spell.DoesSpellExist then
    local ok, res = pcall(C_Spell.DoesSpellExist, spellID)
    if ok then return res and true or false end
  end
  return nil -- inconnu
end

local requested = {}
function ns.RequestSpellData(spellID)
  if requested[spellID] then return false end
  if not (C_Spell and C_Spell.RequestLoadSpellData) then return false end
  if ns.SpellExists(spellID) == false then return false end
  requested[spellID] = true
  pcall(C_Spell.RequestLoadSpellData, spellID)
  return true
end

-- Tous les IDs référencés par les rotations d'une classe
function ns.AllSpellIDs(class)
  local seen, ids = {}, {}
  local function add(id) if id and not seen[id] then seen[id] = true; table.insert(ids, id) end end
  local function collect(e)
    if type(e) ~= "table" then return end
    add(e.id)
    for _, id in ipairs(e.ids or {}) do add(id) end
    if type(e.talent) == "table" then for _, id in ipairs(e.talent) do add(id) end else add(e.talent) end
    for _, sub in ipairs(e.alt or {}) do collect(sub) end
    for _, sub in ipairs(e.args or {}) do collect(sub) end
  end
  for _, rot in pairs(ns.Rotations[class] or {}) do
    for _, ph in ipairs(rot.phases or {}) do
      for _, def in ipairs(ph.macros or {}) do
        for _, l in ipairs(def.lines or {}) do collect(l) end
        for _, e in ipairs(def.sequence or {}) do collect(e) end
        collect(def.filler)
        for _, l in ipairs(def.after or {}) do collect(l) end
      end
    end
  end
  return ids
end

-- Groupes de candidats (un par sort logique) référencés par une classe
function ns.AllSpellGroups(class)
  local seen, groups = {}, {}
  local function add(list)
    if not list then return end
    if type(list) ~= "table" then list = { list } end
    local key = table.concat(list, "/")
    if not seen[key] then seen[key] = true; table.insert(groups, list) end
  end
  local function collect(e)
    if type(e) ~= "table" then return end
    add(e.id); add(e.ids); add(e.talent)
    for _, sub in ipairs(e.alt or {}) do collect(sub) end
    for _, sub in ipairs(e.args or {}) do collect(sub) end
  end
  for _, rot in pairs(ns.Rotations[class] or {}) do
    for _, ph in ipairs(rot.phases or {}) do
      for _, def in ipairs(ph.macros or {}) do
        for _, l in ipairs(def.lines or {}) do collect(l) end
        for _, e in ipairs(def.sequence or {}) do collect(e) end
        collect(def.filler)
        for _, l in ipairs(def.after or {}) do collect(l) end
      end
    end
  end
  return groups
end

-- Demande le chargement de tous les sorts dont le nom n'est pas encore disponible.
-- Retourne le nombre de demandes émises.
function ns.PreloadSpells()
  local n = 0
  for _, id in ipairs(ns.AllSpellIDs(ns.PlayerClass())) do
    if not ns.SpellName(id) and ns.RequestSpellData(id) then n = n + 1 end
  end
  return n
end

-- Premier ID d'une liste de candidats dont le nom se résout (et, en mode strict, qui est connu).
-- Permet de couvrir plusieurs rangs ou des IDs différents entre Vanilla et Forever.
function ns.PickSpellID(ids, strict)
  local firstNamed
  for _, id in ipairs(ids) do
    if ns.SpellName(id) then
      if not strict or ns.IsKnown(id) then return id end
      firstNamed = firstNamed or id
    end
  end
  return firstNamed
end

-- Parcourt le grimoire du joueur : callback(spellID, name, itemType, subtext) pour chaque sort.
function ns.ForEachSpellBookSpell(callback)
  local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or "spell"
  if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and C_SpellBook.GetSpellBookSkillLineInfo then
    local okN, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
    if okN and numLines then
      for line = 1, numLines do
        local ok, info = pcall(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if ok and type(info) == "table" and info.itemIndexOffset and info.numSpellBookItems then
          for i = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
            local ok2, item = pcall(C_SpellBook.GetSpellBookItemInfo, i, bank)
            if ok2 and type(item) == "table" and item.spellID and item.name then
              callback(item.spellID, item.name, item.itemType, item.subName or ns.SpellSubtext(item.spellID))
            end
          end
        end
      end
      return true
    end
  end
  if type(GetNumSpellTabs) == "function" and type(GetSpellTabInfo) == "function" and type(GetSpellBookItemInfo) == "function" then
    for tab = 1, GetNumSpellTabs() do
      local _, _, offset, numSpells = GetSpellTabInfo(tab)
      for i = (offset or 0) + 1, (offset or 0) + (numSpells or 0) do
        local kind, id = GetSpellBookItemInfo(i, "spell")
        if id then callback(id, ns.SpellName(id) or "?", kind, ns.SpellSubtext(id)) end
      end
    end
    return true
  end
  return false
end

-- Une baguette est-elle équipée ? (emplacement arme à distance, classe Arme / sous-classe Baguette)
function ns.HasWand()
  if type(HasWandEquipped) == "function" then
    local ok, res = pcall(HasWandEquipped)
    if ok and res ~= nil then return res and true or false end
  end
  local itemID = GetInventoryItemID and GetInventoryItemID("player", RANGED_SLOT)
  if not itemID then return false end
  local getInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
  if type(getInstant) ~= "function" then return false end
  local ok, _, _, _, equipLoc, _, classID, subclassID = pcall(getInstant, itemID)
  if not ok then return false end
  if classID == 2 and subclassID == 19 then return true end
  return equipLoc == "INVTYPE_RANGEDRIGHT" and classID == 2 and subclassID ~= 2 and subclassID ~= 3 and subclassID ~= 18
end

-------------------------------------------------------------------------------
-- Résolution des entrées
-------------------------------------------------------------------------------
-- ctx = { level=, strict=, wand= }
-- Conditions communes aux entrées et aux lignes. Retourne ok, raison
local function CheckConditions(e, ctx)
  if e.minLevel and ctx.level < e.minLevel then return false, "niveau" end
  if e.maxLevel and ctx.level > e.maxLevel then return false, "niveau max" end
  if e.wand and not ctx.wand then return false, "pas de baguette" end
  if e.nowand and ctx.wand then return false, "baguette équipée" end
  if e.option and not ns.db[e.option] then return false, "option désactivée" end
  return true
end

-- Retourne name, nil  ou  nil, raison
local function ResolveEntry(e, ctx)
  local ok, why = CheckConditions(e, ctx)
  if not ok then return nil, why end
  if e.alt then
    local lastWhy = "aucune alternative"
    for _, sub in ipairs(e.alt) do
      local name, w = ResolveEntry(sub, ctx)
      if name then return name end
      lastWhy = w
    end
    return nil, lastWhy
  end
  local id = e.id
  if e.ids then id = ns.PickSpellID(e.ids, ctx.strict) end
  local name = id and ns.SpellName(id)
  if not name then return nil, "nom introuvable (ID " .. tostring(id or (e.ids and e.ids[1])) .. ")" end
  if ctx.strict then
    if not ns.IsKnown(id) then return nil, "inconnu" end
    if e.talent then
      local talentID = type(e.talent) == "table" and ns.PickSpellID(e.talent, true) or e.talent
      if not talentID or not ns.IsKnown(talentID) then return nil, "talent" end
    end
  end
  if e.bang then name = "!" .. name end -- « !Tir » : ne coupe pas le tir auto si on réappuie
  return name
end

-- Libellé lisible d'une entrée pour les messages
function ns.EntryLabel(e)
  local id = e.id or (e.ids and ns.PickSpellID(e.ids, false))
  return (id and ns.SpellName(id)) or e.label or ("ID " .. tostring(id or (e.ids and e.ids[1])))
end

-- Retourne la ligne de texte ou nil, raison
local function ResolveLine(line, ctx)
  if type(line) == "string" then return line end
  local ok, why = CheckConditions(line, ctx)
  if not ok then return nil, why end
  if line.text then return line.text end
  local names = {}
  for i, arg in ipairs(line.args or {}) do
    local name, w = ResolveEntry(arg, ctx)
    if not name then return nil, w end
    names[i] = name
  end
  return string.format(line.fmt, unpack(names))
end

-------------------------------------------------------------------------------
-- Phase
-------------------------------------------------------------------------------
function ns.CurrentPhase(class, specKey, level)
  local rot = ns.Rotations[class] and ns.Rotations[class][specKey]
  if not rot or not rot.phases then return nil end
  local best
  for _, phase in ipairs(rot.phases) do
    if level >= (phase.minLevel or 1) and (not best or (phase.minLevel or 1) >= (best.minLevel or 1)) then
      best = phase
    end
  end
  return best
end

-------------------------------------------------------------------------------
-- Construction
-------------------------------------------------------------------------------
-- Construit une macro. Retourne body, info  ou  nil, raison
-- info = { included = {noms}, skipped = {{nom|texte, raison}}, fillerCount = }
local function BuildOne(def, ctx)
  local info = { included = {}, skipped = {} }
  local lines = def.noTooltip and {} or { "#showtooltip" }

  for _, line in ipairs(def.lines or {}) do
    local text, why = ResolveLine(line, ctx)
    if text then table.insert(lines, text)
    elseif type(line) == "table" and line.fmt then
      table.insert(info.skipped, { line.fmt:gsub("%%s", "…"), why })
    end
  end

  local seq = {}
  for _, entry in ipairs(def.sequence or {}) do
    local name, why = ResolveEntry(entry, ctx)
    if name then
      for _ = 1, (entry.count or 1) do table.insert(seq, name) end
      table.insert(info.included, name)
    else
      table.insert(info.skipped, { ns.EntryLabel(entry), why })
    end
  end

  local fillerName
  if def.filler then
    local name, why = ResolveEntry(def.filler, ctx)
    if name then fillerName = name
    else table.insert(info.skipped, { ns.EntryLabel(def.filler), why }) end
  end

  local after = {}
  for _, line in ipairs(def.after or {}) do
    local text, why = ResolveLine(line, ctx)
    if text then table.insert(after, text)
    elseif type(line) == "table" and line.fmt then
      table.insert(info.skipped, { line.fmt:gsub("%%s", "…"), why })
    end
  end

  local hasSequence = (#seq > 0 or fillerName ~= nil)
  if not hasSequence and #lines + #after <= (def.noTooltip and 0 or 1) then
    return nil, "aucun sort utilisable"
  end

  local function Assemble(fillerCount)
    local all = {}
    for _, l in ipairs(lines) do table.insert(all, l) end
    if hasSequence then
      local parts = {}
      for _, n in ipairs(seq) do table.insert(parts, n) end
      if fillerName then for _ = 1, fillerCount do table.insert(parts, fillerName) end end
      local cmd = "/castsequence " .. (def.conditions and (def.conditions .. " ") or "")
        .. "reset=" .. (def.reset or "target/combat") .. " " .. table.concat(parts, ", ")
      table.insert(all, cmd)
    end
    for _, l in ipairs(after) do table.insert(all, l) end
    return table.concat(all, "\n")
  end

  local wanted = fillerName and (def.fillerCount or 4) or 0
  local body = Assemble(wanted)
  while #body > MACRO_MAX and wanted > 1 do
    wanted = wanted - 1
    body = Assemble(wanted)
  end
  while #body > MACRO_MAX and #seq > 1 do
    local removed = table.remove(seq)
    table.insert(info.skipped, { removed, "macro trop longue" })
    body = Assemble(wanted)
  end
  if #body > MACRO_MAX then
    return nil, "macro trop longue même réduite (" .. #body .. " caractères)"
  end
  info.fillerCount = wanted
  info.fillerName = fillerName
  return body, info
end

-- Construit toutes les macros de la phase courante.
-- Retourne list, ctxInfo  ou  nil, raison
-- list[i] = { def=, name=, body=, info= }  (body nil si la macro n'a rien à contenir)
-- ctxInfo = { class, level, specKey, specLabel, how, phase, wand }
function ns.BuildAll(forcedSpec)
  if not ns.db then return nil, "addon pas encore initialisé" end
  local class, level = ns.PlayerClass(), ns.PlayerLevel()
  if not ns.Rotations[class] then return nil, "classe non supportée : " .. tostring(class) end

  local specKey, how = forcedSpec, "forcée"
  if not specKey then specKey, how = ns.CurrentSpec() end
  if not specKey then
    return nil, "spé indéterminable (" .. tostring(how) .. "). Utilise /obr spec <nom>."
  end
  local phase = ns.CurrentPhase(class, specKey, level)
  if not phase then return nil, "pas de rotation pour la spé " .. tostring(specKey) end

  local ctx = { level = level, strict = ns.db.strict, wand = ns.HasWand() }
  local ctxInfo = { class = class, level = level, specKey = specKey, specLabel = ns.SpecLabel(class, specKey),
                    how = how, phase = phase, wand = ctx.wand }
  local list = {}
  local defs = {}
  for _, def in ipairs(phase.macros or {}) do table.insert(defs, def) end
  if ns.SocialMacroDef and ns.db.socialMacro ~= false then table.insert(defs, ns.SocialMacroDef) end
  for _, def in ipairs(defs) do
    local body, info = BuildOne(def, ctx)
    table.insert(list, { def = def, name = def.name, body = body, info = body and info or nil, reason = (not body) and info or nil })
  end
  return list, ctxInfo
end

-- Compatibilité : la macro principale seule. Retourne body, info  ou  nil, raison
function ns.BuildMacro(forcedSpec)
  local list, ctxInfo = ns.BuildAll(forcedSpec)
  if not list then return nil, ctxInfo end
  local main = list[1]
  if not main or not main.body then return nil, main and main.reason or "aucune macro" end
  local info = main.info
  info.specKey, info.specLabel, info.how, info.level, info.class = ctxInfo.specKey, ctxInfo.specLabel, ctxInfo.how, ctxInfo.level, ctxInfo.class
  info.phase, info.wand = ctxInfo.phase, ctxInfo.wand
  return main.body, info
end

-------------------------------------------------------------------------------
-- Application
-------------------------------------------------------------------------------
local function MacroLimits()
  local consts = Constants and Constants.MacroConsts
  local maxGlobal = (consts and consts.MAX_ACCOUNT_MACROS) or MAX_ACCOUNT_MACROS or 120
  local maxPerChar = (consts and consts.MAX_CHARACTER_MACROS) or MAX_CHARACTER_MACROS or 18
  return maxGlobal, maxPerChar
end

local function MacroSlotsAvailable(perCharacter)
  local numGlobal, numPerChar = GetNumMacros()
  local maxGlobal, maxPerChar = MacroLimits()
  if perCharacter then return (numPerChar or 0) < maxPerChar end
  return (numGlobal or 0) < maxGlobal
end

-- Crée ou met à jour une macro. Retourne index, statut  ou  nil, raison
function ns.ApplyMacro(name, body, icon)
  if InCombatLockdown() then return nil, "en combat" end
  icon = icon or QUESTION_MARK_ICON
  name = name:sub(1, MACRO_NAME_MAX)
  local index = GetMacroIndexByName(name)
  if index and index > 0 then
    local _, _, oldBody = GetMacroInfo(index)
    if oldBody == body then return index, "inchangée" end
    EditMacro(index, name, icon, body)
    return index, "mise à jour"
  end
  local perChar = ns.db.perCharacter
  if not MacroSlotsAvailable(perChar) then
    if MacroSlotsAvailable(not perChar) then perChar = not perChar
    else return nil, "plus d'emplacement de macro libre" end
  end
  local ok, res = pcall(CreateMacro, name, icon, body, perChar)
  if not ok then
    ok, res = pcall(CreateMacro, name, "INV_MISC_QUESTIONMARK", body, perChar)
  end
  if not ok or not res or res == 0 then return nil, "CreateMacro a échoué (" .. tostring(res) .. ")" end
  return res, "créée"
end

-- Pose une macro sur un emplacement de barre d'action (1-120) si configuré.
function ns.PlaceOnBar(index, slot)
  if not slot or InCombatLockdown() then return end
  local actionType, id = GetActionInfo(slot)
  if actionType == "macro" and id == index then return end
  if actionType ~= nil then
    Print("L'emplacement %d est déjà occupé, macro non posée (/obr slot pour changer).", slot)
    return
  end
  ClearCursor()
  PickupMacro(index)
  if GetCursorInfo() then
    PlaceAction(slot)
    ClearCursor()
    Print("Macro posée sur l'emplacement %d.", slot)
  end
end

-- Raisons attendues (conditions de phase), inutiles à signaler dans le chat
local QUIET_REASONS = { ["niveau"] = true, ["niveau max"] = true, ["baguette équipée"] = true,
                        ["pas de baguette"] = true, ["option désactivée"] = true }
local function FormatSkipped(skipped)
  local parts = {}
  for _, s in ipairs(skipped) do
    if not QUIET_REASONS[s[2]] then table.insert(parts, s[1] .. " (" .. s[2] .. ")") end
  end
  return table.concat(parts, ", ")
end

function ns.BuildAndApply(reason)
  local list, ctxInfo = ns.BuildAll()
  if not list then
    Print("Macro non générée : %s", tostring(ctxInfo))
    if ns.RefreshUI then ns.RefreshUI() end
    return
  end
  local changed = {}
  for _, m in ipairs(list) do
    if not m.body then
      Print("Macro « %s » non générée : %s", m.name, tostring(m.reason))
    else
      local index, status = ns.ApplyMacro(m.name, m.body, m.def.icon)
      if not index then
        Print("Échec pour « %s » : %s", m.name, tostring(status))
      else
        if status ~= "inchangée" then
          table.insert(changed, string.format("%s %s (%d/255)", m.name, status, #m.body))
          local skipped = FormatSkipped(m.info.skipped)
          if skipped ~= "" then Print("« %s », sorts ignorés : %s", m.name, skipped) end
        end
        ns.PlaceOnBar(index, m.def.slotKey and ns.db[m.def.slotKey])
      end
    end
  end
  if #changed > 0 then
    Print("%s – %s niveau %d, phase « %s »%s%s.", table.concat(changed, ", "),
      ctxInfo.specLabel, ctxInfo.level, ctxInfo.phase.name or "?",
      ctxInfo.wand and ", baguette" or "", reason and (", " .. reason) or "")
  end
  if ns.RefreshUI then ns.RefreshUI() end
end

-------------------------------------------------------------------------------
-- Debug
-------------------------------------------------------------------------------
-- Rangs d'un sort présents dans le grimoire, triés par rang croissant.
-- Retourne list ({id, rank, subtext}) ou nil si aucune API de grimoire.
function ns.KnownRanks(spellName)
  if not spellName then return nil end
  local ranks = {}
  local ok = ns.ForEachSpellBookSpell(function(id, name, _, subtext)
    if name == spellName then
      table.insert(ranks, { id = id, rank = ns.RankNumber(subtext), subtext = subtext })
    end
  end)
  if not ok then return nil end
  table.sort(ranks, function(a, b) return a.rank < b.rank end)
  return ranks
end

-- Affiche, pour chaque sort utilisé par les macros courantes, le rang le plus élevé connu.
-- Forever garde les rangs de Classic : ils s'apprennent chez le maître, et une macro sans
-- rang lance toujours le rang le plus élevé connu.
function ns.RankReport()
  local list, ctxInfo = ns.BuildAll()
  if not list then Print("Rangs : %s", tostring(ctxInfo)) return end
  local seen, names = {}, {}
  for _, m in ipairs(list) do
    for _, name in ipairs((m.info and m.info.included) or {}) do
      name = name:gsub("^!", "")
      if not seen[name] then seen[name] = true; table.insert(names, name) end
    end
    if m.info and m.info.fillerName then
      local name = m.info.fillerName:gsub("^!", "")
      if not seen[name] then seen[name] = true; table.insert(names, name) end
    end
  end
  if #names == 0 then Print("Rangs : aucun sort dans les macros courantes.") return end
  Print("Rangs connus (niveau %d) – la macro lance toujours le rang le plus élevé :", ctxInfo.level)
  local noAPI = false
  for _, name in ipairs(names) do
    local ranks = ns.KnownRanks(name)
    if not ranks then noAPI = true
    elseif #ranks == 0 then Print("  %s : absent du grimoire ?", name)
    else
      local top = ranks[#ranks]
      Print("  %s : %s (ID %d)%s", name, top.subtext or "rang unique", top.id,
        #ranks > 1 and string.format(", %d rangs connus", #ranks) or "")
    end
  end
  if noAPI then Print("  (aucune API de grimoire sur ce client)") end
  Print("Nouveaux rangs chez le maître de classe, en général tous les 2 niveaux : pense à y passer.")
end

function ns.DebugInfo()
  local version, build, date, toc = GetBuildInfo()
  Print("Client %s (build %s, %s) – interface %s – addon v%s", tostring(version), tostring(build), tostring(date), tostring(toc), ns.VERSION)
  local class, level = ns.PlayerClass(), ns.PlayerLevel()
  local spec, how = ns.CurrentSpec()
  local phase = spec and ns.CurrentPhase(class, spec, level)
  Print("Personnage : %s niveau %d, spé %s (%s), phase « %s », baguette : %s",
    tostring(class), level, spec and ns.SpecLabel(class, spec) or "?", tostring(how),
    phase and phase.name or "?", ns.HasWand() and "oui" or "non")
  local apis = {
    "GetTalentTabInfo", "GetSpecialization", "IsPlayerSpell", "IsSpellKnown", "GetSpellInfo", "HasWandEquipped",
    "CreateMacro", "EditMacro", "PickupMacro", "PlaceAction", "GetInventoryItemID",
    "C_Spell.GetSpellName", "C_Spell.GetSpellInfo", "C_SpellBook.IsSpellKnown", "C_Item.GetItemInfoInstant",
    "C_SpecializationInfo.GetSpecializationInfo", "C_SpecializationInfo.GetSpecialization",
  }
  local present, missing = {}, {}
  for _, n in ipairs(apis) do
    local ns1, fn = n:match("^([%w_]+)%.([%w_]+)$")
    local f = ns1 and (type(_G[ns1]) == "table" and _G[ns1][fn]) or _G[n]
    if type(f) == "function" then table.insert(present, n) else table.insert(missing, n) end
  end
  Print("API présentes : %s", table.concat(present, ", "))
  if #missing > 0 then Print("API absentes : %s", table.concat(missing, ", ")) end
  local numGlobal, numPerChar = GetNumMacros()
  local maxGlobal, maxPerChar = MacroLimits()
  Print("Macros : %s/%s compte, %s/%s personnage", tostring(numGlobal), tostring(maxGlobal), tostring(numPerChar), tostring(maxPerChar))
  local trees, api = ns.TalentTrees()
  if trees then
    local parts = {}
    for _, t in ipairs(trees) do
      table.insert(parts, string.format("%d:%s=%d pts", t.tab, tostring(t.name), t.points))
    end
    Print("Arbres (%s) : %s", tostring(api), table.concat(parts, " ; "))
  else
    Print("Arbres de talents : aucune API trouvée")
  end
  Print("WOW_PROJECT_ID = %s (Forever/Camelot = %s)", tostring(WOW_PROJECT_ID), tostring(WOW_PROJECT_CAMELOT))
  Print("Fichiers chargés : %s", tostring(ns.loadedFiles))
  if ns.loadErrors then Print("Erreurs au chargement : %s", ns.loadErrors) end

  -- Un résumé par sort logique : l'ID retenu, ou l'état des candidats
  local requestedNow = ns.PreloadSpells()
  Print("Sorts référencés (%d demandes de chargement émises, retape /obr info dans quelques secondes si > 0) :", requestedNow)
  for _, group in ipairs(ns.AllSpellGroups(class)) do
    local id = ns.PickSpellID(group, true)
    if id then
      Print("  %s : ID %d, %s", ns.SpellName(id), id, ns.IsKnown(id) and "connu" or "inconnu")
    else
      local existing = {}
      for _, cand in ipairs(group) do
        if ns.SpellExists(cand) ~= false then table.insert(existing, tostring(cand)) end
      end
      Print("  aucun nom chargé pour %s (existent : %s)", table.concat(group, "/"),
        #existing > 0 and table.concat(existing, "/") or "aucun")
    end
  end
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Macro"
