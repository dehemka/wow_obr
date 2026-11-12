-- OneButtonRotation - Fenêtre principale : menu à gauche, pages à droite

local ADDON_NAME, ns = ...
local Print = ns.Print

local frame
local pages, menuButtons = {}, {}
local MENU = {
  { key = "rotation", label = "Rotation" },
  { key = "talents",  label = "Talents" },
  { key = "social",   label = "Anneau social" },
  { key = "options",  label = "Options" },
  { key = "help",     label = "Aide" },
}
local MENU_WIDTH = 140

local function Tooltip(widget, text)
  widget:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(text, 1, 1, 1, 1, true)
    GameTooltip:Show()
  end)
  widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Button(parent, label, w, h, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, h or 24)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function Label(parent, text, template)
  local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
  fs:SetText(text)
  return fs
end

local function CheckBox(parent, label, key, tooltip, onChange)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb.text = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  cb.text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  cb.text:SetText(label)
  cb.dbKey = key
  cb:SetScript("OnClick", function(self)
    local checked = self:GetChecked() and true or false
    if onChange then onChange(checked) else ns.db[key] = checked end
    ns.RefreshUI()
  end)
  if tooltip then Tooltip(cb, tooltip) end
  return cb
end

local function SlotBox(parent, anchor, key, label)
  local fs = Label(parent, label, "GameFontHighlight")
  fs:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(36, 20)
  box:SetPoint("LEFT", fs, "RIGHT", 8, 0)
  box:SetAutoFocus(false)
  box:SetNumeric(true)
  box:SetMaxLetters(3)
  box.dbKey = key
  box:SetScript("OnEnterPressed", function(self)
    local n = tonumber(self:GetText())
    ns.db[key] = (n and n > 0) and n or nil
    self:ClearFocus()
    ns.RefreshUI()
  end)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  return box
end

-- Zone de texte défilante en lecture seule
local function ScrollText(parent, fontObject)
  local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
  local child = CreateFrame("Frame", nil, scroll)
  child:SetSize(10, 10)
  local text = child:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlight")
  text:SetPoint("TOPLEFT")
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetSpacing(3)
  scroll:SetScrollChild(child)
  scroll.child, scroll.text = child, text
  scroll:SetScript("OnSizeChanged", function(self, w)
    child:SetWidth(w)
    text:SetWidth(w)
    child:SetHeight(math.max(10, text:GetStringHeight() + 10))
  end)
  function scroll:SetContent(s)
    text:SetText(s)
    child:SetHeight(math.max(10, text:GetStringHeight() + 10))
  end
  return scroll
end

-------------------------------------------------------------------------------
-- Pages
-------------------------------------------------------------------------------
local function NewPage(key)
  local p = CreateFrame("Frame", nil, frame)
  p:SetPoint("TOPLEFT", MENU_WIDTH + 14, -30)
  p:SetPoint("BOTTOMRIGHT", -10, 10)
  p:Hide()
  pages[key] = p
  return p
end

