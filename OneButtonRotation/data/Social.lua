-- OneButtonRotation - Phrases de l'anneau social
-- Chaque phrase : label (affiché), emote (jeton DoEmote, indépendant de la langue, optionnel),
-- text (envoyé dans le canal choisi, optionnel ; %t = nom de la cible),
-- icon (nom de fichier dans Interface\\Icons, optionnel : affiché dans la case de l'anneau).
-- Huit phrases par page, dans l'ordre des aiguilles d'une montre en partant du haut.

local ADDON_NAME, ns = ...

ns.SocialPhrases = {
  { -- Page 1 : l'essentiel
    { label = "Bonjour",  emote = "WAVE", icon = "Spell_Misc_EmotionHappy",         text = "Bonjour !" },
    { label = "Merci",    emote = "THANK", icon = "INV_Misc_Gift_01",        text = "Merci %t !" },
    { label = "Oui",      emote = "NOD", icon = "Spell_ChargePositive",          text = "Oui" },
    { label = "GG",       emote = "CONGRATULATE", icon = "Achievement_BG_winWSG", text = "GG !" },
    { label = "2 sec",    emote = "WAIT", icon = "INV_Misc_PocketWatch_01",         text = "2 secondes" },
    { label = "Pardon",   emote = "APOLOGIZE", icon = "Spell_Misc_EmotionSad",    text = "Pardon !" },
    { label = "Non",      emote = "NO", icon = "Spell_ChargeNegative",           text = "Non" },
    { label = "De rien",  emote = "WELCOME", icon = "Spell_Holy_HolyGuidance",      text = "De rien !" },
  },
  { -- Page 2 : groupe
    { label = "J'arrive", icon = "Ability_Rogue_Sprint",     text = "J'arrive" },
    { label = "Pull", icon = "Ability_Warrior_Charge",         text = "Pull !" },
    { label = "Besoin d'aide", emote = "HELPME", icon = "Spell_Holy_PrayerOfHealing02",  text = "Besoin d'aide !" },
    { label = "Plus de mana", emote = "OOM", icon = "INV_Potion_76",      text = "Plus de mana" },
    { label = "Pause", icon = "INV_Drink_05",        text = "Pause 5 min" },
    { label = "Attention", icon = "Spell_Misc_EmotionAfraid",    text = "Attention !" },
    { label = "Bien joué",    emote = "CHEER", icon = "INV_Misc_Horn_01",    text = "Bien joué !" },
    { label = "Au revoir",    emote = "BYE", icon = "Spell_Shadow_Teleport",      text = "Au revoir !" },
  },
}

-- Canaux proposés (LB/RB). AUTO = raid si en raid, groupe si groupé, sinon dire.
ns.SocialChannels = {
  { key = "AUTO",  label = "Auto" },
  { key = "SAY",   label = "Dire" },
  { key = "PARTY", label = "Groupe" },
  { key = "RAID",  label = "Raid" },
  { key = "GUILD", label = "Guilde" },
  { key = "YELL",  label = "Crier" },
  { key = "REPLY", label = "Répondre" },
}

-- Macro posée sur la barre : un bouton de la manette ouvre l'anneau.
ns.SocialMacroDef = {
  name = "OBR_SOCIAL", slotKey = "actionSlotSocial",
  lines = { "/obr social" }, noTooltip = true,
  icon = "Interface\\Icons\\INV_Misc_GroupNeedMore",
  desc = "L'anneau social : un appui ouvre une roue de phrases rapides (bonjour, merci, oui, non, GG…). "
    .. "Stick ou croix pour choisir, A pour envoyer, B pour fermer, LB/RB pour le canal, Y pour changer de page. "
    .. "Chaque phrase joue l'emote correspondante et envoie le texte dans le canal choisi.",
}

ns.loadedFiles = (ns.loadedFiles or "") .. ", Social(data)"
