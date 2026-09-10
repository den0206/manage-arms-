#!/usr/bin/env bash
#
# release-changelog.sh の自己テスト。依存ゼロ。`scripts/test-release-changelog.sh` で実行する。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUT="$HERE/release-changelog.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fails=0
check() { # check <説明> <期待> <実際>
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else
    echo "  FAIL $1"; echo "    expected: $2"; echo "    actual:   $3"; fails=$((fails + 1))
  fi
}
contains() { # contains <説明> <文字列> <部分列>
  case "$2" in *"$3"*) echo "  ok   $1" ;; *) echo "  FAIL $1 ('$3' が無い)"; fails=$((fails + 1)) ;; esac
}

fixture() {
  cat > "$TMP/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Added

- A thing

## [0.0.1] — 2026-07-26

### Added

- The first thing

[Unreleased]: https://example.test/o/r/compare/Ver_0.0.1...HEAD
[0.0.1]: https://example.test/o/r/releases/tag/Ver_0.0.1
EOF
}
run() { CHANGELOG_FILE="$TMP/CHANGELOG.md" "$CUT" "$@" 2>&1; }

echo "cut"
fixture
out="$(run 0.0.2 2026-08-23)"; rc=$?
check "終了コード 0" 0 "$rc"
body="$(cat "$TMP/CHANGELOG.md")"
contains "版見出しができる"       "$body" "## [0.0.2] — 2026-08-23"
contains "本文が移る"             "$body" "- A thing"
contains "[Unreleased] は残る"    "$body" "## [Unreleased]"
contains "Unreleased リンク更新"  "$body" "[Unreleased]: https://example.test/o/r/compare/Ver_0.0.2...HEAD"
contains "版リンク追加"           "$body" "[0.0.2]: https://example.test/o/r/compare/Ver_0.0.1...Ver_0.0.2"
check "[Unreleased] が空になる" 0 "$(awk '/^## \[Unreleased\]/{f=1;next} /^## /{f=0} f && /[^ \t]/' "$TMP/CHANGELOG.md" | wc -l | tr -d ' ')"

echo "冪等（+N 再ビルド）"
out="$(run 0.0.2 2026-08-24)"
contains "2 回目は no-op" "$out" "既に切り出し済み"
check "見出しは 1 つだけ" 1 "$(grep -c '^## \[0\.0\.2\]' "$TMP/CHANGELOG.md")"

echo "[Unreleased] が空"
out="$(run 0.0.3 2026-08-23)"
contains "空なら no-op" "$out" "項目が無い"
check "空見出しを作らない" 0 "$(grep -c '^## \[0\.0\.3\]' "$TMP/CHANGELOG.md")"

echo "--section"
check "節を取り出す" "### Added

- A thing" "$(run --section 0.0.2)"
run --section 9.9.9 >/dev/null 2>&1
check "存在しない版は失敗" 1 "$?"

echo "prerelease"
fixture
out="$(run 0.1.0-alpha.1 2026-09-10)"; rc=$?
check "SemVer prereleaseを切り出せる" 0 "$rc"
contains "prerelease見出し" "$(cat "$TMP/CHANGELOG.md")" "## [0.1.0-alpha.1] — 2026-09-10"

echo "--check"
fixture
out="$(run --check)"; check "正常な CHANGELOG は通る" 0 "$?"
printf -- '- \346\227\245\346\234\254\350\252\236\n' >> "$TMP/CHANGELOG.md"
run --check >/dev/null 2>&1; check "日本語混入を落とす" 1 "$?"
fixture
printf -- '### Notes\n' >> "$TMP/CHANGELOG.md"
run --check >/dev/null 2>&1; check "未知の見出しを落とす" 1 "$?"

echo
if [[ $fails -eq 0 ]]; then echo "release-changelog: 全テスト通過"; else echo "release-changelog: $fails 件失敗"; fi
exit $((fails > 0))