local function BuildRotationPage()
  local p = NewPage("rotation")
  local status = Label(p, "", "GameFontHighlight")
  status:SetPoint("TOPLEFT", 4, -4)
  status:SetPoint("RIGHT", -4, 0)
  status:SetJustifyH("LEFT")
  status:SetHeight(32)
  p.status = status

  local specLabel = Label(p, "Spécialisation :")
  specLabel:SetPoint("TOPLEFT", 4, -44)
  p.specButtons = {}
  local x = 4
  for i, s in ipairs(ns.SpecNames[ns.PlayerClass()] or {}) do
    local b = Button(p, s.label, 118, 22, function()
      ns.db.spec[ns.CharKey()] = s.key
      Print("Spé manuelle : %s", s.label)
      ns.RefreshUI()
    end)
    b:SetPoint("TOPLEFT", x, -60)
    b.specKey = s.key
    p.specButtons[i] = b
    x = x + 124
  end
  local autoBtn = Button(p, "Auto (talents)", 118, 22, function()
    ns.db.spec[ns.CharKey()] = nil
    ns.RefreshUI()
  end)
  autoBtn:SetPoint("TOPLEFT", 4, -86)
  Tooltip(autoBtn, "Détecte la spé d'après l'arbre où tu as le plus de points.")

  local go = Button(p, "Créer / mettre à jour les macros", 240, 22, function() ns.Refresh("fenêtre") end)
  go:SetPoint("TOPLEFT", 128, -86)

  local previewLabel = Label(p, "Aperçu des macros :")
  previewLabel:SetPoint("TOPLEFT", 4, -118)
  local helpBtn = Button(p, "À quoi servent-elles ?", 160, 20, function() ns.ToggleMacroHelp("open") end)
  helpBtn:SetPoint("TOPRIGHT", -4, -114)
  Tooltip(helpBtn, "Ouvre l'explication des macros dans une fenêtre à part, en grand.")

  local scroll = ScrollText(p, "ChatFontNormal")
  scroll:SetPoint("TOPLEFT", 4, -136)
  scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  p.preview = scroll
end

local function BuildTalentsPage()
  local p = NewPage("talents")
  if ns.CreateTalentsPanel then
    p.panel = ns.CreateTalentsPanel(p)
    p.panel:SetAllPoints(p)
  else
    Label(p, "Module talents non chargé.", "GameFontHighlight"):SetPoint("TOPLEFT", 4, -4)
  end
end

local function BuildSocialPage()
  local p = NewPage("social")
  local intro = Label(p, "Une roue de huit phrases rapides avec emote (bonjour, merci, oui, non…), pensée pour la manette. "
    .. "Elle s'ouvre avec un bouton lié ci-dessous, ou avec la macro OBR_SOCIAL.", "GameFontHighlight")
  intro:SetPoint("TOPLEFT", 4, -4)
  intro:SetPoint("RIGHT", -4, 0)
  intro:SetJustifyH("LEFT")
  intro:SetHeight(44)

  local open = Button(p, "Ouvrir l'anneau", 150, 24, function() if ns.ToggleSocialWheel then ns.ToggleSocialWheel("open") end end)
  open:SetPoint("TOPLEFT", 4, -56)
  local reset = Button(p, "Recentrer l'anneau", 150, 24, function()
    if ns.ResetSocialWheelPosition then ns.db.socialPos = nil; ns.ResetSocialWheelPosition(); Print("Anneau recentré.") end
  end)
  reset:SetPoint("LEFT", open, "RIGHT", 8, 0)
  Tooltip(reset, "L'anneau se déplace à la souris en le faisant glisser ; ce bouton le remet au centre.")

  local bind = Button(p, "Lier l'anneau à un bouton manette", 240, 24, function() if ns.BindSocial then ns.BindSocial("") end end)
  bind:SetPoint("TOPLEFT", 4, -88)
  Tooltip(bind, "Après le clic, appuie sur le bouton de la manette (ou la touche) qui ouvrira l'anneau.\n"
    .. "C'est un vrai raccourci (Options > Raccourcis > AddOns), pas une macro.")
  local unbind = Button(p, "Délier", 70, 24, function() if ns.BindSocial then ns.BindSocial("clear") end ns.RefreshUI() end)
  unbind:SetPoint("LEFT", bind, "RIGHT", 8, 0)
  local bindText = Label(p, "", "GameFontHighlight")
  bindText:SetPoint("TOPLEFT", 4, -118)
  bindText:SetPoint("RIGHT", -4, 0)
  bindText:SetJustifyH("LEFT")
  p.bindText = bindText

  p.checks = {
    CheckBox(p, "Créer la macro OBR_SOCIAL (/obr social)", "socialMacro",
      "Décoche si la macro t'encombre : le raccourci suffit.",
      function(v) ns.db.socialMacro = v; ns.Refresh("option social", true) end),
    CheckBox(p, "Garder l'anneau ouvert après un envoi", "socialKeepOpen"),
  }
  p.checks[1]:SetPoint("TOPLEFT", 0, -140)
  p.checks[2]:SetPoint("TOPLEFT", 0, -164)

  local slotLabel = Label(p, "Macro OBR_SOCIAL sur l'emplacement de barre :", "GameFontHighlight")
  slotLabel:SetPoint("TOPLEFT", 4, -198)
  local box = SlotBox(p, slotLabel, "actionSlotSocial", "")
  p.slotBoxes = { box }

  local controls = ScrollText(p, "GameFontHighlight")
  controls:SetPoint("TOPLEFT", 4, -226)
  controls:SetPoint("BOTTOMRIGHT", -26, 4)
  controls:SetContent(table.concat({
    "|cffffd100Manette (disposition Xbox)|r",
    "  Stick gauche ou croix : choisir une phrase",
    "  A : envoyer        B : fermer",
    "  LB / RB : canal (auto, dire, groupe, raid, guilde, crier, répondre)",
    "  Y, LT / RT : page suivante (2 pages de 8 phrases)",
    "",
    "|cffffd100Souris / clavier|r",
    "  Survol ou flèches, touches 1 à 8 : choisir   Entrée : envoyer   Échap : fermer",
    "  Molette ou clic au centre : canal   Tab : page",
    "",
    "|cffffd100Barre manette de Forever|r",
    "  Si l'écran d'assignation refuse la macro, l'addon peut la poser lui-même :",
    "  /obr pad   liste les boutons de la barre manette et leur contenu",
    "  /obr pad social <page> <barre> <bouton>   pose OBR_SOCIAL sur ce bouton",
    "",
    "Les phrases sont dans data/Social.lua (2 pages × 8, libres à modifier). %t = nom de la cible.",
  }, "\n"))
