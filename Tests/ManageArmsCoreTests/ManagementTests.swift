import Foundation
import Testing
@testable import ManageArmsCore

@Suite("管理操作の回帰テスト")
struct ManagementTests {
    private func fixture(_ files: [String: String] = [:]) throws -> Environment {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: "management-\(UUID().uuidString)")
        let env = Environment.test(home: home)
        for (path, text) in files {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return env
    }

    @Test("同名SkillとSubagentの管理情報が独立する")
    func separateKinds() throws {
        var registry = Registry()
        registry.upsert(.init(name: "review", kind: .skill, repo: "a/skill"))
        registry.upsert(.init(name: "review", kind: .subagent, repo: "b/agent"))
        #expect(registry.resources.count == 2)
        #expect(registry.entry(named: "review", kind: .skill)?.repo == "a/skill")
        #expect(registry.entry(named: "review", kind: .subagent)?.repo == "b/agent")
    }

    @Test("壊れたCursor設定を追加操作で上書きしない", arguments: ["{", "[]", #"{"mcpServers":[]}"#])
    func preservesBrokenConfig(_ original: String) throws {
        let env = try fixture([".cursor/mcp.json": original])
        defer { try? FileManager.default.removeItem(at: env.home) }
        #expect(throws: (any Error).self) {
            try MCPManager.add(.init(name: "demo", transport: .stdio(command: "true", args: [], env: [:])), to: .cursor, env: env)
        }
        #expect(try String(contentsOf: env.home.appending(path: ".cursor/mcp.json"), encoding: .utf8) == original)
        #expect(throws: (any Error).self) { try MCPScanner.read(.cursor, env: env) }
    }

    @Test("既存の同名MCPを追加で上書きしない")
    func duplicateConnection() throws {
        let original = #"{"mcpServers":{"demo":{"command":"original","env":{"TOKEN":"original"}}}}"#
        let env = try fixture([".cursor/mcp.json": original])
        defer { try? FileManager.default.removeItem(at: env.home) }
        #expect(throws: MCPManager.Failure.alreadyExists("demo")) {
            try MCPManager.add(.init(name: "demo", transport: .stdio(command: "other", args: [], env: [:])), to: .cursor, env: env)
        }
        #expect(try String(contentsOf: env.home.appending(path: ".cursor/mcp.json"), encoding: .utf8) == original)
    }

