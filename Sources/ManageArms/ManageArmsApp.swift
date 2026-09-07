import AppKit
import SwiftUI
import ManageArmsCore

@main
struct ManageArmsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    /// メニューバーからウィンドウを開き直すための id。
    static let windowID = "main"

    @SwiftUI.Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: Self.windowID) {
            ContentView(model: model)
                // サイドバー 208 + 一覧。理想値は要約タイル 4 枚とエージェント 2 列が
                // そのまま入る幅にする（最小のままだと初回だけ窮屈に見える）。
                .frame(minWidth: 820, idealWidth: 1020, minHeight: 540, idealHeight: 720)
                // DESIGN.md 3.5 — FSEvents で監視せず、アクティブ化のたびに読み直す。
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.reload()
                }
        }
        .defaultSize(width: 1020, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("設定…") { showSettings() }.keyboardShortcut(",")
            }
        }

        // 常駐（DESIGN.md 3.5）。OFF なら項目ごと外れ、最後のウィンドウで終了する。
        MenuBarExtra(isInserted: .init(get: { model.staysInMenuBar },
                                       set: { model.setMenuBarResident($0) })) {
            MenuBarMenu(model: model)
        } label: {
            MenuBarIcon(alert: model.watcher.pending != nil)
        }

    }

    /// 設定はサイドバーの 1 画面。**別ウィンドウにしない** — 画面が 2 種類あると
    /// 「どっちで直したか」が分からなくなる。⌘, もそこへ飛ばす。
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: Self.windowID)
        model.pendingScreen = .settings
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 常駐が ON ならウィンドウを閉じても終了しない（DESIGN.md 3.5）。
    /// 閉じた時点で一覧は捨ててあるので、残るのはメニューバー項目とタイマーだけ。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !Registry.load(env: .live).staysInMenuBar
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // DMG や外付けから直接起動していたら /Applications への移動を促す。
        // 一覧を読む前に出す（移動して再起動するなら、その走査は無駄になる）。
        InstallLocationGuard.promptIfNeeded()
    }
}

@MainActor
@Observable
final class AppModel {
    private(set) var inventory = Inventory.empty
    private(set) var isLoading = false
    var errorMessage: String?
    var isChecking = false
    var isAnalyzing = false
    var isPinning = false
    var isMutating = false
    private var isRefreshingActivity = false
    /// 走査中に来た再読み込みの依頼。終わってから 1 回だけ流す。
    private var pendingReload = false
    private var pendingReloadForcesCLI = false
    var isCleaning = false
    /// 一括削除シートの中身。nil で閉じる。
    var cleanup: [CleanupItem]?
    var isEditingPermissions = false
    /// 権限は一覧とは別に読む。プロジェクトのパスが動的で `Source` に載らないため（8 章）。
    private(set) var permissions: [PermissionEntry] = []
    private(set) var duplicateCounts: [String: Int] = [:]
    var preview: UpdatePreview?
    /// ブラウザ検知（DESIGN.md 6 章）。ウィンドウが開いている間だけ動く。
    let watcher = BrowserWatcher()
    private(set) var detectsBrowserURLs = false
    /// メニューバー常駐（DESIGN.md 3.5）。
    private(set) var staysInMenuBar = true
    /// 外観（システム / ライト / ダーク）。
    private(set) var appearance = Appearance.system
    /// 検知から来た追加候補。ContentView が拾って AddSheet を開く。
    var incomingLead: ToolLead?
    /// メニューバー・⌘, から開きたい画面。ContentView が拾って切り替える。
    var pendingScreen: Screen?

    init() {
        let registry = Registry.load(env: .live)
        detectsBrowserURLs = registry.detectsBrowserURLs
        staysInMenuBar = registry.staysInMenuBar
        appearance = Appearance(stored: registry.appearance)
        appearance.apply()
        watcher.onAdd = { [weak self] in self?.incomingLead = $0 }
        watcher.onError = { [weak self] in self?.errorMessage = $0 }
        // 許可されずに止まったら、設定も OFF に戻す（ON なのに動かない状態を残さない）。
        watcher.onDisabled = { [weak self] in self?.setBrowserDetection(false) }
        watcher.setEnabled(detectsBrowserURLs)
        // 一覧はウィンドウが出てから読む（常駐だけの状態では走査しない）。
    }

