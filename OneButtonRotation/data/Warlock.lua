-- OneButtonRotation - Démoniste
-- Rotations de leveling solo d'après le guide Method « WoW Forever Warlock Leveling
-- Guide & Talents » (Roguery, 8 nov. 2026), complété par la pratique Vanilla.
--
-- IDs de sorts = rang 1 (Vanilla). Le nom est résolu en jeu dans la langue du client,
-- ce qui suit les renommages de Forever (Malédiction d'agonie -> Plaie d'agonie).
--
-- Structure :
--   ns.Rotations.WARLOCK.<SPE>.phases = { { minLevel=, name=, macros={ macroDef, ... } }, ... }
--   L'addon prend la phase la plus haute dont minLevel <= niveau du joueur.
--
--   macroDef = {
--     name       = "OBR",            -- nom de la macro en jeu (16 caractères max)
--     slotKey    = "actionSlot",     -- clé d'option pour l'emplacement de barre
--     lines      = { ... },          -- lignes avant le /castsequence
--     sequence   = { entry, ... },   -- sorts d'ouverture
--     filler     = entry,            -- sort répété fillerCount fois en fin de séquence
--     fillerCount = 4,
--     reset      = "target/combat",  -- conditions de reset du castsequence
--     conditions = "[nochanneling]", -- conditions de macro devant le castsequence
--     after      = { ... },          -- lignes après le /castsequence
--   }
--   Une ligne est une chaîne, ou { text = "...", <conditions> }, ou
--   { fmt = "/cast %s", args = { entry, ... }, <conditions> } (ligne retirée si un arg est inconnu).
--   entry = { id = N | ids = { N, ... } | alt = { entry, ... }, minLevel=, maxLevel=, talent=, count=,
--             wand = true (baguette équipée), nowand = true (pas de baguette), option = "cléOption" }

local _, ns = ...

-- Chaque sort est une liste d'IDs candidats : rang 1 Vanilla d'abord, puis les autres rangs
-- et les IDs propres à Forever (liens Wowhead Forever du guide Method). Le premier dont le
-- nom se résout sur le client, et qui est connu, est utilisé. Sur Forever, 980 / 1454 / 689 /
-- 18265 / 18220 existent aussi sur Forever (sauf Pacte noir, absent), mais leur nom n'est
-- disponible qu'après chargement des données (voir ns.PreloadSpells).
local SHADOW_BOLT   = { 686, 695, 705, 1088, 1106, 7641, 11659, 11660, 11661, 25307 }   -- Trait de l'ombre (niv. 1)
local IMMOLATE      = { 348, 707, 1094, 2941, 11665, 11667, 11668, 25309 }              -- Immolation (niv. 1)
local CORRUPTION    = { 172, 6222, 6223, 7648, 11671, 11672, 25311, 1223963 }           -- Corruption (niv. 4)
local LIFE_TAP      = { 1454, 1455, 1456, 11687, 11688, 11689 }                         -- Connexion (niv. 6)
local AGONY         = { 980, 1014, 6217, 11711, 11712, 11713 }                          -- Plaie d'agonie (niv. 8)
local DRAIN_LIFE    = { 689, 699, 709, 7651, 11699, 11700 }                             -- Drain de vie (niv. 14)
local SHOOT         = { 5019 }                                                          -- Tir (baguette)
local SIPHON_LIFE   = { 18265, 18879, 18880, 18881 }                                    -- Siphon de vie (talent Affliction)
local DARK_PACT     = { 18220, 18937, 18938 }                                           -- Pacte noir (talent, absent du build Method)
local CONFLAGRATE   = { 17962, 18930, 18931, 18932, 1293817 }                           -- Conflagration (talent Destruction, niv. 29)
local SUMMON_IMP    = { 688 }                                                           -- Invocation d'un diablotin
local SUMMON_VOID   = { 697, 25112 }                                                    -- Invocation d'un marcheur du Vide (niv. 10)
local SUMMON_SUCC   = { 712 }                                                           -- Invocation d'une succube (niv. 20)

