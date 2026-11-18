#!/usr/bin/env bash
# Deploys the addon into the WoW Forever client (from WSL).
#   tools/deploy.sh            copies Renatus (exact mirror) + installs Renatus_Press if missing
#   WOW=/mnt/c/.../_forever_ tools/deploy.sh   other installation
# Press.lua is never overwritten: the companion writes it.
# After deploying: /reload in game (restart the game only the first time).
set -euo pipefail

WOW="${WOW:-/mnt/c/MyGames/World of Warcraft/_forever_}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
ADDONS="$WOW/Interface/AddOns"

[ -d "$ADDONS" ] || { echo "Dossier introuvable : $ADDONS" >&2; exit 1; }

# Former addon name (before v0.4.1): two copies loaded at once would step on each other.
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
