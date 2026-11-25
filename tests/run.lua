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
expect(#M.macros == 8 and M.macros[1].name == "OBR" and M.macros[2].name == "OBR_VIE" and M.macros[3].name == "OBR_SOCIAL"
  and M.macros[4].name == "OBR_GROUPE" and M.macros[5].name == "OBR_OUI" and M.macros[6].name == "OBR_NON" and M.macros[7].name == "OBR_MERCI"
  and M.macros[8].name == "OBR_DECK" and M.macros[8].body == "/obr say deck", "huit macros créées")
expect(M.macros[4].body == "/invite\n/obr say groupe" and M.macros[5].body == "/obr say oui" and M.macros[7].body == "/obr say merci", "macros rapides : /invite puis /obr say <clé>")
expect(M.macros[3].body == "/obr social" and M.macros[3].icon == "Interface\\Icons\\INV_Misc_GroupNeedMore", "OBR_SOCIAL = /obr social avec icône")
M.level = 35; M.talentPoints = {26, 0, 0}
ns.BuildAndApply("test2")
expect(#M.macros == 8 and M.macros[1].body:find("nochanneling", 1, true) ~= nil, "macros mises à jour en place au changement de phase")
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
-- Cas 19 : guide RestedXP embarqué
local h = ns.RXPHeader("213|2295048190:D+Gz4rzZp0u1D418eW4wwtXR5iOwTlVhA%|40000")
expect(h and h.nGuides == 213 and h.id == 2295048190 and h.base == 40000, "RestedXP : en-tête 213 guides / id / base 40000")
expect(ns.RXPHeader("") == nil and ns.RXPHeader("n'importe quoi") == nil, "RestedXP : en-tête invalide -> nil")
ns.RestedXPGuide = nil
local st = ns.RestedXPStatus()
expect(st.hasGuide == false and st.rxpLoaded == false, "RestedXP : sans guide ni addon")
local okImp, msgImp = ns.ImportRestedXP()
expect(okImp == false and msgImp:find("Aucun guide", 1, true) ~= nil, "RestedXP : import refusé sans guide")
_G.DMK_RXP = { name = "Test", generated = "2026-11-16", text = "2|123:QUJD%|40000" }
_G.DMK_RXP.size = #_G.DMK_RXP.text
M.loadedAddons = { DMK_RXP = true }
st = ns.RestedXPStatus()
expect(st.hasGuide and st.companionLoaded and st.nGuides == 2 and st.id == 123 and st.rxpLoaded == false, "RestedXP : guide lu depuis l'addon compagnon DMK_RXP, RestedXP absent")
okImp, msgImp = ns.ImportRestedXP()
expect(okImp == false and msgImp:find("pas chargé", 1, true) ~= nil, "RestedXP : import refusé sans RXPGuides")
-- RestedXP présent, guide pas encore importé
local calls = 0
_G.RXPGuides = { version = 40000, db = { profile = { guideId = 1, guideLength = 1 } },
  LoadCachedGuides = function() calls = calls + 1 end,
  guideImporter = { Open = function() end } }
M.loadedAddons = { RXPGuides = true, DMK_RXP = true }
st = ns.RestedXPStatus()
expect(st.rxpLoaded and st.compatible == true and st.imported == false, "RestedXP : chargé, compatible, pas importé")
okImp, msgImp = ns.ImportRestedXP()
expect(okImp == true and calls == 1 and RXPString == _G.DMK_RXP.text, "RestedXP : import appelle LoadCachedGuides et pose RXPString")
-- déjà importé
_G.RXPGuides.db.profile.guideId, _G.RXPGuides.db.profile.guideLength = 123, 2
st = ns.RestedXPStatus()
okImp, msgImp = ns.ImportRestedXP()
expect(st.imported == true and okImp == true and calls == 1 and msgImp:find("déjà", 1, true) ~= nil, "RestedXP : déjà importé -> pas de réimport")
-- guide plus ancien que RestedXP (base 40000 < version 50000) : refusé
_G.RXPGuides.version = 50000; _G.RXPGuides.db.profile.guideId = 1
st = ns.RestedXPStatus(); okImp, msgImp = ns.ImportRestedXP()
expect(st.compatible == false and okImp == false and msgImp:find("mets RestedXP", 1, true) ~= nil, "RestedXP : guide trop ancien pour la version de RestedXP -> refusé")
_G.RXPGuides = nil; M.loadedAddons = nil
M.chat = {}; ns.RestedXPReport()
expect(M.chat[1] and M.chat[1]:find("2 guides", 1, true) ~= nil, "RestedXP : /obr rxp chat résume le guide")
_G.DMK_RXP = nil
expect(ns.RestedXPStatus().hasGuide == false, "RestedXP : sans DMK_RXP, plus de guide")
-- Cas 20 : nouveau rang appris -> le texte du /castsequence change (le client fige les IDs
-- par texte de séquence ; sans changement de texte, la macro boucle sur le même sort)
expect(ns.JoinSequence({ "A", "B", "C" }) == "A, B, C", "JoinSequence sans rangs = virgule + 1 espace")
expect(ns.JoinSequence({ "A", "B", "!C", "!C" }, function(n) return ({ A = 2, B = 3 })[n] or 1 end) == "A,  B,   !C, !C",
  "JoinSequence : autant d'espaces après un sort que son rang connu")
expect(ns.JoinSequence({ "A", "B" }, function() return nil end) == "A, B", "JoinSequence : rang inconnu = 1 espace")
ns.db.spec[ns.CharKey()] = "AFFLICTION"
M.level = 24; M.known = K(SB, IMMO, CORR, TAP, AGONY, DRAIN, SHOOT); M.wand = true
M.spellbook = { {id=172,name="Corruption",sub="Rang 1"}, {id=6222,name="Corruption",sub="Rang 2"}, {id=6223,name="Corruption",sub="Rang 3"},
  {id=980,name="Malédiction d'agonie",sub="Rang 1"}, {id=1014,name="Malédiction d'agonie",sub="Rang 2"}, {id=5019,name="Tir"}, {id=689,name="Drain de vie",sub="Rang 3"} }
expect(ns.MaxKnownRank("Corruption") == 3 and ns.MaxKnownRank("Tir") == 1 and ns.MaxKnownRank("Inconnu") == 1, "MaxKnownRank : 3 / 1 / 1")
b = body("OBR"); print(b)
expect(b == "#showtooltip\n/petattack\n/castsequence reset=target/combat/10 Malédiction d'agonie,  Corruption,   !Tir, !Tir, !Tir, !Tir",
  "niveau 24 : Plaie d'agonie rang 2 → 2 espaces, Corruption rang 3 → 3 espaces, Tir sans rang → 1")
-- le texte avec les rangs du niveau 15 est différent : le client relira les IDs après la mise à jour de la macro
M.spellbook[3] = nil
expect(body("OBR") ~= b, "un rang de moins = texte de macro différent")
M.spellbook = nil
expect(body("OBR"):find("Malédiction d'agonie, Corruption, !Tir", 1, true) ~= nil, "sans sous-titres de rang : texte d'origine inchangé")
-- Cas 21 : macros rapides (/obr say <clé>) : textes FR / EN, chuchotement à la cible, deux lignes
expect(ns.QuickMacroByKey("oui").name == "OBR_OUI" and ns.QuickMacroByKey("OBR_NON").key == "non" and ns.QuickMacroByKey("zzz") == nil, "QuickMacroByKey : clé ou nom")
M.sent, M.emotes = {}, {}; M.inGroup = false; M.target = nil
expect(ns.QuickSay("oui") and M.sent[1].text == "Oui / Yes" and M.sent[1].chatType == "SAY" and M.emotes[1] == "NOD", "say oui : « Oui / Yes » en /dire, emote NOD")
M.sent, M.emotes = {}, {}
expect(ns.QuickSay("non") and M.sent[1].text == "Non / No" and M.emotes[1] == "NO", "say non : « Non / No », emote NO")
M.sent, M.emotes = {}, {}; M.target = "Copain"
expect(ns.QuickSay("merci") and #M.sent == 2 and M.sent[1].text == "Merci / Thank you Copain" and M.sent[2].text == "GL HF" and M.emotes[1] == "THANK", "say merci : deux lignes, nom de la cible, emote THANK")
M.sent = {}; M.target = nil
expect(ns.QuickSay("merci") and M.sent[1].text == "Merci / Thank you" and M.sent[2].text == "GL HF", "say merci sans cible : pas de nom")
M.sent, M.emotes = {}, {}; M.target = "Copain"
expect(ns.QuickSay("groupe") and M.sent[1].chatType == "WHISPER" and M.sent[1].target == "Copain" and M.sent[1].text == "Groupe ? / Group?" and M.emotes[1] == "BECKON", "say groupe : chuchoté à la cible joueur")
M.sent = {}; M.target = nil
expect(ns.QuickSay("groupe") and M.sent[1].chatType == "SAY", "say groupe sans cible : canal courant")
M.sent, M.emotes = {}, {}
expect(ns.QuickSay("deck") and #M.sent == 2 and M.sent[1].text:find("Steam Deck", 1, true) and M.sent[2].text:find("Steam Deck", 1, true)
  and #M.sent[1].text <= 255 and #M.sent[2].text <= 255 and M.emotes[1] == "SHRUG", "say deck : FR puis EN, emote SHRUG")
local okq, whyq = ns.QuickSay("zzz")
expect(okq == false and whyq:find("phrase inconnue", 1, true) ~= nil and whyq:find("groupe|oui|non|merci|deck", 1, true) ~= nil, "say inconnu : refusé avec la liste des clés")
ns.db.quickMacros = false
local names = {}
for _, m in ipairs(assert(ns.BuildAll())) do names[m.name] = true end
expect(names.OBR_SOCIAL and not names.OBR_OUI, "quickMacros off : plus de macros rapides, OBR_SOCIAL reste")
ns.db.quickMacros = true
-- Cas 22 : hôtel des ventes, bonnes affaires (scan complet, prix vendeur, recherches, achats, rapport)
local AH = ns.Auction
expect(AH.MoneyString(123456) == "12po 34pa 56pc" and AH.MoneyString(5) == "5pc" and AH.MoneyString(10000) == "1po 0pa 0pc", "MoneyString")
expect(AH.ClockString(754) == "12:34" and AH.SuffixFromLink("|Hitem:12345:0:0:0:0:0:-12:777|h") == -12 and AH.SuffixFromLink(nil) == 0, "ClockString / suffixe de lien")
expect(AH.ErrorText(4) == "enchère déjà partie" and AH.ErrorText(99):find("erreur", 1, true), "ErrorText")
ns.db.ahLastScan = nil; ns.db.ahMinProfit = 0
local okS, whyS = AH.CanScan()
expect(okS == false and whyS:find("ouvre d'abord", 1, true), "scan refusé si l'HV est fermé")
AH.OnEvent("AUCTION_HOUSE_SHOW")
expect(AH.CanScan() == true and AH.ScanRemaining() == 0, "HV ouvert, pas de verrou : scan possible")
-- Enchères : 1001 = objet unique rentable (2 enchères, une des deux à moi), 1002 = empilable rentable, 1003 = trop cher, 1004 = prix vendeur à charger, 1005 = sans prix vendeur
M.sellPrice = { [1001] = 1000, [1002] = 10, [1003] = 50, [1004] = 500, [1005] = 0 }
M.itemLoad = { [1004] = true }
M.ah.replicate = {
  { itemID = 1001, count = 1, buyout = 600, owner = "Autre", link = "|Hitem:1001:0:0:0:0:0:-5:1|h[Épée]|h" },
  { itemID = 1001, count = 1, buyout = 300, owner = "Testeur", link = "|Hitem:1001:0:0:0:0:0:-5:1|h[Épée]|h" }, -- la mienne : ignorée
  { itemID = 1002, count = 20, buyout = 100, owner = "Autre" }, -- 5 pc l'unité, vendeur 10
  { itemID = 1003, count = 1, buyout = 80, owner = "Autre" },
  { itemID = 1004, count = 2, buyout = 400, owner = "Autre" },
  { itemID = 1005, count = 1, buyout = 1, owner = "Autre" },
  { itemID = 1001, count = 1, buyout = 0, owner = "Autre" }, -- enchère sans rachat : ignorée
}
M.ah.items[1001] = { { auctionID = 501, buyout = 600, qty = 1 }, { auctionID = 502, buyout = 950, qty = 1 }, { auctionID = 503, buyout = 1200, qty = 1 }, { auctionID = 504, buyout = 100, qty = 1, owner = true } }
M.ah.items[1004] = { { auctionID = 601, buyout = 400, qty = 2 } }
M.ah.commodities[1002] = { { unit = 5, qty = 20 }, { unit = 8, qty = 5 }, { unit = 12, qty = 100 } }
M.ah.calls = {}
AH.CHUNK = 3
local okStart, msgStart = AH.StartScan()
expect(okStart and AH.state.phase == "replicate" and M.ah.calls[1][1] == "replicate" and ns.db.ahLastScan ~= nil, "StartScan : ReplicateItems appelé, verrou posé")
local okS2, whyS2 = AH.CanScan()
expect(okS2 == false and whyS2 == "scan en cours", "pas de second scan pendant le scan")
AH.OnEvent("REPLICATE_ITEM_LIST_UPDATE")
expect(AH.state.phase == "process" and AH.state.index == 3, "dépouillement par paquets : 3 lues sur 7")
while AH.state.phase == "process" do AH.ProcessChunk() end
expect(AH.state.phase == "prices" and AH.state.pendingCount == 1 and AH.state.stats.scanned == 7 and AH.state.stats.keys == 5, "7 enchères, 5 clés (dont suffixe -5), 1 prix vendeur à charger")
M.itemLoad[1004] = nil -- le jeu a mis l'objet en cache
AH.OnEvent("ITEM_DATA_LOAD_RESULT", 1004, true)
expect(AH.state.phase == "search" and AH.state.stats.candidates == 3, "prix chargé → 3 candidats (1001, 1002, 1004 ; 1003 trop cher, 1005 sans prix vendeur)")
expect(AH.state.current.itemID == 1001 and M.ah.calls[#M.ah.calls][1] == "search" and M.ah.calls[#M.ah.calls][2] == 1001 and M.ah.calls[#M.ah.calls][3] == -5,
  "candidat le plus prometteur d'abord : 1001 (1000 - 600 = 400 par unité), recherché avec son suffixe -5")
AH.OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 1001 })
expect(AH.state.current.itemID == 1004, "puis 1004 (500 - 200 = 300)")
AH.OnEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 1004 })
expect(AH.state.current.itemID == 1002, "puis l'empilable 1002")
AH.OnEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 1002)
expect(AH.state.phase == "done" and #AH.state.rows == 4, "scan terminé : 4 affaires (1004 ×2, 1001 à 600 et 950, 1002 ×25)")
local r1, r2, r3, r4 = AH.state.rows[1], AH.state.rows[2], AH.state.rows[3], AH.state.rows[4]
expect(r1.itemID == 1004 and r1.profit == 600 and r2.itemID == 1001 and r2.auctionID == 501 and r2.profit == 400, "tri par gain : 1004 (+600) puis 1001 à 600 (+400)")
expect(r3.kind == "commodity" and r3.qty == 25 and r3.price == 140 and r3.profit == 110 and r3.maxTotal == 249, "empilable : 20 à 5 + 5 à 8 = 25 pour 140, gain 110, plafond 249")
expect(r4.auctionID == 502 and r4.profit == 50, "1001 à 950 : +50 ; 1200 et ma propre enchère écartées")
expect(AH.CanScan() == false and AH.ScanRemaining() > 800, "verrou de 15 min actif après le scan")
expect(AH.ScanRemaining(ns.db.ahLastScan + 900) == 0 and AH.ScanRemaining(ns.db.ahLastScan + 899) == 1, "verrou levé à 900 s")
-- Achats
M.ah.calls = {}
local okB, msgB = AH.BuyNext()
expect(okB and r1.status == "pending" and M.ah.calls[1][1] == "bid" and M.ah.calls[1][2] == 601 and M.ah.calls[1][3] == 400, "BuyNext : PlaceBid(601, 400) sur la meilleure affaire")
local okB2, whyB2 = AH.BuyNext()
expect(okB2 == false and whyB2:find("déjà en cours", 1, true), "pas de second achat pendant l'attente")
AH.OnEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 999)
expect(r1.status == "pending", "autre enchère achevée : ignorée")
AH.OnEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 601)
expect(r1.status == "bought" and AH.state.report.bought == 1 and AH.state.report.spent == 400 and AH.state.report.gain == 600, "achat 601 confirmé : rapport 1 achat, 400 dépensés, gain 600")
AH.BuyNext()
AH.OnEvent("AUCTION_HOUSE_SHOW_ERROR", 4)
expect(r2.status == "failed" and r2.error == "enchère déjà partie" and AH.state.report.failed == 1, "erreur ItemNotFound : ligne en échec, rapport mis à jour")
M.ah.calls = {}
AH.BuyNext()
expect(r3.status == "pending" and M.ah.calls[1][1] == "startc" and M.ah.calls[1][2] == 1002 and M.ah.calls[1][3] == 25, "empilable : StartCommoditiesPurchase(1002, 25)")
AH.OnEvent("COMMODITY_PRICE_UPDATED", 6, 150)
expect(M.ah.calls[2][1] == "confirmc" and r3.paid == 150 and r3.status == "pending", "devis 150 ≤ plafond 249 : confirmation")
AH.OnEvent("COMMODITY_PURCHASE_SUCCEEDED")
expect(r3.status == "bought" and AH.state.report.spent == 550 and AH.state.report.gain == 600 + (250 - 150), "empilable acheté : dépense 550, gain 700")
M.ah.money = 10
local okB4, whyB4 = AH.BuyNext()
expect(okB4 == false and r4.status == "failed" and r4.error:find("pas assez d'argent", 1, true), "sans argent : échec immédiat")
M.ah.money = 10000000
local okB5, whyB5 = AH.BuyNext()
expect(okB5 == false and whyB5:find("plus rien à acheter", 1, true), "plus d'affaire : message de fin")
local lines = AH.ReportLines()
expect(#lines >= 5 and lines[1]:find("7 enchères", 1, true) and lines[2]:find("2 achat(s) pour 5pa 50pc", 1, true) and lines[2]:find("2 échec(s)", 1, true), "rapport : scan + bilan + lignes")
-- devis trop cher sur un empilable : annulation
AH.state.rows = { { kind = "commodity", itemID = 1002, name = "Tissu", qty = 10, price = 50, maxTotal = 99, sellPrice = 10, profit = 50, status = "ready" } }
AH.state.pendingRow = nil; M.ah.calls = {}
AH.BuyNext()
AH.OnEvent("COMMODITY_PRICE_UPDATED", 20, 200)
expect(M.ah.calls[2][1] == "cancelc" and AH.state.rows[1].status == "failed" and AH.state.rows[1].error:find("monté", 1, true), "devis 200 > plafond 99 : annulation")
-- fermeture de l'HV pendant un achat
AH.state.rows = { { kind = "item", itemID = 1001, name = "Épée", auctionID = 7, qty = 1, price = 5, sellPrice = 10, profit = 5, status = "ready" } }
AH.BuyNext()
AH.OnEvent("AUCTION_HOUSE_CLOSED")
expect(AH.state.open == false and AH.state.rows[1].status == "failed" and AH.BuyNext() == false, "HV fermé : achat en attente échoué, plus d'achat possible")
-- /obr ah
M.chat = {}
AH.HandleCommand("profit 250")
expect(ns.db.ahMinProfit == 250 and M.chat[1]:find("2pa 50pc", 1, true), "/obr ah profit 250")
AH.HandleCommand("")
expect(M.chat[2]:find("achat(s) pour", 1, true) ~= nil and M.chat[3]:find("Usage", 1, true) ~= nil, "/obr ah : état (bilan du dernier scan) + usage")
AH.CHUNK = 800; ns.db.ahMinProfit = 0; ns.db.ahLastScan = nil
ns.DebugInfo()
if _G.FAILED then os.exit(1) end
