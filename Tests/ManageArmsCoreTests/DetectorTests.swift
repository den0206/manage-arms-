import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.1 — バージョン文字列パース。実測した 3 書式と失敗時の挙動。
@Suite("バージョン文字列パース")
struct VersionParsingTests {

    @Test("実測した書式", arguments: [
        ("2.1.236 (Claude Code)", "2.1.236"),   // claude --version
        ("codex-cli 0.153.2",     "0.153.2"),   // codex --version
        ("0.46.0",                "0.46.0"),    // gemini --version
        ("v1.2.3",                "1.2.3"),     // v 接頭辞
        ("tool 1.0",              "1.0"),       // 2 桁
        ("foo 1.2.3\nbar 9.9.9",  "1.2.3"),     // 1 行目だけ見る
    ])
    func parses(_ input: String, _ expected: String) {
        #expect(Detector.parseVersion(input) == expected)
    }

    @Test("パースできない入力は nil（検出済み・バージョン不明として扱う）", arguments: [
        "", "unknown", "no digits here", "1", "..", "1..2",
    ])
    func failsSoftly(_ input: String) {
        #expect(Detector.parseVersion(input) == nil)
    }
}

/// DESIGN.md 3.7 の 4 状態。偽ホームと偽 CLI だけを触る。
@Suite("エージェント検出")
struct DetectorTests {

    /// 一時ディレクトリに偽ホームを作る。実ユーザーの ~/.claude には到達しない。
    static func fakeHome(configDirs: [String]) throws -> URL {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        for dir in configDirs {
            try FileManager.default.createDirectory(
                at: home.appending(path: dir), withIntermediateDirectories: true)
        }
        return home
    }

    /// 指定した CLI だけが存在する偽 `run`。
    static func fakeRun(available: [String: String]) -> @Sendable ([String]) throws -> String {
        { command in
            if command.count == 2, command[0] == "which" {
                guard let path = available[command[1]] else {
                    throw Exec.Failure(command: command, code: 1, stderr: "")
                }
                return path + "\n"
            }
            if command.count == 2, command[1] == "--version" {
                return "1.2.3\n"
            }
            throw Exec.Failure(command: command, code: 127, stderr: "unexpected")
        }
    }

    @Test("CLI があれば検出済み + バージョン")
    func detected() throws {
        let home = try Self.fakeHome(configDirs: [".claude"])
        let env = Environment.test(home: home,
            run: Self.fakeRun(available: ["claude": "/opt/homebrew/bin/claude"]))
        #expect(Detector.detect(.claude, env: env)
                == .detected(version: "1.2.3", path: "/opt/homebrew/bin/claude"))
    }

    @Test("CLI が無く設定ディレクトリだけある → configOnly（既存リソースは読める）")
    func configOnly() throws {
        let home = try Self.fakeHome(configDirs: [".codex"])
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        #expect(Detector.detect(.codex, env: env) == .configOnly)
    }

    @Test("CLI も設定ディレクトリも無い → undetected")
    func undetected() throws {
        let home = try Self.fakeHome(configDirs: [])
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        #expect(Detector.detect(.gemini, env: env) == .undetected)
    }

    /// Cursor は CLI が無いことが正常。undetected にしてはいけない（8 章）。
    @Test("Cursor は設定ディレクトリだけで検出済みになる")
    func cursorNeedsNoCLI() throws {
        let home = try Self.fakeHome(configDirs: [".cursor"])
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        #expect(Detector.detect(.cursor, env: env) == .detected(version: nil, path: nil))
    }

    @Test("Cursor は設定ディレクトリが無ければ undetected")
    func cursorWithoutConfig() throws {
        let home = try Self.fakeHome(configDirs: [])
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        #expect(Detector.detect(.cursor, env: env) == .undetected)
    }

    /// PATH 解決に失敗する環境の逃げ道（3.7 / 8 章）。実在する実行ファイルのときだけ勝つ。
    @Test("手動パス指定が which より優先される")
    func overrideWins() throws {
        let home = try Self.fakeHome(configDirs: [])
        let env = Environment.test(home: home,
            run: Self.fakeRun(available: ["codex": "/from/path/codex"]))
        let result = Detector.detect(.codex, env: env, override: "/bin/echo")
        #expect(result == .detected(version: "1.2.3", path: "/bin/echo"))
    }

    /// 指定した実行ファイルが消えたら、無かったことにして `PATH` 解決に戻る。
    /// 「検出済み」のまま緑を出し続けるのが最悪（3.7）。
    @Test("消えた手動パスは無視して which に戻る")
    func staleOverrideFallsBackToPath() throws {
        let home = try Self.fakeHome(configDirs: [])
        let env = Environment.test(home: home,
            run: Self.fakeRun(available: ["codex": "/from/path/codex"]))
        let result = Detector.detect(.codex, env: env, override: "/opt/gone/codex")
        #expect(result == .detected(version: "1.2.3", path: "/from/path/codex"))
    }

    @Test("設定ディレクトリと同名のファイルは設定ありと見なさない")
    func fileIsNotConfigDir() throws {
        let home = try Self.fakeHome(configDirs: [])
        try Data().write(to: home.appending(path: ".codex"))
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        #expect(Detector.detect(.codex, env: env) == .undetected)
    }

    @Test("detectAll は全エージェントを返す")
    func detectAllCoversEveryAgent() throws {
        let home = try Self.fakeHome(configDirs: [".claude", ".cursor"])
        let env = Environment.test(home: home,
            run: Self.fakeRun(available: ["claude": "/bin/claude"]))
        let all = Detector.detectAll(env: env)
        #expect(all.count == Agent.allCases.count)
        #expect(all[.claude]?.isUsable == true)
        #expect(all[.cursor]?.isUsable == true)
        #expect(all[.codex] == .undetected)
        #expect(all[.gemini] == .undetected)
    }
}

