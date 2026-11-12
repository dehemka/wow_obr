-- OneButtonRotation - Bouton autour de la minimap
-- Clic gauche : ouvre/ferme la fenêtre. Clic droit : crée/met à jour les macros.
-- Glisser : déplace le bouton le long du bord (angle mémorisé dans les SavedVariables).

local ADDON_NAME, ns = ...
local Print = ns.Print

local button
local ICON = 136118 -- Spell_Shadow_AbominationExplosion (Corruption)

local function Angle()
  return ns.db and ns.db.minimapAngle or 220
end

local function Position()
  if not button or not Minimap then return end
  local rad = math.rad(Angle())
  local radius = (Minimap:GetWidth() or 140) / 2 + 10
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(rad) * radius, math.sin(rad) * radius)
end

local function OnDragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  if not (mx and cx and scale) then return end
  cx, cy = cx / scale, cy / scale
  ns.db.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
  Position()
end

local function Tooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("One Button Rotation", 1, 1, 1)
  local ok, list, ctx = pcall(ns.BuildAll)
  if ok and list and ctx then
    GameTooltip:AddLine(string.format("%s niveau %d, phase « %s »%s", ctx.specLabel or "?", ctx.level or 0,
      (ctx.phase and ctx.phase.name) or "?", ctx.wand and ", baguette" or ""), 0.8, 0.8, 0.8)
  elseif ok and ctx then
    GameTooltip:AddLine(tostring(ctx), 1, 0.4, 0.4, true)
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Clic gauche : ouvrir la fenêtre", 0, 1, 0)
  GameTooltip:AddLine("Clic droit : créer / mettre à jour les macros", 0, 1, 0)
  GameTooltip:AddLine("Glisser : déplacer le bouton", 0, 1, 0)
  GameTooltip:Show()
end

local function Create()
  if button or not Minimap then return end
  button = CreateFrame("Button", "OneButtonRotationMinimapButton", Minimap)
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:SetMovable(true)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

  local overlay = button:CreateTexture(nil, "OVERLAY")
  overlay:SetSize(53, 53)
  overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  overlay:SetPoint("TOPLEFT")

  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", 7, -5)

  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
  icon:SetPoint("TOPLEFT", 7, -6)

  button:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then
      if InCombatLockdown() then Print("Impossible de modifier les macros en combat.") return end
      ns.BuildAndApply("bouton minimap")
    elseif ns.ToggleUI then
      ns.ToggleUI()
    end
  end)
  button:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", OnDragUpdate)
    GameTooltip:Hide()
  end)
  button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  button:SetScript("OnEnter", Tooltip)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  Position()
end

function ns.PositionMinimapButton() Position() end

function ns.SetMinimapButtonShown(show)
  ns.db.minimapHide = not show
  if show then
    Create()
    if button then button:Show() end
  elseif button then
    button:Hide()
  end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
  if ns.db and not ns.db.minimapHide and ns.Rotations[ns.PlayerClass()] then
    local ok, err = pcall(Create)
    if not ok then ns.loadErrors = (ns.loadErrors or "") .. "minimap : " .. tostring(err) .. " ; " end
  end
end)

ns.loadedFiles = (ns.loadedFiles or "") .. ", Minimap"