    /// ブラウザ検知の ON/OFF。**保存するのは利用者が決めたことだけ**（4.1）。
    func setBrowserDetection(_ on: Bool) {
        detectsBrowserURLs = on
        watcher.setEnabled(on)
        save { $0.browserDetection = on ? nil : false }   // 既定値（ON）は書き出さない
    }

    /// メニューバー常駐の ON/OFF。OFF にしても今開いているウィンドウは閉じない
    /// （次に閉じたときからプロセスごと終了する）。
    func setMenuBarResident(_ on: Bool) {
        staysInMenuBar = on
        save { $0.menuBar = on ? nil : false }            // 既定値（ON）は書き出さない
    }

    /// 外観の切り替え。既定（システム）は書き出さない。
    func setAppearance(_ value: Appearance) {
        appearance = value
        value.apply()
        save { $0.appearance = value == .system ? nil : value.rawValue }
    }

    private func save(_ change: (inout Registry) -> Void) {
        do {
            var registry = try Registry.read(env: .live)
            change(&registry)
            try registry.save(env: .live)
        } catch { errorMessage = "\(error)" }
    }

    /// ウィンドウを閉じたら一覧を捨てる（DESIGN.md 3.5 / 9 章）。
    /// 常駐中に抱え続けてよいのは設定と検知の状態だけで、
    /// 一覧は次に開いたときにどうせ読み直す（キャッシュしない）。
    func releaseForBackground() {
        inventory = .empty
        permissions = []
        duplicateCounts = [:]
        cleanup = nil
        discardPreview()
        CLIScan.clear()          // CLI の結果も持ち越さない（3.5 の例外を閉じる）
    }

    /// ファイル走査はキャッシュしない（DESIGN.md 3.5）。毎回読み直す。
    /// CLI 呼び出しだけは `CLIScan` が数分間引く（3.5 が明示的に求めている）。
    ///
    /// `forceCLI` は明示的な再読み込みと、こちらが設定を書き換えた直後に立てる。
    /// **走っている最中の依頼は捨てない** — 捨てると、操作直後の `reload` が
    /// 進行中の走査と重なったときに一覧が古いまま残る。
    func reload(forceCLI: Bool = false) {
        guard !isLoading else {
            pendingReload = true
            pendingReloadForcesCLI = pendingReloadForcesCLI || forceCLI
            return
        }
        isLoading = true
        Task {
            let loaded = await Self.loadOffMain(forceCLI: forceCLI)
            inventory = loaded
            refreshActivity()
            permissions = await Task.detached {
                PermissionScanner.scan(projects: loaded.projectScan.projects, env: .live)
            }.value
            duplicateCounts = PermissionScanner.duplicates(permissions)
                .mapValues(\.count)
            isLoading = false
            if pendingReload {
                pendingReload = false
                let force = pendingReloadForcesCLI
                pendingReloadForcesCLI = false
                reload(forceCLI: force)
            }
        }
    }

    /// **ファイルを触る操作の共通形。** 実体の移動・コピーはディレクトリ丸ごとになるので、
    /// メインアクターの上でやると UI が止まる（`removeExisting` だけがこの形だった）。
    private func mutate(_ work: @escaping @Sendable () throws -> Void) {
        guard !isMutating else { return }
        isMutating = true
        Task {
            let failure = await Task.detached { () -> String? in
                do { try work(); return nil } catch { return "\(error)" }
            }.value
            if let failure { errorMessage = failure }   // 握り潰さず UI に出す
            isMutating = false
            reload(forceCLI: true)
        }
    }

    /// 選択したエントリを消す（DESIGN.md 8 章）。
    /// 書き換えるのは `permissions` キーだけで、消す前の中身はバックアップされる（9 章）。
    func removePermissions(_ entries: [PermissionEntry]) {
        guard !entries.isEmpty, !isEditingPermissions else { return }
        isEditingPermissions = true
        Task {
            let failure = await Task.detached { () -> String? in
                do { try PermissionWriter.remove(entries, env: .live); return nil }
                catch { return "\(error)" }
            }.value
            if let failure { errorMessage = failure }
            isEditingPermissions = false
            reload()
        }
    }

    /// 有効/無効は全エージェント一括（DESIGN.md 3.2）。
    /// エージェント別の on/off は Cursor / Codex が共有ルートを直読みするため不可能。
    func toggle(_ row: ResourceRow) {
        guard row.isManaged, !isChecking, !isAnalyzing else { return }
        mutate { try Inventory.toggle(row, env: .live) }
    }

