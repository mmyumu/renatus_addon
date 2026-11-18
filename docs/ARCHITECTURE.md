# Guild Chronicle — Architecture (v2)

> Mise à jour : 18/11/2026. Elle intègre les décisions du 18/11 et l'extension des spécifications : Wanted Board, Gazette, collecte enrichie, journaux de combat et cartes.
> La v1 (analyse initiale détaillée de Renacoach) est dans l'historique git (`git show 4d6a2f9:docs/ARCHITECTURE.md`).
> Les points **[À VÉRIFIER]** dépendent de la sonde `tools/ChronicleProbe` (§12).

---

## 0. Décisions prises

| # | Décision | Conséquence |
|---|---|---|
| D1 | **Un seul addon** `GuildChronicle`. Renacoach devient le module `Voice`, une option « pour la blague ». | Fait : `GuildChronicle/Voice/`, désactivé par défaut, `/chronicle voice on` ou `/renacoach on`. |
| D2 | **Bibliothèques externes autorisées.** | v0.3.0 : finalement **aucune** n'est nécessaire. Sérialisation, découpage et file d'envoi sont écrits dans l'addon (`Sync/`, quelques centaines de lignes, testées), ce qui évite toute dépendance à vérifier sur Forever. LibDeflate (compression) reste une option si le débit s'avère insuffisant. |
| D3 | Renacoach visait **Retail** (dernière mise à jour en mai 2026). | Le TOC déclare `16001, 120005` (Forever et Retail). Le code teste l'existence de chaque API au lieu de supposer une version. |
| D4 | Dépôt git initialisé. Le dossier est une copie de travail. | L'historique conserve Renacoach d'origine (`07cd01b`). |
| D5 | Le « TCG » devient l'**Album de guilde** : collection et échanges, **aucun combat de cartes**. | §9 |

---

## 1. État actuel du dépôt

### Avancement v0.4.0 (18/11/2026)

- **Gazette rédigée par IA** (`companion/gazette.py`, `companion/llm.py`) : le compagnon du rédacteur construit une liste de faits numérotés à partir des événements **partagés** de la semaine, l'envoie à une commande externe (par défaut Claude Code en mode `-p`, sans outils, éventuellement sur une autre machine via SSH), puis vérifie la réponse avant de la proposer dans **Gazette > Rédaction**.
- **Consentement synchronisé** (§7, §8.4) : la case « La gazette rédigée par IA peut parler de moi » publie un événement masqué `AI_CONSENT` (toujours partagé, le dernier choix compte). Sans « oui » explicite : événements écartés, nom retiré des faits des autres (fait supprimé si texte libre, « +n autres participants » dans une expédition).
- **Rivaux pseudonymisés** pour l'IA (« Rival A (voleur Orc) ») ; provenance conservée dans les faits (« selon X (déclaré, non vérifié) », « supposé »).
- **Vérification de la réponse** : chaque article doit citer des faits fournis, ne nommer aucun membre non consentant ni rival, respecter les longueurs ; sinon il est rejeté (jamais corrigé). Articles marqués `p.ia`, affichés « rédigé par IA, relu par X ».
- Une édition par semaine via `run` (`[llm] enabled = true`), `gazette --show` affiche la demande exacte sans appeler l'IA.
- 67 tests Lua, 19 tests Python.

### Avancement v0.3.0 (18/11/2026)