    @Test("同名MCPをAgent別の行にしピン留めで他Agentを変更しない")
    func separatesAgents() async throws {
        let claude = #"{"mcpServers":{"demo":{"command":"npx","args":["a@latest"],"env":{"TOKEN":"claude"}}}}"#
        var env = try fixture([
            ".claude.json": claude,
            ".cursor/mcp.json": #"{"mcpServers":{"demo":{"command":"npx","args":["b@latest"],"env":{"TOKEN":"cursor"}}}}"#
        ])
        defer { try? FileManager.default.removeItem(at: env.home) }
        env.httpGet = { _, _ in .init(body: Data(#"{"version":"1.2.3"}"#.utf8), status: 200, headers: [:]) }
        let rows = Inventory.mcpRows(env: env, agents: [:])
        #expect(rows.filter { $0.name == "demo" }.count == 2)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let server = try #require(MCPScanner.read(.cursor, env: env).first)
        try await MCPPin.pin(server, in: [.cursor], env: env)
        #expect(try String(contentsOf: env.home.appending(path: ".claude.json"), encoding: .utf8) == claude)
        let updated = try #require(MCPScanner.read(.cursor, env: env).first)
        #expect(updated.args == ["b@1.2.3"])
        #expect(updated.env == ["TOKEN": "cursor"])
    }

    @Test("Codexの入れ子のtransportとnullの任意項目を読める")
    func nullableCLIFields() throws {
        let env = Environment.test(home: URL(filePath: "/unused"), run: { _ in
            #"[{"name":"demo","enabled":true,"transport":{"type":"stdio","command":"node","args":[],"env":null}}]"#
        })
        let server = try #require(MCPScanner.read(.codex, env: env).first)
        #expect(server.command == "node")
        #expect(server.env.isEmpty)
    }

    @Test("CLIエラーと未知の出力形式を未登録扱いにしない")
    func surfacesFailures() throws {
        let env = Environment.test(home: URL(filePath: "/unused"), run: { _ in #"{"newFormat":[]}"# })
        #expect(throws: (any Error).self) { try PluginScanner.read(.codex, env: env) }
        #expect(throws: (any Error).self) { try MCPScanner.read(.codex, env: env) }
    }

    @Test("引用符付きコマンド・HTTP・JSONを追加用に解釈する")
    func connectionInputs() throws {
        let command = try #require(PasteInput.mcpServers(#"npx -y demo --path "a b" --empty ''"#, name: "demo").first)
        #expect(command.args == ["-y", "demo", "--path", "a b", "--empty", ""])
        #expect(try PasteInput.mcpServers("https://example.com/mcp", name: "remote").first?.url == "https://example.com/mcp")
        #expect(try PasteInput.mcpServers(#"{"mcpServers":{"demo":{"command":"node","env":{"TOKEN":"x"}}}}"#, name: "").first?.env == ["TOKEN": "x"])
        #expect(throws: (any Error).self) { try PasteInput.mcpServers("npx demo; touch /tmp/no", name: "demo") }
        #expect(throws: (any Error).self) { try PasteInput.mcpServers("npx 'broken", name: "demo") }
    }

    @Test("同梱とPluginへのリンクを保護し既存のユーザーToolは削除対象にできる")
    func protectsBundled() throws {
        let env = try fixture([
            ".codex/skills/.system/builtin/SKILL.md": "built in",
            ".codex/skills/personal/SKILL.md": "personal",
            ".claude/plugins/cache/bundled/SKILL.md": "plugin"
        ])
        defer { try? FileManager.default.removeItem(at: env.home) }
        let builtin = env.home.appending(path: ".codex/skills/.system/builtin")
        let alias = env.home.appending(path: ".codex/skills/alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: builtin)
        #expect(throws: (any Error).self) { try WriteGuard.assertUserArtifact(builtin, kind: .skill, env: env) }
        #expect(throws: (any Error).self) { try WriteGuard.assertUserArtifact(alias, kind: .skill, env: env) }
        #expect(throws: (any Error).self) { try WriteGuard.assertUserArtifact(env.home.appending(path: ".codex/skills"), kind: .skill, env: env) }
        let personal = env.home.appending(path: ".codex/skills/personal")
        try WriteGuard.assertUserArtifact(personal, kind: .skill, env: env)
        let row = ResourceRow(name: "personal", kind: .skill, summary: nil, detail: "",
                              state: [:], origin: .user, isDisabled: false,
                              roots: [".codex/skills"])
        #expect(row.removableFiles(agent: .codex, env: env) == [personal])
        let trashed = try Inventory.removeExisting(row, agent: .codex, project: nil,
                                                   file: personal, env: env)
        defer { if let trashed { try? FileManager.default.removeItem(at: trashed) } }
        #expect(!FileManager.default.fileExists(atPath: personal.path))
        #expect(FileManager.default.fileExists(atPath: builtin.appending(path: "SKILL.md").path))
    }

    @Test("保護メタデータがあるMCPとPluginを削除しない")
    func protectsManagedMetadata() throws {
        let env = try fixture([".cursor/mcp.json": #"{"mcpServers":{"builtin":{"command":"node","managed":true}}}"#])
        defer { try? FileManager.default.removeItem(at: env.home) }
        #expect(throws: (any Error).self) { try MCPManager.remove("builtin", from: .cursor, env: env) }
        let calls = Recorder()
        let pluginEnv = Environment.test(home: env.home, run: { argv in
            calls.record(argv)
            return #"{"installed":[{"pluginId":"builtin@system","isBuiltIn":true}]}"#
        })
        #expect(throws: (any Error).self) { try PluginManager.remove("builtin@system", from: .codex, env: pluginEnv) }
        #expect(!calls.all.contains { $0.contains("remove") })
    }

    @Test("Codex Plugin削除には未対応のスコープ引数を付けない")
    func codexRemove() throws {
        let calls = Recorder()
        let env = Environment.test(home: URL(filePath: "/unused"), run: { argv in
            calls.record(argv)
            // 削除が効いた CLI を再現する（効かない側は PluginScannerTests）。
            let removed = calls.all.contains { $0.contains("remove") }
            return removed ? #"{"installed":[]}"# : #"{"installed":[{"pluginId":"demo@market"}]}"#
        })
        try PluginManager.remove("demo@market", from: .codex, env: env)
        #expect(calls.all.contains(["codex", "plugin", "remove", "demo@market"]))
        #expect(!calls.all.contains { $0.contains("-s") }, "Codex は -s を受け付けない")
    }

    @Test("無効化したSubagentの更新で同名Skillを変更しない")
    func updatesDisabledSubagent() throws {
        let env = try fixture([
            ".agents/skills/review/SKILL.md": "skill unchanged",
            "Library/Application Support/ManageArms/disabled-agents/review.md": "old agent",
            "staging/review.md": "new agent"
        ])
        defer { try? FileManager.default.removeItem(at: env.home) }
        var registry = Registry()
        registry.upsert(.init(name: "review", kind: .skill))
        registry.upsert(.init(name: "review", kind: .subagent, sha: "old", disabled: true))
        let root = env.home.appending(path: "staging")
        let candidate = Candidate(kind: .subagent, name: "review", description: nil, localURL: root.appending(path: "review.md"))
        let staging = Staging(root: root, source: .init(repo: "example/repo"), candidates: [candidate])
        let preview = UpdatePreview(name: "review", oldSha: "old", newSha: "new", staging: staging, candidate: candidate, diff: [])
        try Updater.apply(preview, env: env, registry: &registry)
        #expect(try String(contentsOf: env.disabledAgentStore.appending(path: "review.md"), encoding: .utf8) == "new agent")
        #expect(try String(contentsOf: env.skillStore.appending(path: "review/SKILL.md"), encoding: .utf8) == "skill unchanged")
        #expect(registry.entry(named: "review", kind: .subagent)?.sha == "new")
        #expect(registry.entry(named: "review", kind: .skill)?.sha == nil)
    }

    @Test("registry破損時は保存せず元の内容を保つ")
    func corruptRegistry() throws {
        let env = try fixture(["Library/Application Support/ManageArms/registry.json": "broken"])
        defer { try? FileManager.default.removeItem(at: env.home) }
        #expect(throws: (any Error).self) { try Registry().save(env: env) }
        #expect(try String(contentsOf: env.registryFile, encoding: .utf8) == "broken")
    }

    /// 許可ルートを走査と同じ集合にしていないと、一覧には出るのに
    /// 削除だけ「保護対象」と嘘をつく行ができる。
    @Test("サブディレクトリの .claude/skills も削除を許す")
    func nestedProjectArtifact() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let project = env.home.appending(path: "project")
        var registry = Registry()
        registry.projects = [project.path(percentEncoded: false)]
        try registry.save(env: env)

        let nested = project.appending(path: "apps/web/.claude/skills/deploy")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try WriteGuard.assertUserArtifact(nested, kind: .skill,
                                          project: project.path(percentEncoded: false), env: env)

        // スキルルートでない場所は従来どおり拒む。
        let elsewhere = project.appending(path: "apps/web/deploy")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try WriteGuard.assertUserArtifact(elsewhere, kind: .skill,
                                              project: project.path(percentEncoded: false), env: env)
        }
    }

    @Test("手動登録したプロジェクトをClaudeの履歴がなくても検出する")
    func explicitProject() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        var registry = Registry()
        registry.projects = [env.home.appending(path: "project").path]
        try registry.save(env: env)
        #expect(ProjectScan.projectPaths(in: env) == registry.projects)
    }

    /// ホームで `claude` を一度起動すると `~/.claude.json` にホーム自身が載る。
    /// これをプロジェクトとして歩くと、他の全プロジェクトの `.claude/skills` が
    /// 1 つの偽プロジェクトに吸い込まれる（実測 350 件・UI が固まる）。
    @Test("ホーム自身とルートはプロジェクトとして扱わない")
    func homeIsNotProject() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let home = env.home.standardized.path(percentEncoded: false)
        var registry = Registry()
        registry.projects = [home, home + "/", "/", env.home.appending(path: "real").path]
        try registry.save(env: env)
        #expect(ProjectScan.projectPaths(in: env) == [env.home.appending(path: "real").path])
    }

    /// 落としたものは設定画面に出すので、捨てずに返す必要がある。
    @Test("走査しない登録は無視せず持ち帰る")
    func reportsIgnoredProjects() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let home = env.home.standardized.path(percentEncoded: false)
        var registry = Registry()
        registry.projects = [home, "/", env.home.appending(path: "real").path]
        try registry.save(env: env)
        let scan = ProjectScan.load(env: env)
        #expect(scan.projects == [env.home.appending(path: "real").path])
        #expect(scan.ignoredProjects == ["/", home])
    }

    /// Cursor は `//` コメント入りの JSONC を受け付ける。**読めないと
    /// 「読み取りに失敗した項目があります」が出たまま MCP が一覧から消える。**
    @Test("コメント入りのCursor設定を読める")
    func readsCommentedConfig() throws {
        let env = try fixture([".cursor/mcp.json": """
        {
          "mcpServers": {
            // "Figma": {
            //   "url": "http://127.0.0.1:3845/mcp"
            // },
            "github": { "command": "npx", "args": ["-y", "pkg"] }
          }
        }
        """])
        defer { try? FileManager.default.removeItem(at: env.home) }
        let servers = try MCPScanner.read(.cursor, env: env)
        #expect(servers.map(\.name) == ["github"])
    }

    /// **読めても書き戻さない。** `JSONSerialization` で書くとコメントが復元されず、
    /// 利用者が意図的に残したコメントアウト済みの設定が消える。
    @Test("コメント入りのCursor設定は書き換えずに拒否する")
    func refusesToRewriteCommentedConfig() throws {
        let original = """
        {
          "mcpServers": {
            // "Figma": { "url": "http://127.0.0.1:3845/mcp" },
            "github": { "command": "npx", "args": ["-y", "pkg"] }
          }
        }
        """
        let env = try fixture([".cursor/mcp.json": original])
        defer { try? FileManager.default.removeItem(at: env.home) }
        #expect(throws: (any Error).self) {
            try MCPManager.add(.init(name: "demo", transport: .stdio(command: "true", args: [], env: [:])),
                               to: .cursor, env: env)
        }
        #expect(try String(contentsOf: env.home.appending(path: ".cursor/mcp.json"),
                           encoding: .utf8) == original)
    }