    /// 一括削除（DESIGN.md 5.2）。**表示したコマンドをそのまま実行する** —
    /// 何が起きるかを画面と実行で食い違わせない。
    /// リポジトリの中のファイルは対象外（`isRemovalExecutable` が false）。
    func runCleanup(_ items: [CleanupItem]) {
        let targets = items.filter(\.executable)
        guard !targets.isEmpty, !isCleaning else { return }
        isCleaning = true
        Task {
            let failures = await Task.detached {
                Inventory.runCleanup(targets, env: .live)
            }.value
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            isCleaning = false
            cleanup = nil
            reload(forceCLI: true)
        }
    }

    /// 削除（DESIGN.md 8 章）。実体はゴミ箱へ移すので Finder から戻せる。
    /// registry に載っているものだけ — 他ツールが入れたものは WriteGuard が弾く。
    func remove(_ row: ResourceRow) {
        guard row.isManaged, !isChecking, !isAnalyzing else { return }
        mutate { _ = try Inventory.remove(row, env: .live) }
    }

    /// 明示的な「更新を確認」。起動時の自動チェックはしない（DESIGN.md 7.3）。
    func checkUpdates(force: Bool = true) {
        guard !isChecking, !isAnalyzing, !isMutating, !isPinning else { return }
        isChecking = true
        Task {
            guard var registry = try? Registry.read(env: .live) else {
                errorMessage = String(localized: "管理情報を読み取れません。設定を修復してから再試行してください。")
                isChecking = false
                return
            }
            let errors = await UpdateChecker.check(&registry, env: .live, force: force)
            do { try registry.save(env: .live) } catch { errorMessage = "\(error)" }
            if let failure = errors.values.compactMap({ $0 }).first {
                errorMessage = "\(failure)"
            }
            isChecking = false
            reload()
        }
    }

    /// 取得して差分を作るところまで。適用は確認後（7.4）。
    func showDiff(for row: ResourceRow) {
        guard let entry = inventory.registry.entry(named: row.name, kind: row.kind) else { return }
        Task {
            do {
                preview = try await Updater.preview(entry, env: .live,
                                                    registry: inventory.registry)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    /// 差分を確認したうえでの適用。**失敗したらシートを閉じない** —
    /// 閉じると staging への参照が切れ、一時ディレクトリを片付ける手が無くなる。
    func applyPreview() {
        guard let preview, !isMutating else { return }
        isMutating = true
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    var registry = try Registry.read(env: .live)
                    try Updater.apply(preview, env: .live, registry: &registry)
                    return nil
                } catch { return "\(error)" }
            }.value
            if let failure { errorMessage = failure } else { self.preview = nil }
            isMutating = false
            reload(forceCLI: true)
        }
    }

    func discardPreview() {
        preview?.discard()
        preview = nil
    }

    /// 明示的な「使用状況を分析」（DESIGN.md 3.9）。
    ///
    /// 初回は複数 Agent のセッションログを全部読むため起動時には走らせない。
    /// 2 回目以降は前回以降に書かれたログだけの増分（実測 2.54 秒 → 0.013 秒）。
    func analyzeUsage() {
        guard !isAnalyzing, !isChecking, !isMutating, !isPinning else { return }
        isAnalyzing = true
        Task {
            let loaded = Registry.load(env: .live)
            let registry = await Task.detached {
                UsageScanner.refreshed(loaded, env: .live)
            }.value
            do { try registry.save(env: .live) } catch { errorMessage = "\(error)" }
            isAnalyzing = false
            reload()
        }
    }

