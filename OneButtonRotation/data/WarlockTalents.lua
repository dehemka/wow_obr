-- OneButtonRotation - Démoniste : ordre des points de talents
-- D'après le guide Method « WoW Forever Warlock Leveling Guide & Talents » (nov. 2026),
-- section « Talent Point Order ». Seul le build Affliction (drain tank) y est détaillé
-- niveau par niveau ; les arbres Démonologie / Destruction ne sont donnés qu'en image.
--
-- Structure :
--   ns.TalentBuilds.WARLOCK.<SPE> = {
--     name   = "...", source = "...",
--     talents = { CLE = { id = <ID Wowhead Forever rang 1>, name = "<nom anglais, secours>", tree = 1|2|3, max = N }, ... },
--     order   = { { level = 10, talent = "CLE", rank = 1, note = "pourquoi (optionnel)" }, ... },
--   }
-- Le nom est résolu en jeu via C_Spell.GetSpellName(id) pour être comparé aux talents du personnage.

local _, ns = ...
ns.TalentBuilds = ns.TalentBuilds or {}
ns.TalentBuilds.WARLOCK = ns.TalentBuilds.WARLOCK or {}

local T = {
  SUPPRESSION   = { id = 18174,   name = "Suppression",            tree = 1, max = 5 },
  IMP_CORR      = { id = 17810,   name = "Improved Corruption",    tree = 1, max = 5 },
  IMP_LIFE_TAP  = { id = 18182,   name = "Improved Life Tap",      tree = 1, max = 2 },
  PANDEMIC      = { id = 427712,  name = "Pandemic",               tree = 1, max = 3 },
  FEL_CONC      = { id = 17783,   name = "Fel Concentration",      tree = 1, max = 3 },
  NIGHTFALL     = { id = 18094,   name = "Nightfall",              tree = 1, max = 2 },
  MALEVOLENCE   = { id = 1310949, name = "Malevolence",            tree = 1, max = 5 },
  SOUL_SIPHON   = { id = 17804,   name = "Soul Siphon",            tree = 1, max = 3 },
  SHADOW_MAST   = { id = 18271,   name = "Shadow Mastery",         tree = 1, max = 5 },
  SIPHON_LIFE   = { id = 18265,   name = "Siphon Life",            tree = 1, max = 1 },
  IMP_DRAINS    = { id = 403511,  name = "Improved Drains",        tree = 1, max = 3 },
  UNHOLY_POWER  = { id = 18769,   name = "Unholy Power",           tree = 2, max = 5 },
  DEMON_ENERG   = { id = 1225214, name = "Demonic Energies",       tree = 2, max = 2 },
  FEL_VITALITY  = { id = 18731,   name = "Fel Vitality",           tree = 2, max = 3 },
  IMP_AGONY     = { id = 18827,   name = "Improved Bane of Agony", tree = 1, max = 2 },
  GRIM_REACH    = { id = 18218,   name = "Grim Reach",             tree = 1, max = 2 },
}

-- Construit la liste niveau par niveau à partir de blocs { talent, nbPoints, note }
local function Order(blocks)
  local order, level, ranks = {}, 10, {}
  for _, b in ipairs(blocks) do
    for i = 1, b[2] do
      ranks[b[1]] = (ranks[b[1]] or 0) + 1
      table.insert(order, { level = level, talent = b[1], rank = ranks[b[1]], note = (i == 1) and b[3] or nil })
      level = level + 1
    end
  end
  return order
end

ns.TalentBuilds.WARLOCK.AFFLICTION = {
  name = "Affliction drain tank (Method)",
  source = "Guide Method « WoW Forever Warlock Leveling Guide », Talent Point Order",
  talents = T,
  order = Order({
    { "SUPPRESSION",  4, "4 points : plus aucun raté sur les monstres de ton niveau." },
    { "IMP_CORR",     5, "Corruption devient instantanée et tape plus fort." },
    { "IMP_LIFE_TAP", 1, "Connexion rend plus de mana." },
    { "PANDEMIC",     3, "Les DoTs critiquent sur Forever : dégâts critiques de 50 % à 100 %." },
    { "FEL_CONC",     3, "Drains repoussés 70 % moins souvent : début du drain tank confortable." },
    { "NIGHTFALL",    2, "Corruption et Drain de vie peuvent rendre Trait de l'ombre instantané." },
    { "MALEVOLENCE",  2, "2 points pour débloquer la ligne suivante." },
    { "SOUL_SIPHON",  3, "Renforce Drain de vie pour le drain tank." },
    { "MALEVOLENCE",  2, "2 points de plus pour atteindre Maîtrise de l'ombre." },
    { "SHADOW_MAST",  5, "+ dégâts d'ombre, 5 points." },
    { "MALEVOLENCE",  1, "On complète Malevolence." },
    { "SIPHON_LIFE",  1, "Siphon de vie : l'addon l'ajoute à la macro drain tank." },
    { "IMP_LIFE_TAP", 1, "Deuxième point de Connexion améliorée." },
    { "IMP_DRAINS",   3, "Encore du drain tank." },
    { "UNHOLY_POWER", 5, "Arbre Démonologie à partir du niveau 46 : la succube tape plus fort." },
    { "DEMON_ENERG",  2, "Démonologie." },
    { "FEL_VITALITY", 3, "Démonologie, dernier bloc." },
    { "IMP_AGONY",    2, "Retour en Affliction pour les 5 derniers points." },
    { "GRIM_REACH",   2, "Portée des sorts d'Affliction." },
    { "SUPPRESSION",  1, "Dernier point au niveau 60." },
  }),
}
