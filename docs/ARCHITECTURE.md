# Renatus — Architecture (v2)

> Mise à jour : 18/11/2026. Elle intègre les décisions du 18/11 et l'extension des spécifications : Wanted Board, Gazette, collecte enrichie, journaux de combat et cartes.
> La v1 (analyse initiale détaillée de Renacoach) est dans l'historique git (`git show 4d6a2f9:docs/ARCHITECTURE.md`).
> Les points **[À VÉRIFIER]** dépendent de la sonde `tools/ChronicleProbe` (§12).

---

## 0. Décisions prises

| # | Décision | Conséquence |
|---|---|---|
| D1 | **Un seul addon** `Renatus`. Renacoach devient le module `Voice`, une option « pour la blague ». | Fait : `Renatus/Voice/`, désactivé par défaut, `/renatus voice on` ou `/renacoach on`. |
| D2 | **Bibliothèques externes autorisées.** | v0.3.0 : finalement **aucune** n'est nécessaire. Sérialisation, découpage et file d'envoi sont écrits dans l'addon (`Sync/`, quelques centaines de lignes, testées), ce qui évite toute dépendance à vérifier sur Forever. LibDeflate (compression) reste une option si le débit s'avère insuffisant. |
| D3 | Renacoach visait **Retail** (dernière mise à jour en mai 2026). | Le TOC déclare `16001, 120005` (Forever et Retail). Le code teste l'existence de chaque API au lieu de supposer une version. |
| D4 | Dépôt git initialisé. Le dossier est une copie de travail. | L'historique conserve Renacoach d'origine (`07cd01b`). |
| D5 | Le « TCG » devient l'**Album de guilde** : collection et échanges, **aucun combat de cartes**. | §9 |

---

## 1. État actuel du dépôt

### Distribution : launcher et publication automatique (19/11/2026)

- Dépôt public `mmyumu/renatus_addon`. Push sur `main` avec une nouvelle version dans `Renatus.toc` → `addon-release.yml` publie `v<version>` (`Renatus-<version>.zip`, notes = message du commit ; tiret = version de test, en prerelease).
- `launcher/` : application Tauri 2 (Windows) qui détecte `_forever_`, vérifie toutes les 10 minutes, installe la dernière release (même règles que `tools/deploy.sh`) et se met à jour elle-même (`launcher-v*`, release « latest », `latest.json` signé). Détails : `launcher/README.md`.

### Avancement v1.0.11 et Renatus Admin 0.4.6 (23/11/2026) : de quoi varier la gazette

- **Nouveaux faits collectés par l'addon** (pour tous les membres, catégories de confidentialité habituelles) :
  - `Collectors/Feats.lua` : `DUEL` (vainqueur, perdant, fuite ; `occ` commun aux deux duellistes), `NEAR_DEATH` (combat survécu à 5 % de vie ou moins), `RESCUED` (ramené à la vie par quelqu'un), `ROLL_EXTREME` (1 ou 100 au `/roll` 1-100, au besoin ou à la cupidité), `REPUTATION` (honoré, révéré, exalté), `MONEY` (10, 100, 1000 po pour la première fois ; l'or déjà possédé au premier passage ne compte pas), `MOUNT` (journal des montures, peut ne jamais venir sur Forever), `HEARTH_BIND` (pierre de foyer liée ailleurs).
  - `Collectors/Counters.lua` : compteurs du jour, envoyés en **un seul** événement caché `COUNTERS` au changement de jour : sauts, cuites, visites à l'ange, « sacs pleins », poissons, pierres de foyer, or gagné et dépensé, émotes visant un membre de la guilde (`/gifle`, `/bise`…).
  - Sources : messages système du client, reconnus avec ses propres chaînes (toute langue, arguments positionnels compris). En instance, Forever les rend secrets : ignorés. **À confirmer en jeu (V12).**
