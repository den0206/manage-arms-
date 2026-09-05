import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.1 — MCP スキーマ変換。実測した 2 形式を押さえる。
@Suite("MCP のパース")
struct MCPParseTests {

    /// Claude（プロジェクトスコープ）の実データ。
    @Test("type / env 付きの stdio")
    func claudeShape() throws {
        let json = """
        {"chrome-devtools":{"type":"stdio","command":"npx",
         "args":["-y","chrome-devtools-mcp@latest","--autoConnect"],"env":{}}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let servers = MCPServer.parseAll(object)
        #expect(servers.count == 1)
        #expect(servers[0].name == "chrome-devtools")
        #expect(servers[0].command == "npx")
        #expect(servers[0].args == ["-y", "chrome-devtools-mcp@latest", "--autoConnect"])
    }

    /// Cursor の実データ。`type` も `env` も無い。
    @Test("最小形の stdio")
    func cursorShape() throws {
        let json = """
        {"mcpServers":{"chrome-devtools":{"command":"npx",
         "args":["-y","chrome-devtools-mcp@latest","--autoConnect"]}}}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        let servers = MCPServer.parseAll(object)
        #expect(servers.count == 1)
        #expect(servers[0].env.isEmpty)
        #expect(servers[0].summary == "npx -y chrome-devtools-mcp@latest --autoConnect")
    }

    @Test("url があれば HTTP")
    func httpShape() {
        let server = MCPServer.parse(name: "sentry", [
            "url": "https://mcp.sentry.dev/mcp",
            "headers": ["Authorization": "Bearer x"],
        ])
        #expect(server?.url == "https://mcp.sentry.dev/mcp")
        #expect(server?.command == nil)
    }

    @Test("command も url も無ければ解釈しない")
    func rejectsGarbage() {
        #expect(MCPServer.parse(name: "x", ["foo": "bar"]) == nil)
    }

    /// `@latest` は起動ごとに最新を取るので更新機能を作る余地が無い（7.2）。
    @Test("@latest を検出してピン留め対象にする")
    func detectsFloating() {
        let server = MCPServer(name: "x", transport: .stdio(
            command: "npx", args: ["-y", "chrome-devtools-mcp@latest"], env: [:]))
        #expect(server.floatingPackage == "chrome-devtools-mcp")
    }

    @Test("固定されていれば nil")
    func pinnedHasNoFloating() {
        let server = MCPServer(name: "x", transport: .stdio(
            command: "npx", args: ["-y", "chrome-devtools-mcp@1.4.2"], env: [:]))
        #expect(server.floatingPackage == nil)
    }
}

/// DESIGN.md 10.4 — CLI に渡す引数。特に `--` 以降の扱い。
@Suite("MCP コマンドの組み立て")
struct MCPCommandTests {

    static let stdio = MCPServer(name: "chrome-devtools", transport: .stdio(
        command: "npx", args: ["-y", "chrome-devtools-mcp@latest", "--autoConnect"],
        env: ["API_KEY": "x"]))
    static let http = MCPServer(name: "sentry", transport: .http(
        url: "https://mcp.sentry.dev/mcp", headers: ["Authorization": "Bearer t"]))

    /// ⚠️ claude / gemini の既定スコープは local / project。
    /// `-s user` を落とすとユーザー全体に入らない（実測）。
    @Test("claude はユーザースコープを明示し -- でコマンドを渡す")
    func claudeStdio() {
        #expect(MCPCommand.add(Self.stdio, to: .claude) == [
            "claude", "mcp", "add", "-s", "user", "-e", "API_KEY=x",
            "chrome-devtools", "--", "npx", "-y", "chrome-devtools-mcp@latest", "--autoConnect",
        ])
    }

    /// `--autoConnect` のように `-` で始まる引数があるため `--` の後に置くことが必須。
    @Test("ハイフン始まりの引数が -- の後に来る")
    func dashArgsAfterSeparator() {
        let argv = MCPCommand.add(Self.stdio, to: .claude)!
        let separator = argv.firstIndex(of: "--")!
        #expect(argv[separator...].contains("--autoConnect"))
        #expect(!argv[..<separator].contains("--autoConnect"))
    }

    @Test("gemini は -- を受けないので位置引数で渡す")
    func geminiStdio() {
        #expect(MCPCommand.add(Self.stdio, to: .gemini) == [
            "gemini", "mcp", "add", "-s", "user", "-e", "API_KEY=x",
            "chrome-devtools", "npx", "-y", "chrome-devtools-mcp@latest", "--autoConnect",
        ])
    }

    @Test("codex は --env と -- を使い、スコープ指定は無い")
    func codexStdio() {
        #expect(MCPCommand.add(Self.stdio, to: .codex) == [
            "codex", "mcp", "add", "--env", "API_KEY=x",
            "chrome-devtools", "--", "npx", "-y", "chrome-devtools-mcp@latest", "--autoConnect",
        ])
    }

    @Test("HTTP は transport とヘッダを付ける")
    func httpTransport() {
        #expect(MCPCommand.add(Self.http, to: .claude) == [
            "claude", "mcp", "add", "-s", "user", "-t", "http",
            "-H", "Authorization: Bearer t", "sentry", "https://mcp.sentry.dev/mcp",
        ])
        #expect(MCPCommand.add(Self.http, to: .codex) == [
            "codex", "mcp", "add", "sentry", "--url", "https://mcp.sentry.dev/mcp",
        ])
    }

    @Test("Cursor は CLI が無いので nil")
    func cursorHasNoCLI() {
        #expect(MCPCommand.add(Self.stdio, to: .cursor) == nil)
        #expect(MCPCommand.remove("x", from: .cursor) == nil)
    }

    @Test("削除もスコープを明示する")
    func remove() {
        #expect(MCPCommand.remove("x", from: .claude) == ["claude", "mcp", "remove", "x", "-s", "user"])
        #expect(MCPCommand.remove("x", from: .codex) == ["codex", "mcp", "remove", "x"])
    }
}