- **Synchronisation entre membres** (`Sync/`) : protocole par vecteurs (§10), canal GUILD uniquement, envoi seulement hors instance et hors combat, débit limité, validation stricte de ce qui est reçu, distinction « reçu de l'auteur » / « relayé ». Seuls les événements des catégories réglées sur « Guilde » partent ; le reste ne quitte jamais le client.
- **Expéditions** (`Collectors/Expedition.lua`) : donjon, raid, champ de bataille, groupe avec un membre de la guilde ; tolérance de 10 min à la sortie d'instance ; fin estimée (`ded`) après une déconnexion ; membres de la guilde nommés, autres joueurs seulement comptés.
- **Tableau de chasse automatique** (`Collectors/Enemies.lua`) : rencontres avec la **guilde rivale configurée** (cible, survol, barres de nom), une observation par ennemi et par 10 min ; à la mort, rivaux aperçus dans les 30 s notés « présents » (supposé), jamais « tueurs ».
- **Voix** : spécialisations reconnues par **identifiant** (et non par index), repli sur la classe, réglage manuel du rôle et du style de combat (pour les spés propres à Forever).
- **Compagnon v1, sans LLM** (`companion/`) : lecture des SavedVariables et des journaux de combat, causes de mort, affrontements PvP contre des rivaux connus, articles écrits à la main, écriture de `GuildChronicle_Press/Press.lua`. En jeu, **Gazette > Rédaction** : rien n'est publié sans validation.
- **Gazette réelle** : articles (`ARTICLE`, provenance « Rédaction »), votes pour la une (un par membre et par semaine), causes de mort affichées sur les morts (« d'après le journal de combat de X »).
- 66 tests Lua (`lua tests/run.lua`) et 14 tests Python (`python3 -m unittest discover -s tests/companion -t .`).
- **Pas encore faits** : ~~LLM de la gazette (fait en v0.4.0)~~, obtention réelle de boosters (modèle à choisir, §9.2), réglages de guilde signés par le chef (`GUILD_CONFIG` : rédacteurs, rivale commune), tombstones, rivalités détectées (§6.4).

### Avancement v0.2.0 (18/11/2026)

- **Interface complète** (`/chronicle`, bouton de minicarte) : Mon journal, Guilde, Membres, Tableau de chasse, Gazette, Album, Voix, Paramètres. Tout est construit sans templates FrameXML : de simples frames et textures, pour limiter la dépendance à des globales qui pourraient manquer sur Forever.
- **Mode démo** (`/chronicle demo`) : données fictives en mémoire, jamais sauvegardées, pour voir chaque écran rempli.
- **Données réelles** : stockage (`Core/Store.lua`), vues calculées (`Core/Views.lua`), catalogue et boosters déterministes (`Core/Album.lua`).
- **Premiers collecteurs** (`Collectors/Basic.lua`) : niveau, mort (sans cause), quête, boss (`ENCOUNTER_END`), première visite de zone, entrée en guilde. Ils restent à confirmer par la sonde.
- **Saisies manuelles** (marquées « déclaré ») : anecdote, fiche ennemie, affrontement, avis de recherche, courrier des lecteurs.
- **Pas encore faits** : synchronisation (l'onglet Guilde n'affiche que tes événements), détecteur d'expéditions, observation automatique des ennemis, compagnon et gazette réelle, obtention réelle de boosters.
- 40 tests hors client (`lua tests/run.lua`) : Voice, Core, collecteurs, vues et construction de tous les onglets.

### Arborescence initiale (v0.1.0)

```text
GuildChronicle/                 l'addon unique
  GuildChronicle.toc            Interface 16001, 120005 ; SavedVariables GuildChronicleDB (compte), GuildChronicleCharDB (perso)
  Core/Init.lua                 namespace, modules, RegisterGameEvent (inscription protégée par pcall)
  Core/EventBus.lua             Publish/Subscribe, isolation des erreurs ; API publique GuildChronicle.Subscribe
  Core/Settings.lua             valeurs par défaut, version de schéma, migrations
  Core/Slash.lua                /chronicle, /chronicle voice …, /renacoach
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
GuildChronicle/
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
- `GuildChronicleDB.guilds[guilde].events`, plus des tombstones.
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
| Participation à un kill (crédit d'honneur) | `CHAT_MSG_COMBAT_HONOR_GAIN` si Forever a le système d'honneur Classic | `OBS` (« a contribué », pas « a tué ») | **[V10]**, hors instance |
| Coup fatal, tueur, sort utilisé | Fichier de journal de combat | `LOG` | Via le compagnon (§8) |
| Victoire ou défaite déclarée | Formulaire « Déclarer un affrontement » | `MAN`, confirmable par d'autres membres présents | Oui |

- Les observations sont **limitées en fréquence** : une observation par ennemi toutes les 10 min, et la fiche ne garde que la dernière observation par lieu. On garde des rencontres, pas une traque.
- La **guilde rivale** est configurée par son nom (réglage de guilde, voir §7.3). Les autres joueurs ennemis ne sont **pas** enregistrés, sauf ajout manuel.

### 6.2 Fiche ennemi

Elle est calculée à partir des événements `ENEMY_SEEN`, `PVP_CLASH`, `PVP_KILL_LOG` et `ENEMY_NOTE` :
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
2. [jeu]        /reload ou déconnexion : écriture de WTF/…/SavedVariables/GuildChronicle.lua
3. [compagnon]  lecture des SavedVariables (+ journaux de combat facultatifs, §8)
4. [compagnon]  sélection : événements de la période, importance ≥ seuil, groupés par expédition
5. [compagnon]  contexte structuré : faits numérotés, provenance, surnoms, rivalités,
                3 à 5 articles précédents résumés (pour la continuité)
6. [compagnon]  génération LLM : style éditorial configuré
7. [compagnon]  relecture par le rédacteur (éditer, refuser, régénérer)
8. [compagnon]  écriture de l'addon de données GuildChronicle_Press/Press.lua
9. [jeu]        /reload chez le rédacteur : « 4 articles prêts, publier ? »
10. [jeu]       publication = événements ARTICLE du rédacteur → synchro vers la guilde
```

- **Un seul membre a besoin du compagnon** : le rédacteur. Les autres reçoivent les articles par la synchro de l'addon.
- `GuildChronicle_Press` est un mini-addon, sans code, ne contenant qu'une table Lua. Il est réécrit par le compagnon pendant que le jeu tourne et relu au `/reload` (un `/reload` relit les fichiers Lua listés dans les TOC ; seul un **nouveau** fichier exige un redémarrage du client). C'est un mécanisme de fichiers standard, sans injection.
- Chaque article stocke `refs` (identifiants des événements sources) et `style`. Dans le jeu, un bouton « Sources » affiche les faits d'origine.

### 7.2 Garde-fous anti-invention

- Le prompt reçoit des **faits numérotés**. Chaque phrase factuelle du texte doit pouvoir citer un numéro. Les tournures (« la rédaction salue sa persévérance ») sont libres ; les faits (« il est mort trois fois ») doivent exister.
- Une seconde passe automatique (LLM ou règles) liste les affirmations factuelles du texte et les confronte aux faits. Une affirmation non sourcée est signalée au rédacteur avant publication.
- Une provenance `DED` ou `MAN` doit être formulée avec réserve (« selon des sources proches de l'intéressé »). C'est une contrainte de style, et le ton de mauvaise foi s'y prête très bien.

### 7.3 Rôles et règles de publication

- **Réglages de guilde** : un événement `GUILD_CONFIG` signé par un membre de **rang 0** (chef de guilde) dans le roster au moment de la réception. Il désigne les rédacteurs, la guilde rivale et le style éditorial par défaut.
- **Articles** : seuls les rédacteurs publient la une et les éditions spéciales. Chaque article reste possédé par son auteur, qui seul peut publier un `EDIT` (rectificatif) ou un `TOMBSTONE`.
- **Contributions de tous** : brèves proposées, courrier des lecteurs, petites annonces, commentaires. Ce sont des événements de leurs auteurs, affichés dans la gazette avec leur signature.
- **Votes** pour la une de la semaine : événement `VOTE`, un par membre et par semaine, le dernier compte. Résultat calculé.
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
  press.py         écriture de GuildChronicle_Press/Press.lua
  config.toml
```

### 8.2 Journaux de combat

- Le client Retail écrit `Logs/WoWCombatLog-<date>.txt` quand le joueur tape `/combatlog`. **[V11 : à confirmer sur Forever : le fichier existe-t-il, son format, l'option de journalisation avancée]**
- Le fichier n'est **pas** accessible depuis Lua pendant la session. Le compagnon le lit **après coup**. Ce n'est **pas** un pont temps réel.
- **Extraction ciblée** : `UNIT_DIED` (avec les derniers dégâts subis → cause de mort, chute comprise via `ENVIRONMENTAL_DAMAGE`), `PARTY_KILL` (coup fatal), dégâts entre joueurs (affrontements PvP), sorts marquants. On ne garde que les fenêtres utiles : expéditions connues de l'addon, et morts.
- **Alignement** : les horodatages du log sont en heure locale. On les convertit avec l'écart enregistré par l'addon (§4.4), puis on recale sur des ancres présentes des deux côtés (morts du joueur).
- **Fusion** : un événement `LOG` qui correspond à un événement addon (même type, même personnage, ±3 s) l'**enrichit** par une référence, sans créer de doublon. Une divergence (par exemple deux tueurs possibles) est conservée et signalée.

### 8.3 Retour dans le jeu des informations des logs

Les enrichissements `LOG` (causes de mort, coups fataux PvP) passent par le même addon de données `GuildChronicle_Press`. L'addon du rédacteur les publie comme événements `LOG` **signés par le rédacteur**. La fiche affiche « d'après le journal de combat de X ». Personne n'a besoin d'installer le compagnon pour les voir.

### 8.4 Confidentialité de l'export

- Le compagnon n'exporte vers le LLM **que** les événements de visibilité `G`, **et** seulement ceux des auteurs qui ont activé « autoriser l'export hors jeu ». Ce consentement est distinct du partage en guilde, désactivé par défaut et porté dans les métadonnées de l'auteur.
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

### 9.2 Boosters : trois modèles proposés (à choisir)

| Modèle | Règle | Avantages | Inconvénients |
|---|---|---|---|
| **A. Ration hebdomadaire** | 1 booster par semaine si connecté au moins une fois ; +1 par expédition de guilde (≥ 2 membres équipés), plafonné à +2 | Simple ; écart faible entre joueurs occasionnels et assidus | Peu lié aux exploits |
| **B. Jalons** | Booster aux paliers (niveau 10, 20…, premier boss, article publié, avis de recherche levé) | Récompense des moments marquants | Inégal ; concentré en début de partie ; incite à « chasser » les jalons |
| **C. Caisse commune** | Objectifs hebdomadaires de **guilde** (par exemple 5 expéditions collectives) ; tout membre ayant participé au moins une fois reçoit un booster | Pousse à jouer ensemble | Dépend de l'activité des autres |

**Recommandation : A + C**, avec un plafond de 3 boosters par semaine et un report de 2 semaines maximum, pour que les absents rattrapent sans que les assidus creusent l'écart. B pourrait rester réservé à quelques jalons rares, comme les Légendes.

### 9.3 Mécanique vérifiable

- **Obtention** : un événement `BOOSTER_GRANT` de l'auteur, qui référence l'événement justificatif. Les autres clients vérifient le plafond hebdomadaire à partir du journal public.
- **Contenu** : il est **dérivé de façon déterministe** d'un hash de l'identifiant du booster et de la version du catalogue. Impossible de relancer le tirage, et tout le monde peut recalculer le contenu.
- **Échanges** : `TRADE_OFFER` (A propose X contre Y à B) puis `TRADE_ACCEPT` (B, en référençant l'offre). La propriété des cartes est obtenue en **rejouant** les journaux. Si A offre la même carte à deux personnes, la première acceptation (horodatage serveur) gagne et l'autre échoue de façon visible.
- Ce système n'est pas infalsifiable : un client modifié pourrait forger des événements. C'est acceptable entre amis.

---

## 10. Synchronisation

**Implémentation v0.3.0** (`Sync/Serialize.lua`, `Sync/Transport.lua`, `Sync/Sync.lua`) : trois messages suffisent.
- `V` : vecteur `{auteur → séquence contiguë max}`, annoncé à la connexion (+15 à 30 s) puis toutes les 15 min, et en réponse à un vecteur en retard.
- `R` : demande d'une plage (25 événements max) d'un auteur. L'auteur répond sous 1 s, les relais après 3 à 8 s, et se taisent si l'événement est passé sur le canal entre-temps.
- `E` : un événement, diffusé à toute la guilde. Un nouvel événement public est diffusé dès sa création (la file attend la sortie d'instance ou de combat).
- Messages découpés en morceaux de 250 octets ; 4 messages en rafale puis 1 toutes les 1,2 s.

Conception d'origine :
- Journaux par auteur en ajout seul ; anti-entropie par vecteur `{auteur → séquence contiguë max}`.
- Messages `H` (hello), `V` (vecteur), `R` (requête), `E` (événements), `N` (nouveau) ; préfixe `GChron`.
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
| 4 | **Compagnon v1, sans LLM** : lecture des SavedVariables et des journaux de combat, écriture de `GuildChronicle_Press` | ✅ v0.3.0 (résumés d'expédition : commande `facts`) |
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
| V10 | **PvP** : un joueur ennemi en cible, survol ou barre de nom donne-t-il nom, guilde, niveau, race et classe ? `CHAT_MSG_COMBAT_HONOR_GAIN` existe-t-il ? |
| V11 | `/combatlog` écrit-il un fichier dans `_forever_/Logs/` ? (vérification à faire à la main) |

Mode d'emploi :
1. Copier `tools/ChronicleProbe` **et** `GuildChronicle` dans `_forever_/Interface/AddOns/`.
2. Taper `/gcprobe`, `/gcprobe sound`, `/gcprobe comm` et `/gcprobe burst`.
3. Refaire `/gcprobe comm` dans un donjon, en combat et hors combat.
4. Tuer un boss, mourir une fois, monter un niveau.
5. Cibler et survoler quelques joueurs de la faction adverse ; si possible, tuer un joueur adverse en monde ouvert.
6. Taper `/combatlog`, combattre un peu, retaper `/combatlog`, puis regarder le dossier `Logs`.
7. Faire `/reload`, puis transmettre `WTF/Account/<COMPTE>/SavedVariables/ChronicleProbe.lua` (et les premières lignes du fichier de journal de combat s'il existe).

En parallèle, tester GuildChronicle : `/renacoach on`, entrer en combat, puis `/chronicle voice status`.

---

## 13. Décisions encore ouvertes

1. **Modèle de boosters** : A + C recommandé (§9.2).
2. **Nom de l'addon** : `GuildChronicle`, ou le nom de la guilde ? C'est facile à changer maintenant, plus coûteux une fois l'addon diffusé (les SavedVariables portent le nom).
3. **Rédacteurs de la gazette** : qui ? Désignés par le chef de guilde (§7.3) : est-ce que ça te convient ?
4. **Fournisseur LLM** du compagnon : API distante (laquelle ?) ou Ollama local ?
5. **Cartes Membres** : présence par défaut avec possibilité de se retirer (proposé), ou inscription volontaire ?
6. **Valeur par défaut du module Voice** : désactivé pour tout le monde (choix actuel). Le garder activé pour toi seul ne demande qu'un `/renacoach on`.
