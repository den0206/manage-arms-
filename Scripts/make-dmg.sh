#!/bin/bash
# .app からドラッグ&ドロップ設置用の DMG を作る。依存ゼロ（hdiutil / osascript / swift / tiffutil）。
#
#   ./Scripts/make-dmg.sh <path-to-.app> <output.dmg> [ボリューム名]
#
# 例: ./Scripts/make-dmg.sh .build/release/ManageArms.app ManageArms-1.2.3.dmg "ManageArms 1.2.3"
#
# 背景画像・アイコン配置・「Applications へドラッグ」矢印付きのインストール画面にする。
# レイアウト（背景の描画 / アイコン配置 / ウィンドウ）は本スクリプトの定数が単一の真実。
# Finder でのスタイリングは best-effort — ヘッドレス環境（CI 等）で失敗しても、
# 機能的に問題ない素の DMG は必ず生成する（リリースを止めない）。
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${1:?usage: make-dmg.sh <app> <dmg> [volume-name]}"
DMG="${2:?usage: make-dmg.sh <app> <dmg> [volume-name]}"
VOLUME="${3:-ManageArms}"

[ -d "${APP}" ] || { echo "error: ${APP} が見つかりません" >&2; exit 1; }
APP_ITEM="$(basename "${APP}")"   # 例: ManageArms.app

# AppleScript 文字列リテラル用エスケープ（\ と "）。
as_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}
VOLUME_AS="$(as_escape "${VOLUME}")"
APP_ITEM_AS="$(as_escape "${APP_ITEM}")"

# --- レイアウト定数（ポイント / コンテンツ左上原点）------------------------------
WIN_W=600            # ウィンドウ内容の幅
WIN_H=400            # ウィンドウ内容の高さ
TITLEBAR=28          # タイトルバー分（bounds は内容 + タイトルバー）
ICON_SIZE=128
APP_X=170            # アプリアイコンの中心 X
APPS_X=430           # Applications の中心 X
ICON_Y=190           # 両アイコンの中心 Y
SCALE=2              # 背景の Retina 倍率

STAGING="$(mktemp -d)"
RW_DMG="$(mktemp -u).dmg"
RENDER="$(mktemp -d)/render-dmg-background.swift"
DEVICE=""
cleanup() {
    [ -n "${DEVICE:-}" ] && hdiutil detach "${DEVICE}" >/dev/null 2>&1 || true
    rm -rf "${STAGING}" "${RW_DMG}" "$(dirname "${RENDER}")"
}
trap cleanup EXIT

# .app と /Applications へのシンボリックリンク（ドラッグ設置用）を配置。
# ditto はコード署名・公証チケット（CodeResources）を壊さずコピーする（cp -R より安全）。
ditto "${APP}" "${STAGING}/${APP_ITEM}"
ln -s /Applications "${STAGING}/Applications"

# --- 背景画像の描画スクリプト -------------------------------------------------
# 引数: 出力PNG 幅 高さ 倍率 アプリX ApplicationsX アイコンY（座標はすべて Finder と同じ左上原点）
cat > "${RENDER}" <<'SWIFT'
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let out = URL(filePath: a[1])
let w = Double(a[2])!, h = Double(a[3])!, scale = Double(a[4])!
let appX = Double(a[5])!, appsX = Double(a[6])!
// Finder は左上原点、CoreGraphics は左下原点。ここで 1 回だけ反転する。
let iconY = h - Double(a[7])!

guard let ctx = CGContext(
    data: nil, width: Int(w * scale), height: Int(h * scale),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext を作れませんでした") }
ctx.scaleBy(x: scale, y: scale)

// 背景。Finder のアイコンラベルは明色背景を前提に描かれるので淡い階調にする。
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1),
             CGColor(red: 0.90, green: 0.91, blue: 0.95, alpha: 1)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

// 「Applications へドラッグ」の矢印。両アイコンの間、アイコン中心の高さに置く。
// 文字を入れないのは、DMG の背景画像はローカライズできないため（矢印なら言語に依らない）。
let gap = appsX - appX
let from = appX + gap * 0.29, to = appsX - gap * 0.29
let head = 15.0
ctx.setStrokeColor(CGColor(red: 0.45, green: 0.47, blue: 0.55, alpha: 1))
ctx.setFillColor(CGColor(red: 0.45, green: 0.47, blue: 0.55, alpha: 1))
ctx.setLineWidth(5)
ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: from, y: iconY))
ctx.addLine(to: CGPoint(x: to - head, y: iconY))
ctx.strokePath()
ctx.move(to: CGPoint(x: to, y: iconY))
ctx.addLine(to: CGPoint(x: to - head, y: iconY + head * 0.62))
ctx.addLine(to: CGPoint(x: to - head, y: iconY - head * 0.62))
ctx.closePath()
ctx.fillPath()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("PNG を書き出せませんでした") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG の finalize に失敗しました") }
SWIFT