    /// 文字列の中の `//` はコメントではない。壊すと接続先を失う。
    @Test("URL の // をコメントとして落とさない")
    func keepsURLSlashes() {
        let text = #"{"url":"http://127.0.0.1:3845/mcp"}"#
        #expect(MCPScanner.stripComments(text) == text)
        #expect(MCPScanner.stripComments(#"{"a":"say \" // no"}"#) == #"{"a":"say \" // no"}"#)
        #expect(MCPScanner.stripComments(#"{"a":"x"} // tail"#) == #"{"a":"x"} "#)
        #expect(MCPScanner.stripComments("{/* c */\"a\":1}") == #"{"a":1}"#)
    }

    /// `excludedProjects` に入れたパスは走査されず `userIgnoredProjects` に出る。
    @Test("ユーザーが除外したプロジェクトは走査しないが一覧に残る")
    func userExcludedProjectIsSkipped() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let realPath = env.home.appending(path: "real").path(percentEncoded: false)
        let excludedPath = env.home.appending(path: "excluded").path(percentEncoded: false)
        var registry = Registry()
        registry.projects = [realPath, excludedPath]
        registry.excludedProjects = [excludedPath]
        try registry.save(env: env)
        let scan = ProjectScan.load(env: env)
        #expect(scan.projects == [realPath])
        #expect(scan.userIgnoredProjects == [excludedPath])
        #expect(scan.ignoredProjects.isEmpty)
    }

    /// `excludedProjects` が永続化→復元されること。
    @Test("除外リストがregistryに正しく永続化される")
    func excludedProjectsRoundTrip() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let path = env.home.appending(path: "proj").path(percentEncoded: false)
        var registry = Registry()
        registry.excludedProjects = [path]
        try registry.save(env: env)
        let loaded = Registry.load(env: env)
        #expect(loaded.excludedProjects == [path])
    }

    /// ホームは自動除外なので `excludedProjects` に入れても `autoIgnored` に分類される。
    @Test("ホームはユーザー除外でなく自動除外に分類される")
    func homeGoesToAutoIgnoredNotUserIgnored() throws {
        let env = try fixture()
        defer { try? FileManager.default.removeItem(at: env.home) }
        let home = env.home.standardized.path(percentEncoded: false)
        var registry = Registry()
        registry.projects = [home]
        registry.excludedProjects = [home]  // 万一ホームを除外リストに入れても安全か確認
        try registry.save(env: env)
        let scan = ProjectScan.load(env: env)
        #expect(scan.projects.isEmpty)
        #expect(scan.ignoredProjects == [home])
        #expect(scan.userIgnoredProjects.isEmpty)
    }
}
