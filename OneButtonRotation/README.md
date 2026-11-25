# One Button Rotation (WoW Forever)

Addon qui génère et tient à jour des macros « one button rotation » (`/castsequence`)
adaptées à ta **classe**, ta **spé**, ton **niveau** et ton **équipement** (baguette ou non).
Il relit ton grimoire : seuls les sorts que tu connais sont inclus, et les macros sont
régénérées automatiquement au level up, quand tu apprends un sort, quand tu changes de
talents ou quand tu équipes une baguette.

Classes supportées pour l'instant : **Démoniste** (Affliction, Démonologie, Destruction),
rotations de leveling solo basées sur le guide Method « WoW Forever Warlock Leveling Guide ».

## Installation

1. Télécharge le zip : **https://storage.dehemka.net/public/wow/obr.zip** (toujours la dernière version ;
   le fichier téléchargé porte le numéro de version dans son nom).
2. Décompresse-le dans le dossier AddOns de **l'installation Forever** (pas Classic, pas Retail) :
   `World of Warcraft\_forever_\Interface\AddOns\` (le nom du sous-dossier peut varier :
   prends celui qui contient le `Wow.exe` de Forever).
   Tu dois obtenir `…\Interface\AddOns\OneButtonRotation\OneButtonRotation.toc`.
3. Lance le jeu. À l'écran de sélection des personnages, bouton **AddOns** : vérifie que
   « One Button Rotation » est coché. Si le jeu l'affiche « obsolète », coche
   **Charger les AddOns obsolètes** (le numéro d'interface du client bouge souvent).
4. En jeu : `/obr` ouvre la fenêtre. Un menu à gauche donne accès aux pages **Rotation** (spé,
   aperçu des macros), **Talents** (ordre des points et où tu en es), **Anneau social**, **RestedXP**, **Options**
   et **Aide**. Le bouton « À quoi servent-elles ? » (ou `/obr aide`) ouvre l'explication des macros
   dans une fenêtre à part, en grand (A+ / A- pour la taille).

## Utilisation

Un bouton rond (icône de Corruption) est posé autour de la minimap : clic gauche pour ouvrir la
fenêtre, clic droit pour créer ou mettre à jour les macros, glisser pour le déplacer le long du
bord. `/obr minimap off` le cache.

Trois macros de personnage sont créées :

- **OBR** : la rotation. Toujours `/petattack` en tête pour que le familier engage en premier.
  Sans baguette, `/startattack` et des Traits de l'ombre finissent le monstre ; avec une
  baguette équipée, la séquence se termine par `!Tir` répété : le tir ne part qu'une fois les
  DoTs posés (une ligne `/cast !Tir` séparée relançait la baguette à chaque appui et coupait
  l'incantation de Corruption), et le `!` empêche de couper le tir auto si tu réappuies.
- **OBR_VIE** : le sustain. Clic = Drain de vie, Shift+clic = Connexion (ou Pacte noir si tu
  as le talent).
- **OBR_SOCIAL** : ouvre l'anneau social (voir ci-dessous). Contient juste `/obr social`.
- **Macros rapides** (un bouton = une phrase, courte, en français puis en anglais) :
  - **OBR_GROUPE** : `/invite` ta cible, puis lui chuchote « Groupe ? / Group? » (si la cible
    n'est pas un joueur, le texte part dans le canal courant).
  - **OBR_OUI** : « Oui / Yes » avec l'emote /oui.
  - **OBR_NON** : « Non / No » avec l'emote /non.
  - **OBR_MERCI** : « Merci / Thank you <cible> » puis « GL HF », avec l'emote /merci.
  - **OBR_DECK** : « Je joue sur Steam Deck (manette) : difficile d'écrire, mais je fais au mieux ! »
    puis la même phrase en anglais, avec l'emote /hausser (pour prévenir un groupe que tu réponds peu).

  Chacune contient `/obr say <clé>` : l'addon joue l'emote et parle dans le canal choisi dans
  l'anneau (Auto = raid, groupe, sinon dire). `/obr say off` ne les crée plus. Les textes sont
  dans `data/Social.lua` (`ns.QuickMacros`).

Glisse-les une fois sur ta barre depuis `/macro`, ou tape `/obr slot 1`, `/obr slot vie 2`,
`/obr slot social 3`, `/obr slot oui 4`… pour que l'addon les pose lui-même (emplacements 1 à 12 =
barre principale). Sur la barre manette : `/obr pad oui 1 2 3` (voir plus bas).

### Anneau social

Une roue de huit phrases rapides, pensée pour la manette (disposition Xbox / Steam Deck), dessinée
en camembert avec les textures du menu radial du mode manette de Forever (icône ronde par phrase,
part dorée et curseur sur la phrase choisie, canal au centre). `/obr social scale 0.8` la réduit
(0,5 à 2), `/obr social reset` la recentre.
Chaque phrase joue une emote (bonjour = /salut, merci = /merci, oui = /oui, non = /non…) et
envoie un texte dans le canal choisi. `%t` dans un texte est remplacé par le nom de ta cible.

| Entrée                | Manette                | Souris / clavier                    |
|-----------------------|------------------------|-------------------------------------|
| ouvrir / fermer       | bouton lié via `/obr bind` | `/obr social`                   |
| choisir une phrase    | stick gauche ou croix  | survol, flèches, ou touches 1 à 8   |
| envoyer               | A                      | clic, Entrée                        |
| fermer                | B                      | Échap                               |
| canal                 | LB / RB                | molette, clic au centre, PageUp/Down |
| page                  | Y, LT / RT             | Tab                                 |

**Barre manette de Forever** : l'écran d'assignation de Blizzard refuse parfois la macro
(« Impossible de sélectionner une action à associer à l'emplacement de manette »). L'addon peut la
poser lui-même sur la barre manette : `/obr pad` liste les 3 pages × 4 barres × 8 boutons et leur
contenu, puis `/obr pad social 1 2 3` pose OBR_SOCIAL sur la page 1, barre 2, bouton 3 (`obr`,
`vie`, `groupe`, `oui`, `non`, `merci` et `deck` marchent aussi). C'est exactement ce que fait l'écran de Blizzard (PlaceAction sur
l'emplacement de stockage manette), sans passer par son interface.

**Lier un bouton de la manette** : tape `/obr bind` (ou le bouton « Lier l'anneau à un bouton
manette » de la fenêtre) puis appuie sur le bouton voulu. C'est un vrai raccourci, visible dans
Options > Raccourcis > AddOns > One Button Rotation, donc il marche même si l'interface manette
refuse de placer la macro OBR_SOCIAL sur un bouton. `/obr bind PADRSTICK` lie directement une
touche nommée, `/obr bind clear` délie. L'anneau se déplace à la souris (glisser) et
`/obr social reset` le recentre.

Canaux : Auto (raid si en raid, groupe si groupé, sinon dire), Dire, Groupe, Raid, Guilde,
Crier, Répondre (murmure au dernier interlocuteur). Le canal choisi est mémorisé. L'anneau se
ferme après l'envoi (`/obr social keep` pour qu'il reste ouvert). Les phrases sont dans
`data/Social.lua` : deux pages de huit, libres à modifier.

### Talents par niveau

`/obr talents` (ou la page « Talents » de la fenêtre) ouvre la liste des 51 points de
talents du build Affliction drain tank de Method, un par niveau de 10 à 60, confrontée aux talents
réellement pris par le personnage : `[x]` pris, `[>]` prochain point à placer (avec la raison donnée
par le guide), `[!]` en retard, `[ ]` plus tard. L'en-tête indique les points placés et ceux qui
attendent, la liste signale les talents pris hors du build, et une ligne « <- ton niveau » marque où tu
en es. Au level up, le chat rappelle le talent à prendre. `/obr talents chat` donne le résumé dans le
chat. Les talents sont lus via `C_SpecializationInfo.GetTalentInfo` ; sans cette API l'état est
approximatif. L'ordre est dans `data/WarlockTalents.lua` (Method ne détaille que le build Affliction).

### Hôtel des ventes : onglet « Bonnes affaires »

Un onglet de plus dans la fenêtre de l'hôtel des ventes (celui de Forever est l'hôtel des ventes
moderne, API `C_AuctionHouse`). Il cherche les enchères dont le **rachat est inférieur au prix de
revente chez un vendeur** et permet de les acheter pour les revendre au PNJ.

- **Scanner l'hôtel des ventes** : scan complet (`C_AuctionHouse.ReplicateItems`), autorisé une
  fois toutes les 15 minutes ; le bouton affiche le compte à rebours et refuse avant. Le résultat
  est dépouillé par paquets pour ne pas figer le jeu, les prix vendeur manquants sont chargés, puis
  une recherche par objet retenu (60 au maximum, le client limite à 100 recherches/minute) récupère
  les enchères réelles et leurs identifiants. La liste est triée par gain décroissant.
- **Un clic sur une ligne = un achat.** Le jeu exige qu'un achat (`PlaceBid`,
  `StartCommoditiesPurchase`) parte d'un clic ou d'une touche : aucun addon ne peut acheter en boucle
  tout seul. Pour les objets empilables, l'addon demande d'abord le prix réel au serveur et confirme
  seulement s'il reste rentable.
- **Acheter le suivant** : achète la meilleure affaire restante. Un raccourci « Hôtel des ventes :
  acheter la prochaine bonne affaire » (Options > Raccourcis > AddOns) permet de le marteler à la
  manette. Chaque résultat (acheté, déjà parti, prix monté, pas assez d'argent…) est noté. Si la
  confirmation automatique d'un devis d'empilable est ignorée par le jeu, la ligne passe en
  « Clic : confirmer le devis » et le clic suivant confirme.
- **Tout acheter (essai)** : envoie d'un seul clic l'achat de toutes les enchères uniques de la
  liste. Si le jeu n'en accepte qu'une par clic, les autres échouent sur « pas de confirmation » et
  restent achetables avec « Acheter le suivant ».
- L'onglet est greffé comme le font Auctionator et VendorFloor (LibAHTab) : aucune table de la
  fenêtre Blizzard n'est modifiée, sinon la fermeture de l'hôtel des ventes est bloquée (« action
  non utilisable par l'IU de Blizzard »). Le scan suit aussi ce que VendorFloor a constaté en jeu :
  indices de la liste complète à partir de 0, liste reçue par morceaux, requêtes jetées quand la
  ligne est occupée (renvoyées), quantités plafonnées à la taille de pile.
- **Rapport (chat)** : nombre d'achats, dépense, revente vendeur attendue, gain, échecs et causes.
- `/obr ah profit <cuivre>` fixe le gain minimal par affaire (0 par défaut) ; `/obr ah` donne l'état,
  `/obr ah scan`, `/obr ah next`, `/obr ah rapport` font la même chose que les boutons.

### Guide RestedXP (addon compagnon DMK_RXP)

Onglet **RestedXP** (ou `/obr rxp`). Ton export RestedXP (le `.txt` téléchargé sur leur site) est
transformé en un petit addon à part, **DMK_RXP**, distribué hors GitHub (zip privé sur ton stockage,
à installer une fois à la main : WoWDeck → Manual Install → lien direct du zip). Au chargement,
RestedXP lit la variable `RXPString` que DMK_RXP a posée et importe le guide tout seul la première
fois (sa fenêtre d'import s'ouvre, puis les guides apparaissent dans son menu). Rien à copier.

L'onglet montre l'état (DMK_RXP présent, RestedXP chargé, guide importé ou non), un bouton
« Importer maintenant » si l'import automatique n'a pas eu lieu, et en secours un bouton qui met
tout le texte dans une zone déjà sélectionnée pour un Ctrl+C / Ctrl+V dans RestedXP > Import.

Pour changer de guide : remplace `private/restedxp_guide.txt`, puis `./deploy.sh` reconstruit
`dist/DMK_RXP.zip` (via `tools/gen_rxp_guide.sh`) et le met en ligne ; réinstalle-le sur le Deck.

### Phases démoniste

| Phase | Affliction | Démonologie | Destruction |
|---|---|---|---|
| 1 à 9 | Immolation, Corruption, puis Trait de l'ombre / mêlée / baguette | idem | idem |
| 10 à 29 | Plaie d'agonie, Corruption, puis baguette | Plaie d'agonie, Immolation, puis Trait de l'ombre / baguette | Immolation (+ Conflagration, Immolation à 29), puis Trait de l'ombre / baguette |
| 30+ | Drain tank : Plaie d'agonie, Corruption, Siphon de vie (talent), Drain de vie ×3, avec `[nochanneling]` | comme 10+ | comme 10+ |

Restent manuels, volontairement : Brûlure de l'ombre (finisher), Douleur brûlante (aggro),
Feu de l'âme gratuit (proc Decimation), Peur, Drain d'âme.
- Avant le niveau 10 il n'y a pas de talents : choisis ta spé dans la fenêtre ou avec
  `/obr spec affli` / `demono` / `destru`. Dès que tu as des points de talents, la
  détection automatique prend le dessus.

### Commandes

| Commande              | Effet                                                        |
|-----------------------|--------------------------------------------------------------|
| `/obr`                | ouvre / ferme la fenêtre                                     |
| `/obr create`         | crée ou met à jour la macro maintenant                       |
| `/obr preview`        | affiche la macro dans le chat sans la créer                  |
| `/obr spec <nom>`     | fixe la spé manuellement (`auto` pour revenir aux talents)   |
| `/obr slot <n>`       | pose OBR sur l'emplacement de barre n (0 = désactiver)       |
| `/obr slot vie <n>`   | idem pour OBR_VIE                                            |
| `/obr slot social <n>` | idem pour OBR_SOCIAL                                        |
| `/obr slot groupe\|oui\|non\|merci\|deck <n>` | idem pour les macros rapides                 |
| `/obr ah [scan\|next\|rapport\|profit <n>]` | hôtel des ventes : bonnes affaires (voir ci-dessus) |
| `/obr say <clé>`      | envoie une phrase rapide (groupe, oui, non, merci, deck) ; `on`/`off` crée ou non les 5 macros |
| `/obr social`         | ouvre / ferme l'anneau social ; `on`/`off` crée ou non la macro ; `keep` garde l'anneau ouvert après envoi ; `scale <n>` taille ; `reset` recentre |
| `/obr auto on\|off`   | mise à jour automatique                                      |
| `/obr strict on\|off` | `off` = inclure les sorts par niveau sans vérifier le grimoire |
| `/obr pet on\|off`    | ajoute `/cast [nopet,nocombat] Invocation …` à la macro      |
| `/obr immo on\|off`   | Affliction 10-29 : ajoute Immolation en 3e DoT (hors guide Method) |
| `/obr minimap on\|off` | affiche ou cache le bouton autour de la minimap                 |
| `/obr minimap <angle>` | place le bouton (0 = droite, 90 = haut, 180 = gauche, 270 = bas)  |
| `/obr bind [touche\|clear]` | lie l'anneau social à un bouton manette (appuie dessus après la commande) |
| `/obr info`           | infos de debug (client, API disponibles, sorts connus)       |
| `/obr find <texte>`   | cherche dans le grimoire les sorts dont le nom contient le texte (IDs) |
| `/obr rangs`          | rang le plus élevé connu pour chaque sort de la macro        |
| `/obr talents`        | liste des points de talents par niveau (guide Method) et où tu en es ; `chat` = résumé dans le chat |
| `/obr aide`           | explication des macros dans une fenêtre à part, en grand                 |
| `/obr rxp [chat]`     | onglet RestedXP (guide embarqué : état, import, copie du texte)           |
| `/obr pad [page]`     | liste la barre manette de Forever et son contenu                         |
| `/obr pad <obr\|vie\|social> <page> <barre> <bouton>` | pose la macro sur ce bouton de la barre manette |

### Exemples

Démoniste niveau 4 sans baguette :

```
#showtooltip
/petattack
/startattack
/castsequence reset=target/combat Immolation, Corruption, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre, Trait de l'ombre
```

Affliction niveau 15 avec baguette :

```
#showtooltip
/petattack
/castsequence reset=target/combat/10 Plaie d'agonie, Corruption, !Tir, !Tir, !Tir, !Tir
```

Affliction niveau 35 (drain tank) :

```
#showtooltip
/petattack
/castsequence [nochanneling] reset=target/combat/15 Plaie d'agonie, Corruption, Siphon de vie, Drain de vie, Drain de vie, Drain de vie
```

## Si ça ne marche pas

**`/obr` répond « commande inconnue »** alors que l'addon est dans la liste : son code n'a pas
tourné.

1. Dans la liste des addons (écran de sélection du personnage, bouton AddOns), regarde s'il
   est marqué **obsolète** : coche « Charger les AddOns obsolètes » en haut de la liste.
2. Vérifie le chemin : il faut `Interface\AddOns\OneButtonRotation\OneButtonRotation.toc`,
   pas un dossier `OneButtonRotation` imbriqué dans un autre.
3. Active l'affichage des erreurs Lua avec `/console scriptErrors 1` puis `/reload`, et note
   l'erreur affichée.
4. Récupère le numéro d'interface du client avec `/run print((select(4, GetBuildInfo())))`
   pour l'ajouter dans le `.toc` s'il n'y est pas.

**Les DoTs font peu de dégâts** : WoW Forever garde les **rangs de sorts** de Classic. Chaque
nouveau rang s'achète chez le maître de classe, en général tous les 2 niveaux, et rien ne
prévient. La macro écrit les sorts sans numéro de rang, donc elle lance toujours le rang le plus
élevé que tu connais : si tu n'as pas revu le maître depuis le niveau 4, tu lances toujours le
rang 1. `/obr rangs` liste le rang connu de chaque sort de la macro, et l'addon rappelle le
maître à chaque niveau pair.

**La macro relance le même sort en boucle après un nouveau rang** (ex. Corruption au niveau 24) :
c'est un comportement du client. Le `/castsequence` mémorise, au premier appui, l'ID de chaque
étape d'après le texte de la séquence et ne le relit jamais (jusqu'au `/reload`). Après un
nouveau rang, « Corruption » lance le rang 3 mais l'étape attend l'ID du rang 2 : elle n'avance
plus. Depuis la 0.5.1, l'addon encode le rang connu dans le texte de la macro (le nombre d'espaces
après chaque virgule = rang du sort, invisible pour le jeu) et la réécrit dès qu'un sort est
appris : le client relit alors les IDs. Si ça arrive quand même (rang appris en combat, addon
pas chargé), `/reload` suffit.

**Autres problèmes** : tape `/obr info` et copie le résultat : il indique la version du client, quelles fonctions
d'API existent et si chaque sort de la rotation est détecté comme connu.

- Les sorts sont tous « INCONNU » alors que tu les as : `/obr strict off` en attendant un
  correctif (les sorts seront inclus d'après leur niveau d'apprentissage).
- La spé n'est pas détectée malgré des talents : `/obr spec <nom>` en attendant.

## Ajouter une classe ou modifier une rotation

Tout est dans `data/<Classe>.lua`, à déclarer ensuite dans `OneButtonRotation.toc`.
Un fichier déclare `ns.SpecNames.<CLASSE>` (clés, libellés, onglet de talents) et
`ns.Rotations.<CLASSE>.<SPE>.phases` : une liste de phases par niveau minimum, chacune
avec ses macros. Le format complet est commenté en tête de `data/Warlock.lua`.

```lua
{ minLevel = 10, name = "Baguette (10-29)",
  macros = {
    { name = "OBR", slotKey = "actionSlot",
      lines = { "/petattack", { text = "/startattack", nowand = true } },
      sequence = { { id = 980 }, { id = 172 } },          -- Plaie d'agonie, Corruption
      filler = { id = 686, nowand = true }, fillerCount = 4, -- Trait de l'ombre sans baguette
      reset = "target/combat/10",
      after = { { fmt = "/cast !%s", args = { { id = 5019, wand = true } } } }, -- Tir
    },
  },
}
```

Les IDs sont ceux du rang 1 ; le nom est résolu en jeu dans la langue du client (ce qui
suit les renommages de Forever), et un `/castsequence` sans rang lance toujours le rang le
plus élevé connu. Dans la séquence, chaque virgule est suivie d'autant d'espaces que le rang
connu du sort qui la précède (`ns.JoinSequence`) : voir « relance le même sort en boucle ». Une entrée peut porter `minLevel`, `maxLevel`, `talent` (ID à connaître),
`wand` / `nowand` (baguette équipée ou non), `option` (clé d'option) ou `alt` (liste
d'entrées, la première utilisable gagne).

## Construire et publier le zip

```
./build.sh        # produit dist/OneButtonRotation-<version>.zip
./deploy.sh       # build + upload S3 + purge CloudFront
./deploy.sh --release   # idem + commit et push → Release GitHub v<version> (WoWDeck / WowUp)
```

Code source et Releases : https://github.com/dehemka/wow_obr. Dans **WoWDeck** (Manual Install) ou
**WowUp** (Installer depuis une URL), cette adresse donne les mises à jour automatiques : à chaque
push sur main qui change `## Version:`, le workflow GitHub publie une Release avec un zip `-forever`
et un `release.json`.

La version est lue dans `OneButtonRotation.toc` (`## Version:`). Le déploiement publie :

- `https://storage.dehemka.net/public/wow/obr.zip` : lien court, dernière version
- `https://storage.dehemka.net/public/wow/addons/OneButtonRotation-<version>.zip` : version figée
- `https://storage.dehemka.net/public/wow/addons/version.txt` : numéro de la version en ligne
