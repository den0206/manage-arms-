#!/bin/bash
# アプリアイコン（AppIcon.icns）を生成して Resources/ に置く。依存ゼロ（swift / sips / iconutil）。
# 1024px のマスターを CoreGraphics で描き、sips で各サイズに落として iconutil で束ねる。
# 差し替えたくなったら、下の Swift の描画部分だけを書き換えるか
# Resources/AppIcon.icns を手製のものに置き換える（build-app.sh は在れば使う）。
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
MASTER="${WORK}/icon_1024.png"
ICONSET="${WORK}/AppIcon.iconset"
RENDER="${WORK}/render-icon.swift"
mkdir -p "${ICONSET}"

cat > "${RENDER}" <<'SWIFT'
// 1024px のマスターアイコンを描く。引数: 出力 PNG のパス。
// 図案 = 中心のハブから 4 方向へ伸びるノード（1 つの GUI から 4 エージェントを束ねる）。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(filePath: CommandLine.arguments[1])
let size = 1024.0

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext を作れませんでした") }

// macOS のアイコンは 1024 のキャンバスいっぱいには描かない（周囲に余白を残す）。
let inset = 100.0
let box = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = CGPath(roundedRect: box, cornerWidth: box.width * 0.2237,
                      cornerHeight: box.width * 0.2237, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [CGColor(red: 0.36, green: 0.42, blue: 1.00, alpha: 1),
             CGColor(red: 0.66, green: 0.33, blue: 0.97, alpha: 1)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                       end: CGPoint(x: box.maxX, y: box.minY), options: [])
ctx.restoreGState()

// ハブとスポーク。
let center = CGPoint(x: size / 2, y: size / 2)
let spoke = 200.0
let nodes = [45.0, 135.0, 225.0, 315.0].map { deg -> CGPoint in
    let r = deg * .pi / 180
    return CGPoint(x: center.x + cos(r) * spoke, y: center.y + sin(r) * spoke)
}

ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(30)
ctx.setLineCap(.round)
for node in nodes {
    ctx.move(to: center)
    ctx.addLine(to: node)
}
ctx.strokePath()

ctx.setFillColor(CGColor(gray: 1, alpha: 1))
for node in nodes {
    ctx.fillEllipse(in: CGRect(x: node.x - 46, y: node.y - 46, width: 92, height: 92))
}
ctx.fillEllipse(in: CGRect(x: center.x - 74, y: center.y - 74, width: 148, height: 148))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("PNG を書き出せませんでした") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("PNG の finalize に失敗しました") }
SWIFT

echo "▸ Rendering master icon…"
swift "${RENDER}" "${MASTER}"

echo "▸ Generating iconset sizes…"
gen() { sips -z "$1" "$1" "${MASTER}" --out "${ICONSET}/$2" >/dev/null; }
gen 16   icon_16x16.png
gen 32   icon_16x16@2x.png
gen 32   icon_32x32.png
gen 64   icon_32x32@2x.png
gen 128  icon_128x128.png
gen 256  icon_128x128@2x.png
gen 256  icon_256x256.png
gen 512  icon_256x256@2x.png
gen 512  icon_512x512.png
cp "${MASTER}" "${ICONSET}/icon_512x512@2x.png"

echo "▸ Building icns…"
mkdir -p Resources
iconutil -c icns "${ICONSET}" -o Resources/AppIcon.icns

echo "✓ Resources/AppIcon.icns"