ns.SpecNames.WARLOCK = {
  { key = "AFFLICTION",  label = "Affliction",   tab = 1, specIDs = { 265 }, aliases = { "affli", "aff" } },
  { key = "DEMONOLOGY",  label = "Démonologie",  tab = 2, specIDs = { 266 }, aliases = { "demono", "demo", "demonologie" } },
  { key = "DESTRUCTION", label = "Destruction",  tab = 3, specIDs = { 267 }, aliases = { "destru", "destro" } },
}

-- Lignes communes à toutes les macros de rotation
local function Lines(summonID)
  return {
    -- Optionnel (/obr pet on) : invoque le familier de la phase s'il est absent, hors combat
    { fmt = "/cast [nopet,nocombat] %s", args = { { ids = summonID } }, option = "summonPet" },
    "/petattack",
    -- Sans baguette, on finit les monstres à l'attaque de mêlée (Method, niv. 1-9)
    { text = "/startattack", nowand = true },
  }
end

-- Finition de la séquence, après les DoTs :
--  - avec baguette : « !Tir » en fin de /castsequence (standard Classic). Dans une ligne
--    /cast séparée, le tir partait à chaque appui et coupait l'incantation de Corruption ;
--    en fin de séquence il ne part qu'une fois les DoTs posés, et le « ! » évite de couper
--    le tir auto quand on réappuie.
--  - sans baguette : Traits de l'ombre.
local FINISHER = { alt = {
  { ids = SHOOT, wand = true, bang = true },
  { ids = SHADOW_BOLT, nowand = true },
} }

-- Macro de sustain : Shift = mana (Pacte noir si connu, sinon Connexion), sinon Drain de vie
local MANA = { alt = { { ids = DARK_PACT, talent = DARK_PACT }, { ids = LIFE_TAP, minLevel = 6 } } }
-- Textes affichés dans la fenêtre (desc = chaîne ou fonction(ctx) -> chaîne)
local OBR_DESC = function(ctx)
  local finish = ctx.wand and "la baguette (!Tir en fin de séquence, une fois les DoTs posés)" or "des Traits de l'ombre et l'attaque de mêlée"
  if ctx.phase and ctx.phase.minLevel >= 30 then finish = "Drain de vie en boucle (drain tank : ta vie sert de ressource)" end
  return "La rotation : un seul bouton à marteler. Le familier engage en premier (/petattack), "
    .. "puis les DoTs partent dans l'ordre, puis la finition avec " .. finish
    .. ". La séquence repart du début quand tu changes de cible ou sors du combat."
end
local SUSTAIN_DESC = function(ctx)
  if ctx.level >= 14 then
    return "Le sustain, à utiliser entre deux monstres ou quand la vie baisse : clic = Drain de vie "
      .. "(canalisé, te rend de la vie), Shift+clic = Connexion (convertit ta vie en mana"
      .. (ns.IsKnown(DARK_PACT[1]) and ", ou Pacte noir" or "") .. "). Boucle Connexion puis Drain de vie = mana gratuit."
  end
  return "Le sustain : clic = Connexion (convertit ta vie en mana). Mange ensuite pour remonter la vie. "
    .. "Au niveau 14, Drain de vie s'ajoute au clic simple et Connexion passe sur Shift+clic."
end

local SUSTAIN = {
  name = "OBR_VIE", slotKey = "actionSlotSustain", desc = SUSTAIN_DESC,
  lines = {
    { fmt = "/cast [mod:shift] %s; %s", args = { MANA, { ids = DRAIN_LIFE, minLevel = 14 } }, minLevel = 14 },
    { fmt = "/cast %s", args = { MANA }, maxLevel = 13 },
  },
}

