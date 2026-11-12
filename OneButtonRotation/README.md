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
   aperçu des macros), **Talents** (ordre des points et où tu en es), **Anneau social**, **Options**
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

Glisse-les une fois sur ta barre depuis `/macro`, ou tape `/obr slot 1`, `/obr slot vie 2` et
`/obr slot social 3` pour que l'addon les pose lui-même (emplacements 1 à 12 = barre principale).

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
contenu, puis `/obr pad social 1 2 3` pose OBR_SOCIAL sur la page 1, barre 2, bouton 3 (`obr` et
`vie` marchent aussi). C'est exactement ce que fait l'écran de Blizzard (PlaceAction sur
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
plus élevé connu. Une entrée peut porter `minLevel`, `maxLevel`, `talent` (ID à connaître),
`wand` / `nowand` (baguette équipée ou non), `option` (clé d'option) ou `alt` (liste
d'entrées, la première utilisable gagne).

## Construire et publier le zip

```
./build.sh        # produit dist/OneButtonRotation-<version>.zip
./deploy.sh       # build + upload S3 + purge CloudFront
```

La version est lue dans `OneButtonRotation.toc` (`## Version:`). Le déploiement publie :

- `https://storage.dehemka.net/public/wow/obr.zip` : lien court, dernière version
- `https://storage.dehemka.net/public/wow/addons/OneButtonRotation-<version>.zip` : version figée
- `https://storage.dehemka.net/public/wow/addons/version.txt` : numéro de la version en ligne
