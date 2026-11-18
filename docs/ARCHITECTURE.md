# GuildChronicle — Phase 0 : analyse et architecture

> Statut : proposition, à valider. Date : 18/11/2026.
> Les points marqués **[À VÉRIFIER]** doivent être confirmés dans le client avec la sonde `tools/ChronicleProbe` (voir §3.3).

---

## 1. Analyse de l'addon vocal existant (Renacoach)

### 1.1 Inventaire

| Fichier | Rôle |
|---|---|
| `Renacoach.toc` | `## Interface: 120005` (Retail Midnight 12.0.5), auteur Dakey, v1.0.0. **Pas de `SavedVariables`.** |
| `Renacoach.lua` (273 lignes) | Tout le code : tables de sons, frame d'événements, lecture, atténuation du volume. |
| `Resources/*.ogg` | 34 répliques, de 0,6 à 2,7 s (48 s au total). **Toutes référencées, aucune orpheline.** |
| `boost_ogg_volume.py` | Outil hors-jeu (ffmpeg) de normalisation. `--overwrite` réécrit les originaux : **à ne pas lancer** (consigne : ne pas modifier l'audio). |

### 1.2 Architecture

Un seul fichier, une seule frame, aucun namespace. Les fonctions sont **globales** (`OnLoad`, `UpdateCombat`, `PlayRandomSound`, `DuckCombatSounds`, `RestoreCombatSounds`, `GetSpecInfos`, `ConcatenateLists`, `GetCharacterType`, plus la variable `playerClassID`). `OnLoad` en global est un nom très générique, donc un risque de collision avec un autre addon.

### 1.3 Déclencheurs

| Événement WoW | Effet | Familles de répliques |
|---|---|---|
| `PLAYER_LOGIN` | Construit la liste « en combat » selon le **rôle** (spé) et le **type** (melee/caster/ranged). | — |
| `PLAYER_REGEN_DISABLED` (entrée en combat) | Joue une réplique, puis remet le minuteur à zéro. | `startFight` (4) |
| `OnUpdate`, toutes les 3 s si `InCombatLockdown()` | 50 % de chances de jouer une réplique. | `fightGeneric` (11) + rôle (`fightTank` 5, `fightHealer` 2, `fightDPS` 0) + type (`fightMelee` 2, `fightCaster` 2, `fightRanged` 1) |
| `PLAYER_REGEN_ENABLED` (sortie de combat) | Joue une réplique. | `endFight` (3) |
| `PLAYER_DEAD` | Joue une réplique. | `death` (4) |
| `PLAYER_LOGOUT` | Restaure immédiatement le volume SFX. | — |

### 1.4 Lecture des sons

- `PlaySoundFile(path, "Ambience")`. Si le son est refusé (canal Ambiance coupé), nouvel essai sur `"Master"`.
- Anti-chevauchement : `StopSound(lastSoundHandle)` avant chaque lecture. Une seule réplique joue à la fois, la nouvelle coupe l'ancienne.
- **Ducking** : le CVar `Sound_SFXVolume` est abaissé à 0,25 pendant 2,8 s, puis remonte en fondu (1,2 s, 8 paliers via `C_Timer.After`). Un jeton (`duckToken`) annule les restaurations obsolètes.

### 1.5 Ce qui n'existe pas

- **Aucune communication entre joueurs.** Les répliques sont jouées **uniquement chez le joueur qui a l'addon**, pour ses propres événements. Il n'y a pas de mécanisme de synchronisation à réutiliser.
- Pas de configuration : tout est codé en dur (probabilité 0,5, période 3 s, canal, ducking). Pas de commande slash, pas d'interface, pas de persistance.
- Aucune dépendance externe (pas de bibliothèque).

### 1.6 Défauts et risques identifiés (sans correction à ce stade)

1. **TOC** : `120005` est une interface Retail. D'après des sources non officielles, Forever annonce `16001`. Si c'est confirmé, l'addon apparaît « périmé » et ne se charge que si « Charger les addons périmés » est coché. **[À VÉRIFIER]**
2. **Spécialisations** : `GetSpecialization()` / `GetSpecializationInfo()` sont des API Retail. Forever ayant des talents de style Classic, deux cas sont possibles. Si la fonction n'existe pas, `OnLoad` plante. Si elle renvoie `nil`, le rôle est `nil`, aucune branche ne s'applique, et **la liste « en combat » reste vide** : seules les répliques de début et de fin de combat et de mort jouent. **[À VÉRIFIER — point le plus important pour la V1 vocale]**
3. **Chasseur** : la table donne `{ranged, melee, ranged}`. Dans l'ordre Retail (Maîtrise des bêtes, Précision, Survie), **Précision passe donc en « melee » et Survie en « ranged »**. Ce sont deux erreurs. L'Évocateur est absent (sans effet sur Forever s'il n'y existe pas).
4. Un changement de spé n'est pris en compte qu'au prochain `/reload`.
5. **Volume SFX bloqué** : le ducking modifie un CVar **persistant**. Un crash ou une déconnexion pendant la fenêtre de 4 s laisse le volume SFX à 25 % de façon permanente. Si le joueur change son volume SFX pendant un ducking, son réglage est écrasé à la restauration.
6. À la mort, `PLAYER_DEAD` et `PLAYER_REGEN_ENABLED` arrivent presque en même temps : la réplique « fin de combat » peut couper la réplique « mort », ou l'inverse. **[À VÉRIFIER en jeu]**
7. `OnUpdate` tourne à chaque frame, même hors combat. Le coût est négligeable, mais un `C_Timer.NewTicker` actif seulement en combat serait plus propre.
8. Fréquence : une chance sur deux toutes les 3 s donne une réplique toutes les 6 s en moyenne en combat. C'est le comportement voulu à préserver, mais il devra être réglable.

### 1.7 Ce qui est réutilisable

Les 34 fichiers audio et leur **classement en familles**. Ce classement est déjà une taxonomie exploitable : encouragement générique, rôle, type, mort, début et fin de combat. Le mécanisme anti-chevauchement et le ducking (une fois sécurisé) le sont aussi.

---

## 2. Ce qu'est WoW Forever (état des connaissances)

Sources : guides et sites de fans (wowforevertierlist.com, conquestcapped.com, foreverchanges.pro), pas de documentation Blizzard. Elles concordent sur l'essentiel :

- C'est un **type de jeu Blizzard qui tourne sur le client Retail** (base de code Midnight), avec un contenu de style Classic. Client 1.60.1, **interface `16001`**, en ligne depuis le 4 novembre 2026 (une seule source donne cette date).
- **Les restrictions d'addons de Midnight s'appliquent** (« secret values »). Une source précise que cette affirmation repose sur une déclaration Discord, sans liste officielle propre à Forever.
- Les addons Classic Era ne se chargent pas tels quels. Les addons Retail ne sont pas garantis non plus (environ un millier de globales FrameXML retirées).
- Pendant la bêta, le type de jeu interne était `camelot` (`WOW_PROJECT_CAMELOT = 18`), avec un renommage annoncé : **ne rien coder en dur dessus**.
- Bug de bêta : les SavedVariables étaient écrites mais pas relues. Corrigé selon deux sources, non confirmé selon une troisième. **[À VÉRIFIER — critique pour un journal]**

### 2.1 Conséquences des restrictions Midnight (si confirmées sur Forever)

| Contrainte | Impact sur le projet |
|---|---|
| **Journal de combat (`COMBAT_LOG_EVENT_UNFILTERED`) retiré aux addons** | Pas de **cause de mort**, pas de « tué par X », pas de détection de mort par chute, pas de kill de rare via le journal de combat. Le titre « Ennemi juré de la gravité » est **irréalisable** en l'état. |
| **Aucune communication vers les autres joueurs en instance** (ni messages d'addon, ni chat) | **Aucune synchro en donjon ou en raid.** Tout ce qui se passe en instance est mis en file d'attente et envoyé à la sortie. |
| Chat reçu en instance livré en « secret values » | Les messages de butin (`CHAT_MSG_LOOT`) ne sont probablement **pas lisibles en donjon**. La détection d'objets rares y est compromise. |
| Noms et GUID des créatures secrets en instance | Le nom d'un boss passe par `ENCOUNTER_END` (si son nom n'est pas secret) ou par son `encounterID`. **[À VÉRIFIER]** |
| Hors instance : « presque pas de limites » | La synchro, la collecte en monde ouvert et l'interface fonctionnent normalement. |

Bonne nouvelle pour le projet : un journal **narratif** n'a besoin que d'événements de haut niveau, pas de chiffres de combat. La philosophie du cahier des charges (« pas un outil d'optimisation ») tombe exactement du bon côté des restrictions.

---

## 3. Vérifications à faire dans le client

### 3.1 Liste

| # | Question | Pourquoi |
|---|---|---|
| V1 | Valeur de `GetBuildInfo()` (interface) | Valeur à mettre dans les TOC |
| V2 | SavedVariables relues après `/reload` et après redémarrage | Tout le journal en dépend |
| V3 | `GetSpecialization` existe-t-elle et que renvoie-t-elle ? Alternative de rôle (`UnitGroupRolesAssigned`, `GetTalentTabInfo`) | Renacoach (§1.6-2) |
| V4 | `C_ChatInfo.SendAddonMessage` sur GUILD, PARTY et WHISPER, **dans et hors instance, dans et hors combat** ; codes de retour | Protocole de synchro |
| V5 | Taille maximale d'un message (255 octets ?) et throttling réel (rafale de 30) | Dimensionner le transport |
| V6 | Inscription à `COMBAT_LOG_EVENT_UNFILTERED` refusée ? | Confirmer l'absence de cause de mort |
| V7 | Payload réel de `PLAYER_LEVEL_UP`, `QUEST_TURNED_IN`, `ENCOUNTER_END`, `BOSS_KILL`, `PLAYER_DEAD`, `CHAT_MSG_SKILL`, `CHAT_MSG_LOOT`, `ACHIEVEMENT_EARNED`, `UI_INFO_MESSAGE` (découverte de zone), **en instance et hors instance** (valeurs secrètes ?) | Choix des collecteurs |
| V8 | `PlaySoundFile` sur le canal `Ambience` avec un fichier d'addon | Renacoach |
| V9 | Format de `UnitGUID("player")` et de `GetGuildInfo` | Identifiants |

### 3.2 Ce qu'on peut déjà affirmer avec confiance

- Le Lua est le **Lua 5.1** de WoW (sans `require` ni I/O), avec les SavedVariables, `C_Timer` et `CreateFrame`. Le client étant Retail, ces fondations sont acquises.
- Retail a déjà fusionné `SendAddonMessage` dans `C_ChatInfo`, et la fonction renvoie un code de résultat.

### 3.3 Sonde de diagnostic

`tools/ChronicleProbe/` est un addon autonome, qui ne modifie rien d'autre que sa propre sauvegarde.

1. Copier `tools/ChronicleProbe` dans `World of Warcraft/_forever_/Interface/AddOns/`.
2. Se connecter, puis taper `/gcprobe` (résumé), `/gcprobe sound`, `/gcprobe comm` et `/gcprobe burst`.
3. Refaire `/gcprobe comm` **dans un donjon**, en combat et hors combat. Si possible, faire un boss, mourir une fois et monter un niveau.
4. Idéalement, un deuxième membre de la guilde installe aussi la sonde, pour confirmer que les messages GUILD sont bien **reçus**.
5. `/reload`, puis transmettre `WTF/Account/<COMPTE>/SavedVariables/ChronicleProbe.lua`.

---

## 4. Architecture proposée

### 4.1 Décision structurante : deux addons distincts dans le même dépôt

```text
Renacoach/          (addon vocal existant, conservé tel quel en V1)
GuildChronicle/     (nouvel addon : journal, synchro, legacy, UI)
tools/ChronicleProbe/   (diagnostic, non distribué)
```

Pourquoi ne pas fusionner :

- Le cahier des charges exige que Voice et Chronicle fonctionnent l'un sans l'autre. **Deux addons** donnent cette indépendance gratuitement : chacun peut être désactivé dans la liste des addons.
- Renacoach n'est pas réécrit. On le **namespace** et on le **paramètre** (Phase 1-V), puis on ajoute un **pont optionnel** (Phase 3).
- La liaison passe par `## OptionalDeps: GuildChronicle` dans le TOC de Renacoach et par une API publique minimale : `GuildChronicle.Subscribe(type, fn)`. Si GuildChronicle est absent, Renacoach se comporte exactement comme aujourd'hui.

### 4.2 Structure de GuildChronicle

L'arborescence du cahier des charges est simplifiée : on ne crée pas de fichiers pour des modules qui n'existent pas encore.

```text
GuildChronicle/
  GuildChronicle.toc
  Core/
    Init.lua          namespace, ADDON_LOADED, /chronicle
    EventBus.lua      Publish/Subscribe interne (~40 lignes)
    Database.lua      SavedVariables, schéma, migrations, purge
    Ids.lua           identifiants d'auteur et d'événement
    Settings.lua      réglages et confidentialité
  Collectors/         un fichier par famille ; chacun s'active seulement si ses API existent
    Progression.lua   niveau, quêtes, métiers
    Combat.lua        mort, boss
    Exploration.lua   zones
    Social.lua        guilde, groupe, expéditions
  Chronicle/
    Store.lua         insertion, déduplication, requêtes et filtres
    Aggregation.lua   regroupement des événements collectifs, à l'affichage
  Sync/               (Phase 2)
    Transport.lua     envoi par lots, throttling, file d'attente hors instance
    Protocol.lua      messages, validation
  UI/
    MainWindow.lua    onglets
    Timeline.lua      liste avec défilement (ScrollBox Retail)
  Tests/              (hors client, exclu du TOC)
```

`Legacy/`, `Export/`, `Narrator`, `TCG` : pas avant leur phase.

### 4.3 Flux

```text
 Événement WoW ─▶ Collector ─▶ normalise ─▶ EventBus.Publish("CHRONICLE_EVENT", ev)
                                                 │
                     ┌───────────────────────────┼────────────────────────┐
                     ▼                           ▼                        ▼
             Store (dédup + sauvegarde)   UI (rafraîchit si ouverte)   Abonnés externes
                     │                                                (Renacoach, Legacy)
                     ▼
              Sync (si visibilité = GUILD) ─▶ file d'attente ─▶ envoi hors instance
```

Les événements reçus par la synchro passent par le même `Store` (dédup), puis sont publiés avec `origin = "remote"`. Renacoach ignore les événements distants par défaut, pour ne pas jouer un son quand un membre meurt à l'autre bout du monde.

---

## 5. Modèle de données

### 5.1 Identifiants

- **Auteur (`a`)** : GUID du joueur (`Player-<serverId>-<hex>`), stable et unique par personnage. Le nom et le royaume sont gardés à part pour l'affichage. **[V9]**
- **Guilde (`g`)** : `NomDeGuilde-Royaume`, faute d'un identifiant de guilde stable connu côté addon. Un renommage de guilde crée une nouvelle « histoire » ; c'est acceptable.
- **Événement** : `id = a .. ":" .. s`, où `s` est un **numéro de séquence par auteur**, croissant et jamais réutilisé. L'unicité est garantie sans horloge ni hasard, la dédup est triviale, et la synchro devient un simple « il me manque les numéros 41 à 57 de tel auteur ».
- Seuls les événements **partagés** consomment un numéro de la séquence publique. Un événement privé reçoit un identifiant local `a:p<n>`. Sinon, les trous de séquence correspondant aux événements privés seraient éternellement réclamés par les autres, et leur existence même fuiterait.

### 5.2 Structure Lua (stockage compact)

```lua
-- un événement
{
  v  = 1,                    -- version du schéma de l'événement
  id = "Player-1234-0ABC:42",
  a  = "Player-1234-0ABC",   -- auteur
  s  = 42,                   -- séquence (nil si privé)
  t  = 1795000000,           -- GetServerTime(), horloge serveur, commune à tous
  k  = "LEVEL_UP",           -- type
  z  = 1581,                 -- uiMapID (nom résolu à l'affichage, donc indépendant de la langue)
  vis = "G",                 -- "P" privé, "G" guilde
  src = "A",                 -- "A" automatique, "M" manuel
  occ = "ENC:1234:...",      -- clé d'occurrence pour l'agrégation (facultative)
  p  = { lvl = 20 },         -- payload propre au type
  pt = { "Player-...", ... },-- participants observés par l'auteur (facultatif)
}
```

- Les **types** sont déclarés dans une table de registre, avec pour chacun : version du payload, validateur, rendu texte et catégorie de confidentialité. Ajouter un type = ajouter une entrée.
- Les types inconnus reçus d'un client plus récent sont **conservés tels quels mais pas affichés** : on peut les retransmettre et les afficher après une mise à jour.

### 5.3 SavedVariables

```lua
GuildChronicleDB = {               -- au niveau du compte
  schema = 1,                      -- version globale, déclenche les migrations
  guilds = {
    ["MaGuilde-Royaume"] = {
      events  = { [id] = ev, ... },
      authors = { [guid] = { name=, class=, maxSeq=, lastSeen= } },
      tombstones = { [id] = t },
    },
  },
  private = { [guid] = { events = {...}, nextPrivate = n } },  -- par personnage
  seq = { [guid] = n },            -- prochaine séquence publique par personnage
}
GuildChronicleCharDB = { settings = {...} }   -- par personnage
```

- **Limites** : le plafond est configurable (par défaut 5 000 événements reçus par guilde). On purge d'abord les événements **reçus**, anciens et peu importants (quêtes). On ne purge jamais ses propres jalons (niveaux, boss, expéditions). Le fichier de sauvegarde est relu en entier à chaque chargement : il faut rester sous quelques Mo.

### 5.4 Collecteurs prévus (V1 = colonne « fiabilité attendue » haute)

| Type | Source | Fiabilité attendue sur Forever |
|---|---|---|
| `LEVEL_UP` | `PLAYER_LEVEL_UP` | Haute |
| `DEATH` (zone, niveau, instance, en groupe ou non) | `PLAYER_DEAD` | Haute, **sans cause** |
| `BOSS_KILL` | `ENCOUNTER_END` avec `success == 1` (sinon `BOSS_KILL`) | Haute pour l'ID **[V7 pour le nom]** |
| `EXPEDITION` (instance, durée, membres du groupe, boss, morts) | entrée et sortie d'instance + `GROUP_ROSTER_UPDATE` | Haute, synthétisé à la sortie |
| `ZONE_FIRST_VISIT` | `ZONE_CHANGED_NEW_AREA` + `C_Map`, première visite connue de l'addon | Haute (« première fois depuis l'installation ») |
| `QUEST_DONE` | `QUEST_TURNED_IN` | Haute, **regroupé par jour** dans la timeline pour éviter le bruit |
| `GUILD_JOIN` | `PLAYER_GUILD_UPDATE` + comparaison avec l'état mémorisé | Moyenne |
| `PROFESSION_MILESTONE` (75, 150, 225, 300) | `CHAT_MSG_SKILL` / `SKILL_LINES_CHANGED` + API de compétences | **[V7]** |
| `RARE_ITEM` (épique et plus) | `CHAT_MSG_LOOT` | Hors instance seulement, probablement **[V7]** |
| `ACHIEVEMENT` | `ACHIEVEMENT_EARNED` | **[V7]** : existence inconnue sur Forever |
| Monture, kill de rare | — | Reporté : pas de source fiable sans journal de combat |

---

## 6. Événements collectifs

Principe : **on stocke des faits individuels, on agrège à l'affichage.** Chaque participant équipé émet son propre événement. Aucune fusion n'est écrite en base, donc aucune fusion erronée n'est irréversible et aucun participant n'est inventé.

- **Clé d'occurrence (`occ`)**, calculée de façon déterministe par chaque client :
  - `BOSS_KILL` : `encounterID` + identifiant d'instance + date. La clé ne contient pas l'ensemble du groupe, car chaque client peut avoir une vue du roster légèrement différente.
  - `EXPEDITION` : `instanceID` + **chef du groupe à l'entrée** + date.
- Deux événements de même clé sont regroupés si leurs horodatages sont à moins de 15 minutes (fenêtre configurable). Deux clears du même donjon le même soir par des groupes différents restent donc séparés, car le chef diffère.
- **Participants affichés** : ceux qui ont un événement dans le groupe (« équipés de l'addon ») **et** ceux qu'un auteur a observés dans son roster. L'interface distingue « a confirmé » et « était présent selon X ». Rien n'est déduit au-delà.
- Les statistiques de relations (expéditions communes, boss ensemble) se calculent à partir de ces groupes, à la volée ou mises en cache.

---

## 7. Protocole de synchronisation

### 7.1 Choix : journaux par auteur en ajout seul + anti-entropie par vecteur de versions

Chaque auteur possède un journal en ajout seul (séquence 1, 2, 3…). L'état d'un client se résume donc à un **vecteur** `{ auteur → plus grande séquence contiguë possédée }`. C'est le schéma classique d'anti-entropie (type Dynamo/Bayou), réduit au minimum :

- **Pas de conflit possible** : un événement n'a qu'un auteur et n'est jamais modifié. Les corrections sont de nouveaux événements, par exemple `EDIT` ou `TOMBSTONE` référençant l'id d'origine.
- **Pas de boucle** : un événement déjà connu (même id) est ignoré et **jamais réémis spontanément**. On n'envoie que ce qui est explicitement demandé.
- **Relais naturel** : A crée un événement, B le reçoit, A se déconnecte, puis C se connecte plus tard et l'obtient de B.

### 7.2 Messages (préfixe `GChron`, 16 caractères maximum)

| Message | Canal | Contenu |
|---|---|---|
| `H` (hello) | GUILD | version du protocole, version de l'addon, **résumé** du vecteur (nombre d'auteurs + hash) |
| `V` (vecteur) | WHISPER | le vecteur complet, découpé, si le résumé diffère |
| `R` (requête) | WHISPER | `auteur, de, à` (plages manquantes, 50 événements maximum par requête) |
| `E` (événements) | WHISPER | événements sérialisés, compressés, découpés |
| `N` (nouveau) | GUILD | annonce légère « auteur X est à la séquence n », sans contenu |

Déroulé à la connexion : attendre environ 30 s (laisser le jeu se stabiliser) puis envoyer `H`. Chaque client qui constate un écart répond `V` **après un délai aléatoire de 0 à 10 s, et seulement si personne d'autre ne l'a fait**, ce qui évite qu'une guilde de 40 personnes réponde en même temps. Le client choisit ensuite **un** pair par auteur et demande les plages manquantes.

### 7.3 Contraintes WoW

- **Jamais d'envoi en instance** : `Transport` vérifie `IsInInstance()` (et, si l'API existe, un état de verrouillage du chat **[V4]**) avant chaque envoi, et met en file d'attente sinon. Pas d'envoi en combat non plus, par prudence et par politesse pour les performances.
- **Taille et débit** : messages de 255 octets maximum **[V5]**, découpage et rythme d'envoi. Recommandé : **AceComm-3.0 + ChatThrottleLib** pour le découpage et le throttling, **LibSerialize + LibDeflate** pour la sérialisation et la compression. Ce sont des bibliothèques Lua pures, intégrées dans l'addon, utilisées par des milliers d'addons. **[À VÉRIFIER : qu'elles se chargent sur Forever]**
- **Reprise après interruption** : la synchro est idempotente. On ne conserve que les événements complets et validés, et on relance une requête pour ce qui manque encore. Un message tronqué est jeté sans risque.
- **Versions** : le message `H` porte la version du protocole. Une version majeure différente fait **ignorer** le pair (affiché dans l'interface comme « version incompatible »). Une version mineure plus récente reste compatible (types inconnus conservés, voir §5.2).
- **Validation** : schéma vérifié (types Lua, longueurs, type d'événement connu ou conservé brut, horodatage plausible), taille plafonnée, expéditeur présent dans le roster de la guilde.
- **Authenticité** : il n'existe pas de signature cryptographique praticable. On marque l'événement « vérifié » s'il est reçu **directement de son auteur**, et « relayé » sinon. Un membre qui modifierait son addon pourrait forger des événements relayés. C'est acceptable pour un usage entre amis ; c'est **documenté, pas résolu**.

### 7.4 Confidentialité

- Le partage est **désactivé par défaut**. À la première ouverture, une fenêtre propose de l'activer, catégorie par catégorie : progression, morts, boss, exploration, social, butin.
- Chaque catégorie peut être réglée sur **Désactivé** (non enregistré), **Privé** (local) ou **Guilde** (partagé).
- **Passer de privé à guilde** : l'événement reçoit un numéro de séquence publique, puis est partagé.
- **Passer de guilde à privé ou supprimer** : on émet un `TOMBSTONE` signé par l'auteur. Les clients honnêtes masquent et purgent l'événement. **Aucune garantie d'effacement** des copies existantes, et l'interface doit le dire clairement.
- **Départ de la guilde** : les événements reçus restent dans l'histoire de la guilde chez les autres. L'auteur peut publier des tombstones avant de partir. Ses nouveaux événements ne sont plus reçus, puisque l'expéditeur n'est plus dans le roster.

---

## 8. Événements manuels

Ils utilisent le même modèle, avec `src = "M"` et le type `ANECDOTE` (payload : titre, description, catégorie, date libre, participants, zone). L'auteur est l'unique propriétaire. Une modification est un nouvel événement `EDIT` qui référence l'original et dont l'auteur est vérifié. L'interface affiche « modifié » et l'historique. Personne ne peut modifier le contenu d'un autre. Ce module viendra en Phase 4.

---

## 9. Évolution du module vocal

### Phase 1-V : préserver et rendre réglable, sans changer le comportement par défaut

Modifications minimales de `Renacoach.lua` :

1. Mettre toutes les fonctions en `local` (supprimer les globales).
2. Mettre à jour le TOC (`16001`, ou multi-interface) et ajouter `SavedVariables: RenacoachDB`.
3. Ajouter un repli si `GetSpecialization` est absente ou renvoie `nil`, par exemple `UnitGroupRolesAssigned("player")`, ou à défaut le générique seul. C'est le minimum pour que les répliques en combat continuent de jouer sur Forever **[V3]**.
4. Corriger la table du chasseur. C'est un correctif : à valider par l'utilisateur.
5. Sécuriser le ducking : mémoriser le volume d'origine dans `RenacoachDB` et le restaurer au chargement suivant s'il est resté abaissé après un crash.
6. Ajouter `/renacoach` : activer ou désactiver, probabilité, période, canal, ducking oui ou non, familles activables une à une.

Les **valeurs par défaut restent celles d'aujourd'hui.**

### Phase 3 : déclencheurs historiques

Dans un fichier séparé `Renacoach/Bridge.lua`, actif uniquement si GuildChronicle est chargé :

- On ne réutilise que les **familles existantes**, sans nouveau son. Exemples de correspondances, **à valider une par une par l'utilisateur** :
  - 3e mort ou plus dans la même expédition → famille `death`, en privilégiant `renatus_honte` et `pauvre_merde`.
  - Niveau palier (10, 20, …) → `cest_bien` ou `tu_peux_le_faire`.
  - Boss vaincu après y être mort → `rien_arrete`.
- Ordre de priorité : déclencheur historique > mort > début ou fin de combat > répliques en combat.
- Cooldown global (par défaut 4 s) et cooldown par famille.
- Les déclencheurs historiques **ne concernent que le joueur local** : en V1, rien n'est déclenché par les événements des autres.

---

## 10. Plan de développement

| Étape | Contenu | Prérequis | Livrable utilisable |
|---|---|---|---|
| **0.1** | Lancer la sonde en jeu, me transmettre `ChronicleProbe.lua` | — | Matrice d'API confirmée (§3) |
| **0.2** | `git init` du dépôt et réorganisation `Renacoach/`, `GuildChronicle/`, `tools/` | — | — |
| **1-V** | Renacoach : namespace, TOC, repli de spé, ducking sûr, réglages (§9) | 0.1 | Renacoach fonctionnel et vérifié sur Forever |
| **1a** | Core : EventBus, Database (schéma et migrations), Ids, Settings, `/chronicle` | 0.1 | Addon chargeable, à vide |
| **1b** | Collecteurs : niveau, mort, boss, expédition, zones, quêtes | 1a | Journal qui se remplit |
| **1c** | Interface : fenêtre, timeline personnelle, filtres simples | 1b | **V1 jouable (journal personnel)** |
| **1d** | Tests hors client (§11) | 1a | CI locale |
| **2a** | Transport : file d'attente, blocage en instance et en combat, bibliothèques | 1a | — |
| **2b** | Protocole H/V/R/E/N, validation, tombstones, confidentialité | 2a | **Journal de guilde synchronisé** |
| **2c** | Onglet Guilde, filtres (joueur, type, période, zone), agrégation à l'affichage | 2b | — |
| 3 | Pont vocal historique | 1-V, 1b | — |
| 4 | Anecdotes manuelles, profils, Legacy, titres | 2 | — |
| 5 | Export JSON et application compagnon Python et LLM (lecture des SavedVariables hors jeu, réimport des chroniques via un fichier `.lua` à copier pendant que le jeu est fermé) | 4 | — |
| 6 | TCG | — | — |

---

## 11. Tests

**Hors client** (Lua 5.1 ou LuaJIT avec busted, et un module `Tests/wow_stub.lua` qui simule `CreateFrame`, `GetServerTime`, `C_Timer` et l'envoi de messages vers un « réseau » en mémoire de N clients) :

- Un passage de niveau produit un seul événement, y compris si l'événement WoW est reçu deux fois.
- Sauvegarde puis rechargement : identique ; une migration de schéma v1 → v2 fonctionne.
- Reconnexion : pas de doublon, la séquence reprend correctement.
- Un événement privé n'est jamais transmis, ni sa séquence.
- 3 à 5 clients simulés convergent, y compris avec des déconnexions et des messages perdus ou tronqués en cours de route.
- Une version de protocole incompatible est ignorée proprement ; un type inconnu est conservé.
- Les messages malformés (types faux, chaînes géantes, séquences négatives) sont rejetés sans erreur Lua.
- Un tombstone masque l'événement.
- Agrégation : même boss, deux groupes différents le même soir → deux occurrences.
- Renacoach : la sélection des familles selon le rôle, les cooldowns et les priorités (logique extraite en fonctions pures).

**Uniquement dans le client** : chargement sur Forever, relecture des SavedVariables, réception GUILD réelle entre deux comptes, blocage effectif en instance, lecture audio et ducking, absence de baisse d'images par seconde en raid (`/run` avec profilage CPU des addons), rendu de l'interface.

---

## 12. Risques

| Risque | Gravité | Parade |
|---|---|---|
| Restrictions Forever plus strictes que prévu (par exemple communication bloquée aussi hors instance en combat) | Haute | Sonde (V4) ; envoi uniquement hors combat et hors instance |
| SavedVariables non relues (bug de bêta) | Haute | V2 avant toute chose |
| Renacoach sans répliques en combat sur Forever (spécialisations) | Moyenne | Repli 1-V |
| API Forever qui évolue (jeu tout récent) | Moyenne | Collecteurs qui testent l'existence des API ; aucun code en dur sur le type de jeu |
| Bibliothèques Ace ou Lib non chargées sur Forever | Moyenne | Vérifier ; à défaut, transport maison (≈ 200 lignes) |
| Taille des SavedVariables sur la durée | Moyenne | Plafonds et purge des événements reçus |
| Forge d'événements par un membre | Faible (entre amis) | « Vérifié » ou « relayé », documenté |
| Volume SFX resté bas après un crash | Faible mais irritant | Restauration au chargement (1-V) |

---

## 13. Décisions à prendre

1. **Renacoach tourne-t-il aujourd'hui sur Forever, sur Retail, ou sur les deux ?** Cela détermine s'il faut un TOC multi-interface.
2. **Deux addons séparés** (recommandé) ou un seul addon fusionné ?
3. **Bibliothèques intégrées** (AceComm, ChatThrottleLib, LibSerialize, LibDeflate) acceptées ?
4. **Partage désactivé par défaut** avec activation catégorie par catégorie : d'accord ?
5. **Correction de la table du chasseur** : à corriger, ou à garder telle quelle (comportement actuel) ?
6. **Correspondances vocales historiques** (§9) : liste à valider le moment venu.
7. Identité de guilde = `Nom-Royaume` : acceptable ?

---

### Sources (sites non officiels, à recouper avec la sonde)

- https://wowforevertierlist.com/addons/restrictions
- https://conquestcapped.com/guides/wow-forever/wow-forever-addons/
- https://foreverchanges.pro/addons
- https://warcraft.wiki.gg/wiki/Patch_12.0.0/Planned_API_changes