@Suite("MCP の走査と Cursor の直接編集")
struct MCPScannerTests {

    static func fixture(_ files: [String: String]) throws -> Environment {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-mcp-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        for (path, body) in files {
            let url = home.appending(path: path)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return Environment.test(home: home, run: { _ in "[]" })
    }

    @Test("4 エージェントぶんを読む")
    func scansAll() throws {
        let env = try Self.fixture([
            ".claude.json": #"{"numStartups":1,"mcpServers":{"a":{"command":"x"}}}"#,
            ".cursor/mcp.json": #"{"mcpServers":{"b":{"command":"y"}}}"#,
            ".gemini/settings.json": #"{"general":{},"mcpServers":{"c":{"url":"https://z"}}}"#,
        ])
        let found = MCPScanner.scan(env: env)
        #expect(found[.claude]?.map(\.name) == ["a"])
        #expect(found[.cursor]?.map(\.name) == ["b"])
        #expect(found[.gemini]?.map(\.name) == ["c"])
        #expect(found[.codex]?.isEmpty == true)
    }

    /// mcpServers キーが無いのは「未登録」であって異常ではない（実測: 両方とも無い）。
    @Test("キーが無くてもクラッシュしない")
    func missingKey() throws {
        let env = try Self.fixture([
            ".claude.json": #"{"numStartups":1}"#,
            ".gemini/settings.json": #"{"general":{}}"#,
        ])
        // #expect の中で allSatisfy を書くとマクロが rethrows と解釈して展開に失敗する
        let allEmpty = MCPScanner.scan(env: env).values.allSatisfy(\.isEmpty)
        #expect(allEmpty)
    }

    /// **`mcpServers` 以外のキーを壊さないこと。**
    @Test("Cursor の編集で他のキーが保たれる")
    func preservesOtherKeys() throws {
        let env = try Self.fixture([
            ".cursor/mcp.json": #"{"someOtherKey":42,"mcpServers":{"old":{"command":"o"}}}"#,
        ])
        let server = MCPServer(name: "new", transport: .stdio(
            command: "npx", args: ["-y", "pkg"], env: [:]))
        try MCPManager.add(server, to: .cursor, env: env)

        let data = try Data(contentsOf: env.home.appending(path: ".cursor/mcp.json"))
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(root["someOtherKey"] as? Int == 42)
        let servers = root["mcpServers"] as! [String: Any]
        #expect(Set(servers.keys) == ["old", "new"])
    }

    @Test("Cursor から削除できる")
    func removesFromCursor() throws {
        let env = try Self.fixture([
            ".cursor/mcp.json": #"{"mcpServers":{"a":{"command":"x"},"b":{"command":"y"}}}"#,
        ])
        try MCPManager.remove("a", from: .cursor, env: env)
        #expect(MCPScanner.scan(env: env)[.cursor]?.map(\.name) == ["b"])
    }

    @Test("ファイルが無くても追加できる")
    func createsFile() throws {
        let env = try Self.fixture([:])
        try MCPManager.add(MCPServer(name: "a", transport: .stdio(command: "x", args: [], env: [:])),
                           to: .cursor, env: env)
        #expect(MCPScanner.scan(env: env)[.cursor]?.map(\.name) == ["a"])
    }

    @Test("MCP 非対応のエージェントは無い（4 つとも対応）")
    func allSupportMCP() {
        for agent in Agent.allCases { #expect(agent.supports(.mcp)) }
    }
}