# --- 背景画像を生成（best-effort）---------------------------------------------
BG_ITEM=""   # 空なら背景なしでフォールバック
mkdir -p "${STAGING}/.background"
if command -v swift >/dev/null 2>&1 \
   && swift "${RENDER}" "${STAGING}/.background/bg1x.png" \
        "${WIN_W}" "${WIN_H}" 1 "${APP_X}" "${APPS_X}" "${ICON_Y}" >/dev/null 2>&1 \
   && swift "${RENDER}" "${STAGING}/.background/bg2x.png" \
        "${WIN_W}" "${WIN_H}" "${SCALE}" "${APP_X}" "${APPS_X}" "${ICON_Y}" >/dev/null 2>&1; then
    # Retina 対応の HiDPI TIFF（1x + 2x）にまとめる。失敗したら 1x PNG を使う。
    if command -v tiffutil >/dev/null 2>&1 \
       && tiffutil -cathidpicheck "${STAGING}/.background/bg1x.png" "${STAGING}/.background/bg2x.png" \
            -out "${STAGING}/.background/background.tiff" >/dev/null 2>&1; then
        BG_ITEM="background.tiff"
    else
        cp "${STAGING}/.background/bg1x.png" "${STAGING}/.background/background.png"
        BG_ITEM="background.png"
    fi
    rm -f "${STAGING}/.background/bg1x.png" "${STAGING}/.background/bg2x.png"
fi

# 同名ボリュームが既にマウントされていたら外す（採番 "VOLUME 1" を避ける）。
hdiutil detach "/Volumes/${VOLUME}" >/dev/null 2>&1 || true

# --- 書き込み可能 DMG を作ってマウント（スタイリング用。失敗しても convert は続行）----
hdiutil create -srcfolder "${STAGING}" -volname "${VOLUME}" \
    -fs HFS+ -format UDRW -ov "${RW_DMG}" >/dev/null

# pipefail 下で grep 不一致がスクリプト全体を落とさないよう、attach 行は || true。
ATTACH_OUT="$(hdiutil attach "${RW_DMG}" -readwrite -noverify -noautoopen 2>/dev/null || true)"
DEVICE="$(printf '%s\n' "${ATTACH_OUT}" | grep -E '^/dev/' | grep 'Apple_HFS' | head -1 | awk '{print $1}' || true)"
MOUNT="/Volumes/${VOLUME}"

if [ -z "${DEVICE}" ]; then
    echo "warn: DMG をマウントできなかったため Finder スタイリングをスキップします（素の DMG を作成）" >&2
else
    # --- Finder でウィンドウをスタイリング（best-effort）-------------------------
    BG_LINE=""
    [ -n "${BG_ITEM}" ] && BG_LINE="set background picture of opts to file \".background:${BG_ITEM}\""
    RIGHT=$((200 + WIN_W))
    BOTTOM=$((120 + WIN_H + TITLEBAR))
    osascript <<EOF >/dev/null 2>&1 || echo "warn: Finder でのスタイリングをスキップしました（素の DMG を作成）" >&2
tell application "Finder"
  tell disk "${VOLUME_AS}"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, ${RIGHT}, ${BOTTOM}}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to ${ICON_SIZE}
    set text size of opts to 13
    ${BG_LINE}
    set position of item "${APP_ITEM_AS}" of container window to {${APP_X}, ${ICON_Y}}
    set position of item "Applications" of container window to {${APPS_X}, ${ICON_Y}}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

    # ボリュームアイコン（best-effort）。Finder が開いた「後」に置く必要がある
    # （属性の無い孤立 .VolumeIcon.icns を Finder が掃除してしまうため、srcfolder 同梱では消える）。
    if [ -f Resources/AppIcon.icns ]; then
        cp Resources/AppIcon.icns "${MOUNT}/.VolumeIcon.icns" 2>/dev/null \
            && { SetFile -a C "${MOUNT}" || /usr/bin/SetFile -a C "${MOUNT}" || xcrun SetFile -a C "${MOUNT}"; } >/dev/null 2>&1 || true
    fi

    sync
    hdiutil detach "${DEVICE}" >/dev/null 2>&1 || true
    DEVICE=""
fi

# --- 圧縮 read-only DMG に変換 ------------------------------------------------
rm -f "${DMG}"
hdiutil convert "${RW_DMG}" -format UDZO -imagekey zlib-level=9 -o "${DMG}" >/dev/null

echo "✓ Created ${DMG}"
