-- OneButtonRotation - Core
-- Détection classe / niveau / spé, événements, commandes slash.

local ADDON_NAME, ns = ...
OBR = ns -- table globale pour le debug en jeu (/dump OBR)

-- La commande /obr est enregistrée en tout premier : si le reste du chargement échoue,
-- elle explique au moins ce qui s'est passé au lieu de « commande inconnue ».
SLASH_ONEBUTTONROTATION1 = "/obr"
SLASH_ONEBUTTONROTATION2 = "/onebutton"
SlashCmdList.ONEBUTTONROTATION = function(msg)
  if ns.HandleSlash then return ns.HandleSlash(msg) end
  local chat = DEFAULT_CHAT_FRAME or ChatFrame1
  chat:AddMessage("|cff9482c9OBR|r l'addon est chargé mais son initialisation a échoué (erreur Lua au chargement).")
  chat:AddMessage("|cff9482c9OBR|r Tape /console scriptErrors 1 puis /reload pour voir l'erreur, et envoie-la à l'auteur.")
  chat:AddMessage("|cff9482c9OBR|r Fichiers chargés : " .. tostring(ns.loadedFiles or "aucun"))
end
ns.loadedFiles = "Core(début)"

ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))
  or (GetAddOnMetadata and GetAddOnMetadata(ADDON_NAME, "Version")) or "dev"

