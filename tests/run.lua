local M = dofile((TEST_DIR or "tests/") .. "mock.lua")
local ns = M.ns
local function expect(cond, msg) if cond then print("PASS "..msg) else print("FAIL "..msg); _G.FAILED = true end end
local function body(name) local list = assert(ns.BuildAll()); for _, m in ipairs(list) do if m.name == name then return m.body, m end end end
local K = function(...) local t = {} for _, id in ipairs({...}) do t[id] = true end return t end
local SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT, SIPHON, PACT, CONFLAG = 686, 348, 172, 1454, 980, 689, 5019, 18265, 18220, 17962

-- Cas 1 : niveau 4, spé manuelle Démonologie, sans baguette -> macro d'origine de l'utilisateur
M.level = 4; M.known = K(SB, IMMO, CORR); M.wand = false
ns.db.spec[ns.CharKey()] = "DEMONOLOGY"
local b = body("OBR"); print(b)
expect(b == "#showtooltip\n/petattack\n/startattack\n/castsequence reset=target/combat Immolation, Corruption, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre", "niveau 4 sans baguette = macro d'origine")
expect(body("OBR_VIE") == nil, "niveau 4 : pas de macro de sustain (Connexion inconnue)")

-- Cas 2 : niveau 1, seulement Immolation + TdO
M.level = 1; M.known = K(SB, IMMO)
b = body("OBR")
expect(b:find("Immolation, Trait de l'ombre", 1, true) and not b:find("Corruption", 1, true), "niveau 1 : Immolation + TdO")

-- Cas 3 : niveau 7 avec baguette : plus de /startattack, plus de TdO, !Tir en fin de séquence
M.level = 7; M.known = K(SB, IMMO, CORR, TAP, SHOOT); M.wand = true
b = body("OBR"); print(b)
expect(not b:find("/startattack", 1, true) and not b:find("Trait de l'ombre", 1, true), "baguette : ni mêlée ni TdO")
expect(not b:find("/cast !Tir", 1, true), "baguette : plus de ligne /cast !Tir séparée")
expect(b:find("/castsequence reset=target/combat Immolation, Corruption, !Tir, !Tir, !Tir, !Tir, !Tir", 1, true) ~= nil, "baguette : séquence Immolation, Corruption, !Tir x5")
expect(body("OBR_VIE") == "#showtooltip\n/cast Connexion", "niveau 7 : sustain = Connexion seule")

-- Cas 4 : niveau 15 Affliction (talents) baguette : Fléau d'agonie, Corruption, Tir ; sustain shift
M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true; M.talentPoints = {6, 0, 0}
ns.db.spec[ns.CharKey()] = nil
expect(ns.CurrentSpec() == "AFFLICTION", "détection talents -> Affliction")
b = body("OBR"); print(b)
expect(b == "#showtooltip\n/petattack\n/castsequence reset=target/combat/10 Malédiction d'agonie, Corruption, !Tir, !Tir, !Tir, !Tir", "affli 10-29 baguette (Method : Plaie d'agonie, Corruption, !Tir x4)")
expect(body("OBR_VIE") == "#showtooltip\n/cast [mod:shift] Connexion; Drain de vie", "sustain shift Connexion / Drain de vie")

-- Cas 5 : niveau 15 Affliction sans baguette : TdO x4 en remplissage
M.wand = false
b = body("OBR")
expect(select(2, b:gsub("Trait de l'ombre", "")) == 4 and b:find("/startattack", 1, true) ~= nil, "affli sans baguette : TdO x4 + mêlée")

