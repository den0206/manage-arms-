import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.1 / 7.5 — 読むのは CLI の JSON、書き込みは CLI に委譲。
@Suite("プラグインの読み取り")
struct PluginScannerTests {

    /// 実測した `claude plugin list --json` の形。
    static let claudeJSON = """
    [
      {"id":"swift-lsp@claude-plugins-official","version":"1.0.0","scope":"user",
       "enabled":true,"installPath":"/x"},
      {"id":"ponytail@ponytail","version":"4.9.0","scope":"local","enabled":true,
       "projectPath":"/Users/y/Free-Projects/auto-free"},
      {"id":"ponytail@ponytail","version":"4.9.0","scope":"local","enabled":true,
       "projectPath":"/Users/y/Free-Projects/reborn"}
    ]
    """

    /// 実測した `codex plugin list --json` の形。
    /// `installPolicy` は Codex の既定プラグインに付く（`INSTALLED_BY_DEFAULT`）。
    static let codexJSON = """
    {"installed":[{"pluginId":"plugin-management@openai-curated-remote",
                   "name":"plugin-management","version":"0.1.0","enabled":true,
                   "installPolicy":"INSTALLED_BY_DEFAULT","authPolicy":"ON_USE"},
                  {"pluginId":"mine@my-marketplace",
                   "name":"mine","version":"0.2.0","enabled":true}],
     "available":[{"pluginId":"gmail@openai-curated-remote"}]}
    """

    static func env(marketplaces: String? = nil) throws -> Environment {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-plug-\(UUID().uuidString)")
        let dir = home.appending(path: ".claude/plugins")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let marketplaces {
            try marketplaces.write(to: dir.appending(path: "known_marketplaces.json"),
                                   atomically: true, encoding: .utf8)
        }
        return Environment.test(home: home, run: { command in
            if command.first == "claude" { return claudeJSON }
            if command.first == "codex" { return codexJSON }
            return ""
        })
    }

    @Test("両エージェントの導入済みを読む")
    func readsBoth() throws {
        let found = PluginScanner.scan(env: try Self.env())
        #expect(found.filter { $0.agent == .claude }.count == 3)
        #expect(found.filter { $0.agent == .codex }.count == 2)
        // available は導入済みではないので拾わない
        #expect(!found.contains { $0.id.hasPrefix("gmail") })
    }

    /// Codex の `openai-curated-remote` の 3 つはユーザーが入れたものではない。
    /// ユーザー全体に「削除」付きで並べると、消してもエージェントが入れ直す。
    @Test("installPolicy: INSTALLED_BY_DEFAULT は同梱として扱う")
    func defaultInstalledIsBundled() throws {
        let found = PluginScanner.scan(env: try Self.env()).filter { $0.agent == .codex }
        #expect(found.first { $0.id.hasPrefix("plugin-management") }?.isBundled == true)
        #expect(found.first { $0.id.hasPrefix("mine") }?.isBundled == false)
    }

    /// **このアプリ最大の見せ場**（5.2）。実測: ponytail が 5 プロジェクトに個別導入。
    @Test("同一プラグインの複数プロジェクト重複を検出する")
    func findsDuplicates() throws {
        let dupes = PluginScanner.duplicates(PluginScanner.scan(env: try Self.env()))
        #expect(dupes.keys.sorted() == ["ponytail@ponytail"])
        #expect(dupes["ponytail@ponytail"]?.count == 2)
        #expect(dupes["swift-lsp@claude-plugins-official"] == nil)   // user スコープは対象外
    }

    /// autoUpdate が付いているものは Claude Code が既に自動更新している。
    /// アプリが手を出すと二重管理になる（7.5）。
    @Test("marketplace の autoUpdate を拾う")
    func readsAutoUpdate() throws {
        let env = try Self.env(marketplaces: """
        {"ponytail":{"autoUpdate":true},"claude-plugins-official":{}}
        """)
        let found = PluginScanner.scan(env: env)
        #expect(found.first { $0.id == "ponytail@ponytail" }?.autoUpdate == true)
        #expect(found.first { $0.id.hasPrefix("swift-lsp") }?.autoUpdate == false)
    }

    @Test("CLI が失敗してもクラッシュしない")
    func survivesCLIFailure() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let env = Environment.test(home: home, run: { _ in
            throw Exec.Failure(command: [], code: 1, stderr: "boom")
        })
        #expect(PluginScanner.scan(env: env).isEmpty)
    }

    @Test("壊れた JSON でもクラッシュしない")
    func survivesMalformedJSON() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let env = Environment.test(home: home, run: { _ in "not json at all" })
        #expect(PluginScanner.scan(env: env).isEmpty)
    }

    @Test("プラグイン行は操作不可（各 CLI が管理する）")
    func rowsAreNotManaged() throws {
        let env = try Self.env()
        let rows = Inventory.pluginRows(env: env, agents: [
            .claude: .detected(version: "1", path: "/x"),
            .codex: .detected(version: "1", path: "/x"),
            .cursor: .detected(version: nil, path: nil),
            .gemini: .undetected,
        ])
        let ponytail = try #require(rows.first { $0.name == "ponytail@ponytail" })
        #expect(ponytail.isManaged == false)
        // 入れたのはユーザー自身。同梱扱いにしない（8 章）。
        #expect(ponytail.origin == .user)
        #expect(ponytail.detail.contains("2 プロジェクトに重複導入"))
        #expect(ponytail.state[.claude] == .explicit)
        #expect(ponytail.state[.gemini] == .unsupported)   // Gemini に Plugin は無い
    }
}
