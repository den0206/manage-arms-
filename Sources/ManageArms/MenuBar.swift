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
/// 検知したものがある間だけ図案を**緑**にする。数字や件数は出さない —
/// 出せるのは常に 1 件で、点で足りる。
/// 更新があるときは図案の**右横**に緑の点を並べる（検知と混ざらないよう別の場所）。
struct MenuBarIcon: View {
    let alert: Bool
    /// 更新があるか。図案を塗り替えず、横に点を足すだけ。
    var badge: Bool = false

    /// メニューバーの他アイコンと同じくらいの見え方になる大きさ。
    private static let size = 18.0
    /// ハブから見たノードの距離。
    private static let spoke = size * 0.40
    /// 横に並べる点。図案の中に置くと 18pt では気づけないので外に出す。
    private static let dotSize = 5.0
    private static let dotGap = 2.0

    /// **色を出せるのは非テンプレート画像だけ。** `MenuBarExtra` はラベルを
    /// まるごとテンプレートとして描くため、`Circle().fill(.green)` を重ねても
    /// 単色に潰れる（実機で確認）。そこで検知中だけ色付きの画像に差し替える。
    var body: some View {
        // 通常時はテンプレート。明暗の追従・メニュー選択中の反転を OS に任せられる。
        Image(nsImage: Self.mark(alert: alert, badge: badge))
            .renderingMode(alert || badge ? .original : .template)
            .accessibilityLabel(label)
    }

    private var label: Text {
        if alert { return Text("ManageArms（追加できるToolがあります）") }
        if badge { return Text("ManageArms（更新があります）") }
        return Text("ManageArms")
    }

    /// 18pt の図形 1 枚（+ 点）。描くのは状態が変わったときだけで、持ち回らない。
    private static func mark(alert: Bool, badge: Bool) -> NSImage {
        let width = badge ? size + dotGap + dotSize : size
        let image = NSImage(size: NSSize(width: width, height: size), flipped: false) { rect in
            let spoke = MenuBarIcon.spoke
            let center = CGPoint(x: rect.minX + MenuBarIcon.size / 2, y: rect.midY)
            let nodes = [45.0, 135.0, 225.0, 315.0].map { deg -> CGPoint in
                let r = deg * .pi / 180
                return CGPoint(x: center.x + cos(r) * spoke, y: center.y + sin(r) * spoke)
            }
            func dot(_ p: CGPoint, _ r: Double) {
                NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)).fill()
            }
            // **検知中は図案ごと緑にする。** ノード 1 つだけだと 18pt では気づけない
            // （実機で確認）。通常時はテンプレートなのでここの色は使われない。
            // 非テンプレートになる（= 点を出す）ときは、明暗追従を OS に任せられない。
            // `labelColor` は描画時の appearance で解決されるのでここで拾える。
            let ink: NSColor = alert ? .systemGreen : (badge ? .labelColor : .black)
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
            if badge {
                NSColor.systemGreen.setFill()
                dot(CGPoint(x: rect.maxX - MenuBarIcon.dotSize / 2, y: rect.midY),
                    MenuBarIcon.dotSize / 2)
            }
            return true
        }
        // 点は色なので、あるうちはテンプレートにできない（実機で確認）。
        image.isTemplate = !alert && !badge
        // 外観が変わったら描き直させる（`labelColor` を焼き付けない）。
        image.cacheMode = .never
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
            if !model.inventory.projectScan.projects.isEmpty {
                Section {
                    projectRows(model.inventory.projectScan.projects, button: "除外") {
                        model.setProject($0, excluded: true)
                    }
                } header: {
                    Text("走査中プロジェクト")
                }
            }
            // 利用者が明示的に除外したもの。復元できる（自動除外と区別する）。
            if !model.inventory.projectScan.userIgnoredProjects.isEmpty {
                Section {
                    projectRows(model.inventory.projectScan.userIgnoredProjects, button: "復元") {
                        model.setProject($0, excluded: false)
                    }
                    Text("走査から除いています。「復元」を押すと再び一覧に出ます。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("除外したプロジェクト")
                }
            }
            // 走査しないと決めたものを黙って捨てない。**削除の導線は置かない**
            // （理由と実測は DESIGN.md 5.1）。事実だけ出して判断は利用者に返す。
            if !model.inventory.projectScan.ignoredProjects.isEmpty {
                Section {
                    projectRows(model.inventory.projectScan.ignoredProjects)
                    Text("ここはプロジェクトとして扱いません。ホームフォルダやルートを1つのプロジェクトとして読むと、配下にある他の全プロジェクトのスキルを巻き込んでしまうためです。ほかのプロジェクトは通常どおり一覧に出ます。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Label("走査しないプロジェクト登録", systemImage: "exclamationmark.triangle")
                }
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
    /// パス 1 行 + 任意の操作ボタン。3 つの節で形が同じなのでここにまとめる。
    @ViewBuilder
    func projectRows(_ paths: [String], button: LocalizedStringKey? = nil,
                     action: @escaping (String) -> Void = { _ in }) -> some View {
        ForEach(paths, id: \.self) { path in
            HStack {
                Text(verbatim: path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                if let button {
                    Spacer()
                    Button(button) { action(path) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }

}
