#!/bin/bash
# Agent Toolの書き込み境界を静的に検査する（設計決定 D-9）。
set -uo pipefail
cd "$(dirname "$0")/.."

status=0
fail() { echo "::error::$1"; shift; printf '%s\n' "$@"; status=1; }

# 実体とリンクはwriteGuard.ts、registry.jsonはregistry.ts、mcp.jsonはmcpScanner.tsだけが書く。
# fetcher.tsはOSの一時領域にだけ書く。`./env`を読み込まないので、ホームやglobalStorageの
# パスを組み立てられない = 利用者のデータには到達できない（下で検査する）。
WRITERS='/(writeGuard|registry|mcpScanner|fetcher)\.ts:'
# 同期APIの名前だけを見る。`link(` のような素の名前は自前の関数と衝突するので、
# promise形式は `node:fs/promises` の読み込み自体を別に禁止して塞ぐ。
# openSyncは読み取り（frontmatterの先頭4 KB）にも使うので、実際に書くwriteSyncの側を見る。
FS_WRITES='\b(writeFileSync|appendFileSync|renameSync|rmSync|rmdirSync|unlinkSync|mkdirSync|symlinkSync|linkSync|cpSync|copyFileSync|truncateSync|utimesSync|chmodSync|writeSync|createWriteStream|mkdtempSync)\('

LEAKS=$(grep -rnE "$FS_WRITES" src/ --include='*.ts' \
        | grep -vE "$WRITERS" \
        | grep -vE ':[0-9]+:[[:space:]]*(//|\*)')
if [ -n "$LEAKS" ]; then
    fail "ファイル書き込みがwriteGuard / registry / mcpScannerの外に漏れています" "$LEAKS"
else
    echo "✓ ファイル書き込みは3経路と一時領域に限定されています"
fi

LEAKS=$(grep -rn 'node:fs/promises' src/ --include='*.ts' | grep -vE "$WRITERS")
if [ -n "$LEAKS" ]; then
    fail "node:fs/promises経由の書き込み経路が増えています" "$LEAKS"
fi

if grep -qE 'from "\./env"' src/fetcher.ts; then
    fail "fetcher.tsが./envを読み込んでいます（一時領域の外へ書ける経路になります）"
elif ! grep -q 'mkdtempSync(join(tmpdir()' src/writeGuard.ts; then
    fail "一時領域がOSの一時ディレクトリから作られていません"
else
    echo "✓ 取得と移行の作業領域はOSの一時領域に限定されています"
fi

for file in skillManager installer updater; do
    grep -q 'assertMutable\|assertValidName' "src/$file.ts" \
        || fail "src/$file.tsがWriteGuardの検査を呼んでいません"
done
echo "✓ 取得物の名前と可変性は作成前に検査されています"

# 走査はホワイトリストだけを見る。ホームやワークスペース全体を再帰走査しない。
LEAKS=$(grep -rnE '\breaddirSync\(' src/ --include='*.ts' \
        | grep -vE '/(source|skillScanner|projectScan|fetcher|updater)\.ts:')
if [ -n "$LEAKS" ]; then
    fail "走査がホワイトリストの外に漏れています" "$LEAKS"
else
    echo "✓ ディレクトリ走査は走査系モジュールに限定されています"
fi

exit $status
