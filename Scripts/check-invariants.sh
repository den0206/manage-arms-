#!/bin/bash
# Agent Tool Coreの書き込み境界を静的に検査する。
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "::error::$1"; shift; printf '%s\n' "$@"; status=1; }

LEAKS=$(grep -rnE '\.write\(to:|write\(toFile:|createFile\(' Sources/ --include='*.swift' \
        | grep -vE '/(Registry|MCPScanner)\.swift:' \
        | grep -vE ':[0-9]+:[[:space:]]*//')
if [ -n "$LEAKS" ]; then
    fail "ファイル書き込みがRegistry / MCPScannerの外に漏れています" "$LEAKS"
else
    echo "✓ ファイル書き込みは2か所に限定されています"
fi

# Migration は旧ManageArmsの固定パスから、競合が無いglobalStorageUriだけへ移す。
# 既存のユーザーデータを削除・上書きする経路ではないため、移動の許可対象に含める。
LEAKS=$(grep -rnE 'removeItem|moveItem|createSymbolicLink|trashItem' Sources/ --include='*.swift' \
        | grep -vE '/(SkillManager|Updater|Fetcher|Installer|Migration)\.swift:' \
        | grep -vE ':[0-9]+:[[:space:]]*//')
if [ -n "$LEAKS" ]; then
    fail "削除・移動がWriteGuardを通る経路の外に漏れています" "$LEAKS"
else
    echo "✓ 削除・移動はWriteGuardを通る経路に限定されています"
fi

for file in SkillManager Updater; do
    if ! grep -q 'WriteGuard.assertMutable' "Sources/AgentToolCore/$file.swift"; then
        fail "$file.swiftがWriteGuard.assertMutableを呼んでいません"
    fi
done

for file in Installer SkillManager; do
    if ! grep -q 'WriteGuard.assertValidName' "Sources/AgentToolCore/$file.swift"; then
        fail "$file.swiftがWriteGuard.assertValidNameを呼んでいません"
    fi
done
echo "✓ 取得物の名前は作成前に検査されています"

exit $status
