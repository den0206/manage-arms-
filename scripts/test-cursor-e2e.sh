#!/bin/sh
# 配布 VSIX が Cursor に読み込めることを確認する。
# CI では固定した Cursor を必ず起動する。見つからないまま緑にすると、
# このジョブは「VSIX を検証した」ように見えて何も検証していない。
set -eu
cursor=${CURSOR_PATH:-$(command -v cursor 2>/dev/null || true)}
if [ -z "$cursor" ] && [ -x /Applications/Cursor.app/Contents/Resources/app/bin/cursor ]; then
  cursor=/Applications/Cursor.app/Contents/Resources/app/bin/cursor
fi
if [ -z "$cursor" ] || [ ! -x "$cursor" ]; then
  if [ "${CI:-}" = "true" ]; then
    echo "Cursor E2E: CURSOR_PATH が未設定です（CI では固定版の Cursor を必ず起動します）" >&2
    exit 1
  fi
  echo "Cursor E2E: skipped (CURSOR_PATHまたはcursorコマンドが未設定)"
  exit 0
fi
"$cursor" --version
vsix=${1:-vsix/agent-tool.vsix}
test -f "$vsix"
temp_dir=$(mktemp -d)
trap 'rm -rf "$temp_dir"' EXIT
extensions_dir="$temp_dir/extensions"
user_data_dir="$temp_dir/user-data"
"$cursor" --install-extension "$vsix" --extensions-dir "$extensions_dir" --user-data-dir "$user_data_dir" --force
"$cursor" --list-extensions --extensions-dir "$extensions_dir" --user-data-dir "$user_data_dir" | grep -qx 'yuuki-sakai.agent-tool'
echo "✓ Cursorが隔離ディレクトリ内のAgent Tool VSIXを認識"
