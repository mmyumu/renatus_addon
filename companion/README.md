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

## Gazette rédigée par IA

```text
python -m companion gazette --show    affiche exactement ce qui serait envoyé à l'IA (n'appelle rien)
python -m companion gazette           rédige l'édition de la semaine -> Press.lua
```

Avec `enabled = true` dans la section `[llm]` de `config.toml`, `run` rédige aussi la gazette,
**une fois par semaine** (édition déjà faite = ignorée ; `gazette` force une nouvelle édition).

**Ce qui est envoyé** : uniquement les événements **partagés** (réglés sur « Guilde ») des 7
derniers jours, et **seulement ceux des personnages qui ont coché** « La gazette rédigée par IA
peut parler de moi » (Paramètres, en jeu). Un membre qui n'a pas coché n'est jamais nommé : ses
événements sont écartés, un fait d'un autre membre qui le cite est retiré, et dans une
expédition il devient « +1 autre participant ». Les rivaux sont remplacés par des alias
(« Rival A (voleur Orc) »). La provenance est conservée (« selon X » pour ce qui est déclaré à la main).

**Ce qui est vérifié au retour** : chaque article doit citer des faits fournis (sinon rejeté),
ne nommer aucun membre sans consentement ni aucun rival, et rester court. Les articles retenus
arrivent dans **Rédaction** en jeu, marqués « Article (IA) » : tu les relis, publies ou ignores.
En jeu, ils s'affichent « rédigé par IA, relu par <toi> ».

### Brancher le Claude de ton Raspberry Pi

Le compagnon lance une commande, lui envoie la demande sur l'entrée standard et lit la réponse.
Avec Claude Code installé et connecté sur le Pi :

1. Sur ton PC, une clé SSH vers le Pi (une fois) : `ssh-keygen` puis
   `type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh moi@pi5 "cat >> ~/.ssh/authorized_keys"`
   (PowerShell). Vérifie que `ssh moi@pi5 echo ok` répond sans mot de passe.
2. Vérifie Claude sur le Pi : `ssh moi@pi5 "~/.local/bin/claude -p 'dis bonjour'"`
   (adapte le chemin si `which claude` sur le Pi donne autre chose).
3. Dans `config.toml` :

   ```toml
   [llm]
   enabled = true
   command = ["ssh", "moi@pi5", "cd /tmp && ~/.local/bin/claude -p --output-format json --tools '' --no-session-persistence"]
   ```

L'IA n'a aucun outil (`--tools ''`) : elle lit la demande et répond, rien d'autre. Elle utilise
l'abonnement du compte connecté sur le Pi (une édition par semaine pèse peu, mais c'est partagé
avec ce que le Pi fait déjà).

## Tests

```text
python3 -m unittest discover -s tests/companion -t .
```
