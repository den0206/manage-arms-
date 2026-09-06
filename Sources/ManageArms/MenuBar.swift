import AppKit
import SwiftUI
import ManageArmsCore

/// メニューバーの中身（DESIGN.md 3.5）。
/// ウィンドウを閉じてもここだけが残る。**持つのは model への参照だけ** —
/// 一覧はウィンドウを閉じた時点で捨ててあるので、常駐中のメモリはこの項目分しかない。
struct MenuBarMenu: View {
    let model: AppModel
    @SwiftUI.Environment(\.openWindow) private var openWindow

    var body: some View {
        if let lead = model.watcher.pending {
            Button(lead.localizedTitle) {
                showWindow()
                model.watcher.accept(lead)
            }
            Button("今はしない") { model.watcher.dismiss() }
            Divider()
        }
        Button("ManageArmsを開く") { showWindow() }
        Button("設定…") {
            showWindow()
            model.pendingScreen = .settings
        }
        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: ManageArmsApp.windowID)
    }
}

/// メニューバーのアイコン。**アプリアイコンと同じ図案**（ハブから斜め 4 方向のノード）を
/// メニューバーの大きさで描き直したもの。比率は `Scripts/make-icon.sh` に合わせてある。
/// SF Symbol に寄せると「1 つの GUI から 4 エージェントを束ねる」という図が崩れる。
///
/// 検知したものがある間だけ右上のノードを**緑**にする。数字や件数は出さない —
/// 出せるのは常に 1 件で、点で足りる。
struct MenuBarIcon: View {
    let alert: Bool

    /// メニューバーの他アイコンと同じくらいの見え方になる大きさ。
    private static let size = 18.0
    /// ハブから見たノードの距離。
    private static let spoke = size * 0.40

    /// **色を出せるのは非テンプレート画像だけ。** `MenuBarExtra` はラベルを
    /// まるごとテンプレートとして描くため、`Circle().fill(.green)` を重ねても
    /// 単色に潰れる（実機で確認）。そこで検知中だけ色付きの画像に差し替える。
    var body: some View {
        // 通常時はテンプレート。明暗の追従・メニュー選択中の反転を OS に任せられる。
        Image(nsImage: Self.mark(alert: alert))
            .renderingMode(alert ? .original : .template)
            .accessibilityLabel(alert ? Text("ManageArms（追加できるToolがあります）") : Text("ManageArms"))
    }

    /// 18pt の図形 1 枚。描くのは alert が変わったときだけで、持ち回らない。
    private static func mark(alert: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let spoke = MenuBarIcon.spoke
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let nodes = [45.0, 135.0, 225.0, 315.0].map { deg -> CGPoint in
                let r = deg * .pi / 180
                return CGPoint(x: center.x + cos(r) * spoke, y: center.y + sin(r) * spoke)
            }
            func dot(_ p: CGPoint, _ r: Double) {
                NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
            // **検知中は図案ごと緑にする。** ノード 1 つだけだと 18pt では気づけない
            // （実機で確認）。通常時はテンプレートなのでここの色は使われない。
            let ink: NSColor = alert ? .systemGreen : .black
            ink.setStroke()
            ink.setFill()
            let spokes = NSBezierPath()
            spokes.lineWidth = spoke * 0.171
            spokes.lineCapStyle = .round
            for node in nodes {
                spokes.move(to: center)
                spokes.line(to: node)
            }
            spokes.stroke()
            for node in nodes { dot(node, spoke * 0.276) }
            dot(center, spoke * 0.438)
            return true
        }
        image.isTemplate = !alert
        return image
    }
}

/// 設定画面。**サイドバーの 1 画面**として出す（別ウィンドウにしない）。
/// メニューバーの「設定…」も ⌘, もここへ来る。
/// **置くのは利用者が決めることだけ** — 検出結果は持たない（DESIGN.md 4.1）。
struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("外観", selection: .init(get: { model.appearance },
                                               set: { model.setAppearance($0) })) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("外観")
            }
            Section {
                Toggle("メニューバーに常駐する",
                       isOn: .init(get: { model.staysInMenuBar },
                                   set: { model.setMenuBarResident($0) }))
                Text("OFFにすると、ウィンドウを閉じた時点でアプリを終了します。常駐中もウィンドウを閉じていれば一覧はメモリから捨てます。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("常駐")
            }
            Section {
                Toggle("ブラウザで見つけたToolを知らせる",
                       isOn: .init(get: { model.detectsBrowserURLs },
                                   set: { model.setBrowserDetection($0) }))
                Text("ブラウザでSkill・Plugin・Subagentのページを開くと、メニューバーのアイコンが緑になります（ページから離れれば元に戻ります）。前面のブラウザを見るだけで、URLは保存しません。ブラウザの制御を許可する必要があります。")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("ブラウザ検知")
            }
        }
        .formStyle(.grouped)
    }
}
