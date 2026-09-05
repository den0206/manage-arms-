#!/usr/bin/env bash
#
# release-changelog.sh — CHANGELOG.md の `[Unreleased]` をバージョン見出しへ切り出す
#
# 依存ゼロ・通信ゼロ（awk / perl / POSIX テキストツールのみ）。
#
#   Scripts/release-changelog.sh 0.0.6 [YYYY-MM-DD]   切り出して書き戻す（省略時は UTC の今日）
#   Scripts/release-changelog.sh --section 0.0.6      その版の節だけ標準出力へ（Release 本文用）
#   Scripts/release-changelog.sh --check              英語のみ・見出し語彙・[Unreleased] の検査
#
# リリース（`release/Ver_X.Y.Z` の push）で release.yml が呼ぶ。**Release を作る前に**走らせること。
# 何度呼んでも安全（その版の見出しが既にあれば何もしない）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${CHANGELOG_FILE:-$REPO_ROOT/CHANGELOG.md}"

die() { echo "error: $*" >&2; exit 1; }

# --- モード -----------------------------------------------------------------
MODE=cut
case "${1:-}" in
  --section) MODE=section; shift ;;
  --check)   MODE=check;   shift ;;
  -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[[ -f "$FILE" ]] || die "CHANGELOG が見つかりません: $FILE"

# --- --check: 公開物なので英語のみ・Keep a Changelog の見出し語彙に揃える ----
if [[ "$MODE" == check ]]; then
  status=0
  grep -qx '## \[Unreleased\]' "$FILE" || { echo "'## [Unreleased]' がありません" >&2; status=1; }

  # 日本語混入（コミットは日本語のまま、CHANGELOG は英語 — docs/06 §7）
  if jp="$(perl -CSD -ne 'print "$.: $_" if /\p{Han}|\p{Hiragana}|\p{Katakana}/' "$FILE")" && [[ -n "$jp" ]]; then
    echo "日本語が混ざっています:" >&2; echo "$jp" >&2; status=1
  fi

  # 節見出しは Keep a Changelog の 6 種のみ
  if bad="$(grep -nE '^### ' "$FILE" | grep -vE '^[0-9]+:### (Added|Changed|Deprecated|Removed|Fixed|Security)$')" && [[ -n "$bad" ]]; then
    echo "未知の節見出しです（Added/Changed/Deprecated/Removed/Fixed/Security のみ）:" >&2
    echo "$bad" >&2; status=1
  fi

  [[ $status -eq 0 ]] && echo "release-changelog: check OK"
  exit $status
fi

VERSION="${1:-}"
[[ -n "$VERSION" ]] || die "バージョンを X.Y.Z 形式で指定してください"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "バージョンは X.Y.Z 形式です（受領: $VERSION）"

# --- --section: 指定版の本文だけ取り出す（gh release --notes-file 用）-------
if [[ "$MODE" == section ]]; then
  body="$(awk -v ver="$VERSION" '
    $0 ~ "^##[ \t]+\\[?" ver "\\]?([ \t]|$)" { inside = 1; next }
    inside && (/^## / || /^\[[^]]+\]:[ \t]+[^ \t]/) { inside = 0 }
    inside                                       { n++; body[n] = $0; if ($0 ~ /[^ \t]/) { if (!first) first = n; last = n } }
    END { for (i = first; i <= last; i++) print body[i] }
  ' "$FILE")"
  [[ -n "$body" ]] || die "$VERSION の節が空か存在しません"
  printf '%s\n' "$body"
  exit 0
fi

# --- cut: [Unreleased] を `## [X.Y.Z] — YYYY-MM-DD` へ移す ------------------
DATE="${2:-$(date -u +%F)}"
[[ "$DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "日付は YYYY-MM-DD 形式です（受領: $DATE）"

OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

set +e
awk -v ver="$VERSION" -v date="$DATE" '
  function versionOf(s,   t) {
    if (s !~ /^##[ \t]+\[?[0-9]+\.[0-9]+\.[0-9]+/) return ""
    t = s; sub(/^##[ \t]+\[?/, "", t)
    return (match(t, /^[0-9]+\.[0-9]+\.[0-9]+/)) ? substr(t, 1, RLENGTH) : ""
  }
  { line[NR] = $0 }
  END {
    head = 0
    for (i = 1; i <= NR; i++) {
      if (line[i] == "## [Unreleased]") head = i
      if (versionOf(line[i]) == ver) { print "already" > "/dev/stderr"; exit 3 }
    }
    if (!head) { print "no-unreleased" > "/dev/stderr"; exit 4 }

    end = NR + 1; prev = ""
    for (i = head + 1; i <= NR; i++) {
      if (line[i] ~ /^## /) { end = i; prev = versionOf(line[i]); break }
      if (line[i] ~ /^\[[^]]+\]:[ \t]+[^ \t]/) { end = i; break }
    }

    first = 0; last = 0
    for (i = head + 1; i < end; i++) if (line[i] ~ /[^ \t]/) { if (!first) first = i; last = i }
    if (!first) { print "empty" > "/dev/stderr"; exit 5 }

    for (i = 1; i <= head; i++) print line[i]
    printf "\n## [%s] \342\200\224 %s\n\n", ver, date
    for (i = first; i <= last; i++) print line[i]
    print ""
    for (i = end; i <= NR; i++) {
      # 末尾の比較リンクを更新する（無ければ何もしない）
      if (line[i] ~ /^\[Unreleased\]:[ \t]+[^ \t]+\/compare\/[^ \t]+$/) {
        base = line[i]; sub(/^\[Unreleased\]:[ \t]+/, "", base); sub(/\/compare\/.*$/, "", base)
        printf "[Unreleased]: %s/compare/Ver_%s...HEAD\n", base, ver
        if (prev != "") printf "[%s]: %s/compare/Ver_%s...Ver_%s\n", ver, base, prev, ver
        else            printf "[%s]: %s/releases/tag/Ver_%s\n", ver, base, ver
        continue
      }
      print line[i]
    }
  }
' "$FILE" > "$OUT"
rc=$?
set -e

case $rc in
  0) cp "$OUT" "$FILE"; echo "release-changelog: [Unreleased] を $VERSION — $DATE へ切り出しました" ;;
  3) echo "release-changelog: 変更なし（$VERSION は既に切り出し済み）" ;;
  4) die "'## [Unreleased]' が見つかりません" ;;
  5) echo "release-changelog: 変更なし（[Unreleased] に項目が無い）" ;;
  *) die "awk が失敗しました (rc=$rc)" ;;
esac
