# Compagnon Guild Chronicle

Petit programme Python **facultatif**, pour le seul **rédacteur** de la gazette, sur **son** PC.
Les autres membres n'en ont pas besoin : ils reçoivent ce que le rédacteur publie par la
synchronisation de l'addon.

Il ne touche pas au jeu : il **lit des fichiers** que le jeu écrit (SavedVariables, journaux de
combat) et **écrit un seul fichier**, `Interface/AddOns/GuildChronicle_Press/Press.lua`, que le
jeu relit au `/reload`. Rien n'est publié tant que tu ne l'as pas validé en jeu.

## Installation (une fois)

1. Python 3.11 ou plus récent (aucune bibliothèque à installer).
2. Copier le dossier `GuildChronicle_Press` dans `_forever_/Interface/AddOns/`, puis **redémarrer le
   jeu** une fois (un nouvel addon n'est détecté qu'au démarrage ; ensuite `/reload` suffit).
3. Copier `companion/config.example.toml` en `companion/config.toml` et y mettre le chemin de `_forever_`.

## Utilisation

Depuis le dossier qui contient `companion/` :

```text
python -m companion status            ce que le compagnon voit
python -m companion facts --days 7    faits partagés de la semaine, numérotés, avec leurs identifiants
python -m companion deaths            causes de mort (journaux de combat) -> Press.lua
python -m companion articles          articles .md de companion/articles -> Press.lua
python -m companion run               les deux
```

Puis en jeu : `/reload`, onglet **Gazette**, bouton **Rédaction** : *Publier* ou *Ignorer* chaque élément.

### Journaux de combat

En jeu, tape `/combatlog` avant de jouer (et à nouveau pour arrêter). Le client écrit
`_forever_/Logs/WoWCombatLog-….txt`. Le compagnon y cherche :

- les **morts** de joueurs et le dernier coup reçu (cause) : il **complète** une mort déjà
  enregistrée par l'addon (même personnage, même instant), il n'en crée jamais ;
- les **coups fatals PvP** contre des personnages **déjà connus** du tableau de chasse.

L'écart d'horloge entre ton PC et le serveur est estimé et corrigé automatiquement.

### Articles écrits à la main

Un fichier `.md` par article dans `companion/articles/` (voir `exemple.md.txt`). Les `refs` sont
les identifiants donnés par `facts` : ce sont les « sources » que les lecteurs verront en jeu.

## Pas encore là

- Rédaction automatique par un LLM (avec consentement séparé de chaque membre, voir
  `docs/ARCHITECTURE.md` §7 et §8.4).

## Tests

```text
python3 -m unittest discover -s tests/companion -t .
```
