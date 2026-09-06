import AppKit
import SwiftUI
import ManageArmsCore

/// 前面のブラウザが開いている URL を見て、追加できる Tool ならウィンドウに出す（DESIGN.md 6 章）。
///
/// **このファイルだけが Apple Events を投げる**（`Scripts/check-invariants.sh` が検査する）。
/// DESIGN.md 3.5「監視しない」の唯一の例外で、条件を 2 つとも満たすときだけ:
/// 設定が ON・既知ブラウザが前面。ウィンドウを閉じていても常駐中は動く
/// （見つけたものはメニューバーのアイコンを緑にして知らせる）。
///
/// 取得した URL は判定に使ってすぐ捨てる。保存もログ出力もしない。
@MainActor
@Observable
final class BrowserWatcher {

    /// 既知ブラウザ。Chromium 系は AppleScript 辞書が共通なので 1 行で増やせる。
    enum Browser: String, CaseIterable {
        case safari = "com.apple.Safari"
        case chrome = "com.google.Chrome"
        case edge = "com.microsoft.edgemac"
        case brave = "com.brave.Browser"
        case arc = "company.thebrowser.Browser"

        /// Safari だけ辞書が別（front document）。
        var script: String {
            switch self {
            case .safari:
                "tell application id \"com.apple.Safari\" to return URL of front document"
            default:
                "tell application id \"\(rawValue)\" to return URL of active tab of front window"
            }
        }
    }

    /// 見つけたもの。メニューバーのアイコンを緑にし、ウィンドウを開いていれば帯にも出す。
    /// **システム通知は使わない** —
    /// 見せる場所を 2 つ持たず、通知の許可も要らない状態にしておく。
    private(set) var pending: ToolLead?
    /// 「追加する」を押されたとき。ContentView が AddSheet を開く。
    var onAdd: ((ToolLead) -> Void)?
    /// 許可が無いなど、利用者に伝えるべき失敗。
    var onError: ((String) -> Void)?
    /// ブラウザ制御を拒否されたので設定を OFF に戻した。
    var onDisabled: (() -> Void)?

    private var enabled = false
    private var timer: Timer?
    private var observer: (any NSObjectProtocol)?
    /// 事前コンパイルして使い回す。3 秒ごとにコンパイルし直さない。
    private var scripts: [Browser: NSAppleScript] = [:]
    /// 起動中だけの記憶（永続ファイルを増やさない）。
    private var seen: Set<String> = []
    private var lastURL = ""

    /// URL が変わっている間（＝閲覧中）の間隔。
    static let interval: TimeInterval = 3
    /// 同じページに留まっている間の間隔。**Apple Event 1 回が実測 ~100ms** かかり、
    /// 常駐して 3 秒ごとに投げ続けると CPU 3% を使い続ける（実測）。
    /// 動きが無い間は落とす — 開いたままのページは何度訊いても同じ答えしか返さない。
    static let idleInterval: TimeInterval = 15
    /// この回数だけ URL が変わらなければ `idleInterval` に落とす（3 秒 × 10 = 30 秒）。
    static let idleAfter = 10
    private var idleTicks = 0

    // MARK: - 開始・停止

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncTimer() }
        }
        syncTimer()
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        pending = nil
        lastURL = ""
    }

    /// ブラウザが前面の間だけタイマーを回す。それ以外は止めておく（3.5）。
    private func syncTimer() {
        guard enabled, frontBrowser != nil else {
            timer?.invalidate(); timer = nil
            return
        }
        idleTicks = 0                      // 前面が変わったら追従を速い方に戻す
        schedule(Self.interval)
        tick()
    }

    /// 間隔を変えるには張り直すしかない。`idleTicks` の増減に合わせて 2 段階だけ持つ。
    private func schedule(_ seconds: TimeInterval) {
        guard timer?.timeInterval != seconds else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private var frontBrowser: Browser? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .flatMap(Browser.init(rawValue:))
    }

    // MARK: - 1 回分の検知

    private func tick() {
        guard let browser = frontBrowser, let url = frontURL(browser) else { return }

        // 出していたページから離れたら引っ込める。**ブラウザが前面でない間は消さない** —
        // URL が読めないだけで、メニューを触っている最中かもしれない。
        if let shown = pending, shown.url != url {
            seen.remove(shown.url)   // 自分で消したわけではないので、戻ってきたらまた出す
            pending = nil
        }

        guard url != lastURL else {
            idleTicks += 1
            if idleTicks >= Self.idleAfter { schedule(Self.idleInterval) }
            return
        }
        idleTicks = 0
        schedule(Self.interval)
        lastURL = url

        // ここから先へ渡すのは github.com / skills.sh の URL だけ。それ以外は即捨てる。
        guard let lead = ToolURL.lead(url),
              ToolURL.shouldNotify(lead, registry: Registry.load(env: .live), seen: seen)
        else { return }

        seen.insert(lead.url)      // 確認の往復中に同じ URL でもう一度走らせない
        Task { [weak self] in
            guard await Self.exists(lead) else { return }
            self?.pending = lead
        }
    }

    /// 実在確認。**どれか 1 つでも 200 なら本物**。404・通信失敗は黙る。
    private static func exists(_ lead: ToolLead) async -> Bool {
        guard !lead.proofs.isEmpty else { return true }
        for url in lead.proofURLs() {
            if let status = try? await Environment.live.httpHead(url), status == 200 { return true }
        }
        return false
    }

    /// 帯のボタン。「今はしない」も `seen` に入っているので、この起動中は再提案しない。
    func accept(_ lead: ToolLead) {
        pending = nil
        onAdd?(lead)
    }

    func dismiss() { pending = nil }

    // MARK: - Apple Events

    /// 前面タブの URL。**許可されていなければ機能ごと止める**（毎回ダイアログを出さない）。
    private func frontURL(_ browser: Browser) -> String? {
        let script = scripts[browser] ?? NSAppleScript(source: browser.script)
        guard let script else { return nil }
        scripts[browser] = script

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            // -1743 = errAEEventNotPermitted（オートメーションを拒否された）。
            // それ以外（ウィンドウが無い -1728 など）は黙って次の tick を待つ。
            if code == -1743 {
                setEnabled(false)
                onDisabled?()
                onError?(String(localized: "ブラウザの制御が許可されていないため、検知を停止しました。システム設定 > プライバシーとセキュリティ > オートメーション で ManageArms を許可してください。"))
            }
            return nil
        }
        return result.stringValue
    }
}

extension ToolLead {
    /// 帯の見出し。**種別ごとに別のキーにする** — 一覧の見出し（複数形）を
    /// 流用すると英語で "Found Skills「foo」" になる。
    var localizedTitle: String {
        switch kind {
        case .skill:    String(localized: "スキル「\(name)」を見つけました")
        case .subagent: String(localized: "サブエージェント「\(name)」を見つけました")
        case .plugin:   String(localized: "プラグイン「\(name)」を見つけました")
        case .mcp:      String(localized: "MCP「\(name)」を見つけました")
        }
    }
}

/// 見つけたものを出す帯。ホームの一番上に置く。
struct BrowserLeadBanner: View {
    let lead: ToolLead
    let add: () -> Void
    let skip: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: lead.kind.symbol).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(lead.localizedTitle)
                Text(verbatim: lead.source.repo)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("追加する", action: add).buttonStyle(.borderedProminent)
            Button("今はしない", action: skip)
        }
        .padding(12)
        .background(.tint.opacity(0.08))
    }
}
