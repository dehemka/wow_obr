-- OneButtonRotation - Anneau social
-- Roue de 8 phrases ouverte par /obr social (macro OBR_SOCIAL sur la barre manette).
-- Manette (disposition Xbox / Steam Deck) : stick gauche ou croix = choisir, A = envoyer,
-- B = fermer, LB/RB = canal, Y / LT / RT = page. Souris : clic sur une case, molette = canal.
-- Clavier : flèches, Entrée, Échap, Tab = page, PageUp/PageDown = canal, 1-8 = envoyer direct.

local ADDON_NAME, ns = ...
local Print = ns.Print

local wheel
local SLOTS = 8
local RADIUS = 122          -- distance centre -> centre des cases
local SLOT_SIZE = 58        -- diamètre d'une case (atlas du flyout manette, agrandi)
local ICON_SIZE = 42
local DISC = 2 * (RADIUS + 52) -- diamètre du camembert
local SLOT_W, SLOT_H = SLOT_SIZE + 40, SLOT_SIZE + 18 -- zone cliquable (case + libellé)

-- Direction artistique : atlas du menu radial du mode manette de Forever
-- (Blizzard_GamepadActionBars/FlyoutRadial.lua), avec repli si un atlas manque.
local ART = {
  base      = "gamepad-flyout-circular-base",
  slotBack  = "gamepad-flyout-circular-slot-backdrop",
  slotNorm  = "gamepad-flyout-circular-slot-normal",
  slotSel   = "gamepad-flyout-circular-slot-selected",
  slotGlow  = "gamepad-flyout-circular-slot-highlight",
  slotMask  = "gamepad-flyout-circular-slot-mask",
  indicator = "gamepad-flyout-selection-indicator",
  cursor    = "gamepad-largecursor",
  center    = "gamepad-actionbar-focus-bg-circ",
}
local function HasAtlas(name)
  return C_Texture and type(C_Texture.GetAtlasInfo) == "function" and C_Texture.GetAtlasInfo(name) ~= nil
end
-- Applique un atlas à la taille w×h ; h = "fit" garde le ratio de l'atlas pour une hauteur w.
local function SetArt(tex, atlas, w, h, fallbackColor)
  if HasAtlas(atlas) then
    tex:SetAtlas(atlas, false)
    if h == "fit" then
      local info = C_Texture.GetAtlasInfo(atlas)
      local ratio = (info and info.width and info.height and info.height > 0) and (info.width / info.height) or 1
      tex:SetSize(w * ratio, w)
    else
      tex:SetSize(w, h or w)
    end
    return true
  end
  if h == "fit" then h = w end
  tex:SetTexture("Interface\\Buttons\\WHITE8x8")
  tex:SetVertexColor(unpack(fallbackColor or { 0, 0, 0, 0.6 }))
  tex:SetSize(w, h or w)
  return false
end

local state = { page = 1, selected = 1, channel = 1 }

