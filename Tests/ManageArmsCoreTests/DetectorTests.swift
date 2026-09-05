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

    /// PATH 解決に失敗する環境の逃げ道（3.7 / 8 章）。
    @Test("手動パス指定が which より優先される")
    func overrideWins() throws {
        let home = try Self.fakeHome(configDirs: [])
        let env = Environment.test(home: home, run: Self.fakeRun(available: [:]))
        let result = Detector.detect(.codex, env: env, override: "/custom/codex")
        #expect(result == .detected(version: "1.2.3", path: "/custom/codex"))
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
