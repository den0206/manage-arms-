import AppKit
import SwiftUI
import ManageArmsCore

@main
struct ManageArmsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                // 固定幅列の合計（名前 240 + 最終使用 96 + エージェント 4×108 + 更新 132
                // + 操作 84 + 余白 32 = 1016）を下回ると、右端の操作列が切れる。
                .frame(minWidth: 1160, minHeight: 480)
                // DESIGN.md 3.5 — FSEvents で監視せず、アクティブ化のたびに読み直す。
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification)) { _ in
                    model.reload()
                }
        }
        .windowToolbarStyle(.unified)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // DESIGN.md 3.5 — 常駐しない。閉じたらプロセスごと終了、アイドル時のメモリ消費 0。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
    var isEditingPermissions = false
    /// 権限は一覧とは別に読む。プロジェクトのパスが動的で `Source` に載らないため（8 章）。
    private(set) var permissions: [PermissionEntry] = []
    private(set) var duplicateCounts: [String: Int] = [:]
    var preview: UpdatePreview?

    init() { reload() }

    /// キャッシュしない（DESIGN.md 3.5）。毎回読み直す。
    /// 走査は数十ファイル + CLI 数回で終わるが、CLI が node 起動を伴うため
    /// メインスレッドは塞がない。
    func reload() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            let loaded = await Self.loadOffMain()
            inventory = loaded
            permissions = await Task.detached { PermissionScanner.scan(env: .live) }.value
            duplicateCounts = PermissionScanner.duplicates(permissions)
                .mapValues(\.count)
            isLoading = false
        }
    }

    /// 選択したエントリを消す（DESIGN.md 8 章）。
    /// 書き換えるのは `permissions` キーだけで、消す前の中身はバックアップされる（9 章）。
    func removePermissions(_ entries: [PermissionEntry]) {
        guard !entries.isEmpty, !isEditingPermissions else { return }
        isEditingPermissions = true
        do {
            try PermissionWriter.remove(entries, env: .live)
        } catch {
            errorMessage = "\(error)"
        }
        isEditingPermissions = false
        reload()
    }

    /// 有効/無効は全エージェント一括（DESIGN.md 3.2）。
    /// エージェント別の on/off は Cursor / Codex が共有ルートを直読みするため不可能。
    func toggle(_ row: ResourceRow) {
        do {
            var registry = Registry.load(env: .live)
            switch (row.kind, row.isDisabled) {
            case (.subagent, true):  try SubagentManager.enable(row.name, env: .live, registry: &registry)
            case (.subagent, false): try SubagentManager.disable(row.name, env: .live, registry: &registry)
            case (_, true):          try SkillManager.enable(row.name, env: .live, registry: &registry)
            case (_, false):         try SkillManager.disable(row.name, env: .live, registry: &registry)
            }
            reload()
        } catch {
            // 握り潰さず UI に出す。
            errorMessage = "\(error)"
        }
    }

    /// 明示的な「更新を確認」。起動時の自動チェックはしない（DESIGN.md 7.3）。
    func checkUpdates(force: Bool = true) {
        guard !isChecking else { return }
        isChecking = true
        Task {
            var registry = Registry.load(env: .live)
            let errors = await UpdateChecker.check(&registry, env: .live, force: force)
            try? registry.save(env: .live)
            if let failure = errors.values.compactMap({ $0 }).first {
                errorMessage = "\(failure)"
            }
            isChecking = false
            reload()
        }
    }

    /// 取得して差分を作るところまで。適用は確認後（7.4）。
    func showDiff(for row: ResourceRow) {
        guard let entry = inventory.registry.entry(named: row.name) else { return }
        Task {
            do {
                preview = try await Updater.preview(entry, env: .live,
                                                    registry: inventory.registry)
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    func applyPreview() {
        guard let preview else { return }
        do {
            var registry = Registry.load(env: .live)
            try Updater.apply(preview, env: .live, registry: &registry)
            self.preview = nil
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    func discardPreview() {
        preview?.discard()
        preview = nil
    }

    /// 明示的な「使用状況を分析」（DESIGN.md 3.9）。
    ///
    /// 初回は 140 MB のセッションログを全部読むため起動時には走らせない。
    /// 2 回目以降は前回以降に書かれたログだけの増分（実測 1.27 秒 → 0.001 秒）。
    func analyzeUsage() {
        guard !isAnalyzing else { return }
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
    func pin(_ row: ResourceRow) {
        guard !isPinning, row.kind == .mcp else { return }
        isPinning = true
        Task {
            defer { isPinning = false }
            // 行の情報ではなく設定を読み直す。押すまでの間に変わっているかもしれない。
            let byAgent = MCPScanner.scan(env: .live)
            guard let server = byAgent.values.flatMap({ $0 }).first(where: { $0.name == row.name })
            else { return }
            let owners = byAgent.filter { $0.value.contains { $0.name == row.name } }.map(\.key)
            do {
                try await MCPPin.pin(server, in: owners, env: .live)
                reload()
            } catch {
                errorMessage = "\(error)"
            }
        }
    }

    /// 上流が方針転換した時に更新を止める（7.4）。
    func togglePin(_ row: ResourceRow) {
        guard var entry = inventory.registry.entry(named: row.name) else { return }
        entry.pinned.toggle()
        do {
            var registry = Registry.load(env: .live)
            registry.upsert(entry)
            try registry.save(env: .live)
            reload()
        } catch {
            errorMessage = "\(error)"
        }
    }

    private nonisolated static func loadOffMain() async -> Inventory {
        await Task.detached { Inventory.load(env: .live) }.value
    }
}
