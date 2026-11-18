#!/usr/bin/env bash
# Deploie l'addon dans le client WoW Forever (depuis WSL).
#   tools/deploy.sh            copie Renatus (miroir exact) + installe Renatus_Press s'il manque
#   WOW=/mnt/c/.../_forever_ tools/deploy.sh   autre installation
# Press.lua n'est jamais ecrase : c'est le compagnon qui l'ecrit.
# Apres un deploiement : /reload en jeu (redemarrer le jeu seulement la premiere fois).
set -euo pipefail

WOW="${WOW:-/mnt/c/MyGames/World of Warcraft/_forever_}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADDONS="$WOW/Interface/AddOns"

[ -d "$ADDONS" ] || { echo "Dossier introuvable : $ADDONS" >&2; exit 1; }

# Ancien nom de l'addon (avant v0.4.1) : deux copies chargees en meme temps se marcheraient dessus.
for old in GuildChronicle GuildChronicle_Press; do
    if [ -f "$ADDONS/$old/$old.toc" ]; then rm -rf "${ADDONS:?}/$old"; echo "Ancien dossier $old retire"; fi
done

rsync -rt --delete --exclude '.*' "$REPO/Renatus/" "$ADDONS/Renatus/"
echo "Renatus -> $ADDONS/Renatus"

PRESS="$ADDONS/Renatus_Press"
mkdir -p "$PRESS"
cp "$REPO/Renatus_Press/Renatus_Press.toc" "$PRESS/"
if [ ! -f "$PRESS/Press.lua" ]; then
    cp "$REPO/Renatus_Press/Press.lua" "$PRESS/"
    echo "Renatus_Press installe (nouvel addon : redemarre le jeu une fois)"
fi

version=$(grep -m1 '^## Version:' "$REPO/Renatus/Renatus.toc" | cut -d' ' -f3)
echo "Version $version deployee. En jeu : /reload"