end

local function BuildOptionsPage()
  local p = NewPage("options")
  p.checks = {
    CheckBox(p, "Mise à jour automatique (level up, nouveau sort, talents)", "autoUpdate"),
    CheckBox(p, "N'inclure que les sorts présents dans le grimoire", "strict",
      "Décoche si l'addon ne détecte pas tes sorts : tous les sorts du palier de niveau seront inclus."),
    CheckBox(p, "Invoquer le familier s'il est absent (hors combat)", "summonPet",
      "Ajoute une ligne /cast [nopet,nocombat] Invocation ... à la macro."),
    CheckBox(p, "Affliction 10-29 : ajouter Immolation en 3e DoT", "immolate",
      "Hors guide Method : Immolation coûte du mana et 1,5 s de cast, mais ajoute un DoT. À toi de voir."),
    CheckBox(p, "Bouton autour de la minimap", "minimapHide",
      "Clic gauche : cette fenêtre. Clic droit : créer / mettre à jour les macros. Glisser : le déplacer.",
      function(v) if ns.SetMinimapButtonShown then ns.SetMinimapButtonShown(v) else ns.db.minimapHide = not v end end),
  }
  p.checks[5].inverted = true
  for i, cb in ipairs(p.checks) do cb:SetPoint("TOPLEFT", 0, -4 - (i - 1) * 26) end
  for _, cb in ipairs(p.checks) do
    if cb.dbKey ~= "minimapHide" then
      local key = cb.dbKey
      cb:SetScript("OnClick", function(self)
        ns.db[key] = self:GetChecked() and true or false
        if key ~= "autoUpdate" then ns.Refresh("option", true) end
        ns.RefreshUI()
      end)
    end
  end

  local slotTitle = Label(p, "Emplacements de barre (1 à 12 = barre principale, vide = ne pas poser)")
  slotTitle:SetPoint("TOPLEFT", 4, -144)
  local slotLabel = Label(p, "OBR", "GameFontHighlight")
  slotLabel:SetPoint("TOPLEFT", 4, -168)
  local b1 = SlotBox(p, slotLabel, "actionSlot", "")
  local b2 = SlotBox(p, b1, "actionSlotSustain", "VIE")
  local b3 = SlotBox(p, b2, "actionSlotSocial", "SOCIAL")
  p.slotBoxes = { b1, b2, b3 }

  local note = Label(p, "Ces emplacements sont ceux de la barre classique. Pour la barre manette de Forever, "
    .. "utilise /obr pad (page Aide).", "GameFontHighlightSmall")
  note:SetPoint("TOPLEFT", 4, -196)
  note:SetPoint("RIGHT", -4, 0)
  note:SetJustifyH("LEFT")
  note:SetHeight(40)

  local ver = Label(p, "Version " .. ns.VERSION .. "  –  /obr info pour le diagnostic", "GameFontDisableSmall")
  ver:SetPoint("BOTTOMLEFT", 4, 4)
