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
// ノードだけ色を変えて「4 つの別物を束ねている」ことを一目で出す。
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = URL(filePath: CommandLine.arguments[1])
let size = 1024.0
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

guard let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size),
    bitsPerComponent: 8, bytesPerRow: 0,
    space: sRGB,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { fatalError("CGContext を作れませんでした") }

// macOS のアイコンは 1024 のキャンバスいっぱいには描かない（周囲に余白を残す）。
let inset = 100.0
let box = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = box.width * 0.2237
let squircle = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 台座の影は焼き込まない。透明背景に落とすと、影ではなく黒い縁取りに見えるため。
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// 背景 = 青紫の中で色相をわずかに振るだけ。ポップさはノードの色で出し、面は静かに保つ。
let gradient = CGGradient(
    colorsSpace: sRGB,
    colors: [CGColor(red: 0.38, green: 0.42, blue: 0.95, alpha: 1),
             CGColor(red: 0.55, green: 0.38, blue: 0.93, alpha: 1)] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                       end: CGPoint(x: box.maxX, y: box.minY), options: [])

// 左上の艶。面が単調にならない程度にとどめる。
let gloss = CGGradient(
    colorsSpace: sRGB,
    colors: [CGColor(gray: 1, alpha: 0.13), CGColor(gray: 1, alpha: 0)] as CFArray,
    locations: [0, 1]
)!
ctx.drawRadialGradient(gloss,
                       startCenter: CGPoint(x: box.minX + box.width * 0.24, y: box.maxY - box.height * 0.14),
                       startRadius: 0,
                       endCenter: CGPoint(x: box.minX + box.width * 0.24, y: box.maxY - box.height * 0.14),
                       endRadius: box.width * 0.62, options: [])
ctx.restoreGState()

// 内側のふち。エッジを締めるとガラスっぽく見える。
ctx.saveGState()
ctx.addPath(squircle)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// ハブとスポーク。
let center = CGPoint(x: size / 2, y: size / 2)
let spoke = 210.0
let accents = [
    CGColor(red: 1.00, green: 0.82, blue: 0.30, alpha: 1),   // 右上
    CGColor(red: 0.36, green: 0.93, blue: 0.98, alpha: 1),   // 左上
    CGColor(red: 0.44, green: 0.96, blue: 0.66, alpha: 1),   // 左下
    CGColor(red: 1.00, green: 0.51, blue: 0.56, alpha: 1),   // 右下
]
let nodes = [45.0, 135.0, 225.0, 315.0].map { deg -> CGPoint in
    let r = deg * .pi / 180
    return CGPoint(x: center.x + cos(r) * spoke, y: center.y + sin(r) * spoke)
}

func circle(_ p: CGPoint, _ r: Double) -> CGRect {
    CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
}

// 前景をひとかたまりの影として落とす（要素ごとに影を付けると重なりが濁る）。
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: CGColor(red: 0.14, green: 0.04, blue: 0.32, alpha: 0.38))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)

ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(36)
ctx.setLineCap(.round)
for node in nodes {
    ctx.move(to: center)
    ctx.addLine(to: node)
}
ctx.strokePath()

ctx.setFillColor(CGColor(gray: 1, alpha: 1))
for node in nodes { ctx.fillEllipse(in: circle(node, 58)) }
ctx.fillEllipse(in: circle(center, 92))

ctx.endTransparencyLayer()
ctx.restoreGState()

// ノードの色芯とハブの芯。白地の上に置くので小サイズでも色が潰れない。
for (node, color) in zip(nodes, accents) {
    ctx.setFillColor(color)
    ctx.fillEllipse(in: circle(node, 40))
}
ctx.saveGState()
ctx.addPath(CGPath(ellipseIn: circle(center, 38), transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                       end: CGPoint(x: box.maxX, y: box.minY), options: [])
ctx.restoreGState()

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