-- Phase 1-9 commune : Immolation puis Corruption, finition Trait de l'ombre / mêlée / baguette
local function EarlyPhase(summonID)
  return {
    minLevel = 1, name = "Diablotin (1-9)",
    macros = {
      {
        name = "OBR", slotKey = "actionSlot", desc = OBR_DESC,
        lines = Lines(summonID),
        sequence = {
          { ids = IMMOLATE },
          { ids = CORRUPTION, minLevel = 4 },
        },
        filler = FINISHER, fillerCount = 5,
        reset = "target/combat",
      },
      SUSTAIN,
    },
  }
end

ns.Rotations.WARLOCK = {
  AFFLICTION = {
    phases = {
      EarlyPhase(SUMMON_IMP),
      {
        -- Method : Corruption + Plaie d'agonie, puis baguette. Immolation seulement en option (mana).
        -- Plaie d'agonie en premier : instantané et tague le monstre.
        minLevel = 10, name = "Baguette (10-29)",
        macros = {
          {
            name = "OBR", slotKey = "actionSlot", desc = OBR_DESC,
            lines = Lines(SUMMON_VOID),
            -- Ordre Method, validé en jeu : Plaie d'agonie d'abord (instantané, tague le
            -- monstre), le marcheur du Vide reprend l'aggro sans problème, puis Corruption.
            sequence = {
              { ids = AGONY },
              { ids = CORRUPTION },
              -- Hors Method : 3e DoT, option « /obr immo on » (coûte du mana et 1,5 s de cast)
              { ids = IMMOLATE, option = "immolate" },
            },
            filler = FINISHER, fillerCount = 4,
            reset = "target/combat/10",
          },
          SUSTAIN,
        },
      },
      {
        -- Method : drain tank à partir de 30 avec la succube. [nochanneling] évite de
        -- couper Drain de vie en réappuyant ; 3 drains avant de reposer les DoTs.
        minLevel = 30, name = "Drain tank (30+)",
        macros = {
          {
            name = "OBR", slotKey = "actionSlot", desc = OBR_DESC,
            lines = Lines(SUMMON_SUCC),
            sequence = {
              { ids = AGONY },
              { ids = CORRUPTION },
              { ids = SIPHON_LIFE, talent = SIPHON_LIFE },
            },
            filler = { ids = DRAIN_LIFE }, fillerCount = 3,
            reset = "target/combat/15",
            conditions = "[nochanneling]",
          },
          SUSTAIN,
        },
      },
    },
  },

  DEMONOLOGY = {
    phases = {
      EarlyPhase(SUMMON_IMP),
      {
        -- Method : Immolation + Plaie d'agonie, puis Trait de l'ombre et baguette.
        -- Douleur brûlante et Feu de l'âme (Decimation) restent manuels (aggro, proc).
        minLevel = 10, name = "Marcheur du Vide (10+)",
        macros = {
          {
            name = "OBR", slotKey = "actionSlot", desc = OBR_DESC,
            lines = Lines(SUMMON_VOID),
            sequence = {
              { ids = AGONY },
              { ids = IMMOLATE },
            },
            filler = FINISHER, fillerCount = 4,
            reset = "target/combat/10",
          },
          SUSTAIN,
        },
      },
    },
  },

  DESTRUCTION = {
    phases = {
      EarlyPhase(SUMMON_IMP),
      {
        -- Method : Immolation puis Trait de l'ombre / baguette. À 29 avec Conflagration :
        -- Immolation, Conflagration, Immolation à nouveau, puis finition.
        -- Brûlure de l'ombre reste un finisher manuel (fragment remboursé si le monstre meurt).
        minLevel = 10, name = "Diablotin (10+)",
        macros = {
          {
            name = "OBR", slotKey = "actionSlot", desc = OBR_DESC,
            lines = Lines(SUMMON_IMP),
            sequence = {
              { ids = IMMOLATE },
              { ids = CONFLAGRATE, talent = CONFLAGRATE },
              { ids = IMMOLATE, talent = CONFLAGRATE },
            },
            filler = FINISHER, fillerCount = 4,
            reset = "target/combat/10",
          },
          SUSTAIN,
        },
      },
    },
  },
}

ns.loadedFiles = (ns.loadedFiles or "") .. ", Warlock"
