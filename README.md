# Renatus

L'addon de la guilde Renatus pour World of Warcraft Forever : gazette, album de cartes, journaux, tableau de chasse.

## Installer

### 👉 [Télécharger le launcher (Renatus-Launcher-setup.exe)](https://github.com/mmyumu/renatus_addon/releases/latest/download/Renatus-Launcher-setup.exe)

Le launcher installe l'addon et le garde à jour tout seul. Windows uniquement.

1. Lancez `Renatus-Launcher-setup.exe`. Si Windows affiche « Windows a protégé votre ordinateur »
   (l'application n'est pas signée) : *Informations complémentaires* → *Exécuter quand même*.
   Pas besoin de droits administrateur.
2. S'il ne trouve pas le jeu, cliquez sur **Changer** et choisissez votre dossier « World of Warcraft ».
3. Redémarrez le jeu une fois après la première installation. C'est tout : les mises à jour
   suivantes s'installent toutes seules, une notification vous dit quand faire `/reload`.

Le launcher démarre avec Windows et reste près de l'horloge. Clic droit sur son icône → **Quitter** pour l'arrêter.
Pour le désinstaller : Paramètres Windows → Applications → *Renatus Launcher*.

Plus de détails : [launcher/README.md](launcher/README.md).

## Développement

- `Renatus/` : l'addon des membres. `Renatus_Admin/` : l'addon des officiers.
- `launcher/` : le launcher des membres. `admin/` : l'application Renatus Admin des officiers.
- Architecture : [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