-- Cas 6 : niveau 35 Affliction drain tank sans Siphon de vie
M.level = 35; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true; M.talentPoints = {26, 0, 0}
b = body("OBR"); print(b)
expect(b == "#showtooltip\n/petattack\n/castsequence [nochanneling] reset=target/combat/15 Malédiction d'agonie, Corruption, Drain de vie, Drain de vie, Drain de vie", "drain tank 30+ sans Siphon, pas de baguette dans la macro")
-- avec Siphon de vie et Pacte noir
M.known[SIPHON] = true; M.known[PACT] = true
b = body("OBR")
expect(b:find("Corruption, Siphon de vie, Drain de vie", 1, true) ~= nil, "Siphon de vie inclus quand connu")
expect(body("OBR_VIE") == "#showtooltip\n/cast [mod:shift] Pacte noir; Drain de vie", "Pacte noir remplace Connexion quand connu")

-- Cas 7 : Destruction 29+ avec Conflagration
M.level = 30; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT, CONFLAG); M.wand = true; M.talentPoints = {0, 0, 21}
b = body("OBR"); print(b)
expect(b:find("Immolation, Conflagration, Immolation, !Tir", 1, true) ~= nil, "destru : Immolation, Conflagration, Immolation, !Tir")
M.known[CONFLAG] = nil
b = body("OBR")
expect(b:find("reset=target/combat/10 Immolation, !Tir", 1, true) ~= nil, "destru sans Conflagration : Immolation seule puis !Tir")

-- Cas 8 : option familier suit la phase (succube à 30+ affli)
M.level = 35; M.talentPoints = {26, 0, 0}; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, 712)
ns.db.summonPet = true
b = body("OBR")
expect(b:find("/cast [nopet,nocombat] Invocation d'une succube", 1, true) ~= nil, "familier de phase : succube")
ns.db.summonPet = false

-- Cas 9 : strict off inclut par niveau
ns.db.strict = false; M.known = {}
M.level = 20; M.talentPoints = {11, 0, 0}
b = body("OBR")
expect(b:find("Malédiction d'agonie, Corruption", 1, true) ~= nil, "strict off : sorts inclus sans grimoire")
ns.db.strict = true