end

local function BuildHelpPage()
  local p = NewPage("help")
  local big = Button(p, "Explication des macros (en grand)", 260, 24, function() ns.ToggleMacroHelp("open") end)
  big:SetPoint("TOPLEFT", 4, -4)
  local scroll = ScrollText(p, "GameFontHighlight")
  scroll:SetPoint("TOPLEFT", 4, -36)
  scroll:SetPoint("BOTTOMRIGHT", -26, 4)
  scroll:SetContent(table.concat({
    "|cffffd100Commandes|r",
    "/obr                   cette fenêtre",
    "/obr create            crée ou met à jour les macros",
    "/obr talents           ordre des talents et où tu en es",
    "/obr social            ouvre l'anneau social",
    "/obr bind              lie l'anneau à un bouton (appuie dessus ensuite)",
    "/obr pad               liste la barre manette ; /obr pad social 1 2 3 pose la macro",
    "/obr slot <n>, /obr slot vie <n>, /obr slot social <n>   pose les macros sur la barre",
    "/obr spec affli|demono|destru|auto",
    "/obr rangs             rang connu de chaque sort (penser au maître de classe)",
    "/obr immo on|off       Immolation en 3e DoT (hors guide)",
    "/obr minimap on|off|<angle>",
    "/obr find <texte>      cherche un sort dans le grimoire",
    "/obr info              diagnostic à copier en cas de problème",
    "",
    "|cffffd100Rappels|r",
    "Les rangs de sorts s'achètent chez le maître, en général tous les 2 niveaux : la macro lance",
    "toujours le rang le plus élevé connu.",
    "Le guide suivi est celui de Method (WoW Forever Warlock Leveling Guide).",
  }, "\n"))
end

-------------------------------------------------------------------------------
-- Popup d'aide des macros, en grand
-------------------------------------------------------------------------------
local help
local function CreateHelp()
  help = CreateFrame("Frame", "OneButtonRotationHelpFrame", UIParent, "BasicFrameTemplateWithInset")
  help:SetSize(640, 520)
  help:SetPoint("CENTER", 0, 40)
  help:SetMovable(true)
  help:EnableMouse(true)
  help:RegisterForDrag("LeftButton")
  help:SetScript("OnDragStart", help.StartMoving)
  help:SetScript("OnDragStop", help.StopMovingOrSizing)
  help:SetClampedToScreen(true)
  help:SetFrameStrata("DIALOG")
  help:Hide()
  tinsert(UISpecialFrames, "OneButtonRotationHelpFrame")
  help.TitleText:SetText("À quoi servent les macros")

  local scroll = ScrollText(help, "GameFontHighlight")
  scroll:SetPoint("TOPLEFT", 16, -34)
  scroll:SetPoint("BOTTOMRIGHT", -34, 44)
  help.scroll = scroll
  local fontPath = scroll.text:GetFont()
  function help:ApplyFont()
    local size = ns.db.helpFontSize or 18
    scroll.text:SetFont(fontPath, size, "")
    scroll.text:SetSpacing(math.floor(size / 3))
    scroll:SetContent(help.content or "")
  end

  local minus = Button(help, "A-", 50, 24, function()
    ns.db.helpFontSize = math.max(12, (ns.db.helpFontSize or 18) - 2); help:ApplyFont()
  end)
  minus:SetPoint("BOTTOMLEFT", 16, 12)
  local plus = Button(help, "A+", 50, 24, function()
    ns.db.helpFontSize = math.min(32, (ns.db.helpFontSize or 18) + 2); help:ApplyFont()
  end)
  plus:SetPoint("LEFT", minus, "RIGHT", 6, 0)
  local close = Button(help, "Fermer", 120, 24, function() help:Hide() end)
  close:SetPoint("BOTTOMRIGHT", -16, 12)
  help:SetScript("OnShow", function() ns.RefreshMacroHelp() end)
