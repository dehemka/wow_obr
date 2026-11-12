-- OneButtonRotation - Barre d'actions manette (mode Gamepad de Forever)
--
-- Le mode manette de Forever range ses actions dans des emplacements de stockage séparés
-- de la barre classique : C_GamepadUI.GetFirstGamepadActionStorageSlotIndex() donne le
-- premier, puis 3 pages standard de 4 barres de 8 boutons (Blizzard_GamepadActionBars).
-- PlaceAction(index) fonctionne sur ces emplacements, c'est ce que fait l'écran
-- d'assignation de Blizzard (GamepadActionBarBindingUtil.AssignActionToGamepadStandardSlot).

local _, ns = ...
local Print = ns.Print

local function Const(name, default)
  local c = Constants and Constants.GamepadActionBarConstants
  local v = c and c[name]
  return type(v) == "number" and v or default
end

-- Géométrie de la barre manette, ou nil si ce client n'en a pas
function ns.GamepadBarLayout()
  local api = C_GamepadUI
  if not api or type(api.GetFirstGamepadActionStorageSlotIndex) ~= "function" then return nil end
  local ok, first = pcall(api.GetFirstGamepadActionStorageSlotIndex)
  if not ok or type(first) ~= "number" then return nil end
  local perBar = Const("NUM_SLOTS_PER_GAMEPAD_ACTION_BAR", 8)
  local bars = Const("NUM_PAGEABLE_BARS_IN_GAMEPAD_ACTION_BAR_PAGE_UNIT", 4)
  return {
    first = first,
    perBar = perBar,
    bars = bars,
    perPage = Const("NUM_PAGEABLE_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT_STANDARD_PAGE", perBar * bars),
    pages = Const("NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT", 3),
  }
end

-- Index de stockage d'un bouton : page 1..3, barre 1..4, bouton 1..8
function ns.GamepadStorageIndex(page, bar, button)
  local L = ns.GamepadBarLayout()
  if not L then return nil, "pas de barre manette sur ce client" end
  if not (page and bar and button) or page < 1 or page > L.pages or bar < 1 or bar > L.bars or button < 1 or button > L.perBar then
    return nil, string.format("page 1-%d, barre 1-%d, bouton 1-%d", L.pages, L.bars, L.perBar)
  end
  local index = L.first + (page - 1) * L.perPage + (bar - 1) * L.perBar + (button - 1)
  if C_GamepadUI.IsValidGamepadActionStorageSlotIndex then
    local ok, valid = pcall(C_GamepadUI.IsValidGamepadActionStorageSlotIndex, index)
    if ok and valid == false then return nil, "emplacement refusé par le client" end
  end
  return index
end

-- Nom lisible du contenu d'un emplacement d'action
function ns.ActionSlotLabel(slot)
  local ok, actionType, id, subType = pcall(GetActionInfo, slot)
  if not ok or not actionType then return nil end
  if actionType == "spell" then return (ns.SpellName(id) or ("sort " .. tostring(id))) end
  if actionType == "macro" then local name = GetMacroInfo(id); return "macro " .. tostring(name or id) end
  if actionType == "item" then
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
    return "objet " .. tostring(name or id)
  end
  return actionType .. " " .. tostring(id)
end

-- Liste le contenu de la barre manette dans le chat (page donnée ou toutes)
function ns.GamepadBarReport(onlyPage)
  local L = ns.GamepadBarLayout()
  if not L then Print("Barre manette : API introuvable sur ce client (C_GamepadUI).") return end
  Print("Barre manette : %d pages de %d barres de %d boutons (premier index %d).", L.pages, L.bars, L.perBar, L.first)
  for page = 1, L.pages do
    if not onlyPage or onlyPage == page then
      local used, empties = {}, 0
      for bar = 1, L.bars do
        for button = 1, L.perBar do
          local index = ns.GamepadStorageIndex(page, bar, button)
          local label = index and ns.ActionSlotLabel(index)
          if label then table.insert(used, string.format("  page %d, barre %d, bouton %d : %s", page, bar, button, label))
          else empties = empties + 1 end
        end
      end
      Print("Page %d : %d emplacement(s) utilisé(s), %d libre(s)", page, #used, empties)
      for _, line in ipairs(used) do Print(line) end
    end
  end
  Print("Pour y poser une macro : /obr pad <obr|vie|social> <page> <barre> <bouton>")
end

-- Pose une macro de l'addon sur un bouton de la barre manette
function ns.PlaceOnGamepadBar(macroName, page, bar, button)
  if InCombatLockdown() then Print("Impossible en combat.") return false end
  local macroIndex = GetMacroIndexByName(macroName)
  if not macroIndex or macroIndex == 0 then Print("La macro %s n'existe pas encore (/obr create).", macroName) return false end
  local index, why = ns.GamepadStorageIndex(page, bar, button)
  if not index then Print("Emplacement invalide : %s", why) return false end
  local before = ns.ActionSlotLabel(index)
  ClearCursor()
  PickupMacro(macroIndex)
  if not GetCursorInfo() then Print("Le client refuse de prendre la macro %s sur le curseur.", macroName) return false end
  PlaceAction(index)
  ClearCursor()
  local after = ns.ActionSlotLabel(index)
  if after == "macro " .. macroName then
    Print("Macro %s posée sur la barre manette : page %d, barre %d, bouton %d%s.", macroName, page, bar, button,
      before and (" (remplace " .. before .. ")") or "")
    return true
  end
  Print("Échec : l'emplacement contient %s.", tostring(after or "rien"))
  return false
end

-- Commande : /obr pad [<page>] | /obr pad <obr|vie|social|NOM> <page> <barre> <bouton>
function ns.HandlePadCommand(rest)
  local words = {}
  for w in (rest or ""):gmatch("%S+") do table.insert(words, w) end
  if #words <= 1 then
    ns.GamepadBarReport(tonumber(words[1]))
    return
  end
  local alias = { obr = ns.db.macroName or "OBR", vie = "OBR_VIE", social = "OBR_SOCIAL" }
  local name = alias[words[1]:lower()] or words[1]
  local page, bar, button = tonumber(words[2]), tonumber(words[3]), tonumber(words[4])
  if not (page and bar and button) then
    Print("Usage : /obr pad <obr|vie|social> <page> <barre> <bouton>  (/obr pad seul liste la barre)")
    return
  end
  ns.PlaceOnGamepadBar(name, page, bar, button)
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Gamepad"