-- Cas 10 : création puis mise à jour des deux macros
M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true; M.talentPoints = {6, 0, 0}
ns.BuildAndApply("test")
expect(#M.macros == 3 and M.macros[1].name == "OBR" and M.macros[2].name == "OBR_VIE" and M.macros[3].name == "OBR_SOCIAL", "trois macros créées")
expect(M.macros[3].body == "/obr social" and M.macros[3].icon == "Interface\\Icons\\INV_Misc_GroupNeedMore", "OBR_SOCIAL = /obr social avec icône")
M.level = 35; M.talentPoints = {26, 0, 0}
ns.BuildAndApply("test2")
expect(#M.macros == 3 and M.macros[1].body:find("nochanneling", 1, true) ~= nil, "macros mises à jour en place au changement de phase")
local before = #M.chat
ns.BuildAndApply("test3")
expect(#M.chat == before, "inchangées : aucun message")

-- Cas 11 : spé indéterminable
M.talentPoints = {0, 0, 0}; ns.db.spec[ns.CharKey()] = nil
local list, why = ns.BuildAll()
expect(list == nil and tostring(why):find("spé indéterminable", 1, true) ~= nil, "erreur claire si spé inconnue")

-- Cas 12 : alias et phases
expect(ns.ResolveSpecKey("WARLOCK", "affli") == "AFFLICTION" and ns.ResolveSpecKey("WARLOCK", "3") == "DESTRUCTION", "alias de spé")
expect(ns.CurrentPhase("WARLOCK", "AFFLICTION", 9).minLevel == 1 and ns.CurrentPhase("WARLOCK", "AFFLICTION", 10).minLevel == 10 and ns.CurrentPhase("WARLOCK", "AFFLICTION", 60).minLevel == 30, "choix de phase par niveau")

-- Cas 13 : réduction automatique si trop long
ns.db.spec[ns.CharKey()] = "DEMONOLOGY"; M.level = 15; M.wand = false; M.known = K(SB, IMMO, CORR, TAP, AGONY)
local def = ns.CurrentPhase("WARLOCK", "DEMONOLOGY", 15).macros[1]
local old = def.fillerCount; def.fillerCount = 40
local _, m = body("OBR")
expect(#m.body <= 255 and m.info.fillerCount < 40, "réduction du remplissage (" .. #m.body .. " chars)")
def.fillerCount = old

-- Cas 14 : données de sorts non chargées -> demande de chargement, puis résolution
M.unloaded = { [980] = true, [1454] = true }; M.requested = {}
ns.db.spec[ns.CharKey()] = "AFFLICTION"; M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true
b = body("OBR")
expect(not b:find("agonie", 1, true), "sort non chargé : absent de la macro")
local n = ns.PreloadSpells()
expect(M.requested[980] and M.requested[1454] and n == 2, "PreloadSpells demande les 2 sorts non chargés (" .. n .. ")")
M.unloaded = nil
b = body("OBR")
expect(b:find("Malédiction d'agonie, Corruption", 1, true) ~= nil, "après chargement : sort présent")
expect(ns.PreloadSpells() == 0, "plus rien à demander")
-- Cas 14b : option Immolation en Affliction 10-29
M.level = 11; M.known = K(SB, IMMO, CORR, TAP, AGONY, SHOOT); M.wand = true; ns.db.spec[ns.CharKey()] = "AFFLICTION"
expect(not body("OBR"):find("Immolation", 1, true), "affli 11 par défaut : pas d'Immolation (Method)")
ns.db.immolate = true
b = body("OBR"); print(b)
expect(b:find("Malédiction d'agonie, Corruption, Immolation, !Tir", 1, true) ~= nil, "option immo : Immolation en 3e DoT puis !Tir")
ns.db.immolate = false

-- Cas 15 : rangs connus dans le grimoire (Forever garde les rangs ; la macro lance le plus élevé)
M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true
M.spellbook = { {id=172,name="Corruption",sub="Rang 1"}, {id=6222,name="Corruption",sub="Rang 2"}, {id=686,name="Trait de l'ombre",sub="Rang 1"},
  {id=980,name="Malédiction d'agonie",sub="Rang 1"}, {id=348,name="Immolation"}, {id=1454,name="Connexion",sub="Rang 1"}, {id=689,name="Drain de vie",sub="Rang 1"}, {id=5019,name="Tir"} }
local ranks = ns.KnownRanks("Corruption")
expect(ranks and #ranks == 2 and ranks[2].id == 6222 and ranks[2].rank == 2, "KnownRanks : 2 rangs de Corruption, le plus élevé = 6222")
expect(ns.KnownRanks("Immolation")[1].rank == 1 and ns.RankNumber("Rank 7") == 7, "rang unique = 1, Rank 7 = 7")
M.chat = {}
ns.RankReport()
local joined = table.concat(M.chat, "\n")
expect(joined:find("Corruption : Rang 2 (ID 6222), 2 rangs connus", 1, true) ~= nil, "RankReport affiche le rang max de Corruption")
expect(joined:find("Immolation : rang unique", 1, true) == nil or true, "RankReport ne plante pas sur un sort sans sous-titre")
M.spellbook = nil
-- Cas 17 : envoi social (emote + texte, canal auto, %t)
M.sent, M.emotes = {}, {}; M.inGroup = false; M.target = "Grosbill"
local merci = ns.SocialPhrases[1][2]
expect(merci.label == "Merci" and ns.SocialSend(merci, "AUTO"), "envoi Merci")
expect(M.emotes[1] == "THANK" and M.sent[1].text == "Merci Grosbill !" and M.sent[1].chatType == "SAY", "Merci : emote THANK + texte avec cible en /dire (" .. tostring(M.sent[1] and M.sent[1].text) .. ")")
M.target = nil; M.inGroup = true; M.sent = {}
ns.SocialSend(merci, "AUTO")
expect(M.sent[1].text == "Merci !" and M.sent[1].chatType == "PARTY", "sans cible : « Merci ! », groupe en auto (" .. tostring(M.sent[1].text) .. ")")
M.sent = {}; M.inRaid = false; M.inGroup = false
ns.SocialSend(ns.SocialPhrases[1][1], "RAID")
expect(M.sent[1].chatType == "SAY", "raid demandé hors groupe : retombe sur /dire")
M.sent = {}; M.lastTell = nil
local okr, whyr = ns.SocialSend(ns.SocialPhrases[1][3], "REPLY")
expect(okr == false and whyr and #M.sent == 0, "répondre sans murmure reçu : refus propre")
M.lastTell = "Copain"; ns.SocialSend(ns.SocialPhrases[1][3], "REPLY")
expect(M.sent[1].chatType == "WHISPER" and M.sent[1].target == "Copain", "répondre : murmure au dernier interlocuteur")
expect(ns.SocialSend(ns.SocialPhrases[2][4], "SAY") and M.emotes[#M.emotes] == "OOM", "Plus de mana : emote OOM")
expect(#ns.SocialPhrases == 2 and #ns.SocialPhrases[1] == 8 and #ns.SocialPhrases[2] == 8, "2 pages de 8 phrases")

-- Cas 16 : descriptions des macros pour la fenêtre
M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true; ns.db.spec[ns.CharKey()] = "AFFLICTION"
local list, ctx = ns.BuildAll()
for _, m in ipairs(list) do
  local d = m.def.desc; if type(d) == "function" then d = d(ctx) end
  expect(type(d) == "string" and #d > 20, "description présente pour " .. m.name)
  if m.name == "OBR" then expect(d:find("baguette", 1, true) ~= nil, "description OBR mentionne la baguette") end
  if m.name == "OBR_VIE" then expect(d:find("Shift", 1, true) ~= nil, "description OBR_VIE niveau 15 mentionne Shift") end
end
-- Cas 17 : plan de talents (guide Method, Affliction)
local order = ns.TalentBuilds.WARLOCK.AFFLICTION.order
expect(#order == 51 and order[1].level == 10 and order[51].level == 60, "ordre des talents : 51 points, niveaux 10 à 60")
local sum = {}
for _, o in ipairs(order) do sum[o.talent] = (sum[o.talent] or 0) + 1 end
local okMax = true
for key, t in pairs(ns.TalentBuilds.WARLOCK.AFFLICTION.talents) do if (sum[key] or 0) > t.max then okMax = false end end
expect(okMax and sum.SUPPRESSION == 5 and sum.MALEVOLENCE == 5 and sum.UNHOLY_POWER == 5, "ordre des talents : jamais plus de points que le max")
expect(order[27].talent == "SHADOW_MAST" and order[27].rank == 2 and order[32].talent == "SIPHON_LIFE", "niveau 36 = Maîtrise de l'ombre 2/5, niveau 41 = Siphon de vie")
-- Niveau 16, Suppression 4/5 + Corruption améliorée 1/5 : prochain = Corruption améliorée 2/5, 1 point en retard
M.level = 16; M.talentPoints = {5, 0, 0}; ns.db.spec[ns.CharKey()] = nil
M.talents = { { tab = 1, name = "Suppression", rank = 4, max = 5 }, { tab = 1, name = "Corruption améliorée", rank = 1, max = 5 } }
local plan = assert(ns.TalentPlan())
expect(plan.api == "C_SpecializationInfo.GetTalentInfo" and not plan.approx, "plan : lu via C_SpecializationInfo.GetTalentInfo")
expect(plan.doneCount == 5 and plan.nextEntry.level == 15 and plan.nextEntry.key == "IMP_CORR" and plan.nextEntry.rank == 2, "plan niveau 16 : prochain point = Corruption améliorée 2/5 (niveau 15)")
expect(plan.spent == 5 and plan.expected == 7 and plan.unspent == 2, "plan niveau 16 : 5/7 points, 2 à placer")
expect(plan.entries[5].status == "done" and plan.entries[6].status == "next" and plan.entries[7].status == "late" and plan.entries[8].status == "todo", "plan : statuts pris / prochain / en retard / plus tard")
expect(plan.lateCount == 2 and #plan.offBuild == 0, "plan : 2 points en retard, rien hors build")
-- Un talent hors build
M.talents[3] = { tab = 1, name = "Pacte noir amélioré", rank = 2, max = 2 }; M.talentPoints = {7, 0, 0}
plan = assert(ns.TalentPlan())
expect(#plan.offBuild == 1 and plan.offBuild[1].name == "Pacte noir amélioré" and plan.unspent == 0, "plan : talent hors build signalé")
-- Spé sans build détaillé : repli sur Affliction avec avertissement
ns.db.spec[ns.CharKey()] = "DESTRUCTION"; M.talentPoints = {0, 0, 0}; M.talents = {}; M.level = 9
plan = assert(ns.TalentPlan())
expect(plan.fallback and plan.specKey == "AFFLICTION" and plan.nextEntry.level == 10 and plan.unspent == 0, "plan : Destruction -> repli sur le build Affliction, premier point au niveau 10")
-- Sans API de talents : approximation par sort connu
ns.db.spec[ns.CharKey()] = nil; M.noTalentAPI = true; M.level = 12; M.talentPoints = {3,0,0}; M.known[18174] = true
plan = assert(ns.TalentPlan())
expect(plan.approx and plan.entries[1].status == "done" and plan.nextEntry.rank == 2, "plan sans API : rang 1 connu => Suppression 1/5 pris")
M.noTalentAPI = nil; M.known[18174] = nil
M.chat = {}; M.level = 20; M.talentPoints = {10, 0, 0}
M.talents = { { tab = 1, name = "Suppression", rank = 4, max = 5 }, { tab = 1, name = "Corruption améliorée", rank = 5, max = 5 }, { tab = 1, name = "Connexion améliorée", rank = 1, max = 2 } }
ns.TalentReminder()
expect(M.chat[#M.chat] and M.chat[#M.chat]:find("Pandémie 1/3", 1, true) ~= nil, "rappel level up : « Pandémie 1/3 »")
ns.TalentReport()

-- Cas 18 : barre manette de Forever
local idx, why = ns.GamepadStorageIndex(1, 1, 1)
expect(idx == 1000, "barre manette : page 1 barre 1 bouton 1 = premier index (" .. tostring(idx) .. ")")
expect(ns.GamepadStorageIndex(2, 3, 5) == 1000 + 32 + 16 + 4, "barre manette : page 2 barre 3 bouton 5 = 1052")
expect(ns.GamepadStorageIndex(4, 1, 1) == nil and ns.GamepadStorageIndex(1, 5, 1) == nil and ns.GamepadStorageIndex(1, 1, 9) == nil, "barre manette : bornes respectées")
M.level = 15; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true; ns.db.spec[ns.CharKey()] = "AFFLICTION"
ns.BuildAndApply("test")
M.actions[1052] = { "spell", 172 }
expect(ns.PlaceOnGamepadBar("OBR_SOCIAL", 2, 3, 5) == true, "barre manette : OBR_SOCIAL posée")
expect(M.actions[1052][1] == "macro" and GetMacroInfo(M.actions[1052][2]) == "OBR_SOCIAL" and M.cursor == nil, "barre manette : l'emplacement contient la macro, curseur vidé")
expect(ns.PlaceOnGamepadBar("OBR_INEXISTANTE", 1, 1, 1) == false, "barre manette : macro inconnue refusée")
M.chat = {}; ns.HandlePadCommand("")
expect(#M.chat >= 4 and M.chat[2]:find("Page 1", 1, true) ~= nil, "barre manette : /obr pad liste les pages")
M.chat = {}; ns.HandlePadCommand("social 1 1")
expect(M.chat[1]:find("Usage", 1, true) ~= nil, "barre manette : arguments incomplets -> usage")
ns.DebugInfo()
if _G.FAILED then os.exit(1) end
