-- Faux environnement WoW minimal pour tester Core.lua / Macro.lua / data hors jeu
local M = { level = 4, class = "WARLOCK", known = {}, talentPoints = {0,0,0}, macros = {}, chat = {} }
_G.MOCK = M
local names = {
  [686]="Trait de l'ombre",[348]="Immolation",[172]="Corruption",[980]="Malédiction d'agonie",
  [18265]="Siphon de vie",[17877]="Brûlure de l'ombre",[17962]="Conflagration",
  [688]="Invocation d'un diablotin",[697]="Invocation d'un marcheur du Vide",[712]="Invocation d'une succube",
  [1454]="Connexion",[689]="Drain de vie",[5019]="Tir",[18220]="Pacte noir",
  -- talents (noms fictifs pour le test)
  [18174]="Suppression",[17810]="Corruption améliorée",[18182]="Connexion améliorée",[427712]="Pandémie",
  [17783]="Concentration gangrenée",[18094]="Tombée de la nuit",[1310949]="Malveillance",[17804]="Siphon d'âme",
  [18271]="Maîtrise de l'ombre",[403511]="Drains améliorés",[18769]="Puissance impie",[1225214]="Énergies démoniaques",
  [18731]="Vitalité gangrenée",[18827]="Plaie d'agonie améliorée",[18218]="Portée sinistre",
}
M.requested = {}
C_Spell = {
  GetSpellName = function(id) if M.unloaded and M.unloaded[id] then return nil end return names[id] end,
  DoesSpellExist = function(id) return names[id] ~= nil end,
  RequestLoadSpellData = function(id) M.requested[id] = true end,
}
C_AddOns = { GetAddOnMetadata = function() return "test" end }
C_Timer = { After = function(_, f) end }
function UnitClass() return "Démoniste", M.class, 9 end
function UnitLevel() return M.level end
function UnitName() return "Testeur" end
function GetRealmName() return "Forever" end
function InCombatLockdown() return false end
function IsPlayerSpell(id) return M.known[id] or false end
local treeNames = {"Affliction","Démonologie","Destruction"}
-- Talents pris : M.talents = { { tab=, name=, rank=, max= }, ... }
M.talents = {}
C_SpecializationInfo = {
  GetTalentInfo = function(q)
    if M.noTalentAPI then return nil end
    local list = {}
    for _, t in ipairs(M.talents) do if t.tab == q.specializationIndex then table.insert(list, t) end end
    local t = list[q.talentIndex]
    if not t then return nil end
    return { name = t.name, rank = t.rank, maxRank = t.max, spellID = t.id, tier = 1, column = 1 }
  end,
  GetActiveSpecGroup = function() return 1 end,
  GetNumSpecializationsForClassID = function() return 3 end,
  GetSpecializationInfo = function(i, isInspect, isPet, target, sex, group)
    return 100+i, treeNames[i], "desc", 123, "DAMAGER", 1, M.talentPoints[i], "bg", 0, true
  end,
}
M.wand = false
function GetInventoryItemID(unit, slot) if slot == 18 and M.wand then return 5208 end return nil end
C_Item = { GetItemInfoInstant = function(id) return id, "Arme", "Baguette", "INVTYPE_RANGEDRIGHT", 1, 2, 19 end }
-- Grimoire : liste optionnelle M.spellbook = { {id=, name=, sub=}, ... } ; sinon dérivée de M.known
M.subtext = {}
C_Spell.GetSpellSubtext = function(id) return M.subtext[id] end
local function spellbook()
  if M.spellbook then return M.spellbook end
  local t = {}
  for id in pairs(M.known) do table.insert(t, { id = id, name = names[id] or "?", sub = M.subtext[id] }) end
  table.sort(t, function(a, b) return a.id < b.id end)
  return t
