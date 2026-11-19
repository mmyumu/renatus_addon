#!/usr/bin/env bash
# Builds the launcher installer from WSL: copies launcher/ to a Windows folder,
# runs scripts/build-windows.cmd there, and copies the installer to launcher/artifacts/.
#   LAUNCHER_WIN_BUILD_DIR=/mnt/c/...   build folder (default %USERPROFILE%\renatus-launcher-build)
#   LAUNCHER_WIN_TOOLS=C:\...\folder    folder holding portable node\ and toolchain\ (optional)
set -euo pipefail

launcher="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! cmd.exe /c exit >/dev/null 2>&1; then
  echo "Cannot run Windows programs from WSL (interop disabled)." >&2
  exit 1
fi

if [[ -n "${LAUNCHER_WIN_BUILD_DIR:-}" ]]; then
  build_dir="$LAUNCHER_WIN_BUILD_DIR"
else
  win_profile="$(cd /mnt/c && cmd.exe /c 'echo %USERPROFILE%' 2>/dev/null | tr -d '\r')"
  build_dir="$(wslpath -u "$win_profile")/renatus-launcher-build"
fi
case "$build_dir" in
  /mnt/*) ;;
  *) echo "The build directory must be on a Windows drive (/mnt/...): $build_dir" >&2; exit 1 ;;
esac

echo "Syncing sources to $build_dir"
mkdir -p "$build_dir"
rsync -a --delete \
  --exclude /node_modules --exclude /target --exclude /artifacts \
  --exclude /node --exclude /toolchain --exclude /.cargo --exclude /.npm-cache \
  --exclude /src-tauri/gen \
  "$launcher/" "$build_dir/"

echo "Building on Windows"
(cd "$build_dir" && cmd.exe /c "scripts\\build-windows.cmd ${LAUNCHER_WIN_TOOLS:-}")

setup="$(ls -t "$build_dir"/target/release/bundle/nsis/*-setup.exe | head -n 1)"
mkdir -p "$launcher/artifacts"
rm -f "$launcher"/artifacts/*-setup.exe
cp "$setup" "$launcher/artifacts/"
echo "Installer: $launcher/artifacts/$(basename "$setup")"