ns.Rotations = ns.Rotations or {}      -- rempli par data/*.lua : ns.Rotations[CLASS][SPEC]
ns.SpecNames = ns.SpecNames or {}      -- ns.SpecNames[CLASS] = { {key=, label=, tab=, specIDs={...}}, ... }

-- Raccourcis (Bindings.xml) : visibles dans Options > Raccourcis > AddOns
BINDING_HEADER_ONEBUTTONROTATION = "One Button Rotation"
BINDING_NAME_OBR_SOCIAL_WHEEL = "Ouvrir / fermer l'anneau social"
BINDING_NAME_OBR_TOGGLE_UI = "Ouvrir / fermer la fenêtre OBR"
function OneButtonRotation_ToggleSocial() if ns.ToggleSocialWheel then ns.ToggleSocialWheel() end end
function OneButtonRotation_ToggleUI() if ns.ToggleUI then ns.ToggleUI() end end

local DEFAULTS = {
  autoUpdate = true,     -- regénérer la macro au level up / changement de spé
  strict = true,         -- n'inclure que les sorts présents dans le grimoire
  summonPet = false,     -- ajouter une ligne d'invocation du familier hors combat
  immolate = false,      -- Affliction 10-29 : ajouter Immolation en 3e DoT (hors guide Method)
  actionSlotSocial = nil, -- emplacement de barre de la macro OBR_SOCIAL
  socialMacro = true,    -- créer la macro OBR_SOCIAL (/obr social)
  socialChannel = "AUTO", -- dernier canal choisi dans l'anneau social
  socialKeepOpen = false, -- garder l'anneau ouvert après un envoi
  socialScale = 1,        -- échelle de l'anneau social (0.5 à 2)
  minimapHide = false,   -- bouton autour de la minimap
  minimapAngle = 220,    -- position du bouton (degrés, 0 = droite, sens trigonométrique)
  helpFontSize = 18,     -- taille de police du popup « À quoi servent les macros »
  lastPage = "rotation", -- dernière page ouverte dans la fenêtre
  macroName = "OBR",
  perCharacter = true,
  actionSlot = nil,         -- emplacement de barre de la macro de rotation (nil = ne pas poser)
  actionSlotSustain = nil,  -- emplacement de barre de la macro de sustain OBR_VIE
  spec = {},             -- spec choisie manuellement, par personnage : spec[charKey] = "AFFLICTION"
}

local PREFIX = "|cff9482c9OBR|r "
function ns.Print(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  local chat = DEFAULT_CHAT_FRAME or ChatFrame1
  chat:AddMessage(PREFIX .. msg)
end
local Print = ns.Print

-------------------------------------------------------------------------------
-- SavedVariables
-------------------------------------------------------------------------------
local function InitDB()
  OneButtonRotationDB = OneButtonRotationDB or {}
  for k, v in pairs(DEFAULTS) do
    if OneButtonRotationDB[k] == nil then
      OneButtonRotationDB[k] = (type(v) == "table") and {} or v
    end
  end
  ns.db = OneButtonRotationDB
end

function ns.CharKey()
  local name, realm = UnitName("player"), GetRealmName()
  return (name or "?") .. "-" .. (realm or "?")
end

-------------------------------------------------------------------------------
-- Détection
-------------------------------------------------------------------------------
function ns.PlayerClass()
  local _, token = UnitClass("player")
  return token
end

function ns.PlayerLevel()
  return UnitLevel("player") or 1
end

-- Retourne la clé de spé détectée via les talents, ou nil si indétectable.
-- Plusieurs API sont tentées car on ne sait pas à l'avance laquelle le client expose :
--  1) C_SpecializationInfo.GetSpecializationInfo(i) : c'est ce que Forever (client
--     moderne, arbres Classic) utilise ; le 7e retour est le nombre de points dépensés.
--  2) GetTalentTabInfo(i) : arbres Classic sur anciens clients.
--  3) GetSpecialization() : spécialisation Retail.
local function MatchSpec(specs, tab, specID, name)
  for _, s in ipairs(specs) do
    if specID and s.specIDs then
      for _, id in ipairs(s.specIDs) do if id == specID then return s.key end end
    end
  end
  if name then
    for _, s in ipairs(specs) do
      if s.label:lower() == tostring(name):lower() then return s.key end
    end
  end
  for _, s in ipairs(specs) do
    if tab and s.tab == tab then return s.key end
  end
  return nil
end

-- Points dépensés par arbre : { {tab=, points=, specID=, name=}, ... } ou nil
function ns.TalentTrees()
  local trees = {}
  local CSI = C_SpecializationInfo
  if CSI and type(CSI.GetSpecializationInfo) == "function" then
    local group = 1
    if type(CSI.GetActiveSpecGroup) == "function" then
      local ok, g = pcall(CSI.GetActiveSpecGroup, false, false)
      if ok and type(g) == "number" then group = g end
    end
    local numTabs = 3
    if type(CSI.GetNumSpecializationsForClassID) == "function" then
      local _, _, classID = UnitClass("player")
      local ok, n = pcall(CSI.GetNumSpecializationsForClassID, classID)
      if ok and type(n) == "number" and n > 0 then numTabs = n end
    end
    for tab = 1, numTabs do
      local ok, specID, name, _, _, _, _, pointsSpent = pcall(CSI.GetSpecializationInfo, tab, false, false, nil, nil, group)
      if ok and (specID or name) then
        table.insert(trees, { tab = tab, points = tonumber(pointsSpent) or 0, specID = specID, name = name })
      end
    end
    if #trees > 0 then return trees, "C_SpecializationInfo" end
  end
  if type(GetTalentTabInfo) == "function" then
    local numTabs = (type(GetNumTalentTabs) == "function" and GetNumTalentTabs()) or 3
    for tab = 1, numTabs do
      local ok, a, b, c, d, e = pcall(GetTalentTabInfo, tab)
      if ok and a ~= nil then
        -- Classic Era : name, texture, pointsSpent, fileName
        -- Wrath/Cata   : id, name, description, icon, pointsSpent
        local points, name = 0, nil
        if type(a) == "table" then
          points, name = a.pointsSpent or 0, a.name
        elseif type(c) == "number" then
          points, name = c, a
        elseif type(e) == "number" then
          points, name = e, b
        end
        table.insert(trees, { tab = tab, points = points, name = name })
      end
    end
    if #trees > 0 then return trees, "GetTalentTabInfo" end
  end
  return nil
end

function ns.DetectSpec()
  local class = ns.PlayerClass()
  local specs = ns.SpecNames[class]
  if not specs then return nil, "classe non supportée" end

  -- 1) et 2) arbres de talents : l'arbre avec le plus de points gagne
  local trees, api = ns.TalentTrees()
  if trees then
    local best
    for _, t in ipairs(trees) do
      if t.points > 0 and (not best or t.points > best.points) then best = t end
    end
    if best then
      local key = MatchSpec(specs, best.tab, best.specID, best.name)
      if key then return key, string.format("talents, %d pts", best.points) end
      return nil, "arbre « " .. tostring(best.name) .. " » non reconnu"
    end
    -- Aucun point : on retombe sur le choix manuel (niveau < 10 par exemple)
  end

  -- 3) Spécialisation Retail
  local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
  local getSpecInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
  if not trees and type(getSpec) == "function" and type(getSpecInfo) == "function" then
    local ok, idx = pcall(getSpec)
    if ok and idx then
      local ok2, specID, name = pcall(getSpecInfo, idx)
      if ok2 and (specID or name) then
        local key = MatchSpec(specs, idx, specID, name)
        if key then return key, "spécialisation" end
      end
    end
  end

  return nil, trees and "aucun point de talent" or "API de talents introuvable"
end

-- Spé effective : détection, sinon choix manuel sauvegardé, sinon nil.
function ns.CurrentSpec()
  local detected, how = ns.DetectSpec()
  if detected then return detected, how end
  local manual = ns.db.spec[ns.CharKey()]
  if manual then return manual, "choix manuel" end
  return nil, how
end

function ns.SpecLabel(class, key)
  for _, s in ipairs(ns.SpecNames[class] or {}) do
    if s.key == key then return s.label end
  end
  return key or "?"
end

-- Accepte "affli", "demono", "destru", "1", "2", "3", ou la clé complète.
function ns.ResolveSpecKey(class, input)
  if not input then return nil end
  input = input:lower()
  for i, s in ipairs(ns.SpecNames[class] or {}) do
    local key, label = s.key:lower(), s.label:lower()
    if input == key or input == tostring(i) or key:find("^" .. input, 1, false) or label:find("^" .. input, 1, false) then
      return s.key
    end
    for _, alias in ipairs(s.aliases or {}) do
      if input == alias then return s.key end
    end
  end
  return nil
end

-------------------------------------------------------------------------------
-- Événements
-------------------------------------------------------------------------------
local frame = CreateFrame("Frame")
ns.frame = frame
local pendingRefresh = false

local function Refresh(reason, silent)
  if InCombatLockdown() then
    pendingRefresh = true
    if not silent then Print("En combat : la macro sera mise à jour à la fin du combat.") end
    return
  end
  ns.BuildAndApply(reason)
end
ns.Refresh = Refresh

for _, ev in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_LEVEL_UP", "PLAYER_REGEN_ENABLED", "LEARNED_SPELL_IN_TAB" }) do
  local ok, err = pcall(frame.RegisterEvent, frame, ev)
  if not ok then ns.loadErrors = (ns.loadErrors or "") .. ev .. " : " .. tostring(err) .. " ; " end
end
pcall(frame.RegisterEvent, frame, "PLAYER_TALENT_UPDATE")
pcall(frame.RegisterEvent, frame, "CHARACTER_POINTS_CHANGED")
pcall(frame.RegisterEvent, frame, "PLAYER_SPECIALIZATION_CHANGED")
pcall(frame.RegisterEvent, frame, "SPELLS_CHANGED")
pcall(frame.RegisterEvent, frame, "TRAIT_CONFIG_UPDATED")
pcall(frame.RegisterEvent, frame, "PLAYER_EQUIPMENT_CHANGED")
pcall(frame.RegisterEvent, frame, "SPELL_DATA_LOAD_RESULT")
pcall(frame.RegisterEvent, frame, "ACTIVE_COMBAT_CONFIG_CHANGED")
pcall(frame.RegisterEvent, frame, "ACTIVE_TALENT_GROUP_CHANGED")

local debounce
local function ScheduleAutoRefresh(reason)
  if not ns.db or not ns.db.autoUpdate then return end
  if not ns.Rotations[ns.PlayerClass()] then return end
  if debounce then return end
  debounce = true
  C_Timer.After(2, function()
    debounce = nil
    Refresh(reason, true)
  end)
end

frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
    InitDB()
  elseif event == "PLAYER_LOGIN" then
    local class = ns.PlayerClass()
    if ns.Rotations[class] then
      Print("v%s chargé. /obr pour ouvrir la fenêtre, /obr help pour l'aide.", ns.VERSION)
      ns.PreloadSpells()
      -- Première génération automatique si la macro n'existe pas encore
      C_Timer.After(5, function()
        if ns.db.autoUpdate and GetMacroIndexByName(ns.db.macroName) == 0 and ns.CurrentSpec() then
          Refresh("connexion")
        end
      end)
    else
      Print("v%s chargé, mais aucune rotation n'est définie pour la classe %s.", ns.VERSION, class or "?")
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if pendingRefresh then
      pendingRefresh = false
      Refresh("fin de combat")
    end
  elseif event == "PLAYER_LEVEL_UP" then
    ScheduleAutoRefresh("niveau " .. tostring(arg1))
    local lvl = tonumber(arg1)
    if lvl and lvl % 2 == 0 then
      Print("Niveau %d : de nouveaux rangs de sorts t'attendent peut-être chez le maître (/obr rangs pour vérifier).", lvl)
    end
    if lvl and lvl >= 10 and ns.TalentReminder then
      C_Timer.After(3, function() pcall(ns.TalentReminder) end)
    end
  elseif event == "SPELL_DATA_LOAD_RESULT" then
    -- Données d'un sort demandé par PreloadSpells arrivées : la macro peut changer
    if ns.loggedIn then ScheduleAutoRefresh("données de sorts") end
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    -- Baguette équipée ou retirée : la finition de la macro change
    if ns.loggedIn and arg1 == 18 then ScheduleAutoRefresh("équipement") end
  elseif event == "LEARNED_SPELL_IN_TAB" or event == "SPELLS_CHANGED" then
    -- Nouveau sort appris chez le maître : la rotation peut changer
    if ns.loggedIn then ScheduleAutoRefresh("nouveau sort") end
  elseif event == "PLAYER_TALENT_UPDATE" or event == "CHARACTER_POINTS_CHANGED" or event == "PLAYER_SPECIALIZATION_CHANGED"
      or event == "TRAIT_CONFIG_UPDATED" or event == "ACTIVE_COMBAT_CONFIG_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
    if ns.loggedIn then ScheduleAutoRefresh("talents") end
  end
  if event == "PLAYER_LOGIN" then
    C_Timer.After(10, function() ns.loggedIn = true end)
  end
end)

-------------------------------------------------------------------------------
-- Commandes
-------------------------------------------------------------------------------
local function Help()
  Print("Commandes :")
  Print("  /obr                 ouvre/ferme la fenêtre")
  Print("  /obr create          crée ou met à jour la macro maintenant")
  Print("  /obr spec <nom>      fixe la spé manuellement (ex: /obr spec affli)")
  Print("  /obr slot <n>        pose la macro OBR sur l'emplacement de barre n (0 = désactiver)")
  Print("  /obr slot vie <n>    idem pour la macro de sustain OBR_VIE")
  Print("  /obr slot social <n> idem pour la macro OBR_SOCIAL")
  Print("  /obr social          ouvre/ferme l'anneau social (phrases rapides + emotes) ; on|off = créer la macro ; keep = rester ouvert")
  Print("  /obr social scale <n> taille de l'anneau (0.5 à 2) ; /obr social reset le recentre")
  Print("  /obr auto on|off     mise à jour automatique au level up")
  Print("  /obr strict on|off   n'inclure que les sorts connus (off = tout inclure)")
  Print("  /obr pet on|off      ajouter l'invocation du familier hors combat")
  Print("  /obr immo on|off     Affliction 10-29 : ajouter Immolation en 3e DoT (Method ne le fait pas)")
  Print("  /obr minimap on|off  afficher ou cacher le bouton autour de la minimap ; /obr minimap <angle> pour le placer")
  Print("  /obr bind            lie l'anneau social à un bouton manette ou une touche (appuie dessus après la commande)")
  Print("  /obr bind <touche>   idem en direct, ex: /obr bind PADRSTICK ; /obr bind clear pour délier")
  Print("  /obr preview         affiche la macro sans la créer")
  Print("  /obr info            infos de debug (client, API, sorts connus)")
  Print("  /obr find <texte>    cherche dans ton grimoire les sorts dont le nom contient <texte> (donne leurs IDs)")
  Print("  /obr rangs           rang le plus élevé connu pour chaque sort de la macro (à comparer avec le maître)")
  Print("  /obr talents         ordre des points de talents niveau par niveau (guide Method) et où tu en es ; « chat » = résumé dans le chat")
  Print("  /obr aide            explication des macros dans une fenêtre à part, en grand (A+ / A-)")
  Print("  /obr pad             liste la barre manette de Forever ; /obr pad social <page> <barre> <bouton> y pose la macro")
end

function ns.HandleSlash(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = (cmd or ""):lower()
  local class = ns.PlayerClass()

  if cmd == "" then
    if ns.ToggleUI then ns.ToggleUI() else Help() end
  elseif cmd == "help" then
    Help()
  elseif cmd == "create" or cmd == "update" or cmd == "go" then
    Refresh("commande")
  elseif cmd == "preview" then
    local list, ctxInfo = ns.BuildAll()
    if not list then Print("Impossible : %s", tostring(ctxInfo)) return end
    Print("%s niveau %d, phase « %s »%s :", ctxInfo.specLabel, ctxInfo.level, ctxInfo.phase.name or "?", ctxInfo.wand and ", baguette équipée" or "")
    for _, m in ipairs(list) do
      if m.body then
        Print("Macro %s (%d/255 caractères) :", m.name, #m.body)
        for line in m.body:gmatch("[^\n]+") do Print("  %s", line) end
      else
        Print("Macro %s : %s", m.name, tostring(m.reason))
      end
    end
  elseif cmd == "spec" then
    if rest == "" or rest == "auto" then
      ns.db.spec[ns.CharKey()] = nil
      Print("Spé : détection automatique.")
    else
      local key = ns.ResolveSpecKey(class, rest)
      if not key then
        Print("Spé inconnue « %s ». Choix possibles :", rest)
        for _, s in ipairs(ns.SpecNames[class] or {}) do Print("  %s", s.label) end
        return
      end
      ns.db.spec[ns.CharKey()] = key
      Print("Spé manuelle : %s", ns.SpecLabel(class, key))
      local detected = ns.DetectSpec()
      if detected and detected ~= key then
        Print("Attention : tes talents indiquent %s, la détection automatique sera prioritaire.", ns.SpecLabel(class, detected))
      end
    end
    if ns.RefreshUI then ns.RefreshUI() end
  elseif cmd == "slot" then
    local key, label = "actionSlot", "OBR"
    local which, num = rest:match("^(%a+)%s+(%d+)$")
    if which then
      rest = num
      if which:lower() == "social" then key, label = "actionSlotSocial", "OBR_SOCIAL"
      else key, label = "actionSlotSustain", "OBR_VIE" end
    end
    local n = tonumber(rest)
    if not n then Print("Usage : /obr slot <1-120>, /obr slot vie <n>, /obr slot social <n> (0 pour désactiver)") return end
    ns.db[key] = (n > 0) and n or nil
    Print("Emplacement de barre de %s : %s", label, ns.db[key] and tostring(ns.db[key]) or "désactivé")
  elseif cmd == "auto" then
    ns.db.autoUpdate = (rest ~= "off" and rest ~= "0")
    Print("Mise à jour automatique : %s", ns.db.autoUpdate and "activée" or "désactivée")
  elseif cmd == "strict" then
    ns.db.strict = (rest ~= "off" and rest ~= "0")
    Print("Vérification du grimoire : %s", ns.db.strict and "activée" or "désactivée")
    ns.Refresh("option strict")
  elseif cmd == "pet" then
    ns.db.summonPet = (rest ~= "off" and rest ~= "0")
    Print("Invocation du familier dans la macro : %s", ns.db.summonPet and "activée" or "désactivée")
    ns.Refresh("option familier")
  elseif cmd == "immo" or cmd == "immolation" then
    ns.db.immolate = (rest ~= "off" and rest ~= "0")
    Print("Immolation en 3e DoT (Affliction 10-29) : %s", ns.db.immolate and "activée" or "désactivée")
    ns.Refresh("option Immolation")
  elseif cmd == "social" or cmd == "anneau" then
    local sub = rest:lower()
    if sub == "on" or sub == "off" then
      ns.db.socialMacro = (sub == "on")
      Print("Macro OBR_SOCIAL : %s", ns.db.socialMacro and "activée" or "désactivée")
      ns.Refresh("option social")
    elseif sub == "reset" or sub == "centre" then
      ns.db.socialPos = nil
      if ns.ResetSocialWheelPosition then ns.ResetSocialWheelPosition() end
      Print("Anneau social recentré.")
    elseif sub:match("^scale") or sub:match("^taille") then
      local n = tonumber(sub:match("[%d%.]+"))
      if ns.SetSocialWheelScale and ns.SetSocialWheelScale(n) then Print("Anneau social : échelle %.2f", n)
      else Print("Usage : /obr social scale <0.5 à 2>") end
    elseif sub == "keep" or sub == "garder" then
      ns.db.socialKeepOpen = not ns.db.socialKeepOpen
      Print("Anneau social : %s après un envoi", ns.db.socialKeepOpen and "reste ouvert" or "se ferme")
    elseif ns.ToggleSocialWheel then
      ns.ToggleSocialWheel(sub == "close" and "close" or nil)
    else
      Print("Anneau social non chargé (fichiers : %s)", tostring(ns.loadedFiles))
    end
  elseif cmd == "bind" or cmd == "lier" then
    if ns.BindSocial then ns.BindSocial(rest) else Print("Anneau social non chargé.") end
  elseif (cmd == "minimap" or cmd == "bouton") and tonumber(rest) then
    ns.db.minimapAngle = tonumber(rest)
    if ns.PositionMinimapButton then ns.PositionMinimapButton() end
    Print("Bouton minimap placé à %d° (0 = droite, 90 = haut, 180 = gauche, 270 = bas).", ns.db.minimapAngle)
  elseif cmd == "minimap" or cmd == "bouton" then
    local show = (rest ~= "off" and rest ~= "0")
    if ns.SetMinimapButtonShown then ns.SetMinimapButtonShown(show) else ns.db.minimapHide = not show end
    Print("Bouton minimap : %s", show and "affiché" or "caché")
  elseif cmd == "info" or cmd == "debug" then
    ns.DebugInfo()
  elseif cmd == "rangs" or cmd == "ranks" or cmd == "rang" then
    ns.RankReport()
  elseif cmd == "talents" or cmd == "talent" or cmd == "build" then
    if rest == "chat" or rest == "print" then
      if ns.TalentReport then ns.TalentReport() end
    elseif ns.ToggleUI then
      ns.ToggleUI("talents")
    else
      Print("Module talents non chargé (fichiers : %s)", tostring(ns.loadedFiles))
    end
  elseif cmd == "pad" or cmd == "manette" then
    if ns.HandlePadCommand then ns.HandlePadCommand(rest) else Print("Module manette non chargé.") end
  elseif cmd == "aide" or cmd == "macros" then
    if ns.ToggleMacroHelp then ns.ToggleMacroHelp() end
  elseif cmd == "options" or cmd == "social-page" then
    if ns.ToggleUI then ns.ToggleUI(cmd == "options" and "options" or "social") end
  elseif cmd == "find" or cmd == "spells" then
    local needle = rest:lower()
    local count = 0
    local ok = ns.ForEachSpellBookSpell(function(id, name, _, subtext)
      if needle == "" or name:lower():find(needle, 1, true) then
        count = count + 1
        Print("  %s%s : ID %d", name, subtext and (" (" .. subtext .. ")") or "", id)
      end
    end)
    if not ok then Print("Aucune API de grimoire disponible sur ce client.")
    elseif count == 0 then Print("Aucun sort contenant « %s » dans le grimoire.", rest)
    else Print("%d sort(s) trouvé(s).", count) end
  else
    Help()
  end
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Core(fin)"