    /// `@latest` を今の最新版に固定する（DESIGN.md 7.2）。
    /// MCP に更新機能は無く、必要なのはこれ。
    func pin(_ row: ResourceRow, agent: Agent) {
        guard !isPinning, row.kind == .mcp else { return }
        isPinning = true
        Task {
            defer { isPinning = false }
            // 行の情報ではなく設定を読み直す。押すまでの間に変わっているかもしれない。
            do {
                guard let server = try MCPScanner.read(agent, env: .live).first(where: { $0.name == row.name }),
                      !server.isProtected else { throw MCPScanner.ReadFailure("MCPサーバーが見つからないか保護されています") }
                try await MCPPin.pin(server, in: [agent], env: .live)
                reload(forceCLI: true)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    /// 上流が方針転換した時に更新を止める（7.4）。
    func togglePin(_ row: ResourceRow) {
        let (name, kind) = (row.name, row.kind)
        // 行の情報ではなく registry を読み直す（`pin` と同じ理由）。
        mutate {
            var registry = try Registry.read(env: .live)
            guard var entry = registry.entry(named: name, kind: kind) else { return }
            entry.pinned.toggle()
            registry.upsert(entry)
            try registry.save(env: .live)
        }
    }

    /// エージェントを管理対象から外す / 戻す（DESIGN.md 3.7）。
    /// **ファイルには一切触れない** — 表示と走査の対象から外すだけ。
    func setAgent(_ agent: Agent, enabled: Bool) {
        updateAgent(agent) { $0.enabled = enabled }
    }

    /// `PATH` から CLI を見つけられない環境の逃げ道（3.7 の 4 番目）。
    /// 選ばせるのは実行ファイル 1 つだけ。ここで受け取ったパスは
    /// 次回以降の検出でそのまま `--version` に渡る。
    func chooseCLIPath(for agent: Agent) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "\(agent.displayName) の実行ファイルを選んでください")
        // npm / uv が入れる CLI は `~/.local/bin` や `~/.bun/bin` にいる。
        // 隠しディレクトリを開けないと、この逃げ道が一番必要な人に届かない。
        panel.showsHiddenFiles = true
        panel.directoryURL = ["/opt/homebrew/bin", "/usr/local/bin"]
            .first { FileManager.default.fileExists(atPath: $0) }
            .map { URL(filePath: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path(percentEncoded: false)
        guard FileManager.default.isExecutableFile(atPath: path) else {
            errorMessage = String(localized: "選んだファイルは実行できません。CLI 本体を選んでください。")
            return
        }
        updateAgent(agent) { $0.path = path }
    }

    func clearCLIPath(for agent: Agent) {
        updateAgent(agent) { $0.path = nil }
    }

    private func updateAgent(_ agent: Agent, _ change: (inout Registry.AgentSetting) -> Void) {
        do {
            var registry = try Registry.read(env: .live)
            registry.update(agent, change)
            try registry.save(env: .live)
            reload(forceCLI: true)      // 検出のやり直しを間隔で待たせない
        } catch { errorMessage = "\(error)" }
    }

    /// 走査から除く／戻す。保存順は誰も読まない（表示順は `ProjectScan` 側で整える）。
    func setProject(_ path: String, excluded: Bool) {
        do {
            var reg = try Registry.read(env: .live)
            reg.excludedProjects.removeAll { $0 == path }
            if excluded { reg.excludedProjects.append(path) }
            try reg.save(env: .live)
            reload()
        } catch { errorMessage = "\(error)" }
    }

    func refreshActivity() {
        guard !isRefreshingActivity else { return }
        isRefreshingActivity = true
        let definitions = inventory.mcpServers
        Task {
            let snapshot = await Task.detached { ProcessScanner.snapshot(env: .live) }.value
            // **エージェントごとに 1 回だけ突き合わせる。** 行ごとに呼ぶと
            // 行数 × サーバー数 × プロセス数 になる（実測 1155 プロセス・3 秒ごと）。
            let live = await Task.detached {
                definitions.mapValues { ProcessScanner.running($0, in: snapshot) }
            }.value
            for index in inventory.rows.indices {
                guard let owner = inventory.rows[index].ownerAgent,
                      inventory.rows[index].kind == .mcp else { continue }
                let match = live[owner]?[inventory.rows[index].name]
                // 所属を辿れなかったものは出さない。**間違った持ち主を名乗るのは
                // 分からないより悪い**（DESIGN.md 3.9）。
                inventory.rows[index].running = match?.owner == owner ? match : nil
            }
            isRefreshingActivity = false
        }
    }

    func removeExisting(_ row: ResourceRow, agent: Agent, project: String?, file: URL? = nil) {
        guard !isMutating, row.origin != .bundled else { return }
        isMutating = true
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    try Inventory.removeExisting(row, agent: agent, project: project,
                                                 file: file, env: .live)
                    return nil
                } catch { return "\(error)" }
            }.value
            if let failure { errorMessage = failure }
            isMutating = false
            reload(forceCLI: true)
        }
    }

    private nonisolated static func loadOffMain(forceCLI: Bool) async -> Inventory {
        await Task.detached { Inventory.load(env: .live, forceCLI: forceCLI) }.value
    }
}
