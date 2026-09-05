import AppKit
import SwiftUI
import ManageArmsCore

/// 画面の共通語彙（DESIGN.md 8.1）。**余白・角丸・動きの数値をここ以外に置かない** —
/// 画面ごとに 14 と 16 が混ざると、リッチではなく雑に見える。
///
/// 方針は**引き算**。グラデーション・ドロップシャドウ・種別ごとの色分けは持たない。
/// 階層は「余白 → 文字の太さ → 罫線」の順に作り、色は**意味があるときだけ**使う
/// （緑=稼働 / 橙=注意 / 赤=破壊 / アクセント=選択と主要ボタン）。
/// 装飾で情報を作ろうとすると、macOS のどのアプリにも似ていない画面になる。
enum Theme {
    /// 4 の倍数だけを使う。中間の値が要ると感じたら、たいてい階層の作り方が間違っている。
    static let tight: CGFloat = 4
    static let gap: CGFloat = 8
    static let pad: CGFloat = 16
    static let block: CGFloat = 24

    /// システムのコントロール（角丸ボタン・テキストフィールド）に合わせる。
    static let radiusS: CGFloat = 6
    static let radiusM: CGFloat = 10

    /// 読み幅の上限。ウィンドウを広げても本文が横に伸び切らないようにする。
    static let readable: CGFloat = 720

    /// 行頭のアイコン列の幅。**全画面で同じ値**にして、本文の左端を縦に揃える。
    static let glyph: CGFloat = 20
}

/// 動きの語彙。**「動きを減らす」設定を必ず尊重する** — アクセシビリティは削らない。
/// `Animation?` を返すので、そのまま `.animation(Motion.pop, value:)` に渡せば
/// 設定が入っている環境では動かなくなる。
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 選択・切り替えなど「位置が動く」もの。
    static var pop: Animation? { reduced ? nil : .spring(response: 0.28, dampingFraction: 0.9) }
    /// ホバーや淡い出入りなど「色が変わる」もの。
    static var gentle: Animation? { reduced ? nil : .easeOut(duration: 0.15) }
    /// 数字・件数の差し替え。
    static var count: Animation? { reduced ? nil : .snappy(duration: 0.25) }
}

extension View {
    /// 情報の 1 かたまり。**囲うのは罫線だけ** — 影を落とすと、
    /// 平面に並んでいるはずのものが浮いて見えて、視線の順序が壊れる。
    /// 入力中に枠を差し色にすることもしない。テキストフィールド自身のフォーカスリングと
    /// 二重になり、青い枠が入れ子で 2 本並ぶ。
    func card(padding: CGFloat = Theme.pad, radius: CGFloat = Theme.radiusM) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.separator, lineWidth: 1)
            }
    }
}

/// 数や短い状態のための小さな囲み。**既定は無彩色**。
/// 色を渡すのは、取り違えると害があるとき（allow / deny、+ / −）だけ。
struct Pill: View {
    let text: String
    var tint: Color?
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(verbatim: text)
        }
        .font(.caption2.weight(.medium))
        .monospacedDigit()
        .padding(.horizontal, 5).padding(.vertical, 1)
        .foregroundStyle(tint ?? .secondary)
        .background((tint ?? .secondary).opacity(0.12), in: Capsule())
    }
}

/// 状態の点。文字を足さずに検出状況を出す（サイドバーは幅が無い）。
struct StatusDot: View {
    let detection: Detection

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .help(help)
            .accessibilityLabel(Text(help))
    }

    private var color: Color {
        switch detection {
        case .detected:   .green
        case .configOnly: .orange
        case .undetected: .secondary.opacity(0.4)
        }
    }

    private var help: String {
        switch detection {
        case .detected:   String(localized: "検出済み")
        case .configOnly: String(localized: "設定のみ")
        case .undetected: String(localized: "未検出")
        }
    }
}

/// ホームの件数 1 つ分。**飾りではなく要約** — 何が何件あるかは、開く前に知りたい情報。
/// 自分では囲まない。呼び出し側が 1 本の帯にまとめて縦罫で仕切る。
struct StatTile: View {
    let title: LocalizedStringKey
    let count: Int
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(count.formatted())
                .font(.system(size: 21, weight: .regular))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.count, value: count)
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// シートとポップオーバーの見出し。**アイコンの色チップを置かない** —
/// システムのシートは太字の 1 行で始まる。ここだけ意匠を持つと浮く。
struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let subtitle {
                Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 読み込み中だけ現れる細い帯。**スピナーを画面中央に出さない** —
/// 一覧は前回の内容のまま読めるほうが速く感じる。
struct BusyBar: View {
    let active: Bool
    @State private var shift = false

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(height: 2)
            .mask(alignment: .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .frame(width: geo.size.width * 0.35)
                        .offset(x: shift ? geo.size.width * 0.65 : -geo.size.width * 0.35)
                }
            }
            .opacity(active ? 1 : 0)
            .animation(Motion.gentle, value: active)
            .allowsHitTesting(false)
            .onAppear { start() }
            .onChange(of: active) { _, _ in start() }
            .accessibilityHidden(true)
    }

    private func start() {
        guard active, !Motion.reduced else { shift = false; return }
        shift = false
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
            shift = true
        }
    }
}

/// 折り返す横並び。件数が環境しだいで増えるチップ（自分で入れたもの・実測 18 件）に使う。
/// `HStack` だと画面外へ消え、`Text` の連結だと 1 つ 1 つが読み取れない。
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var (x, y, lineHeight) = (CGFloat.zero, CGFloat.zero, CGFloat.zero)
        for size in subviews.map({ $0.sizeThatFits(.unspecified) }) {
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var (x, y, lineHeight) = (bounds.minX, bounds.minY, CGFloat.zero)
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX; y += lineHeight + spacing; lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
