# Renatus Admin

Application Windows des **officiers et du rédacteur**. Elle remplace le compagnon Python.
Les membres n'en ont pas besoin : ils ont le launcher et l'addon `Renatus`.

Elle lit les fichiers du jeu (journal de l'addon, journaux de combat), l'armurerie publique, et
n'écrit qu'un fichier : `Interface/AddOns/Renatus_Admin/Press.lua`. En jeu, avec l'addon
`Renatus_Admin` : `/reload`, puis l'icône clé de la minimap (ou `/radmin`) : onglets **Rédaction**
(articles) et **Guilde rivale** pour publier ou ignorer chaque élément (officiers seulement),
**Remise à zéro** pour retirer, pour toute la guilde, ses propres événements cochés (gazettes,
cartes publiées, ouvertures de boosters, lettres, journal ; les réglages restent).
Rien n'est diffusé à la guilde sans ce clic, sauf l'effectif de la guilde rivale déjà en vigueur.

## Ce qu'elle fait

- **Accueil** : versions des addons, bouton pour installer ou mettre à jour `Renatus_Admin`
  (le launcher des membres ne l'installe jamais), état du journal, éléments en attente.
- **Suivi** : tout ce que voit le journal de l'officier, pour vérifier que l'addon marche chez
  chacun. Membres de la guilde (équipés ou non, version de l'addon, badge *nouveau* les 7
  premiers jours, dernière activité, événements manquants), santé de la synchro (dernier reçu,
  délai, reçus directs ou relayés, rejets et motif), alertes, activité des 30 derniers jours et
  flux des derniers événements filtrable par membre et par type. Lecture seule.
- **Guilde rivale** : nom ou lien de l'armurerie (`https://armorywowforever.com/g/forever/eu/pvp/...`).
  Propose en jeu le réglage de guilde (la guilde rivale de tous les membres) et l'effectif relevé
  (niveau, classe, race, rang ; score d'équipement, niveau d'objet et dernière connexion pour les
  ennemis déjà connus de la guilde). En jeu, provenance « Armurerie ». L'effectif est relu au
  lancement de l'app puis toutes les heures, et proposé en jeu
  sans clic dans l'app, seulement s'il a changé (membres, niveaux, rangs, équipement). En jeu,
  `Renatus_Admin` le publie tout seul à la connexion d'un officier (case à cocher dans l'onglet
  Guilde rivale) ; changer de guilde rivale demande toujours un clic.
- **Gazette** : un numéro par parution. Choix des faits envoyés à l'IA (ceux déjà parus dans un
  numéro sont décochés), aperçu exact de la demande, brouillon à relire (articles, rejets,
  réponse brute de l'IA) avant de le proposer en jeu, mise en page (maquette au choix de l'IA
  ou imposée dans les Réglages, voir `docs/ARCHITECTURE.md` §7.1 bis). Les articles écrits à la
  main (`.md`, voir `exemple-article.md.txt`) entrent dans le numéro. Les **cartes de l'album**
  partent avec le numéro (`CARD_SET`, numérotées) : choisies par des règles, nommées et décrites
  par l'IA pour les membres qui l'ont accepté ; publiées en jeu avec la mise en page.
- **Éditeur** : le catalogue de l'album et les numéros déjà publiés, tels que les membres les
  voient. Chaque carte et chaque article peut être corrigé ou retiré (puis rétabli) : la
  correction part dans Press.lua et se publie en jeu comme le reste. Une carte corrigée garde
  son numéro et change aussi chez ceux qui l'ont déjà ouverte ; une carte retirée ne sort plus
  des boosters mais reste à ceux qui l'ont ; un article corrigé reste à sa place dans son numéro.
- **Discord** : chaque numéro publié en jeu part sur le salon de la guilde par un webhook
  (Réglages), en images : les pages comme en jeu, articles en entier (un article coupé continue
  sur les pages « Suites »). L'app le poste au /reload ou à la déconnexion qui suit la
  publication, puis remplace ses pages si un article est corrigé ou retiré. Les numéros parus
  avant le réglage du webhook partent par le bouton de l'Éditeur. Le webhook reste sur le PC.
- **Automatique** : fenêtre ouverte, après chaque `/reload` ou déconnexion, elle analyse les
  journaux de combat s'il y en a et, si coché, rédige
  un numéro quand le précédent a une semaine (faits nouveaux seulement), puis le signale par
  une notification.

L'IA est une commande qui lit la demande sur son entrée standard (Réglages), par exemple Claude
Code sur le Raspberry Pi : `["ssh", "pi5", "cd /tmp && ~/.local/bin/claude -p --output-format json --tools '' --no-session-persistence"]`
(il faut une clé SSH côté Windows).

## Ligne de commande (WSL ou Linux)

```text
cd admin && cargo build --release
target/release/renatus-admin config wowPath "C:/MyGames/World of Warcraft/_forever_"
target/release/renatus-admin status | monitor [json] | facts | deaths | articles <dossier> | gazette [--show]
target/release/renatus-admin rival "<nom ou lien>" | run | install-admin
target/release/renatus-admin print [n°] | discord [n°] [encore]
```

`--dry-run` n'écrit rien. Réglages : `~/.config/renatus-admin/config.json`.

## Développement

- `admin/core` : toute la logique, testée sous Linux (`cd admin && cargo test`) ; dépend de
  `launcher/core` (détection du jeu, lecture des releases).
- `admin/src-tauri` : la fenêtre Windows. Depuis WSL : `admin/scripts/build-windows.sh`
  (`LAUNCHER_WIN_TOOLS=C:\...` pour un dossier avec `node\` et `toolchain\` portables).
- `admin/ui` : HTML/CSS/JS sans outil de build.
- Publier : `admin/scripts/bump.sh 0.2.0`, commit, push. `admin-release.yml` compile, signe et
  publie `admin-v0.2.0`, puis remplace `latest.json` dans la release fixe `admin-updates`, que
  l'application lit pour se mettre à jour (la release « latest » appartient au launcher).
