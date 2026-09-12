#!/bin/bash
# ブラウザ拡張の zip を組み立てる。Chrome Web Store と Edge Add-ons へ同じものを出す。
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="vsix/agent-tool-browser.zip"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

npx tsc -p browser/tsconfig.json

mkdir -p "$STAGE/browser" vsix
cp browser/manifest.json "$STAGE/"
cp -R browser/_locales "$STAGE/_locales"
cp browser/tab.html browser/tab.css "$STAGE/browser/"
cp -R out/web/browser/. "$STAGE/browser/"
cp -R out/web/core "$STAGE/core"

rm -f "$OUT"
(cd "$STAGE" && zip -qr "$OLDPWD/$OUT" .)
echo "$OUT $(wc -c < "$OUT" | tr -d ' ') bytes"
unzip -Z1 "$OUT" | sed "s/^/  /"