end

function ns.MacroHelpText()
  local list, ctxInfo = ns.BuildAll()
  if not list then return "Impossible de générer les macros : " .. tostring(ctxInfo) end
  local parts = {}
  table.insert(parts, string.format("|cff9d9d9d%s niveau %d, %s%s|r", UnitClass("player") or "", ctxInfo.level,
    ctxInfo.specLabel or "?", ctxInfo.wand and ", baguette équipée" or ""))
  for _, m in ipairs(list) do
    local d = m.def.desc
    if type(d) == "function" then
      local ok, text = pcall(d, ctxInfo)
      d = ok and text or nil
    end
    if d then table.insert(parts, string.format("|cffffd100%s|r\n%s", m.name, d)) end
    if m.body then table.insert(parts, "|cff9d9d9d" .. m.body .. "|r") end
  end
  table.insert(parts, "Glisse chaque macro depuis /macro sur ta barre, ou laisse l'addon le faire (page Options, ou /obr pad pour la barre manette).")
  return table.concat(parts, "\n\n")
end

function ns.RefreshMacroHelp()
  if not help or not help:IsShown() then return end
  help.content = ns.MacroHelpText()
  help:ApplyFont()
end

function ns.ToggleMacroHelp(force)
  if not help then CreateHelp() end
  if force == "close" or (help:IsShown() and force ~= "open") then help:Hide() else help:Show() end
end

-------------------------------------------------------------------------------
-- Fenêtre principale
-------------------------------------------------------------------------------
local function SelectPage(key)
  if not pages[key] then key = "rotation" end
  for k, p in pairs(pages) do if k == key then p:Show() else p:Hide() end end
  for _, b in ipairs(menuButtons) do
    if b.pageKey == key then b:LockHighlight() else b:UnlockHighlight() end
  end
  frame.currentPage = key
  ns.db.lastPage = key
  ns.RefreshUI()
end

