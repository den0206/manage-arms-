import AppKit
import SwiftUI
import ManageArmsCore

/// 画面の共通語彙（DESIGN.md 8.1）。**余白・角丸・動きの数値をここ以外に置かない** —
/// 画面ごとに 14 と 16 が混ざると、リッチではなく雑に見える。
enum Theme {
    /// 4 の倍数だけを使う。中間の値が要ると感じたら、たいてい階層の作り方が間違っている。
    static let tight: CGFloat = 4
    static let gap: CGFloat = 8
    static let pad: CGFloat = 16
    static let block: CGFloat = 24

    static let radiusS: CGFloat = 7
    static let radiusM: CGFloat = 12

    /// 読み幅の上限。ウィンドウを広げても本文が横に伸び切らないようにする。
    static let readable: CGFloat = 780

    /// ブランドの差し色。単色より奥行きが出るが、**使うのはヒーローと主要ボタンだけ**。
    static let brand = LinearGradient(colors: [Color.accentColor, Color.purple],
                                      startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// 動きの語彙。**「動きを減らす」設定を必ず尊重する** — アクセシビリティは削らない。
/// `Animation?` を返すので、そのまま `.animation(Motion.pop, value:)` に渡せば
/// 設定が入っている環境では動かなくなる。
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 選択・切り替えなど「位置が動く」もの。
    static var pop: Animation? { reduced ? nil : .spring(response: 0.32, dampingFraction: 0.82) }
    /// ホバーや淡い出入りなど「色が変わる」もの。
    static var gentle: Animation? { reduced ? nil : .easeOut(duration: 0.18) }
    /// 数字・件数の差し替え。
    static var count: Animation? { reduced ? nil : .snappy(duration: 0.28) }
}

extension View {
    /// 情報の 1 かたまり。境界線 + ごく淡い影で、背景と地続きに見えないようにする。
    func card(padding: CGFloat = Theme.pad,
              radius: CGFloat = Theme.radiusM,
              accented: Bool = false) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(accented ? AnyShapeStyle(Theme.brand.opacity(0.7))
                                           : AnyShapeStyle(.separator.opacity(0.6)),
                                  lineWidth: accented ? 1.5 : 1)
            }
            .shadow(color: .black.opacity(accented ? 0.10 : 0.05),
                    radius: accented ? 10 : 5, y: accented ? 4 : 2)
            .animation(Motion.gentle, value: accented)
    }
}

/// 種別・状態の小さな目印。**色は意味に対応させる**（灰=中立 / 橙=注意 / 緑=稼働）。
struct Pill: View {
    let text: String
    var tint: Color?
    var icon: String?

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon) }
            Text(verbatim: text)
        }
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(tint ?? .secondary)
        .background(tint?.opacity(0.14) ?? Color.secondary.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder((tint ?? .secondary).opacity(0.18), lineWidth: 0.5))
    }
}

/// 状態の点。文字を足さずに検出状況を出す（サイドバーは幅が無い）。
struct StatusDot: View {
    let detection: Detection

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 3).blur(radius: 1))
            .help(help)
            .accessibilityLabel(Text(help))
    }

    private var color: Color {
        switch detection {
        case .detected:   .green
        case .configOnly: .orange
        case .undetected: .secondary.opacity(0.5)
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

/// ホームの数字タイル。**飾りではなく要約** — 何が何件あるかは、開く前に知りたい情報。
struct StatTile: View {
    let title: LocalizedStringKey
    let count: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.tight) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7))
            Text(count.formatted())
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(Motion.count, value: count)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(Theme.pad - 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        }
    }
}

/// シートの見出し。3 つのシートで形を揃える（どれも「確認してから実行する」画面）。
struct SheetHeader: View {
    let title: LocalizedStringKey
    var subtitle: String?
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 読み込み中だけ現れる細い帯。**スピナーを画面中央に出さない** —
/// 一覧は前回の内容のまま読めるほうが速く感じる。
struct BusyBar: View {
    let active: Bool
    @State private var shift = false

    var body: some View {
        Rectangle()
            .fill(Theme.brand)
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
