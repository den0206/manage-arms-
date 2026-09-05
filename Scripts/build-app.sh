#!/bin/bash
# ManageArms.app を組み立てて署名する。.xcodeproj は使わない（SwiftPM のみ）。
#
#   ./Scripts/build-app.sh                            # リリース + ユニバーサル + アドホック署名
#   CONFIG=debug UNIVERSAL=0 ./Scripts/build-app.sh   # デバッグ + ネイティブ arch（開発用・高速）
#   SIGN_IDENTITY="Developer ID Application: 名前 (TEAMID)" ./Scripts/build-app.sh
#
# CI と同じものがローカルでも動く（CI 専用の隠れロジックを持たせない）。
# 配布時は Developer ID を指定し、別途 notarize すること。
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ManageArms"                       # Package.swift の executableTarget 名
BUNDLE_ID="com.yuukisakai.manage-arms"
# デバッグ版の bundle id。**末尾の `.debug` は必須**。Environment.live が
# hasSuffix(".debug") で Application Support の保存先を分けている。
DEBUG_BUNDLE_ID="${DEBUG_BUNDLE_ID:-${BUNDLE_ID}.debug}"
CONFIG="${CONFIG:-release}"
# 既定はアドホック（-）。このアプリは TCC 権限を持たないので、ローカル開発で
# 署名 ID を固定する必要がない（署名が変わっても失うものが無い）。
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# リリースビルドはアドホック署名を許さない。アドホックの .app から DMG を作ると
# 「開発元を確認できません」と出る配布物ができ、公証も通らない（公証は Developer ID が前提）。
# 配布物を作る経路の入口で止めるのが一番安い。動作確認だけなら明示的に外せる。
if [ "${CONFIG}" = "release" ] && [ "${SIGN_IDENTITY}" = "-" ] && [ "${ALLOW_ADHOC:-0}" != "1" ]; then
    echo "error: リリースビルドには Developer ID 署名が必要です。" >&2
    echo "  SIGN_IDENTITY=\"Developer ID Application: 名前 (TEAMID)\" ./Scripts/build-app.sh" >&2
    echo "  使える ID の一覧: security find-identity -v -p codesigning" >&2
    echo "  セットアップ手順: docs/signing.md" >&2
    echo "  署名せず動作確認だけしたい場合は ALLOW_ADHOC=1 を付けてください（配布不可）。" >&2
    exit 1
fi

# UNIVERSAL=1（既定）: arm64 + x86_64。0 で実行機のネイティブ arch のみ（高速）。
if [ "${UNIVERSAL:-1}" = "1" ]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
else
    ARCH_FLAGS=()
fi

BUILD_DIR=".build/${CONFIG}"
# .app の**ファイル名**。debug は「ManageArms Debug.app」にする。
# Finder・Dock・強制終了ダイアログはバンドルのファイル名を見せるので、
# ここを分けないとリリース版と見分けがつかない。
if [ "${CONFIG}" = "debug" ]; then
    BUNDLE_NAME="${APP_NAME} Debug"
else
    BUNDLE_NAME="${APP_NAME}"
fi
APP="${BUILD_DIR}/${BUNDLE_NAME}.app"
# 旧名のバンドルが残っていると、どちらを起動したのか分からなくなるので消す。
rm -rf "${BUILD_DIR}/${APP_NAME}.app" "${BUILD_DIR}/${APP_NAME} Debug.app"

echo "▸ Building (${CONFIG}${ARCH_FLAGS:+, universal})…"
swift build -c "${CONFIG}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

echo "▸ Assembling ${APP}…"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

BIN="$(swift build -c "${CONFIG}" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/${APP_NAME}"
cp "${BIN}" "${APP}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP}/Contents/Info.plist"

# バージョン注入（CI がリリースブランチ名から渡す）。未指定なら Info.plist の既定値のまま。
# CFBundleShortVersionString は Apple の形式要件で数値 3 成分のみ（例 0.0.1）。
if [ -n "${MARKETING_VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${MARKETING_VERSION}" "${APP}/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "${APP}/Contents/Info.plist"
fi
# 再ビルド番号込みの完全版（例 0.0.1+1）。未指定なら MARKETING_VERSION に従う。
FULL_VERSION="${FULL_VERSION:-${MARKETING_VERSION:-}}"
if [ -n "${FULL_VERSION}" ]; then
    /usr/libexec/PlistBuddy -c "Set :MAFullVersion ${FULL_VERSION}" "${APP}/Contents/Info.plist"
fi

# デバッグビルドは「別アプリ」にする（別 bundle id + 別表示名）。
# → Environment.live の保存先が Application Support/ManageArms Debug に分かれ、
#   開発中のリビルドがインストール済みリリース版の registry.json を壊さない。
#   ただし ~/.agents/skills と ~/.claude/skills は home 基準の共有ルートなので
#   分離できない（DESIGN.md 3.2）。debug 版でもスキルの有効化は実環境に効く。
if [ "${CONFIG}" = "debug" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${DEBUG_BUNDLE_ID}" "${APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName ${APP_NAME} Debug" "${APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${APP_NAME} Debug" "${APP}/Contents/Info.plist"
fi

# アプリアイコン（無ければ生成）。
if [ ! -f "Resources/AppIcon.icns" ]; then
    ./Scripts/make-icon.sh
fi
cp "Resources/AppIcon.icns" "${APP}/Contents/Resources/AppIcon.icns"

# ローカライズリソース（.lproj）を同梱。Bundle.main がここから引く。
for lproj in Localization/*.lproj; do
    [ -d "${lproj}" ] && cp -R "${lproj}" "${APP}/Contents/Resources/"
done

# デバッグビルドは lldb がアタッチできるよう get-task-allow 付きで署名する。
# 配布／公証ビルド（release）には絶対に含めない。
if [ "${CONFIG}" = "debug" ] && [ -f "Resources/${APP_NAME}.debug.entitlements" ]; then
    ENTITLEMENTS="Resources/${APP_NAME}.debug.entitlements"
else
    ENTITLEMENTS="Resources/${APP_NAME}.entitlements"
fi

echo "▸ Signing (identity: ${SIGN_IDENTITY}, entitlements: ${ENTITLEMENTS})…"
# --options runtime = Hardened Runtime。公証の必須要件なので常に付ける。
# 子プロセス（$SHELL -l -c / claude / codex）の起動に追加の entitlement は要らない。
SIGN_ARGS=(--force --options runtime --entitlements "${ENTITLEMENTS}" --sign "${SIGN_IDENTITY}")
# 公証には安全なタイムスタンプが必須。実 ID の release ビルドのときだけ付与する
# （アドホック - は非対応。debug では毎回ネットワーク待ちになるだけで無意味）。
if [ "${SIGN_IDENTITY}" != "-" ] && [ "${CONFIG}" = "release" ]; then
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "${APP}"

echo "✓ Built ${APP}"
echo "  open \"${APP}\" で起動できます。"
