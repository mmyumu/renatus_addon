# Renatus Launcher

Petite application Windows qui garde l'addon Renatus à jour tout seul.

## Pour un joueur

1. Télécharger **[Renatus-Launcher-setup.exe](https://github.com/mmyumu/renatus_addon/releases/latest/download/Renatus-Launcher-setup.exe)** et le lancer.
   Windows peut afficher « Windows a protégé votre ordinateur » (l'application n'est pas signée) :
   *Informations complémentaires* → *Exécuter quand même*. Pas besoin de droits administrateur.
2. Le launcher cherche le dossier `_forever_` du jeu. S'il ne le trouve pas, clique sur **Changer**
   et montre-lui le dossier « World of Warcraft ».
3. C'est tout. Il démarre avec Windows, reste près de l'horloge, vérifie toutes les 10 minutes et
   installe chaque nouvelle version. Une notification dit quand faire `/reload` en jeu (la toute
   première installation demande de redémarrer le jeu une fois).

Fermer la fenêtre laisse le launcher actif ; clic droit sur l'icône → **Quitter** pour l'arrêter.
Il se met lui-même à jour quand une nouvelle version du launcher sort (toutes les 6 heures).
Deux boutons forcent la vérification tout de suite : **Vérifier l'addon** et **Vérifier le launcher**.

**Désinstaller** : Paramètres Windows → Applications → *Renatus Launcher* → Désinstaller.
L'addon reste dans le jeu (supprimer `Interface\AddOns\Renatus` pour l'enlever aussi).

## Pour publier

- **Addon** : changer la version dans `Renatus/Renatus.toc` (`## Version:`), `Renatus/Core/Init.lua`
  (`ns.version`) et `Renatus_Admin/Renatus_Admin.toc`, commit, push sur `main`. Le workflow `addon-release.yml` lance les tests Lua,
  publie `v<version>` avec `Renatus-<version>.zip` (membres) et `Renatus_Admin-<version>.zip` (officiers) ; le message du commit devient les
  « Nouveautés » affichées par le launcher. Une version avec un tiret (`0.12.0-test.1`) est une
  version de test : seuls les launchers qui ont coché « Recevoir les versions de test » l'installent.
  Supprimer une release sur GitHub fait revenir tout le monde à la précédente.
- **Launcher** : `launcher/scripts/bump.sh 0.2.0`, commit, push. `launcher-release.yml` compile sur
  Windows, signe la mise à jour (secrets `TAURI_SIGNING_PRIVATE_KEY` / `_PASSWORD`, clé dans
  `~/.tauri/renatus-launcher.key`) et publie `launcher-v0.2.0` comme release « latest ».

## Développement

- `launcher/core` : toute la logique (trouver le jeu, choisir la release, installer l'archive,
  réglages), testée sous Linux : `cd launcher && cargo test`.
- `launcher/src-tauri` : la coquille Windows (fenêtre, icône, notifications, boucle de mise à jour).
  Ne compile que sous Windows ; depuis WSL : `launcher/scripts/build-windows.sh`
  (`LAUNCHER_WIN_TOOLS=C:\...` pour un dossier avec `node\` et `toolchain\` portables).
- `launcher/ui` : HTML/CSS/JS sans outil de build.
- L'icône vient de `uv run tools/make_app_icons.py`.

Sécurité : le launcher ne télécharge que depuis ce dépôt, en HTTPS, n'exécute rien de ce qu'il
télécharge et n'écrit que dans `Interface\AddOns\Renatus` (il retire l'ancien `Renatus_Press`). Il n'installe
jamais `Renatus_Admin`, l'addon des officiers, publié à part (`Renatus_Admin-<version>.zip`).
Les mises à jour du launcher lui-même sont vérifiées par signature.
