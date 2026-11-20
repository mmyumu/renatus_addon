#!/usr/bin/env bash
# Builds the Renatus Admin installer from WSL: copies admin/ (and launcher/core, a
# path dependency) to a Windows folder, runs scripts/build-windows.cmd there, and
# copies the installer to admin/artifacts/.
#   ADMIN_WIN_BUILD_DIR=/mnt/c/...      build folder (default %USERPROFILE%\renatus-admin-build)
#   LAUNCHER_WIN_TOOLS=C:\...\folder    folder holding portable node\ and toolchain\ (optional)
set -euo pipefail

admin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo="$(cd "$admin/.." && pwd)"

if ! cmd.exe /c exit >/dev/null 2>&1; then
  echo "Cannot run Windows programs from WSL (interop disabled)." >&2
  exit 1
fi

if [[ -n "${ADMIN_WIN_BUILD_DIR:-}" ]]; then
  build_root="$ADMIN_WIN_BUILD_DIR"
else
  win_profile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  build_root="$(wslpath -u "$win_profile")/renatus-admin-build"
fi
case "$build_root" in
  /mnt/*) ;;
  *) echo "The build directory must be on a Windows drive (/mnt/...): $build_root" >&2; exit 1 ;;
esac

echo "Syncing sources to $build_root"
mkdir -p "$build_root/admin" "$build_root/launcher/core"
rsync -a --delete \
  --exclude /node_modules --exclude /target --exclude /artifacts \
  --exclude /node --exclude /toolchain --exclude /.cargo --exclude /.npm-cache \
  --exclude /src-tauri/gen \
  "$admin/" "$build_root/admin/"
rsync -a --delete "$repo/launcher/core/" "$build_root/launcher/core/"

echo "Building on Windows"
(cd "$build_root/admin" && cmd.exe /c "scripts\\build-windows.cmd ${LAUNCHER_WIN_TOOLS:-}")

setup="$(ls -t "$build_root"/admin/target/release/bundle/nsis/*-setup.exe | head -n 1)"
mkdir -p "$admin/artifacts"
rm -f "$admin"/artifacts/*-setup.exe
cp "$setup" "$admin/artifacts/"
echo "Installer: $admin/artifacts/$(basename "$setup")"