- **Renatus Admin, gazette** :
  - Plus de plafond de 150 faits : toute la période part à l'IA.
  - Nouveaux faits : bestiaire (`MOB_KILL`, un fait par membre, rares et élites d'abord), petites statistiques (`COUNTERS` additionnés ; une émote visant un membre sans consentement est retirée), textes des nouveaux événements, et un seul fait pour un événement enregistré par plusieurs membres (même `occ` : boss, sortie, duel).
  - Faits calculés (`derived.rs`) sur tout l'historique du journal : **records** de la guilde (par jour : morts, quêtes, victoires honorables, niveaux, espèces, contrées, sauts, cuites ; par sortie : durée, morts, boss ; survie la plus juste), un seul par catégorie et par période, contre le record d'avant ; **jalons** (10e mort, 100e quête…, par membre et pour toute la guilde) ; **anniversaires** (mois dans la guilde, années dans le journal) ; **palmarès** et **duo inséparable** du nouveau numéro. Les textes précisent qu'ils sont comptés depuis le début du journal Renatus.
  - **Champs de bataille et arènes** (`loc.it` = `pvp` ou `arena`, même règle que `Views.InHunt`) : leurs morts et victoires ne comptent ni dans les affrontements, ni dans les records, jalons et palmarès. Elles forment un fait « champ de bataille (match organisé par le jeu) » par membre et par champ de bataille, que le prompt demande de raconter à part, en chronique sportive, sans en faire un score face à la faction adverse.
  - **Mémoire de la rédaction** : les 3 derniers numéros publiés, en entier, sont joints à la demande (un article nommant un membre sans consentement en est retiré), avec la consigne de faire suivre les feuilletons sans reprendre titres, tournures ni angles, et de ne citer que les faits numérotés.

### Avancement v0.11.0 (19/11/2026)

- **Album** : boosters réels (par défaut 1 par jour joué, +1 par niveau, boss ou sortie avec un membre de la guilde, 5 par jour au plus ; ces trois nombres sont un réglage de guilde `GUILD_CONFIG.p.boosters`, onglet **Boosters** de `Renatus_Admin`, appliqué à partir du jour de sa diffusion : les jours passés gardent la règle d'alors ; ouvertures enregistrées en événements `BOOSTER_OPEN` cachés, collection rejouée depuis eux). Série fixe **Azeroth** (`Core/Cards.lua`, 123 cartes en 7 séries) et cartes de guilde enrichies (paliers de niveau, avis de recherche, boss, sorties, morts mémorables, unes).
- **Visuel des cartes** : cadre teinté selon la rareté, dos de carte, gemme, halo pour épique et légendaire ; image = icône recadrée, la première candidate présente sur le client (`UI.CardArt`, `GetFileIDFromPath`). Booster distribué face cachée puis retourné carte par carte. Filtre Guilde / Azeroth.
- Reste : échanges de cartes entre membres.

### Avancement v0.12.0 (19/11/2026)

- **Deux addons** : `Renatus` pour tous les membres, `Renatus_Admin` pour les officiers et le rédacteur (il remplace `Renatus_Press`).
  - **Renatus** : la fenêtre (gazette, album, journaux) et des Options réduites aux réglages du membre (confidentialité, consentement IA, album, minicarte, voix). Plus de page Guilde, de mode démo, de diagnostic de synchro ni de bouton Rédaction : **identique pour tous les membres**, que `Renatus_Admin` soit installé ou non (testé).
  - **Renatus_Admin** : sa propre fenêtre (`Window.lua`), ouverte par sa propre icône de minimap (clé, `Minimap.lua`) ou `/radmin`, sans rien ajouter à la fenêtre des membres. Onglets **Rédaction** (articles de `Press.lua` : aperçu, publier, ignorer), **Guilde rivale** (en vigueur, propositions de l'application : réglage + effectif, saisie manuelle), **Boosters** (règle d'obtention des boosters), **Diagnostic** (synchro, données, mode démo). Publier est réservé aux officiers (`A.IsOfficer`, même règle de rang que `GUILD_CONFIG`) ; les autres consultent. Il s'appuie sur `Renatus.ns` (widgets, `UI.MinimapButton`).
- **Réglages de guilde** (`Core/GuildConfig.lua`) : événement `GUILD_CONFIG` partagé, valable si son auteur est au rang `OFFICER_MAX_RANK` (1) ou au-dessus dans le roster **actuel** ; le plus récent gagne. La guilde rivale du tableau de chasse en vient (repli : l'ancien réglage local du personnage). Le compagnon peut aussi en proposer un (élément `GUILD_CONFIG` de `Press.lua`, publié depuis l'onglet Guilde rivale de `Renatus_Admin`).
- **Renatus Admin** (`admin/`, Rust + Tauri, Windows) **remplace le compagnon Python** : mêmes fonctions (journaux de combat, articles, gazette IA, mêmes identifiants d'éléments), plus l'armurerie (`armorywowforever.com`, API JSON `/api/guild/…` et `/api/character/…`) qui produit `GUILD_CONFIG` et `RIVAL_ROSTER` (provenance **`EXT`**, « Armurerie » ; affiché dans le tableau de chasse, en-tête et fiche de l'ennemi), l'installation de `Renatus_Admin` et un mode automatique (surveillance des SavedVariables). Ligne de commande `renatus-admin` pour WSL/Linux. Voir `admin/README.md`.
- **Distribution** : la release contient `Renatus-<v>.zip` (installé par le launcher, qui retire l'ancien `Renatus_Press`) et `Renatus_Admin-<v>.zip` (jamais installé par le launcher). Les deux addons portent la même version.

### Avancement v0.9.0 (19/11/2026)

- **La fenêtre ne montre que du contenu** : Gazette, Album et Tableau de chasse en tête (grands boutons, les trois fonctions principales des membres), puis la section « Journaux » (Mon journal, Guilde, Membres). La Gazette s'ouvre par défaut ; le bouton « Archives » sous la page liste tous les numéros parus avec leur date (il remplace les flèches ‹ › entre éditions). La vue simple/complète de la v0.8 disparaît.
- **Tableau de chasse** : s'ouvre sur une **vue d'ensemble** (bandeau de la guilde rivale avec le bilan victoires – défaites, « Les plus redoutés » cliquables, « Nouvelles du front », raccourci vers les avis), puis les onglets Avis et Registre. Les ennemis sont indexés par **prénom** (`Views.EnemyKey`) : « Ladou » vu en jeu et « Ladou Pipø » de l'armurerie ou tapé dans un avis désignent la même fiche ; le nom complet est affiché quand il est connu (`e.display`).
- **Tous les réglages sont dans Échap > Options > AddOns > Renatus** (`UI/Options.lua`) : page principale (affichage, confidentialité, consentement IA, album) ; sous-page **Voix** (réglages natifs, curseurs compris) ; sous-page **Guilde** (widgets de l'addon : guilde rivale, synchronisation, données). Sans l'API Settings, une seule page reprend tout sauf la voix (`/renatus voice`). Le bouton « Options » de la fenêtre, le clic droit sur la minicarte, `/renatus options` et `/renatus voice` ouvrent la bonne page.
- Les onglets Voix et Paramètres sont supprimés de la fenêtre.

### Avancement v0.8.2 (19/11/2026)

- **Trois niveaux d'usage** :
  1. **Vue simple** (par défaut, tous les membres) : Gazette et Album. Les onglets portent `simple = true`.
  2. **Vue complète** (« Tout afficher ») : en plus, les journaux, les membres, le tableau de chasse, la voix et les paramètres.
  3. **Rédaction** (le rédacteur seul) : l'addon `Renatus_Press` (sans lui, aucun bouton « Rédaction » n'apparaît) et le compagnon hors jeu (LLM). *(v0.12 : remplacé par `Renatus_Admin`.)*

### Avancement v0.8.0 (19/11/2026)

- **Vue simple, par défaut** : la fenêtre n'affiche que la gazette, sans navigation (fenêtre réduite à 754 × 630). Le bouton « Tout afficher » du bandeau, la case des Paramètres et du menu Options, ou `/renatus simple` passent à la vue complète. Demander un autre onglet par son nom (clic droit sur la minicarte, `/renatus wanted`…) bascule aussi en vue complète. La collecte et la synchronisation fonctionnent pareil dans les deux vues.

### Avancement v0.7.0 (19/11/2026)

- **Tueur identifié** (`Collectors/Killer.lua`) : sur les clients qui l'autorisent, l'addon lit le journal de combat et garde en mémoire les coups reçus des 10 dernières secondes ; sinon, il lit le récapitulatif de mort (`C_DeathRecap`). **v0.8.1 : sur Forever (base Midnight), s'inscrire au journal de combat déclenche « action bloquée » (ce n'est pas une erreur Lua, `pcall` ne l'intercepte pas) : l'inscription est désormais évitée sur les clients à valeurs secrètes.** La mort indique « tué par X (paladin elfe de sang) — Jugement ». Un joueur tueur compte comme défaite vérifiée au Tableau de chasse. **À vérifier en jeu** : si Forever ferme les deux, la mort reste « cause inconnue », et l'événement refusé apparaît dans Paramètres.
- **Suppression** (tombstones, §3.1) : clic droit sur une de ses saisies manuelles dans le journal (anecdote, note, déclaration). Privée : effacée. Partagée : vidée chez soi et événement `TOMBSTONE` synchronisé ; les autres clients vident leur copie, même si la suppression arrive avant l'événement. Seul l'auteur peut supprimer.

### Avancement v0.6.0 (19/11/2026)

- **Textures propres à l'addon** (`Renatus/Media/*.tga`, générées par `tools/make_media.py` : `uv run tools/make_media.py --preview DIR`) : cuir rouge sombre, cadre de fer et de bronze avec grenats aux coins, bandeau de titre, onglet actif rouge et or, boutons rouges cerclés d'or, barres de section, papier journal. Elles remplacent les textures du client de la v0.5.0. Chaque élément garde une couleur unie dessous : sans les fichiers, la fenêtre reste lisible.
- Fenêtre 948 × 630, navigation élargie (188 px) : « Tableau de chasse » ne déborde plus.
- **Gazette en vraie une de journal** : titre, numéro d'édition, semaine, prix ; une édition par semaine, la une est l'article le plus voté ; article en deux colonnes équilibrées avec lettrine ; « En bref » tiré des événements de la semaine ; colonne « Dans cette édition », « Le chiffre de la semaine » (décès), courrier des lecteurs ; page de lecture avec les sources.

### Avancement v0.5.0 (19/11/2026)

- **Habillage médiéval** (`UI.Skin` dans `UI/Widgets.lua`) : textures du client (bordure dorée des boîtes de dialogue, fond de pierre, parchemin des hauts faits, boutons rouges, croix de fermeture, halo doré du journal de quêtes), police gothique (Morpheus) pour les onglets. Chaque texture est vérifiée (`GetFileIDFromPath`) ; si elle manque, ou si l'API des backdrops manque, on revient à l'aspect plat d'avant.
- Fenêtre agrandie à 912 × 594 pour laisser la place à la bordure ; la zone utile des onglets ne change pas (698 × 494).

### Avancement v0.4.2 (19/11/2026)

- **Accès à l'addon** : le bouton de minicarte se place sur le **bord** de la minicarte, quelle que soit sa taille (il était posé à l'intérieur de la minicarte Retail, plus grande). Il y a aussi une entrée « Renatus » dans le **menu des addons de la minicarte** (Retail) et une icône dans la liste des addons.
- **Options > AddOns > Renatus** (`UI/Options.lua`, `/renatus options`) : réglages natifs (bouton de minicarte, mode démo, confidentialité par catégorie, consentement IA, album, voix), reliés aux mêmes données que l'onglet Paramètres. Des boutons ouvrent la fenêtre pour le reste. Si l'API Settings diffère sur le client, un panneau minimal avec un bouton la remplace.
- 72 tests Lua.

### Avancement v0.4.0 (18/11/2026)

- **Gazette rédigée par IA** (`companion/gazette.py`, `companion/llm.py`) : le compagnon du rédacteur construit une liste de faits numérotés à partir des événements **partagés** de la semaine, l'envoie à une commande externe (par défaut Claude Code en mode `-p`, sans outils, éventuellement sur une autre machine via SSH), puis vérifie la réponse avant de la proposer dans **Gazette > Rédaction**.
- **Consentement synchronisé** (§7, §8.4) : la case « La gazette rédigée par IA peut parler de moi » publie un événement masqué `AI_CONSENT` (toujours partagé, le dernier choix compte). Sans « oui » explicite : événements écartés, nom retiré des faits des autres (fait supprimé si texte libre, « +n autres participants » dans une expédition).
- **Ennemis nommés** pour l'IA, avec classe, race et guilde (« Décimeur (chasseur Tauren, <Les Cousins Maudits>) », « Gorbash (voleur Orc, guilde rivale) ») ; jusqu'à Renatus Admin 0.4.3 ils étaient pseudonymisés (« Rival A »). Les membres restent soumis au consentement IA : c'est eux que la gazette suit au quotidien (activité, morts, déboires) et dont elle se moque vraiment, pas les ennemis croisés en PvP ; provenance conservée dans les faits (« selon X (déclaré, non vérifié) », « supposé »).
- **Vérification de la réponse** : chaque article doit citer des faits fournis, ne nommer aucun membre non consentant ni rival, respecter les longueurs ; sinon il est rejeté (jamais corrigé). Articles marqués `p.ia`, affichés « rédigé par IA, relu par X ».
- Une édition par semaine via `run` (`[llm] enabled = true`), `gazette --show` affiche la demande exacte sans appeler l'IA.
- 67 tests Lua, 19 tests Python.

### Avancement v0.3.0 (18/11/2026)

- **Synchronisation entre membres** (`Sync/`) : protocole par vecteurs (§10), canal GUILD uniquement, envoi seulement hors instance et hors combat, débit limité, validation stricte de ce qui est reçu, distinction « reçu de l'auteur » / « relayé ». Seuls les événements des catégories réglées sur « Guilde » partent ; le reste ne quitte jamais le client.
- **Expéditions** (`Collectors/Expedition.lua`) : donjon, raid, champ de bataille, groupe avec un membre de la guilde ; tolérance de 10 min à la sortie d'instance ; fin estimée (`ded`) après une déconnexion ; membres de la guilde nommés, autres joueurs seulement comptés.
- **Tableau de chasse automatique** (`Collectors/Enemies.lua`) : rencontres avec la **guilde rivale configurée** (cible, survol, barres de nom), une observation par ennemi et par 10 min ; à la mort, rivaux aperçus dans les 30 s notés « présents » (supposé), jamais « tueurs ».
- **Voix** : spécialisations reconnues par **identifiant** (et non par index), repli sur la classe, réglage manuel du rôle et du style de combat (pour les spés propres à Forever).
- **Compagnon v1, sans LLM** (`companion/`) : lecture des SavedVariables et des journaux de combat, causes de mort, affrontements PvP contre des rivaux connus, articles écrits à la main, écriture de `Renatus_Press/Press.lua`. En jeu, **Gazette > Rédaction** : rien n'est publié sans validation.
- **Gazette réelle** : articles (`ARTICLE`, provenance « Rédaction »), votes pour la une (un par membre et par semaine), causes de mort affichées sur les morts (« d'après le journal de combat de X »).
- 66 tests Lua (`lua tests/run.lua`) et 14 tests Python (`python3 -m unittest discover -s tests/companion -t .`).
- **Pas encore faits** : ~~LLM de la gazette (fait en v0.4.0)~~, obtention réelle de boosters (modèle à choisir, §9.2), ~~réglages de guilde (`GUILD_CONFIG`, rivale commune : fait en v0.12.0, signés par un officier)~~, rédacteurs désignés, ~~tombstones (fait en v0.7.0)~~, rivalités détectées (§6.4).

### Avancement v0.2.0 (18/11/2026)

- **Interface complète** (`/renatus`, bouton de minicarte) : Mon journal, Guilde, Membres, Tableau de chasse, Gazette, Album, Voix, Paramètres. Tout est construit sans templates FrameXML : de simples frames et textures, pour limiter la dépendance à des globales qui pourraient manquer sur Forever.
- **Mode démo** (`/renatus demo`) : données fictives en mémoire, jamais sauvegardées, pour voir chaque écran rempli.
- **Données réelles** : stockage (`Core/Store.lua`), vues calculées (`Core/Views.lua`), catalogue et boosters déterministes (`Core/Album.lua`).
- **Premiers collecteurs** (`Collectors/Basic.lua`) : niveau, mort (sans cause), quête, boss (`ENCOUNTER_END`), première visite de zone, entrée en guilde. Ils restent à confirmer par la sonde.
- **Saisies manuelles** (marquées « déclaré ») : anecdote, fiche ennemie, affrontement, avis de recherche, courrier des lecteurs.
- **Pas encore faits** : synchronisation (l'onglet Guilde n'affiche que tes événements), détecteur d'expéditions, observation automatique des ennemis, compagnon et gazette réelle, obtention réelle de boosters.
- 40 tests hors client (`lua tests/run.lua`) : Voice, Core, collecteurs, vues et construction de tous les onglets.

### Arborescence initiale (v0.1.0)

```text
Renatus/                 l'addon unique
  Renatus.toc            Interface 16001, 120005 ; SavedVariables RenatusDB (compte), RenatusCharDB (perso)
  Core/Init.lua                 namespace, modules, RegisterGameEvent (inscription protégée par pcall)
  Core/EventBus.lua             Publish/Subscribe, isolation des erreurs ; API publique Renatus.Subscribe
  Core/Settings.lua             valeurs par défaut, version de schéma, migrations
  Core/Slash.lua                /renatus, /renatus voice …, /renacoach
  Voice/Voice.lua               Renacoach porté (voir §1.1)
  Voice/Sounds/*.ogg            les 34 répliques d'origine, non modifiées
tests/run.lua, tests/wow_stub.lua   17 tests hors client (lua tests/run.lua)
tools/ChronicleProbe/           sonde de diagnostic, non distribuée
tools/boost_ogg_volume.py       outil audio d'origine, chemins mis à jour
docs/ARCHITECTURE.md
```

### 1.1 Module Voice : ce qui a changé par rapport à Renacoach 1.0.0

**Conservé à l'identique** : les 10 familles et leurs 34 répliques, les déclencheurs (entrée et sortie de combat, mort, tirage périodique en combat), les valeurs par défaut (50 % toutes les 3 s, canal Ambiance avec repli sur Master, ducking à 0,25 pendant 2,8 s puis fondu de 1,2 s) et l'arrêt de la réplique précédente avant chaque lecture.

**Modifié, et testé hors client** :
- Désactivé par défaut et réglable : probabilité, intervalle, canal, ducking, familles une à une.
- Plus aucune fonction globale.
- Rôle : spécialisation Retail si elle existe, sinon rôle de groupe. Type : spécialisation, sinon classe quand elle n'est pas ambiguë. Sur un client sans spécialisations, l'original ne jouait **aucune** réplique en combat ; maintenant, au minimum les génériques.
- Recalcul du rôle sur changement de spé ou de rôle, si ces événements existent.
- Table du chasseur corrigée : Précision était classé « corps à corps ». Évocateur ajouté.
- Volume SFX mémorisé en SavedVariables pendant un ducking, et restauré au chargement suivant après un crash.
- À la mort, la réplique de fin de combat ne coupe plus celle de mort.
- La boucle de combat ne tourne plus qu'en combat (frame cachée sinon).

---

## 2. Contraintes WoW Forever

Forever tourne sur le **client Retail** (base Midnight), interface `16001`, avec un contenu de style Classic. Selon des sources non officielles, **les restrictions Midnight s'appliquent** :

| Restriction | Conséquence |
|---|---|
| Journal de combat (`COMBAT_LOG_EVENT*`) retiré aux addons | Ni cause de mort, ni tueur, ni coup fatal, ni chute **dans l'addon**. Ces informations ne peuvent venir que des **fichiers** de journal de combat, lus hors jeu (§8). |
| Aucune communication vers les autres joueurs en instance | La synchro est différée à la sortie d'instance. **Les champs de bataille sont probablement concernés.** **[V4]** |
| Chat reçu en instance livré en « secret values » | Messages de butin et d'honneur illisibles en instance. **[V7]** |
| Noms et GUID de créatures secrets en instance | Boss identifiés par `encounterID` via `ENCOUNTER_END`. **[V7]** |
| Monde ouvert : quasiment pas de limite | Collecte, observation des joueurs ennemis, synchro et interface fonctionnent normalement. |

---

## 3. Architecture

### 3.1 Principe unificateur : tout est un événement possédé par son auteur

Chaque information partagée est un **événement d'un journal en ajout seul, possédé par son auteur** : une mort, une expédition, un avis de recherche, un vote, un commentaire, un article de gazette, l'ouverture d'un booster, une offre d'échange de cartes.

- On ne modifie jamais l'événement d'un autre. Une correction est un nouvel événement (`EDIT`, `TOMBSTONE`) **du même auteur**.
- Une **seule** couche de synchro, de déduplication et de stockage sert tous les modules.
- Les vues (journal, Wanted Board, gazette, album) sont **calculées** à partir des événements : compteurs, propriétaire de chaque carte, résultat des votes.

### 3.2 Modules

```text
Renatus/
  Core/        Init, EventBus, Settings, Slash, Ids, Store (dédup, requêtes), Provenance
  Collectors/  Progression, Combat, Exploration, Social, PvP
  Expedition/  Detector (machine à états), Aggregation (vue collective)
  Sync/        Transport (file d'attente hors instance), Protocol, libs/
  Chronicle/   timeline personnelle et de guilde, anecdotes manuelles
  Legacy/      statistiques, rivalités, titres
  Wanted/      registre des ennemis, avis de recherche
  Gazette/     lecture des articles importés, votes, commentaires, courrier des lecteurs
  Album/       catalogue, boosters, collection, échanges
  Voice/       Renacoach (fait)
  UI/          fenêtre principale à onglets
companion/     application Python hors jeu (export, logs, LLM, gazette)
```

Chaque module ne dépend que de `Core` (et de `Sync` pour publier). Les modules ne s'appellent pas entre eux : ils s'abonnent à l'`EventBus`.

---

## 4. Modèle de données

### 4.1 Événement (stockage Lua compact)

```lua
{
  v   = 1,                    -- version du payload
  id  = "Player-1234-0ABC:42",-- auteur:séquence (privé : auteur:p<n>)
  a   = "Player-1234-0ABC",   -- auteur (GUID)
  s   = 42,                   -- séquence publique (nil si privé)
  t   = 1795000000,           -- GetServerTime() : horloge serveur, commune
  k   = "DEATH",              -- type
  x   = "Player-1234-0ABC:40",-- expédition parente (facultatif)
  loc = { m = 1581, z = "Westfall", sz = "Moonbrook", i = nil, xy = { 423, 711 } },
  pt  = { "Player-…", … },    -- participants observés par l'auteur
  prov = "OBS",               -- provenance (§4.2)
  miss = { "killer" },        -- ce qu'on sait ne pas savoir
  refs = { "…:12" },          -- événements liés
  vis = "G",                  -- P privé / G guilde
  p   = { lvl = 19 },         -- payload propre au type
}
```

- **Localisation** (`loc`) : identifiant de carte `C_Map`, nom de zone et sous-zone, instance (`GetInstanceInfo`). Coordonnées arrondies au millième, **seulement** au moment d'un événement significatif et **hors instance** (l'API ne les fournit pas en instance). Aucun suivi continu des déplacements.
- Les noms sont résolus et stockés au moment de l'événement. C'est plus lisible pour le LLM, au prix d'un léger surcoût.

### 4.2 Provenance et certitude

| Code | Signification | Exemple | Affichage |
|---|---|---|---|
| `OBS` | Observé automatiquement par l'addon | `PLAYER_LEVEL_UP` | normal |
| `LOG` | Issu d'un fichier de journal de combat, via le compagnon | coup fatal sur un ennemi | icône de parchemin |
| `MAN` | Déclaré manuellement par un membre | « j'ai battu Xyz au pont » | « déclaré par … » (+ « confirmé par … ») |
| `DED` | Déduit par une règle explicite | « ennemis probablement présents » | italique, « supposé » |
| `GEN` | Texte généré (LLM) | article de gazette | **stocké séparément** : jamais un événement factuel |

Règles :
- Une déduction ne devient jamais un fait. Un `DED` peut être **confirmé** par un `LOG` ou un `MAN` qui le référence (`refs`). L'affichage montre alors les deux sources, et les divergences éventuelles.
- Le champ `miss` liste explicitement les inconnues : la cause d'une mort est toujours `miss = { "killer" }` côté addon.
- Les statistiques sont **ventilées par provenance** : « 3 victoires vérifiées, 2 déclarées ».

### 4.3 Identifiants, SavedVariables, limites

Inchangés par rapport à la v1 :
- Identifiant d'auteur = GUID du joueur. Identifiant de guilde = `Nom-Royaume`.
- Séquence publique par auteur ; les événements privés ne consomment pas de séquence.
- `RenatusDB.guilds[guilde].events`, plus des tombstones.
- `RenatusDB.monitor` : état de santé local, jamais diffusé, lu par l'onglet **Suivi** de Renatus Admin : membres vus sur le canal de l'addon (`peers[nom] = { first, seen, proto, ver }`, la version arrive dans le message `V` sous `ve`), compteurs de synchro persistants (`sync`, avec le dernier motif de rejet), instantané de la liste de guilde (`roster`, au plus toutes les 10 min).
- Plafond configurable : on purge d'abord les événements **reçus** anciens et peu importants.
- Types inconnus conservés et relayés sans être affichés.

### 4.4 Chronologie

- Ordre **certain** entre les événements d'un même auteur : sa séquence.
- Entre auteurs : par horodatage serveur, avec une tolérance de ±2 s. En dessous, l'interface et l'export marquent les événements comme « simultanés », sans ordre affirmé.
- L'addon enregistre à chaque connexion l'écart `time() - GetServerTime()` (horloge locale moins horloge serveur). Le compagnon s'en sert pour aligner les journaux de combat, qui sont en heure locale (§8).

---

## 5. Expéditions

Une **expédition** est une période d'activité cohérente. Elle est détectée par une machine à états **locale** à chaque joueur.

| Démarrage | Type |
|---|---|
| Entrée dans une instance de groupe | `DUNGEON` / `RAID` (selon `GetInstanceInfo`) |
| Entrée dans un champ de bataille, ou joueur ennemi de la guilde rivale observé en état PvP | `PVP` |
| Groupe formé avec au moins un membre de la guilde, hors instance | `QUESTING` (ou `EXPLORATION` si plusieurs premières visites de zone) |
| Sinon | pas d'expédition : les événements restent « libres » |

| Fin | Remarque |
|---|---|
| Sortie d'instance, sans y rentrer dans les 10 min | Tolère les morts suivies d'un retour et les allers-retours pour réparer |
| Dissolution du groupe | |
| 20 min sans événement significatif | |
| Déconnexion | Clôturée à la connexion suivante avec `fin estimée` (`DED`) |

- L'expédition est un événement `EXPEDITION` (début, fin, type, instance, membres du groupe vus, compteurs). Les événements produits pendant l'expédition portent `x`.
- **Vue collective** : les expéditions de plusieurs auteurs sont regroupées **à l'affichage** si elles se chevauchent dans le temps **et** si elles partagent au moins un membre de groupe (en instance : même instance et même chef de groupe à l'entrée). Rien n'est fusionné en base, donc aucun participant n'est inventé.
- **Édition** : tout participant peut renommer, fusionner ou scinder **sa** vue via des événements `EXP_EDIT`. La vue collective applique la dernière édition de chaque participant et signale les désaccords.
- Une expédition peut rester partiellement identifiée (type `UNKNOWN`, fin estimée). C'est normal et affiché comme tel.

---

## 6. Wanted Board (registre PvP)

### 6.1 Ce que l'addon peut détecter (à confirmer avec la sonde)

| Information | Source envisagée | Provenance | Faisabilité |
|---|---|---|---|
| **Rencontre** d'un joueur de la guilde rivale (nom, guilde, niveau, race, classe, lieu) | cible, survol, barres de nom (`NAME_PLATE_UNIT_ADDED`) + `GetGuildInfo(unit)` | `OBS` | Probable en monde ouvert **[V10]** |
| Notre mort en zone PvP | `PLAYER_DEAD` + liste des ennemis vus dans les 30 dernières secondes | `OBS` (mort) + `DED` (« ennemis présents ») | Oui, **sans tueur** |
| Participation à un kill (victoire honorable) | `CHAT_MSG_COMBAT_HONOR_GAIN` (« %s meurt (victoire honorable : %s)… », `COMBATLOG_HONORGAIN`), repli sur `PLAYER_PVP_KILLS_CHANGED` + `GetPVPSessionStats()` | `PVP_KILL`, `OBS` (« a contribué », pas « a tué ») ; `DED` si le jeu a compté sans nommer la victime, ou si la victime est déduite | Compteur confirmé sur Forever ; **le 22/11/2026, aucun message reconnu** (5 victoires de Renaa arrivées vides). Depuis la v1.0.7 : tous les formats connus (`COMBATLOG_HONORGAIN`, `_NO_RANK`, `_EXHAUSTION1-4`), sinon un ennemi vu récemment dont le nom ouvre le message ; les messages non reconnus sont gardés (`RenatusCharDB.honorMisses`). Compteur sans message : la victime est le joueur ennemi vu mort dans les 15 s (cible, focus, survol, barres de nom, cibles du groupe, `UNIT_HEALTH`), `DED`. Hors champ de bataille. **Victime nommée quelle que soit sa guilde** (comme les tueurs), avec guilde, race, classe, niveau |
| Coup fatal, tueur, sort utilisé | Fichier de journal de combat | `LOG` | Via le compagnon (§8) |
| Victoire ou défaite déclarée | Formulaire « Déclarer un affrontement » | `MAN`, confirmable par d'autres membres présents | Oui |

- Les observations sont **limitées en fréquence** : une observation par ennemi toutes les 10 min, et la fiche ne garde que la dernière observation par lieu. On garde des rencontres, pas une traque.
- La **guilde rivale** est configurée par son nom (réglage de guilde, voir §7.3). Les simples rencontres (`ENEMY_SEEN`) ne concernent qu'elle. Les autres joueurs ennemis entrent au registre seulement par un **combat** : ils nous ont tués (tueur de `DEATH`, avec sa guilde s'il a été vu juste avant) ou nous les avons tués (`PVP_KILL`), ou par ajout manuel. Le registre a un filtre « Guilde rivale ».
- **Date de départ** (`huntSince` du réglage de guilde, v1.0.7) : un officier remet le tableau de chasse à 0-0 depuis Renatus_Admin (page Remise à zéro). Les combats d'avant (`ENEMY_SEEN`, `PVP_CLASH`, `PVP_KILL`, `DEATH`) et les votes « ennemi juré » d'avant sont ignorés par le tableau ; rien n'est effacé (journaux, gazette, avis, surnoms et notes restent). « Tout reprendre depuis le début » retire la date.
- **Champs de bataille et arènes exclus** (`Views.InHunt`, `loc.it` = `pvp` ou `arena`) : morts, rivaux vus et victoires qui s'y produisent ne comptent ni dans les nouvelles du front, ni dans les scores, ni dans « Ils nous ont vaincus ». Les adversaires y sont tirés par le jeu, nos victoires n'y sont pas relevées (seules nos défaites auraient compté) et l'expédition les résume déjà. Les rencontres saisies à la main (`PVP_CLASH`) n'ont pas de type d'instance et restent comptées.

### 6.2 Fiche ennemi

Elle est calculée à partir des événements `ENEMY_SEEN`, `PVP_CLASH`, `PVP_KILL`, `DEATH` (tueur joueur) et `ENEMY_NOTE` :
- Identité : nom, royaume, guilde, race, classe, chacun avec sa **date de dernière observation**.
- Niveau connu à une date donnée, jamais « niveau actuel ».
- Rencontres ; victoires et défaites **par provenance** ; dernier lieu ; membres de notre guilde impliqués.
- Surnoms et annotations (`ENEMY_NOTE`, `MAN`) : plusieurs auteurs possibles, chacun signé.
- Statut « ennemi juré » : soit voté (au moins 3 membres le marquent), soit attribué par une règle explicite (par exemple 5 défaites `OBS` ou `LOG` face à lui).

### 6.3 Avis de recherche

L'événement `WANTED` (auteur = le membre qui affiche l'avis) contient la cible, un surnom, un motif et une récompense symbolique (points de prime internes, ou booster d'album via §9 si le modèle est retenu). L'historique des affrontements est calculé, et les commentaires sont des événements `COMMENT`. L'avis est « levé » par son auteur (`WANTED_CLOSE`), ou par n'importe qui avec une revanche `LOG` ou une déclaration `MAN` confirmée par un second membre.

### 6.4 Rivalités détectées (règles Legacy, explicites)

| Rivalité | Règle |
|---|---|
| Adversaire récurrent | ≥ 5 rencontres en 30 jours |
| Fléau de la guilde | ≥ 3 membres différents morts avec lui « présent » (`DED`) ou tués par lui (`LOG`) |
| Série noire | ≥ 3 défaites consécutives d'un membre face à la guilde rivale |
| Revanche | victoire sur un ennemi qui avait vaincu ce membre auparavant |
| Bataille rangée | expédition `PVP` avec ≥ 3 membres et ≥ 3 ennemis rivaux observés |

Ces rivalités alimentent le journal (événements `DED`) et la gazette (rubrique Diplomatie).

### 6.5 Limites éthiques (dans le code, pas seulement en intention)

- Uniquement des données **visibles en jeu** sur des personnages : jamais de lien vers une personne réelle, un compte ou un autre jeu. Aucun champ libre « identité réelle » n'est proposé.
- Les données ne circulent que sur le canal **GUILD**. Rien n'est envoyé à la guilde rivale ni en chat public.
- Purge automatique des fiches sans rencontre depuis 6 mois (réglable).

---

## 7. Gazette satirique

### 7.1 Pipeline

```text
1. [jeu]        événements collectés et synchronisés
2. [jeu]        /reload ou déconnexion : écriture de WTF/…/SavedVariables/Renatus.lua
3. [compagnon]  lecture des SavedVariables (+ journaux de combat facultatifs, §8)
4. [compagnon]  sélection : événements de la période, importance ≥ seuil, groupés par expédition
5. [compagnon]  contexte structuré : faits numérotés, provenance, surnoms, rivalités,
                3 à 5 articles précédents résumés (pour la continuité)
6. [compagnon]  génération LLM : style éditorial configuré
7. [compagnon]  relecture par le rédacteur (éditer, refuser, régénérer)
8. [compagnon]  écriture de Renatus_Admin/Press.lua
9. [jeu]        /reload chez le rédacteur : « 4 articles prêts, publier ? »
10. [jeu]       publication = événements ARTICLE du rédacteur → synchro vers la guilde
```

- **Un seul membre a besoin du compagnon** : le rédacteur. Les autres reçoivent les articles par la synchro de l'addon.
- `Renatus_Admin/Press.lua` ne contient qu'une table Lua (`RenatusPress`). Il est réécrit par le compagnon pendant que le jeu tourne et relu au `/reload` (un `/reload` relit les fichiers Lua listés dans les TOC ; seul un **nouveau** fichier exige un redémarrage du client). C'est un mécanisme de fichiers standard, sans injection.
- Chaque article stocke `refs` (identifiants des événements sources) et `style`. Dans le jeu, un bouton « Sources » affiche les faits d'origine.

### 7.1 bis Mise en page des éditions

- **Un numéro par parution** : chaque gazette publiée est un numéro, identifié par la clé `p.edition` (date de rédaction, ex. `2026-11-20-2147`) que portent ses articles et son `EDITION`. L'addon numérote les parutions (n° 1, 2…), les date (date de l'`EDITION`, sinon du dernier article) et permet de les feuilleter ; deux parutions la même semaine font deux numéros. Les articles publiés sans clé (avant les numéros) restent regroupés par semaine. Chaque numéro couvre la période depuis le précédent (`p.till` de l'`EDITION` = fin de la période rédigée) : « En bref » et « Le chiffre » en dépendent.
- **Déjà paru** : un événement cité (refs) par un article publié est « paru dans le n° X » ; l'addon l'indique dans le journal, l'application le décoche par défaut pour le numéro suivant (`admin/core/src/issues.rs`). Rien de nouveau ne circule : les refs des articles sont déjà synchronisées. Dans l'application, l'onglet Gazette liste les faits depuis le dernier numéro (cochés s'ils sont nouveaux) et ceux des 30 jours précédents (décochés) ; on choisit ce qui part à l'IA. Les articles `.md` du dossier entrent dans le numéro, après ceux de l'IA.
- **Hors-séries** (`admin/core/src/special.rs`) : un numéro thématique publié à part, choisi dans l'onglet Gazette de l'application (« Hors-série »). Thèmes prédéfinis : les fêtes françaises (Nouvel An, galette, Chandeleur, Saint-Valentin, Carnaval, 1er avril, Pâques, 1er mai, fêtes des mères et des pères, fête de la musique, 14 Juillet, rentrée, Halloween, Beaujolais, Noël) et quelques fêtes d'Azeroth, les rétrospectives (mois, été, année), le portrait d'un membre consentant, l'édition spéciale sur un événement (période courte) et un thème libre. Chaque thème fournit un titre, une consigne à l'IA (bloc `{special}` du prompt ; un prompt personnalisé sans `{special}` la reçoit en tête) et une période par défaut, tous modifiables ; l'application rappelle les fêtes des 10 prochains jours. La clé du numéro commence par `hs:` : il ne décale pas la période du numéro régulier suivant, ses faits restent « à raconter » pour la gazette, il ne prend ni articles `.md` ni cartes d'album. Son `EDITION` porte `special` (titre) et `since` (début de période). L'addon numérote les hors-séries à part (« HORS-SÉRIE N° 1 »), les liste en tête des archives, ouvre toujours la gazette sur le dernier numéro régulier, et signale un hors-série non lu (icône, bouton lumineux « Hors-série » sous la page, `ns.char.ui.specialsRead`) jusqu'à ce que sa une soit affichée. Une version plus ancienne de l'addon l'affiche comme un numéro ordinaire.
- La mise en page est une **donnée**, pas du code : un événement `EDITION` (masqué, provenance `GEN`) publié avec les articles du numéro. L'addon des membres la dessine (`UI/Newsprint.lua`). Une nouvelle maquette ne demande donc qu'une mise à jour de l'application ; seul un **nouveau type de bloc** demande une nouvelle version de l'addon.
- Format (à plat, car la synchro refuse plus de 8 niveaux de tables imbriquées) : `p = { template, edition, titles = { "", "Titre page 2" }, cells = { { pg, r, w, h, b = { blocs } } } }`. `pg` et `r` numérotent la page et la rangée, `w` est la largeur relative (grille de 12), `h` la part de hauteur de la rangée (facultative).
- Blocs : `story` (article en 1 à 4 colonnes, lettrine, taille du titre), `teaser` (titre et chapeau), `contents` (sommaire des articles non placés), `brief` (en bref de la période du numéro), `quote` (exergue), `figure` (chiffre du numéro), `portrait` (médaillon gravé : emblème de classe, nom, classe et niveau tirés du roster et du journal, identique pour tous), `picture` (texture du jeu, gravée), `notice` (petite annonce encadrée), `wanted` (avis de recherche), `letters` (courrier). Un type inconnu est ignoré.
- Articles : `@n` = n-ième article du numéro dans l'ordre éditorial `p.order` (`@1` = la une) ; ou la clé `p.key` (exergue et portrait restent ainsi attachés à leur article). Un article qu'aucun bloc ne montre va au sommaire, ou sur une page « Suite » : rien n'est perdu.
- Hauteurs : les rangées se partagent la page ; dans une case, les blocs fixes prennent leur hauteur, les blocs souples (en bref, sommaire) au plus la leur, l'article remplit le reste et se coupe sur « Lire la suite ».
- Confiance : une mise en page n'est retenue que si son auteur est officier dans le roster actuel (comme `GUILD_CONFIG`) ; la plus récente pour un même numéro gagne. Sans `EDITION`, la une classique.
- Côté application (`admin/core/src/edition.rs`) : maquettes `classique`, `grande_une`, `trois_colonnes`, `portrait`. L'IA choisit (champ `maquette`), ou le réglage « Maquette de la gazette » l'impose. Elle peut proposer pour chaque article une **exergue** (recopiée mot pour mot du texte, sinon ignorée) et un **portrait** (un membre consentant nommé dans l'article, sinon ignoré), et des intertitres (`## `).
- Dans `Renatus_Admin`, publier la mise en page publie aussi ses articles en attente ; « Aperçu dans la gazette » montre l'édition dans la fenêtre des membres sans rien diffuser.

### 7.2 Garde-fous anti-invention

- Le prompt reçoit des **faits numérotés**. Chaque phrase factuelle du texte doit pouvoir citer un numéro. Les tournures (« la rédaction salue sa persévérance ») sont libres ; les faits (« il est mort trois fois ») doivent exister.
- Une seconde passe automatique (LLM ou règles) liste les affirmations factuelles du texte et les confronte aux faits. Une affirmation non sourcée est signalée au rédacteur avant publication.
- Une provenance `DED` ou `MAN` doit être formulée avec réserve (« selon des sources proches de l'intéressé »). C'est une contrainte de style, et le ton de mauvaise foi s'y prête très bien.

### 7.3 Rôles et règles de publication

- **Réglages de guilde** : un événement `GUILD_CONFIG` dont l'auteur est, dans le roster **actuel** de chaque client, au rang 0 (chef de guilde) ou 1 (officiers ; `GuildConfig.OFFICER_MAX_RANK`). Le plus récent l'emporte ; un officier rétrogradé ne compte plus. Il contient la guilde rivale (fait), la règle des boosters (`boosters = { day, bonus, cap }`, fait ; chaque jour est compté avec la règle diffusée au plus tard ce jour-là), plus tard les rédacteurs et le style éditorial par défaut. Il est publié depuis l'addon `Renatus_Admin`.
- **Articles** : seuls les rédacteurs publient la une et les éditions spéciales. Chaque article reste possédé par son auteur, qui seul peut publier un `EDIT` (rectificatif) ou un `TOMBSTONE`.
- **Courrier des lecteurs** : une lettre (`LETTER`, toujours partagée, signée) porte la clé du numéro qu'on lisait en l'écrivant (`p.edition` ; sans clé, le numéro paru juste avant elle) et paraît aussitôt dans ce numéro, chez tous les membres : page « Courrier des lecteurs » (bouton sous le journal) et encadré `letters` de la mise en page (nombre, extrait de la dernière). Pas de validation ; chacun peut supprimer les siennes.
- **Contributions de tous** : brèves proposées, courrier des lecteurs, petites annonces, commentaires. Ce sont des événements de leurs auteurs, affichés dans la gazette avec leur signature.
- **Votes** pour la une : retirés (la une suit l'ordre de la rédaction). Les anciens événements `VOTE` restent masqués.
- **Formats** : hebdomadaire, édition spéciale (déclenchée par une règle Legacy : boss, série de morts, bataille rangée), brèves, portrait, nécrologie, diplomatie, courrier des lecteurs. Ce sont des gabarits de prompt dans le compagnon.
- **Styles** : journaliste sarcastique, chroniqueur épique, propagandiste, faits divers, historien partial. Ce sont des fichiers de configuration du compagnon (texte de persona + exemples).

---

## 8. Compagnon Python et journaux de combat

### 8.1 Rôle

C'est une application **facultative**, pour le seul rédacteur. Elle se lance à la main, ou en arrière-plan pour surveiller les fichiers.

```text
companion/
  wowfiles.py      localisation de WTF/ et Logs/ ; lecture des SavedVariables (parseur de littéraux Lua)
  combatlog.py     lecture en flux de WoWCombatLog*.txt, extraction ciblée
  reconcile.py     fusion addon + logs + manuel ; dédup ; divergences
  expeditions.py   résumé factuel structuré par expédition
  llm.py           fournisseurs : API distante configurable, Ollama local
  gazette.py       gabarits, styles, vérification des faits
  press.py         écriture de Renatus_Admin/Press.lua
  config.toml
```

### 8.2 Journaux de combat

- Le client Retail écrit `Logs/WoWCombatLog-<date>.txt` quand le joueur tape `/combatlog`. **[V11 : à confirmer sur Forever : le fichier existe-t-il, son format, l'option de journalisation avancée]**
- **Non utilisé (décision du 2026-11-20)** : un addon ne peut pas lire ce fichier, et seul le rédacteur aurait pu le fournir. Une source n'est retenue que si elle vaut pour tous les membres : les morts passent uniquement par l'addon (récapitulatif de mort), pareil pour tout le monde.
- Le fichier n'est **pas** accessible depuis Lua pendant la session. Le compagnon le lit **après coup**. Ce n'est **pas** un pont temps réel.
- **Extraction ciblée** : `UNIT_DIED` (avec les derniers dégâts subis → cause de mort, chute comprise via `ENVIRONMENTAL_DAMAGE`), `PARTY_KILL` (coup fatal), dégâts entre joueurs (affrontements PvP), sorts marquants. On ne garde que les fenêtres utiles : expéditions connues de l'addon, et morts.
- **Alignement** : les horodatages du log sont en heure locale. On les convertit avec l'écart enregistré par l'addon (§4.4), puis on recale sur des ancres présentes des deux côtés (morts du joueur).
- **Fusion** : un événement `LOG` qui correspond à un événement addon (même type, même personnage, ±3 s) l'**enrichit** par une référence, sans créer de doublon. Une divergence (par exemple deux tueurs possibles) est conservée et signalée.

### 8.3 Retour dans le jeu des informations des logs

Les enrichissements `LOG` (causes de mort, coups fataux PvP) passent par le même fichier `Renatus_Admin/Press.lua`. L'addon du rédacteur les publie comme événements `LOG` **signés par le rédacteur**. La fiche affiche « d'après le journal de combat de X ». Personne n'a besoin d'installer le compagnon pour les voir.

### 8.4 Confidentialité de l'export

- Le compagnon n'exporte vers le LLM **que** les événements de visibilité `G`, **et** seulement ceux des auteurs qui ont activé « autoriser l'export hors jeu ». Ce consentement est distinct du partage en guilde, **activé par défaut** (décision du 2026-11-20 : décochable à tout moment, un « non » explicite est toujours conservé) et porté par l'événement `AI_CONSENT` de l'auteur.
- Avec un fournisseur distant, le compagnon affiche avant le premier envoi ce qui part et chez qui. Ollama local évite tout envoi.

---

## 9. Album de guilde (cartes à collectionner)

### 9.1 Catalogue : généré, déterministe, consultable par tous

| Série | Source des cartes | Critère d'apparition |
|---|---|---|
| Fondateurs | liste fixée par le chef de guilde (`GUILD_CONFIG`) | manuel |
| Membres | membres équipés de l'addon **ayant accepté d'apparaître** (désinscription possible à tout moment) | automatique |
| Ennemis jurés | fiches du Wanted Board avec statut d'ennemi juré | règle §6.2 |
| Expéditions | expéditions collectives marquantes (boss, ≥ 4 membres) | règle Legacy |
| Faits divers | anecdotes et nécrologies retenues par la gazette | rédacteur |
| Légendes | exploits historiques | rédacteur, en très petit nombre |

- **Rareté = variante de la carte, pas valeur de la personne.** Chaque carte Membre existe en commune, rare (cadre doré), épique (animée) et légendaire (variante illustrée par une anecdote). Tout le monde a donc sa légendaire.
- Visuel : textures du jeu (cadres de hauts faits, bordures de qualité d'objet, icônes de classe), plus le texte. Des illustrations personnalisées (`.tga`/`.blp`) pourront être ajoutées plus tard. Aucune image de personne réelle.
- Le catalogue est **versionné** (`catalogueVersion`) et recalculé de façon identique chez tous à partir des événements partagés.

### 9.1 bis Catalogue publié (v0.12.0-test.8)

- **Une seule vérité, diffusée en pair à pair.** Le catalogue = le **set de base** Azeroth (`Core/Cards.lua`, numéros `B-001…`, daté du 19/11/2026) + les cartes des événements **`CARD_SET`** publiés par un officier (même règle de confiance que les mises en page, `Views.TrustedOfficer`). Chaque carte a un **numéro** (`no`) et une **date de publication** (celle de l'événement). Un id déjà publié garde son premier numéro.
- **Qui crée les cartes** : l'app admin, avec chaque numéro de la gazette (`admin/core/src/cards.rs`). Les règles choisissent les cartes (4 variantes par membre, un palier tous les 10 niveaux, premier kill d'un boss, sortie à 2+, anecdote, mort au tueur connu, article publié, ennemi qui compte) ; l'IA n'écrit que le nom et le texte, et seulement pour les membres qui ont accepté la gazette IA. Les `CARD_SET` (découpés sous 4 ko) partent dans `Press.lua` avec le numéro ; publier la mise en page dans `Renatus_Admin` publie aussi ses cartes.
- **Transition** : tant qu'aucun `CARD_SET` n'existe, les cartes de guilde sont calculées localement comme avant (`Album.Legacy`). Les cartes possédées absentes du catalogue restent affichées (« ancienne édition »), jamais tirées.
- **Profil de carte** (`CARD_PROFILE`, `Collectors/Profile.lua`) : chaque membre envoie sa race, son sexe, sa classe, ses objets portés et son choix « ne pas apparaître dans l'album des autres » (désormais réellement respecté).
- **Illustration** : fond par série (textures générées), puis modèle 3D (créature `npc` du set de base, ou le membre habillé de ses objets), sinon icône nette en médaillon. Les modèles sont sous `pcall` et vérifiés : un modèle vide laisse la place à l'icône. **À valider en jeu sur Forever.**
- **Ouverture** : le paquet tremble et se déchire, les cartes sortent face cachée ; clic pour en retourner une, ou « Tout retourner ». Clic sur une carte de l'album : vue agrandie.
- **Cartes brillantes** (comme les « foils » d'un TCG) : une **finition**, pas une rareté. Chaque carte tirée a 1 chance sur N d'être brillante, quelle que soit sa rareté (N = `shiny` de la règle des boosters, 20 par défaut, 0 = aucune ; champ « Brillantes » de l'onglet Boosters de `Renatus_Admin`). Tirage sur une suite à part (`Album.BoosterContents`) : le taux ne change jamais les cartes tirées. Un exemplaire brillant est l'**id de la carte suivi de `+`** (`Album.ShinyId`, `Album.BaseId`) : ouvertures, échanges et collections le comptent comme une carte à part sans changer de format ; `Album.Known` le résout à la volée. L'album garde **une case par carte** (normales + brillantes), une étoile à côté du nombre d'exemplaires, l'effet brillant dès qu'on en a une ; filtres « Brillantes » / « Sans brillante » dans le menu de possession. Effet (`UI/TabAlbum.lua`, textures `holo`, `sheen`, `sparkle`) : reflet arc-en-ciel en fondu additif qui dérive, bande de lumière qui balaie la carte, éclats qui scintillent (toujours aux mêmes endroits pour une carte), cadre et halo irisés ; au tirage, « BRILLANTE ! » et une gerbe arc-en-ciel. Un client plus ancien voit un exemplaire brillant comme une « Carte retirée ».

### 9.2 Boosters : trois modèles proposés (à choisir)

| Modèle | Règle | Avantages | Inconvénients |
|---|---|---|---|
| **A. Ration hebdomadaire** | 1 booster par semaine si connecté au moins une fois ; +1 par expédition de guilde (≥ 2 membres équipés), plafonné à +2 | Simple ; écart faible entre joueurs occasionnels et assidus | Peu lié aux exploits |
| **B. Jalons** | Booster aux paliers (niveau 10, 20…, premier boss, article publié, avis de recherche levé) | Récompense des moments marquants | Inégal ; concentré en début de partie ; incite à « chasser » les jalons |
| **C. Caisse commune** | Objectifs hebdomadaires de **guilde** (par exemple 5 expéditions collectives) ; tout membre ayant participé au moins une fois reçoit un booster | Pousse à jouer ensemble | Dépend de l'activité des autres |

**Recommandation : A + C**, avec un plafond de 3 boosters par semaine et un report de 2 semaines maximum, pour que les absents rattrapent sans que les assidus creusent l'écart. B pourrait rester réservé à quelques jalons rares, comme les Légendes.

**Implémenté (`Core/Album.lua`, page Boosters de Renatus_Admin)** : règle de guilde diffusée par un officier (`GUILD_CONFIG.p.boosters`), calculée jour par jour avec la règle en vigueur ce jour-là (une nouvelle règle ne reprend rien).

- **Forme par source** `{ day, cap, src = { [source] = { n, cap } } }` : `day` par jour joué ; pour chaque source, 1 booster toutes les `n` occurrences, au plus `cap` par jour pour cette source ; au plus `cap` par jour en tout. **0 veut toujours dire 0** (n = 0 : source coupée) ; pas de limite haute. Sources (`Album.SOURCES`) : niveau, boss de fin de donjon (`Album.FINAL_ENCOUNTERS`, identifiants de rencontre Classic, une fin par aile), boss de donjon (tous), boss de raid (`loc.it == "raid"`), sortie avec la guilde, victoire honorable, quête rendue, nouvelle zone, objet rare ou mieux, rang de réputation, monture, duel gagné.
- **Ancienne forme** `{ day, bonus, cap }` (et règle par défaut 1/+1/5) : toujours lue pour les jours où elle s'appliquait. Une règle par source porte aussi un `bonus` indicatif pour les clients plus anciens, qui continuent à calculer avec l'ancienne formule.

### 9.3 Mécanique vérifiable

- **Obtention** : un événement `BOOSTER_GRANT` de l'auteur, qui référence l'événement justificatif. Les autres clients vérifient le plafond hebdomadaire à partir du journal public.
- **Contenu** : il est **dérivé de façon déterministe** d'un hash de l'identifiant du booster et de la version du catalogue. Impossible de relancer le tirage, et tout le monde peut recalculer le contenu. La dernière carte est tirée parmi rare, épique et légendaire uniquement : au moins une rare par booster.
- **Échanges** : `TRADE_OFFER` (A propose X contre Y à B) puis `TRADE_ACCEPT` (B, en référençant l'offre). La propriété des cartes est obtenue en **rejouant** les journaux. Si A offre la même carte à deux personnes, la première acceptation (horodatage serveur) gagne et l'autre échoue de façon visible.
- Ce système n'est pas infalsifiable : un client modifié pourrait forger des événements. C'est acceptable entre amis.

### 9.4 Échanges et dons (implémentés, `Core/Trade.lua`, `UI/Trade.lua`)

- **Bonne foi assumée** : aucun contrôle des tirages ni des boosters gagnés (un client modifié peut toujours se donner des cartes). Les seules vérifications servent aussi la cohérence : on ne donne pas une carte qu'on n'a pas, ni deux fois la même.
- **Événements partagés** : `TRADE_OFFER` (le donneur : `p.to`, `p.toName`, `p.give` 1 à 5 cartes, `p.want` 0 à 5 cartes ; vide = **don**) et `TRADE_REPLY` (`refs = { offre }`, `p.ok`) : du destinataire, accepte ou refuse ; du donneur, retire l'offre. Une offre sans réponse expire au bout de 7 jours.
- **Propriété rejouée** (`Trade.Replay`, dans `Store.Dataset` : `ds.trades`) : ouvertures **partagées** et échanges acceptés, dans l'ordre du temps. À l'acceptation, si le donneur n'a plus ses cartes ou le destinataire celles demandées, l'échange **échoue**, pareil chez tous. Les cartes d'un booster ouvert avec l'album en privé restent dans l'album de leur propriétaire mais ne s'échangent pas (les autres ne les voient pas). Échanger demande l'album sur « Guilde ».
- **Réservation** : une carte proposée dans une offre en attente ne peut pas être proposée ailleurs (`Trade.Tradable`).
- **Interface** : bouton « Échanges » de l'album (offres reçues : Voir, Accepter, Refuser ; envoyées : Retirer ; historique), « Nouvelle offre » (mes cartes à gauche, les siennes à droite, d'abord celles que l'autre n'a pas ; la carte survolée en grand au milieu). Menu « Ma collection / membre » de l'album, et « Voir sa collection » dans Membres : clic sur une de ses cartes = la lui demander. Pastille dorée (album, icône de la gazette) = boosters + offres à répondre ; annonce dans le chat à l'arrivée d'une offre ou d'une réponse ; « Reçue de X le … » sous une carte agrandie.

---

## 10. Synchronisation

**Implémentation v0.3.0** (`Sync/Serialize.lua`, `Sync/Transport.lua`, `Sync/Sync.lua`) : trois messages suffisent.
- `V` : vecteur `{auteur → séquence contiguë max}`, annoncé à la connexion (+15 à 30 s) puis toutes les 15 min, et en réponse à un vecteur en retard.
- `R` : demande d'une plage (25 événements max) d'un auteur. L'auteur répond sous 1 s, les relais après 3 à 8 s, et se taisent si l'événement est passé sur le canal entre-temps.
- `E` : un événement, diffusé à toute la guilde. Un nouvel événement public est diffusé dès sa création (la file attend la sortie d'instance ou de combat).
- Messages découpés en morceaux de 250 octets ; 4 messages en rafale puis 1 toutes les 1,2 s.

Conception d'origine :
- Journaux par auteur en ajout seul ; anti-entropie par vecteur `{auteur → séquence contiguë max}`.
- Messages `H` (hello), `V` (vecteur), `R` (requête), `E` (événements), `N` (nouveau) ; préfixe `Renatus`.
- Envoi uniquement hors instance et hors combat ; réponses espacées par un délai aléatoire.
- Validation du schéma, de la taille et de l'appartenance de l'expéditeur au roster ; « vérifié » (reçu de l'auteur) ou « relayé ».
- Partage désactivé par défaut, par catégorie ; tombstones sans promesse d'effacement des copies déjà reçues.

Points nouveaux :
- **Priorités de file d'attente** : `GUILD_CONFIG` > `TOMBSTONE` > événements de jeu > `ARTICLE` (volumineux) > `ENEMY_SEEN`.
- **Taille** : un article fait environ 2 à 4 Ko compressés. Avec AceComm, cela fait 10 à 20 messages, envoyés au fil de l'eau par ChatThrottleLib.
- **Catégories de partage supplémentaires** : PvP / Wanted, Gazette (votes et commentaires), Album (boosters et échanges). L'Album ne fonctionne qu'avec le partage activé pour sa catégorie.

---

## 11. Plan de développement

| Étape | Contenu | État |
|---|---|---|
| 0 | Analyse, architecture, sonde | ✅ |
| 0.1 | **Sonde en jeu (toi)** : V1–V11 | ⏳ bloquant pour les collecteurs |
| 1-V | Addon unique ; Renacoach → module Voice ; tests | ✅ (à valider en jeu) |
| 1a | Core : Ids, Store (dédup, requêtes), Provenance | ✅ v0.2.0 |
| 1b | Collecteurs fiables (niveau, mort, boss, quêtes, zones, guilde) + **détecteur d'expéditions** | ✅ v0.3.0 (à valider en jeu) |
| 1c | Interface : **tous les onglets** (journal, guilde, membres, chasse, gazette, album, voix, paramètres), mode démo | ✅ v0.2.0 (à valider en jeu) |
| 2 | Synchro (protocole, confidentialité), timeline de guilde, vue collective | ✅ v0.3.0 (sans bibliothèque ; tombstones à faire) |
| 3 | **Wanted Board v1** : observations, déclarations manuelles, avis de recherche, fiches | ✅ v0.3.0 (rivalités §6.4 à faire) |
| 4 | **Compagnon v1, sans LLM** : lecture des SavedVariables et des journaux de combat, écriture de `Renatus_Press` | ✅ v0.3.0 (résumés d'expédition : commande `facts`) |
| 5 | **Gazette** : LLM et styles dans le compagnon ; dans le jeu, lecture des articles, votes, commentaires, courrier | après 2 et 4 |
| 6 | Legacy : rivalités, titres, anecdotes ; déclencheurs vocaux historiques | après 2 |
| 7 | **Album** : catalogue, boosters (modèle choisi), échanges | après 2, 3 et 6 |

---

## 12. Vérifications en jeu (sonde `tools/ChronicleProbe`)

| # | Question |
|---|---|
| V1 | Interface renvoyée par `GetBuildInfo()` |
| V2 | SavedVariables relues après `/reload` et après redémarrage |
| V3 | Spécialisations : existence et valeurs (`GetSpecialization`) |
| V4 | Messages d'addon GUILD, PARTY et WHISPER : dans et hors instance, en combat, en champ de bataille |
| V5 | Taille maximale d'un message (255 octets ?) et throttling (rafale de 30) |
| V6 | Inscription à `COMBAT_LOG_EVENT_UNFILTERED` refusée ? |
| V7 | Payloads de niveau, quête, boss, mort, métiers, butin, hauts faits, en instance et hors instance |
| V8 | `PlaySoundFile` avec un son de l'addon |
| V9 | Format de `UnitGUID` et de `GetGuildInfo` |
| V10 | ✅ partiel (21/11/2026) : `COMBATLOG_HONORGAIN` et `GetPVPSessionStats()` existent ; l'arrivée de `CHAT_MSG_COMBAT_HONOR_GAIN` reste à voir à la prochaine victoire. **PvP** : un joueur ennemi en cible, survol ou barre de nom donne-t-il nom, guilde, niveau, race et classe ? `CHAT_MSG_COMBAT_HONOR_GAIN` existe-t-il ? |
| V11 | `/combatlog` écrit-il un fichier dans `_forever_/Logs/` ? (vérification à faire à la main) |
| V12 | Faits divers (v1.0.11), hors instance : messages de duel (`DUEL_WINNER_KNOCKOUT`/`RETREAT`), `/roll` (`RANDOM_ROLL_RESULT`), jets de besoin (`LOOT_ROLL_ROLLED_NEED`), réputation (`FACTION_STANDING_CHANGED`), ivresse (`DRUNK_MESSAGE_SELF*`), `RESURRECT_REQUEST`, `CONFIRM_XP_LOSS`, `NEW_MOUNT_ADDED`, `GetBindLocation`, `UnitHealth` du joueur en combat (secret ?), crochets `JumpOrAscendStart` et `DoEmote`. Les compteurs se vérifient le lendemain (événement `COUNTERS`). |

Mode d'emploi :
1. Copier `tools/ChronicleProbe` **et** `Renatus` dans `_forever_/Interface/AddOns/`.
2. Taper `/gcprobe`, `/gcprobe sound`, `/gcprobe comm` et `/gcprobe burst`.
3. Refaire `/gcprobe comm` dans un donjon, en combat et hors combat.
4. Tuer un boss, mourir une fois, monter un niveau.
5. Cibler et survoler quelques joueurs de la faction adverse ; si possible, tuer un joueur adverse en monde ouvert.
6. Taper `/combatlog`, combattre un peu, retaper `/combatlog`, puis regarder le dossier `Logs`.
7. Faire `/reload`, puis transmettre `WTF/Account/<COMPTE>/SavedVariables/ChronicleProbe.lua` (et les premières lignes du fichier de journal de combat s'il existe).

En parallèle, tester Renatus : `/renacoach on`, entrer en combat, puis `/renatus voice status`.

---

## 13. Décisions encore ouvertes

1. **Modèle de boosters** : A + C recommandé (§9.2).
2. **Nom de l'addon** : `Renatus`, ou le nom de la guilde ? C'est facile à changer maintenant, plus coûteux une fois l'addon diffusé (les SavedVariables portent le nom).
3. **Rédacteurs de la gazette** : qui ? Désignés par le chef de guilde (§7.3) : est-ce que ça te convient ?
4. **Fournisseur LLM** du compagnon : API distante (laquelle ?) ou Ollama local ?
5. **Cartes Membres** : présence par défaut avec possibilité de se retirer (proposé), ou inscription volontaire ?
6. **Valeur par défaut du module Voice** : désactivé pour tout le monde (choix actuel). Le garder activé pour toi seul ne demande qu'un `/renacoach on`.
