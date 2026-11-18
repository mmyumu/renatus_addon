#!/usr/bin/env bash
# Deploie l'addon dans le client WoW Forever (depuis WSL).
#   tools/deploy.sh            copie GuildChronicle (miroir exact) + installe GuildChronicle_Press s'il manque
#   WOW=/mnt/c/.../_forever_ tools/deploy.sh   autre installation
# Press.lua n'est jamais ecrase : c'est le compagnon qui l'ecrit.
# Apres un deploiement : /reload en jeu (redemarrer le jeu seulement la premiere fois).
set -euo pipefail

WOW="${WOW:-/mnt/c/MyGames/World of Warcraft/_forever_}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADDONS="$WOW/Interface/AddOns"

[ -d "$ADDONS" ] || { echo "Dossier introuvable : $ADDONS" >&2; exit 1; }

rsync -rt --delete --exclude '.*' "$REPO/GuildChronicle/" "$ADDONS/GuildChronicle/"
echo "GuildChronicle -> $ADDONS/GuildChronicle"

PRESS="$ADDONS/GuildChronicle_Press"
mkdir -p "$PRESS"
cp "$REPO/GuildChronicle_Press/GuildChronicle_Press.toc" "$PRESS/"
if [ ! -f "$PRESS/Press.lua" ]; then
    cp "$REPO/GuildChronicle_Press/Press.lua" "$PRESS/"
    echo "GuildChronicle_Press installe (nouvel addon : redemarre le jeu une fois)"
fi

version=$(grep -m1 '^## Version:' "$REPO/GuildChronicle/GuildChronicle.toc" | cut -d' ' -f3)
echo "Version $version deployee. En jeu : /reload"
