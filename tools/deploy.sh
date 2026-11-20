#!/usr/bin/env bash
# Deploys the addons into the WoW Forever client (from WSL), for an officer.
#   tools/deploy.sh            copies Renatus and Renatus_Admin (exact mirrors, Press.lua kept)
#   WOW=/mnt/c/.../_forever_ tools/deploy.sh   other installation
# Press.lua is never overwritten: the Renatus Admin app writes it.
# After deploying: /reload in game (restart the game the first time an addon appears).
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

# Renatus_Press (data only, before 0.12) is replaced by Renatus_Admin.
if [ -d "$ADDONS/Renatus_Press" ]; then rm -rf "${ADDONS:?}/Renatus_Press"; echo "Ancien dossier Renatus_Press retire"; fi

ADMIN="$ADDONS/Renatus_Admin"
new_admin=0
[ -d "$ADMIN" ] || new_admin=1
rsync -rt --delete --exclude '.*' --exclude 'Press.lua' "$REPO/Renatus_Admin/" "$ADMIN/"
[ -f "$ADMIN/Press.lua" ] || cp "$REPO/Renatus_Admin/Press.lua" "$ADMIN/"
echo "Renatus_Admin -> $ADMIN"
[ "$new_admin" = 1 ] && echo "Renatus_Admin installe (nouvel addon : redemarre le jeu une fois)"

version=$(grep -m1 '^## Version:' "$REPO/Renatus/Renatus.toc" | cut -d' ' -f3)
echo "Version $version deployee. En jeu : /reload"