end
Enum = { SpellBookSpellBank = { Player = 0 } }
C_SpellBook = {
  IsSpellKnown = function(id) return M.known[id] or false end,
  GetNumSpellBookSkillLines = function() return 1 end,
  GetSpellBookSkillLineInfo = function(i) return { itemIndexOffset = 0, numSpellBookItems = #spellbook() } end,
  GetSpellBookItemInfo = function(i, bank) local e = spellbook()[i]; return e and { spellID = e.id, name = e.name, itemType = 1, subName = e.sub } end,
}
Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 } }
function GetNumMacros() return 0, #M.macros end
function GetMacroIndexByName(n) for i,m in ipairs(M.macros) do if m.name==n then return i end end return 0 end
function GetMacroInfo(i) local m=M.macros[i]; return m.name, m.icon, m.body end
function CreateMacro(n, icon, body, pc) table.insert(M.macros,{name=n,icon=icon,body=body,pc=pc}); return #M.macros end
function EditMacro(i, n, icon, body) M.macros[i]={name=n,icon=icon,body=body} end
function GetBuildInfo() return "1.60.1","12345","Nov 8 2026",16001 end
function GetActionInfo() return nil end
-- Curseur et emplacements d'action (barre classique + barre manette)
M.actions, M.cursor = {}, nil
function GetActionInfo(slot) local a = M.actions[slot]; if a then return a[1], a[2] end return nil end
function ClearCursor() M.cursor = nil end
function PickupMacro(i) if M.macros[i] then M.cursor = { "macro", i } end end
function GetCursorInfo() if M.cursor then return M.cursor[1], M.cursor[2] end return nil end
function PlaceAction(slot) if M.cursor then local prev = M.actions[slot]; M.actions[slot] = M.cursor; M.cursor = prev end end
C_GamepadUI = {
  GetFirstGamepadActionStorageSlotIndex = function() return 1000 end,
  IsValidGamepadActionStorageSlotIndex = function(i) return i >= 1000 and i < 1000 + 96 end,
}
Constants.GamepadActionBarConstants = { NUM_SLOTS_PER_GAMEPAD_ACTION_BAR = 8, NUM_PAGEABLE_BARS_IN_GAMEPAD_ACTION_BAR_PAGE_UNIT = 4,
  NUM_PAGEABLE_SLOTS_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT_STANDARD_PAGE = 32, NUM_STANDARD_PAGES_PER_GAMEPAD_ACTION_BAR_PAGE_UNIT = 3 }
DEFAULT_CHAT_FRAME = { AddMessage = function(_, s) table.insert(M.chat, s); print("  [chat] "..s:gsub("|c%x%x%x%x%x%x%x%x",""):gsub("|r","")) end }
SlashCmdList = {}
UISpecialFrames = {}
function CreateFrame() local f = {} ; function f.RegisterEvent() end ; function f.SetScript(_,_,fn) f.onEvent = fn end ; return f end
function tinsert(t,v) table.insert(t,v) end

-- À lancer depuis la racine du dépôt : lua5.1 tests/run.lua
local DIR = ADDON_DIR or "OneButtonRotation/"
local function loadAddon(file)
  local fn = assert(loadfile(DIR .. file))
  return fn("OneButtonRotation", M.ns)
end
M.ns = {}
M.sent, M.emotes = {}, {}
function SendChatMessage(text, chatType, lang, target) table.insert(M.sent, { text = text, chatType = chatType, target = target }) end
function DoEmote(token) table.insert(M.emotes, token) end
M.inGroup, M.inRaid = false, false
function IsInGroup() return M.inGroup end
function IsInRaid() return M.inRaid end
function IsInGuild() return true end
function UnitExists(u) return u == "target" and M.target ~= nil end
local _UnitName = UnitName
function UnitName(u) if u == "target" then return M.target end return _UnitName(u) end
function ChatEdit_GetLastTellTarget() return M.lastTell end
loadAddon("Core.lua"); loadAddon("data/Warlock.lua"); loadAddon("data/Social.lua"); loadAddon("data/WarlockTalents.lua"); loadAddon("Macro.lua"); loadAddon("Social.lua"); loadAddon("Talents.lua"); loadAddon("Gamepad.lua")
M.ns.frame.onEvent(nil, "ADDON_LOADED", "OneButtonRotation")
return M
