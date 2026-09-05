#!/bin/bash
# 設計上の不変条件を静的に検査する。依存ゼロ（grep / plutil / python3）。
#
#   ./Scripts/check-invariants.sh
#
# CI（.github/workflows/ci.yml）が呼ぶのと同じもの。**CI に別のロジックを持たせない** —
# 片方だけ直すと「手元では通るのに CI で落ちる／その逆」が起きる。
#
# ここに載せるのは「破れると実ユーザーのデータが壊れる」ものだけ。
# 網羅性より、赤くなったときに必ず本物のバグである状態を優先する。
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "::error::$1"; shift; printf '%s\n' "$@"; status=1; }

# --- 1. ファイル書き込みの限定（DESIGN.md 3.1 / 9 章）--------------------------
# 設定ファイルの書き戻しは 3 か所だけ。ここが増えると、CLI に委譲するという
# 中核の設計判断（3.1）が崩れ、実行中の Claude と競合してユーザーの全状態を壊しうる。
#   PermissionWriter … permissions キーだけの書き換え（9 章のホワイトリストの唯一の例外）
#   Registry         … アプリ自身の registry.json
#   MCPScanner       … ~/.cursor/mcp.json（CLI が無いため直接編集する。3.1）
LEAKS=$(grep -rnE '\.write\(to:|write\(toFile:|createFile\(' Sources/ --include='*.swift' \
        | grep -vE '/(PermissionWriter|Registry|MCPScanner)\.swift:' \
        | grep -vE ':[0-9]+:[[:space:]]*//')
if [ -n "$LEAKS" ]; then
    fail "ファイル書き込みが PermissionWriter / Registry / MCPScanner の外に漏れています（DESIGN.md 3.1 / 9 章）" "$LEAKS"
else
    echo "✓ ファイル書き込みは 3 か所に限定されています"
fi

# --- 2. 削除・移動の限定（DESIGN.md 9 章）------------------------------------
# 削除・移動・symlink 作成は WriteGuard.assertMutable を通す経路だけに置く。
# 新しいファイルで無防備に removeItem を書くと、ホワイトリストを迂回して
# ユーザーの ~/.claude や ~/.agents を消しうる。
#   SkillManager / SubagentScanner / Updater … WriteGuard.assertMutable を必ず呼ぶ
#   Fetcher / Installer                      … 一時ディレクトリのみを触る（ユーザーデータ外）
#   InstallLocationGuard                     … /Applications へ自分自身をコピーする際の
#                                              失敗ロールバック。消すのは直前に自分が作った
#                                              バンドルだけで、ユーザーの資源ではない
LEAKS=$(grep -rnE 'removeItem|moveItem|createSymbolicLink|trashItem' Sources/ --include='*.swift' \
        | grep -vE '/(SkillManager|SubagentScanner|Updater|Fetcher|Installer|InstallLocationGuard)\.swift:' \
        | grep -vE ':[0-9]+:[[:space:]]*//')
if [ -n "$LEAKS" ]; then
    fail "削除・移動が WriteGuard を通る経路の外に漏れています（DESIGN.md 9 章）" "$LEAKS"
else
    echo "✓ 削除・移動は WriteGuard を通る経路に限定されています"
fi

# WriteGuard を通す 3 ファイルが、実際に assertMutable を呼んでいることも確かめる
# （上の許可リストに載せただけで中身が空、という抜けを塞ぐ）。
for f in SkillManager SubagentScanner Updater; do
    if ! grep -q 'WriteGuard.assertMutable' "Sources/ManageArmsCore/$f.swift"; then
        fail "$f.swift が WriteGuard.assertMutable を呼んでいません（削除・移動の許可リストに載っているのに無防備）"
    fi
done

# --- 3. ローカライズ（ja / en のキー集合が一致すること）------------------------
plutil -lint Localization/*.lproj/*.strings >/dev/null || {
    plutil -lint Localization/*.lproj/*.strings
    fail ".strings が壊れています"
}
DIFF=$(python3 - <<'PY'
import json, subprocess
def keys(lang):
    out = subprocess.run(["plutil", "-convert", "json", "-o", "-",
                          f"Localization/{lang}.lproj/Localizable.strings"],
                         capture_output=True, text=True)
    return set(json.loads(out.stdout))
ja, en = keys("ja"), keys("en")
for k in sorted(ja - en): print(f"  en.lproj に無い: {k}")
for k in sorted(en - ja): print(f"  ja.lproj に無い: {k}")
PY
)
if [ -n "$DIFF" ]; then
    fail "ja / en のキー集合が一致しません（片方に足し忘れると、その文言だけ日本語のまま英語 UI に出ます）" "$DIFF"
else
    echo "✓ ローカライズのキー集合は ja / en で一致しています（$(grep -c '^"' Localization/ja.lproj/Localizable.strings) キー）"
fi

exit $status