-------------------------------------------------------------------------------
-- Envoi
-------------------------------------------------------------------------------
local function CurrentChannel()
  local list = ns.SocialChannels
  return list[((state.channel - 1) % #list) + 1]
end

local function ResolveChatType(key)
  if key == "AUTO" then
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return "SAY"
  end
  if key == "REPLY" then
    local target = ChatEdit_GetLastTellTarget and ChatEdit_GetLastTellTarget()
    if target and target ~= "" then return "WHISPER", target end
    return nil, "personne à qui répondre"
  end
  if key == "PARTY" and not (IsInGroup and IsInGroup()) then return "SAY" end
  if key == "RAID" and not (IsInRaid and IsInRaid()) then
    return (IsInGroup and IsInGroup()) and "PARTY" or "SAY"
  end
  if key == "GUILD" and IsInGuild and not IsInGuild() then return nil, "pas de guilde" end
  return key
end

function ns.SocialSend(entry, channelKey)
  if not entry then return false, "aucune phrase" end
  if entry.emote then pcall(DoEmote, entry.emote) end
  if entry.text and entry.text ~= "" then
    local chatType, target = ResolveChatType(channelKey or CurrentChannel().key)
    if not chatType then return false, target end
    local text = entry.text
    if text:find("%%t") then
      local name = UnitExists and UnitExists("target") and UnitName("target") or nil
      if name then
        text = text:gsub("%%t", name)
      else -- pas de cible : on retire le nom et l'espace qui le précède (« Merci %t ! » -> « Merci ! »)
        text = text:gsub("%s*%%t", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
      end
    end
    local ok, err = pcall(SendChatMessage, text, chatType, nil, target)
    if not ok then return false, tostring(err) end
  end
  return true
end

-------------------------------------------------------------------------------
-- Fenêtre
-------------------------------------------------------------------------------
local function SlotAngle(i)
  -- Case 1 en haut, puis sens horaire
  return math.rad(90 - (i - 1) * (360 / SLOTS))
end

local function Refresh()
  if not wheel then return end
  local page = ns.SocialPhrases[state.page] or ns.SocialPhrases[1]
  for i, slot in ipairs(wheel.slots) do
    local entry = page[i]
    slot.entry = entry
    if entry then
      slot.label:SetText(entry.label)
      local icon = entry.icon and ("Interface\\Icons\\" .. entry.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
      if slot.icon:SetTexture(icon) == false then slot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark") end
      slot.icon:SetDesaturated(false)
      slot.label:SetAlpha(1)
      slot:Show()
    else
      slot:Hide()
    end
    local selected = (i == state.selected)
    slot.ring:SetShown(not selected)
    slot.ringSel:SetShown(selected)
    slot.glow:SetShown(selected)
    slot.label:SetFontObject(selected and "GameFontNormalLarge" or "GameFontHighlight")
    slot.icon:SetSize(selected and ICON_SIZE + 6 or ICON_SIZE, selected and ICON_SIZE + 6 or ICON_SIZE)
  end
  -- Part du camembert et curseur vers la case choisie
  local a = SlotAngle(state.selected)
  local clockwise = math.rad((state.selected - 1) * (360 / SLOTS))
  if wheel.indicator then wheel.indicator:SetRotation(math.pi - clockwise) end
  if wheel.cursor then
    wheel.cursor:ClearAllPoints()
    wheel.cursor:SetPoint("CENTER", wheel.disc, "CENTER", math.cos(a) * 74, math.sin(a) * 74)
    wheel.cursor:SetRotation(math.pi / 2 - clockwise)
  end
  local ch = CurrentChannel()
  local resolved = ResolveChatType(ch.key)
  local resolvedLabel = ""
  if ch.key == "AUTO" and resolved then
    for _, c in ipairs(ns.SocialChannels) do if c.key == resolved then resolvedLabel = "\n|cff9d9d9d" .. c.label .. "|r" end end
  end
  wheel.channel:SetText(ch.label .. resolvedLabel)
  wheel.page:SetText(string.format("%d / %d", state.page, #ns.SocialPhrases))
  local entry = wheel.slots[state.selected] and wheel.slots[state.selected].entry
  wheel.preview:SetText(entry and (entry.text or ("/" .. (entry.emote or ""):lower())) or "")
end

local function Close()
  if wheel then wheel:Hide() end
end

local function Send()
  local slot = wheel.slots[state.selected]
  local ok, why = ns.SocialSend(slot and slot.entry, CurrentChannel().key)
  if not ok then Print("Anneau social : %s", tostring(why)) end
  if ns.db.socialKeepOpen then Refresh() else Close() end
end

local function Move(delta)
  state.selected = ((state.selected - 1 + delta) % SLOTS) + 1
  Refresh()
end

local function ChangePage(delta)
  state.page = ((state.page - 1 + delta) % #ns.SocialPhrases) + 1
  Refresh()
end

local function ChangeChannel(delta)
  state.channel = ((state.channel - 1 + delta) % #ns.SocialChannels) + 1
  ns.db.socialChannel = ns.SocialChannels[state.channel].key
  Refresh()
end

local function SelectByAngle(x, y)
  -- x,y dans [-1,1] ; angle 0 = droite, sens trigo. Case 1 = haut, sens horaire.
  local deg = math.deg(math.atan2(y, x))
  local clockwiseFromTop = (90 - deg) % 360
  local idx = math.floor((clockwiseFromTop + (180 / SLOTS)) / (360 / SLOTS)) % SLOTS + 1
  if idx ~= state.selected then state.selected = idx; Refresh() end
end

-- Boutons manette (disposition Xbox : PAD1=A, PAD2=B, PAD3=X, PAD4=Y)
local PAD_ACTIONS = {
  PAD1 = Send, PAD2 = Close,
  PAD4 = function() ChangePage(1) end,
  PADLTRIGGER = function() ChangePage(-1) end, PADRTRIGGER = function() ChangePage(1) end,
  PADLSHOULDER = function() ChangeChannel(-1) end, PADRSHOULDER = function() ChangeChannel(1) end,
  PADDLEFT = function() Move(-1) end, PADDRIGHT = function() Move(1) end,
  PADDUP = function() Move(-1) end, PADDDOWN = function() Move(1) end,
  PADBACK = Close, PADFORWARD = Close, PADSYSTEM = Close, PADSOCIAL = Close,
}
local KEY_ACTIONS = {
  ENTER = Send, SPACE = Send, ESCAPE = Close,
  LEFT = function() Move(-1) end, UP = function() Move(-1) end,
  RIGHT = function() Move(1) end, DOWN = function() Move(1) end,
  TAB = function() ChangePage(1) end,
  PAGEUP = function() ChangeChannel(-1) end, PAGEDOWN = function() ChangeChannel(1) end,
}
for i = 1, SLOTS do
  KEY_ACTIONS[tostring(i)] = function() state.selected = i; Send() end
end

function ns.ResetSocialWheelPosition()
  if not wheel then return end
  wheel:ClearAllPoints()
  local pos = ns.db.socialPos
  if pos and pos.point then
    wheel:SetPoint(pos.point, UIParent, pos.relPoint or pos.point, pos.x or 0, pos.y or 0)
  else
    wheel:SetPoint("CENTER", 0, 40)
  end
end

-------------------------------------------------------------------------------
-- Liaison d'un bouton manette / d'une touche à l'anneau (Bindings.xml : OBR_SOCIAL_WHEEL)
-------------------------------------------------------------------------------
local BINDING_ACTION = "OBR_SOCIAL_WHEEL"
local IGNORED_KEYS = { LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true, UNKNOWN = true }
local capture

local function SaveBindingsSafe()
  if type(SaveBindings) == "function" then
    local set = (type(GetCurrentBindingSet) == "function" and GetCurrentBindingSet()) or 1
    pcall(SaveBindings, set)
  end
end

local function ApplyBinding(key)
  if InCombatLockdown() then return false, "impossible en combat" end
  local ok, res = pcall(SetBinding, key, BINDING_ACTION)
  if not ok or res == false then return false, "SetBinding a refusé « " .. tostring(key) .. " »" end
  SaveBindingsSafe()
  return true
end

local function StopCapture()
  if capture then capture:Hide() end
end

local function StartCapture()
  if not capture then
    capture = CreateFrame("Frame", "OneButtonRotationBindCapture", UIParent, "BackdropTemplate")
    capture:SetSize(420, 90)
    capture:SetPoint("CENTER", 0, 160)
    capture:SetFrameStrata("FULLSCREEN_DIALOG")
    capture:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
      insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    local text = capture:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    text:SetPoint("CENTER")
    text:SetWidth(380)
    text:SetText("Appuie sur le bouton de la manette (ou la touche) qui ouvrira l'anneau social.\nÉchap pour annuler.")
    capture:EnableKeyboard(true)
    if capture.EnableGamePadButton then capture:EnableGamePadButton(true) end
    pcall(capture.SetPropagateKeyboardInput, capture, false)
    local function OnInput(_, key)
      if key == "ESCAPE" then StopCapture(); Print("Liaison annulée.") return end
      if IGNORED_KEYS[key] then return end
      StopCapture()
      local ok, why = ApplyBinding(key)
      if ok then Print("Anneau social lié à %s. (/obr bind clear pour délier)", key)
      else Print("Liaison impossible : %s", tostring(why)) end
    end
    capture:SetScript("OnKeyDown", OnInput)
    capture:SetScript("OnGamePadButtonDown", OnInput)
  end
  capture:Show()
  if C_Timer and C_Timer.After then
    C_Timer.After(15, function() if capture:IsShown() then StopCapture(); Print("Liaison : délai dépassé.") end end)
  end
end

function ns.BindSocial(arg)
  arg = (arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local current = type(GetBindingKey) == "function" and GetBindingKey(BINDING_ACTION) or nil
  if arg == "" then
    Print("Anneau social actuellement lié à : %s", current or "rien")
    StartCapture()
  elseif arg:lower() == "clear" or arg:lower() == "aucun" then
    if InCombatLockdown() then Print("Impossible en combat.") return end
    if current then pcall(SetBinding, current); SaveBindingsSafe() end
    Print("Anneau social délié.")
  else
    local ok, why = ApplyBinding(arg:upper())
    if ok then Print("Anneau social lié à %s.", arg:upper()) else Print("Liaison impossible : %s", tostring(why)) end
  end
end

local function Create()
  wheel = CreateFrame("Frame", "OneButtonRotationSocialWheel", UIParent)
  wheel:SetSize(DISC + 16, DISC + 70)
  wheel:SetFrameStrata("DIALOG")
  wheel:SetMovable(true)
  wheel:SetClampedToScreen(true)
  wheel:RegisterForDrag("LeftButton")
  wheel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  wheel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    ns.db.socialPos = { point = point, relPoint = relPoint, x = x, y = y }
  end)
  ns.ResetSocialWheelPosition()
  wheel:SetScale(tonumber(ns.db.socialScale) or 1)
  wheel:EnableMouse(true)
  wheel:EnableMouseWheel(true)
  wheel:SetScript("OnMouseWheel", function(_, delta) ChangeChannel(delta > 0 and -1 or 1) end)
  wheel:Hide()

  -- Entrées clavier et manette : la roue est modale tant qu'elle est ouverte
  wheel:EnableKeyboard(true)
  if wheel.EnableGamePadButton then wheel:EnableGamePadButton(true) end
  if wheel.EnableGamePadStick then wheel:EnableGamePadStick(true) end
  pcall(wheel.SetPropagateKeyboardInput, wheel, false)
  wheel:SetScript("OnKeyDown", function(_, key)
    local action = KEY_ACTIONS[key]
    if action then action() end
  end)
  wheel:SetScript("OnGamePadButtonDown", function(_, button)
    local action = PAD_ACTIONS[button]
    if action then action() end
  end)
  wheel:SetScript("OnGamePadStick", function(_, stick, x, y, len)
    if stick == "Left" and len and len > 0.5 then SelectByAngle(x, y) end
  end)

  -- Le camembert : disque de fond (atlas du flyout manette), ombre, part sélectionnée, séparateurs
  local disc = CreateFrame("Frame", nil, wheel)
  disc:SetSize(DISC, DISC)
  disc:SetPoint("TOP", 0, -8)
  wheel.disc = disc
  local shadow = disc:CreateTexture(nil, "BACKGROUND", nil, -2)
  shadow:SetPoint("CENTER")
  SetArt(shadow, "gamepad-actionbar-circleslot-dropshadow", DISC + 40, nil, { 0, 0, 0, 0 })
  local base = disc:CreateTexture(nil, "BACKGROUND", nil, -1)
  base:SetPoint("CENTER")
  if not SetArt(base, ART.base, DISC) then
    -- Repli : disque sombre dessiné avec un masque circulaire
    base:SetVertexColor(0.07, 0.07, 0.09, 0.92)
    if disc.CreateMaskTexture then
      local mask = disc:CreateMaskTexture()
      mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      mask:SetAllPoints(base)
      base:AddMaskTexture(mask)
    end
  end
  local indicator = disc:CreateTexture(nil, "BACKGROUND", nil, 0)
  indicator:SetPoint("CENTER")
  if SetArt(indicator, ART.indicator, DISC * 0.94, "fit", { 1, 0.82, 0.3, 0 }) then
    indicator:SetAlpha(0.9)
  else
    indicator:Hide()
  end
  wheel.indicator = indicator
  -- Séparateurs entre les parts (lignes fines dorées, tournées)
  for i = 1, SLOTS do
    local line = disc:CreateTexture(nil, "BORDER")
    line:SetTexture("Interface\\Buttons\\WHITE8x8")
    line:SetVertexColor(1, 0.85, 0.5, 0.22)
    local inner, outer = 62, DISC / 2 - 10
    line:SetSize(2, outer - inner)
    local a = math.rad(90 - (i - 1) * (360 / SLOTS) - 180 / SLOTS)
    local mid = (inner + outer) / 2
    line:SetPoint("CENTER", disc, "CENTER", math.cos(a) * mid, math.sin(a) * mid)
    line:SetRotation(a - math.pi / 2)
  end
  -- Moyeu : canal et page
  local hub = disc:CreateTexture(nil, "BORDER", nil, 1)
  hub:SetPoint("CENTER")
  SetArt(hub, ART.center, 118, nil, { 0.1, 0.1, 0.12, 0.95 })
  local title = disc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  title:SetPoint("CENTER", 0, 36)
  title:SetText("CANAL")
  wheel.channel = disc:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  wheel.channel:SetPoint("CENTER", 0, 4)
  wheel.channel:SetJustifyH("CENTER")
  wheel.page = disc:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  wheel.page:SetPoint("CENTER", 0, -34)
  local center = CreateFrame("Button", nil, disc)
  center:SetSize(110, 110)
  center:SetPoint("CENTER")
  center:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  center:SetScript("OnClick", function(_, mouse) ChangeChannel(mouse == "RightButton" and -1 or 1) end)
  local cursor = disc:CreateTexture(nil, "OVERLAY", nil, 2)
  if SetArt(cursor, ART.cursor, 30, "fit", { 1, 1, 1, 0 }) then wheel.cursor = cursor else cursor:Hide() end

  -- Les 8 cases : cercle (atlas), icône masquée en rond, libellé en dessous
  wheel.slots = {}
  for i = 1, SLOTS do
    local slot = CreateFrame("Button", nil, disc)
    slot:SetSize(SLOT_W, SLOT_H)
    local a = SlotAngle(i)
    slot:SetPoint("CENTER", disc, "CENTER", math.cos(a) * RADIUS, math.sin(a) * RADIUS + 8)
    local back = slot:CreateTexture(nil, "ARTWORK", nil, 0)
    back:SetPoint("TOP", 0, 0)
    SetArt(back, ART.slotBack, SLOT_SIZE + 8, nil, { 0, 0, 0, 0.5 })
    slot.icon = slot:CreateTexture(nil, "ARTWORK", nil, 1)
    slot.icon:SetPoint("CENTER", back, "CENTER")
    slot.icon:SetSize(ICON_SIZE, ICON_SIZE)
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if slot.CreateMaskTexture then
      local mask = slot:CreateMaskTexture()
      if HasAtlas(ART.slotMask) then mask:SetAtlas(ART.slotMask) else
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
      end
      mask:SetPoint("CENTER", back, "CENTER")
      mask:SetSize(ICON_SIZE + 6, ICON_SIZE + 6)
      slot.icon:AddMaskTexture(mask)
    end
    slot.ring = slot:CreateTexture(nil, "ARTWORK", nil, 2)
    slot.ring:SetPoint("CENTER", back, "CENTER")
    SetArt(slot.ring, ART.slotNorm, SLOT_SIZE, nil, { 0.3, 0.3, 0.3, 0 })
    slot.ringSel = slot:CreateTexture(nil, "ARTWORK", nil, 2)
    slot.ringSel:SetPoint("CENTER", back, "CENTER")
    SetArt(slot.ringSel, ART.slotSel, SLOT_SIZE, nil, { 1, 0.82, 0.3, 0.35 })
    slot.glow = slot:CreateTexture(nil, "OVERLAY", nil, 1)
    slot.glow:SetPoint("CENTER", back, "CENTER")
    SetArt(slot.glow, ART.slotGlow, SLOT_SIZE + 14, nil, { 1, 0.82, 0.3, 0.25 })
    slot.label = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    slot.label:SetPoint("TOP", back, "BOTTOM", 0, 2)
    slot.label:SetWidth(SLOT_W)
    slot.label:SetJustifyH("CENTER")
    slot:SetScript("OnEnter", function() if state.selected ~= i then state.selected = i; Refresh() end end)
    slot:SetScript("OnClick", function() state.selected = i; Send() end)
    wheel.slots[i] = slot
  end

  -- Texte de la phrase choisie, puis aide, sous le camembert
  wheel.preview = wheel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  wheel.preview:SetPoint("TOP", disc, "BOTTOM", 0, -2)
  wheel.preview:SetWidth(DISC)
  wheel.preview:SetJustifyH("CENTER")
  local hint = wheel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOP", wheel.preview, "BOTTOM", 0, -4)
  hint:SetWidth(DISC + 10)
  hint:SetJustifyH("CENTER")
  hint:SetText("Stick : choisir   A : envoyer   B : fermer   LB/RB : canal   Y : page\n"
    .. "Souris : clic, molette = canal   Clavier : flèches, Entrée, Tab, Échap")

  wheel:SetScript("OnShow", Refresh)
end

function ns.SetSocialWheelScale(scale)
  scale = tonumber(scale)
  if not scale or scale < 0.5 or scale > 2 then return false end
  ns.db.socialScale = scale
  if wheel then wheel:SetScale(scale) end
  return true
end

function ns.ToggleSocialWheel(force)
  if not wheel then
    local ok, err = pcall(Create)
    if not ok then Print("Anneau social : création impossible (%s)", tostring(err)) return end
  end
  if force == "close" or (force == nil and wheel:IsShown()) then wheel:Hide() return end
  -- Canal mémorisé
  for i, c in ipairs(ns.SocialChannels) do
    if c.key == ns.db.socialChannel then state.channel = i end
  end
  state.selected = 1
  wheel:Show()
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", Social"