/// 「非対応」と「未検出」を混ぜないための対応表（2 章 / 3.7）。
@Suite("リソース種別の対応")
struct SupportMatrixTests {

    @Test("Gemini は MCP のみ")
    func geminiOnlyMCP() {
        #expect(Agent.gemini.supports(.mcp))
        for kind in Kind.allCases where kind != .mcp {
            #expect(!Agent.gemini.supports(kind), "\(kind) は Gemini 非対応のはず")
        }
    }

    @Test("Codex は Subagents を持たない")
    func codexHasNoSubagents() {
        #expect(!Agent.codex.supports(.subagent))
        #expect(Agent.codex.supports(.skill))
    }

    @Test("Claude は全種別に対応")
    func claudeSupportsAll() {
        for kind in Kind.allCases { #expect(Agent.claude.supports(kind)) }
    }

    /// 非対応セルは検出状態に関係なく `—`。
    /// 「Gemini を入れれば Skills が使える」という誤解を生まないため。
    @Test("非対応は検出状態と独立している")
    func unsupportedIsIndependentOfDetection() {
        #expect(!Agent.gemini.supports(.skill))
    }
}

/// DESIGN.md 3.7 — 自動検出の上に乗るのは、利用者が決めた 2 つだけ
/// （管理対象にするか / CLI の在り処）。検出結果そのものは保存しない。
@Suite("エージェントの手動設定")
struct AgentSettingTests {

    static func env(_ registry: Registry) throws -> Environment {
        let home = try DetectorTests.fakeHome(configDirs: [".claude", ".codex"])
        let env = Environment.test(home: home,
            run: DetectorTests.fakeRun(available: ["claude": "/bin/claude"]))
        try registry.save(env: env)
        return env
    }

    /// 前のバージョンが書いた registry.json を読めること（4.1 の「欠けたキーは既定値」）。
    @Test("agents キーの無い registry.json は既定値で読める")
    func missingKeyDefaults() throws {
        let json = Data(#"{"resources":[],"projects":[],"repos":{}}"#.utf8)
        let registry = try Registry.decoder.decode(Registry.self, from: json)
        #expect(registry.agents.isEmpty)
        #expect(registry.setting(.claude).enabled)
        #expect(registry.setting(.claude).path == nil)
    }

    /// `enabled` を書かないエントリ（4.1 の記載例そのまま）。ここで落ちると
    /// `Registry.load` が空にフォールバックし、全リソースの出どころが飛ぶ。
    @Test("enabled の無いエントリは有効として読める")
    func partialSettingDefaults() throws {
        let json = Data(#"{"agents":{"codex":{"path":"/opt/homebrew/bin/codex"}}}"#.utf8)
        let registry = try Registry.decoder.decode(Registry.self, from: json)
        #expect(registry.setting(.codex).enabled)
        #expect(registry.setting(.codex).path == "/opt/homebrew/bin/codex")
    }

    /// 意味の無い行を registry.json に増やさない。
    @Test("既定値に戻した設定はファイルに残らない")
    func defaultsAreNotStored() {
        var registry = Registry()
        registry.update(.gemini) { $0.enabled = false }
        #expect(registry.agents["gemini"] == Registry.AgentSetting(enabled: false))
        registry.update(.gemini) { $0.enabled = true }
        #expect(registry.agents.isEmpty)
    }

    @Test("無効にしたエージェントは disabled になり、走査もしない")
    func disabledAgentIsNotScanned() throws {
        var registry = Registry()
        registry.update(.claude) { $0.enabled = false }
        let inventory = Inventory.load(env: try Self.env(registry))
        #expect(inventory.agents[.claude] == .disabled)
        #expect(inventory.mcpServers[.claude] == nil)
        // 「未検出」と混ぜない — CLI も設定も実在している。
        #expect(inventory.agents[.codex] == .configOnly)
    }

    @Test("手動指定した CLI パスが検出に使われる")
    func cliOverrideIsApplied() throws {
        var registry = Registry()
        registry.update(.codex) { $0.path = "/bin/echo" }
        #expect(registry.cliOverrides == [.codex: "/bin/echo"])
        let inventory = Inventory.load(env: try Self.env(registry))
        #expect(inventory.agents[.codex] == .detected(version: "1.2.3", path: "/bin/echo"))
    }

    /// アンインストールや Homebrew の移動で消えた指定を「検出済み」のまま出さない。
    /// 緑の表示のまま全操作が失敗するのが最悪の状態（3.7）。
    @Test("消えた手動指定は検出済みにしない")
    func staleCLIOverrideFallsBack() throws {
        var registry = Registry()
        registry.update(.codex) { $0.path = "/opt/gone/codex" }
        let inventory = Inventory.load(env: try Self.env(registry))
        #expect(inventory.agents[.codex] == .configOnly)   // ~/.codex はあるが CLI は無い
    }
}