local function CreateUI()
  frame = CreateFrame("Frame", "OneButtonRotationFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(600, 600)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame:Hide()
  tinsert(UISpecialFrames, "OneButtonRotationFrame") -- Échap ferme la fenêtre
  frame.TitleText:SetText("One Button Rotation v" .. ns.VERSION)

  -- Menu
  for i, item in ipairs(MENU) do
    local b = Button(frame, item.label, MENU_WIDTH - 16, 30, function() SelectPage(item.key) end)
    b:SetPoint("TOPLEFT", 12, -34 - (i - 1) * 34)
    b.pageKey = item.key
    b:SetNormalFontObject("GameFontNormalLarge")
    b:SetHighlightFontObject("GameFontHighlightLarge")
    b:SetDisabledFontObject("GameFontDisableLarge")
    menuButtons[i] = b
  end
  local sep = frame:CreateTexture(nil, "ARTWORK")
  sep:SetColorTexture(1, 1, 1, 0.15)
  sep:SetPoint("TOPLEFT", MENU_WIDTH + 4, -32)
  sep:SetPoint("BOTTOMLEFT", MENU_WIDTH + 4, 10)
  sep:SetWidth(1)

  local quick = Button(frame, "Créer / MAJ", MENU_WIDTH - 16, 26, function() ns.Refresh("fenêtre") end)
  quick:SetPoint("BOTTOMLEFT", 12, 12)
  Tooltip(quick, "Crée ou met à jour les trois macros maintenant.")

  BuildRotationPage()
  BuildTalentsPage()
  BuildSocialPage()
  BuildOptionsPage()
  BuildHelpPage()

  frame:SetScript("OnShow", function() SelectPage(frame.currentPage or ns.db.lastPage or "rotation") end)
end

function ns.RefreshUI()
  if not frame or not frame:IsShown() then return end
  local class, level = ns.PlayerClass(), ns.PlayerLevel()
  local spec, how = ns.CurrentSpec()
  local page = frame.currentPage or "rotation"

  if page == "rotation" then
    local p = pages.rotation
    local phase = spec and ns.CurrentPhase(class, spec, level)
    p.status:SetText(string.format("%s niveau %d  –  spé : %s (%s)\nPhase : %s  –  baguette : %s",
      UnitClass("player") or class or "?", level,
      spec and ns.SpecLabel(class, spec) or "|cffff4040non déterminée|r", tostring(how),
      phase and phase.name or "?", ns.HasWand() and "oui" or "non"))
    for _, b in ipairs(p.specButtons) do
      if b.specKey == spec then b:LockHighlight() else b:UnlockHighlight() end
    end
    local list, ctxInfo = ns.BuildAll()
    local blocks = {}
    if list then
      for _, m in ipairs(list) do
        if m.body then
          local text = string.format("|cffffd100-- %s (%d/255)|r\n%s", m.name, #m.body, m.body)
          if #m.info.skipped > 0 then
            local parts = {}
            for _, sk in ipairs(m.info.skipped) do table.insert(parts, sk[1] .. " (" .. sk[2] .. ")") end
            text = text .. "\n|cff9d9d9d-- ignorés : " .. table.concat(parts, ", ") .. "|r"
          end
          table.insert(blocks, text)
        else
          table.insert(blocks, string.format("|cffffd100-- %s|r : %s", m.name, tostring(m.reason)))
        end
      end
    else
      table.insert(blocks, "Impossible de générer : " .. tostring(ctxInfo))
    end
    p.preview:SetContent(table.concat(blocks, "\n\n"))
  elseif page == "talents" then
    if pages.talents.panel then pages.talents.panel:Refresh() end
  elseif page == "social" then
    local p = pages.social
    local key = type(GetBindingKey) == "function" and GetBindingKey("OBR_SOCIAL_WHEEL")
    p.bindText:SetText(key and ("Bouton lié : |cff40ff40" .. key .. "|r")
      or "|cffff8000Aucun bouton lié pour l'instant.|r")
    for _, cb in ipairs(p.checks) do cb:SetChecked(ns.db[cb.dbKey] and true or false) end
    for _, box in ipairs(p.slotBoxes) do
      if not box:HasFocus() then box:SetText(ns.db[box.dbKey] and tostring(ns.db[box.dbKey]) or "") end
    end
  elseif page == "options" then
    local p = pages.options
    for _, cb in ipairs(p.checks) do
      local v = ns.db[cb.dbKey] and true or false
      cb:SetChecked(cb.inverted and (not v) or (not cb.inverted and v))
    end
    for _, box in ipairs(p.slotBoxes) do
      if not box:HasFocus() then box:SetText(ns.db[box.dbKey] and tostring(ns.db[box.dbKey]) or "") end
    end
  end
  ns.RefreshMacroHelp()
end

-- Ouvre / ferme la fenêtre ; avec un nom de page, l'ouvre sur cette page
function ns.ToggleUI(page)
  if not frame then CreateUI() end
  if page then
    frame.currentPage = page
    if frame:IsShown() then SelectPage(page) else frame:Show() end
  elseif frame:IsShown() then
    frame:Hide()
  else
    frame:Show()
  end
end

ns.loadedFiles = (ns.loadedFiles or "") .. ", UI"
