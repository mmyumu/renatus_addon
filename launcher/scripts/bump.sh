#!/usr/bin/env bash
# Sets the launcher version everywhere it is written: launcher/scripts/bump.sh 0.2.0
# Then commit and push to main: CI builds and publishes launcher-v0.2.0, and
# installed launchers update themselves within a few hours.
set -euo pipefail
version="${1:?usage: $0 X.Y.Z}"
cd "$(dirname "$0")/.."

npm version "$version" --no-git-tag-version --allow-same-version >/dev/null
node -e '
  const fs = require("fs"), p = "src-tauri/tauri.conf.json";
  const conf = JSON.parse(fs.readFileSync(p, "utf8"));
  conf.version = process.argv[1];
  fs.writeFileSync(p, JSON.stringify(conf, null, 2) + "\n");
' "$version"
sed -i "0,/^version = \".*\"/s//version = \"$version\"/" core/Cargo.toml src-tauri/Cargo.toml
cargo update -p renatus-launcher -p renatus-launcher-core --offline >/dev/null 2>&1 || cargo update -p renatus-launcher -p renatus-launcher-core
# The admin app depends on launcher/core: keep its lock file in step.
(cd ../admin && { cargo update -p renatus-launcher-core --offline >/dev/null 2>&1 || cargo update -p renatus-launcher-core; })
echo "Launcher version: $version"
