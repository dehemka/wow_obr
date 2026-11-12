# One Button Rotation — addon WoW Forever

Addon pour **World of Warcraft Forever** qui génère et tient à jour des macros
« one button rotation » (`/castsequence`) adaptées à ta classe, ta spé, ton niveau
et ton équipement. Il relit ton grimoire et régénère les macros au level up, à chaque
nouveau sort, changement de talents ou baguette équipée. Pensé pour jouer à la manette
(Steam Deck) : anneau social radial, rappel de l'ordre des talents, placement direct
sur la barre manette.

Classe supportée : **Démoniste** (Affliction, Démonologie, Destruction), rotations de
leveling solo d'après le guide Method.

## Installation

### Avec WowUp (mises à jour automatiques)

1. Dans WowUp, sélectionne ton client **Forever** (Options → WoW Clients → Re-Scan s'il manque).
2. Mes addons → **Installer depuis une URL** → colle `https://github.com/dehemka/wow_obr`.
3. WowUp installe la dernière Release et te proposera les suivantes.

### À la main

Télécharge le zip de la [dernière Release](https://github.com/dehemka/wow_obr/releases/latest)
(ou https://storage.dehemka.net/public/wow/obr.zip) et décompresse-le dans
`World of Warcraft/_forever_/Interface/AddOns/`. Tu dois obtenir
`Interface/AddOns/OneButtonRotation/OneButtonRotation.toc`.

## Utilisation

En jeu : `/obr` ouvre la fenêtre (Rotation, Talents, Anneau social, Options, Aide).
Le mode d'emploi complet, les commandes et le dépannage sont dans
[OneButtonRotation/README.md](OneButtonRotation/README.md).

## Développement

- `tests/` : tests hors jeu (Lua 5.1, mock de l'API WoW), voir le README de l'addon.
- `build.sh` construit `dist/OneButtonRotation-<version>.zip`.
- `deploy.sh` publie le zip sur storage.dehemka.net ; `deploy.sh --release` commite, tague
  `v<version>` et pousse : le workflow GitHub Actions crée alors la Release (zip `-forever`
  + `release.json`) que WowUp consomme.
- Le numéro de version se change dans `OneButtonRotation/OneButtonRotation.toc` (`## Version:`).

Licence MIT.
