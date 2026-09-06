import AppKit
import SwiftUI
import UserNotifications
import ManageArmsCore

/// 前面のブラウザが開いている URL を見て、追加できる Tool なら通知する（DESIGN.md 6 章）。
///
/// **このファイルだけが Apple Events を投げる**（`Scripts/check-invariants.sh` が検査する）。
/// DESIGN.md 3.5「監視しない」の唯一の例外で、条件は 3 つとも満たすときだけ:
/// 設定が ON・ウィンドウが開いている（＝プロセスが生きている）・既知ブラウザが前面。
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

    /// 通知が許可されていないときの受け皿。ウィンドウ内に出す。
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
    private var relay: NotificationRelay?
    /// 事前コンパイルして使い回す。3 秒ごとにコンパイルし直さない。
    private var scripts: [Browser: NSAppleScript] = [:]
    /// 起動中だけの記憶（永続ファイルを増やさない）。
    private var seen: Set<String> = []
    private var lastURL = ""
    private var notificationsAllowed = false

    static let interval: TimeInterval = 3

    // MARK: - 開始・停止

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        if on { start() } else { stop() }
    }

    private func start() {
        // `swift run` の裸のバイナリでは UNUserNotificationCenter が落ちる。
        // その場合は通知を諦め、ウィンドウ内の帯だけで動かす（.app では通る）。
        guard Bundle.main.bundleIdentifier != nil else { return startWatching() }

        let relay = NotificationRelay { [weak self] url, add in
            self?.respond(url: url, add: add)
        }
        self.relay = relay
        let center = UNUserNotificationCenter.current()
        center.delegate = relay
        center.setNotificationCategories([NotificationRelay.category])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsAllowed = granted }
        }

        startWatching()
    }

    private func startWatching() {
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
        relay = nil
        pending = nil
        lastURL = ""
    }

    /// ブラウザが前面の間だけタイマーを回す。それ以外は止めておく（3.5）。
    private func syncTimer() {
        guard enabled, frontBrowser != nil else {
            timer?.invalidate(); timer = nil
            return
        }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        tick()
    }

    private var frontBrowser: Browser? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            .flatMap(Browser.init(rawValue:))
    }

    // MARK: - 1 回分の検知

    private func tick() {
        guard let browser = frontBrowser, let url = frontURL(browser) else { return }
        guard url != lastURL else { return }
        lastURL = url

        // ここから先へ渡すのは github.com / skills.sh の URL だけ。それ以外は即捨てる。
        guard let lead = ToolURL.lead(url),
              ToolURL.shouldNotify(lead, registry: Registry.load(env: .live), seen: seen)
        else { return }

        seen.insert(lead.url)      // 確認の往復中に同じ URL でもう一度走らせない
        Task { [weak self] in
            guard await Self.exists(lead) else { return }
            self?.present(lead)
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

    private func present(_ lead: ToolLead) {
        guard notificationsAllowed else {
            pending = lead                      // 通知が使えないのでウィンドウ内に出す
            return
        }
        let content = UNMutableNotificationContent()
        content.title = lead.localizedTitle
        content.body = lead.source.repo
        content.categoryIdentifier = NotificationRelay.categoryID
        content.userInfo = ["url": lead.url]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: lead.url, content: content, trigger: nil))
    }

    /// 通知のボタン。「今はしない」は `seen` に入っているので、この起動中は再提案しない。
    private func respond(url: String, add: Bool) {
        pending = nil
        guard add, let lead = ToolURL.lead(url) else { return }
        NSApp.activate(ignoringOtherApps: true)
        onAdd?(lead)
    }

    func accept(_ lead: ToolLead) { respond(url: lead.url, add: true) }
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

/// 通知のボタンを受ける係。`UNUserNotificationCenterDelegate` は NSObject が要る。
private final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    static let addAction = "MA_ADD"
    static let skipAction = "MA_SKIP"
    static let categoryID = "MA_TOOL_LEAD"
    /// 毎回組み直す（グローバルな可変状態を持たない）。生成は 1 回だけ。
    static var category: UNNotificationCategory {
        UNNotificationCategory(
            identifier: categoryID,
            actions: [
                UNNotificationAction(identifier: addAction,
                                     title: String(localized: "追加する"), options: [.foreground]),
                UNNotificationAction(identifier: skipAction,
                                     title: String(localized: "今はしない"), options: []),
            ],
            intentIdentifiers: [])
    }

    private let handler: @MainActor (String, Bool) -> Void
    init(handler: @escaping @MainActor (String, Bool) -> Void) { self.handler = handler }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse) async {
        guard let url = response.notification.request.content.userInfo["url"] as? String else { return }
        let add = response.actionIdentifier == Self.addAction
            || response.actionIdentifier == UNNotificationDefaultActionIdentifier
        await handler(url, add)
    }
}

extension ToolLead {
    /// 通知とバナーの見出し。**種別ごとに別のキーにする** — 一覧の見出し（複数形）を
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

/// 通知が許可されていないときにウィンドウ内へ出す帯。**機能を完全に死なせない**。
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
