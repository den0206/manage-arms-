import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.9 — MCP だけが「今この瞬間の状態」を持つ。
@Suite("MCP の実行中検出")
struct ProcessTests {

    /// 実機の `ps -eo pid,ppid,etime,command` から採った実物（10.5）。
    static let sample = """
      PID  PPID     ELAPSED COMMAND
    87070     1    19:02:11 /Applications/Cursor.app/Contents/MacOS/Cursor
    87139 87070       18:58 Cursor Helper: mcp-process
    87431 87139       18:54 npm exec chrome-devtools-mcp@latest --autoConnect
    87446 87431       18:54 chrome-devtools-mcp
    87447 87446       18:54 /Applications/Cursor.app/Contents/Resources/app/resources/helpers/node /Users/x/.npm/_npx/15c/node_modules/chrome-devtools-mcp/build/src/telemetry/watchdog/main.js --parent-pid=87446
    87480 87458       01:20 claude
    87383 87138       18:10 /Users/x/.cursor/extensions/openai.chatgpt-26.825/bin/macos-aarch64/codex -c features.code_mode_host=true app-server
    """

    static func server(_ name: String, _ command: String, _ args: [String]) -> MCPServer {
        MCPServer(name: name, transport: .stdio(command: command, args: args, env: [:]))
    }

    // MARK: - ps の解析（10.1）

    @Test("ヘッダを落として 7 行読む")
    func parsesPS() {
        let rows = ProcessScanner.parse(Self.sample)
        #expect(rows.count == 7)
        #expect(rows[0].pid == 87070)
        #expect(rows[0].ppid == 1)
        #expect(rows[0].elapsed == "19:02:11")
        // コマンドは空白を含む。切り詰めてはいけない。
        #expect(rows[1].command == "Cursor Helper: mcp-process")
        #expect(rows[2].command.hasPrefix("npm exec chrome-devtools-mcp@latest"))
    }

    @Test("壊れた出力でも落ちない", arguments: ["", "PID PPID ELAPSED COMMAND", "abc def ghi jkl", "1 2 3"])
    func toleratesGarbage(_ text: String) {
        #expect(ProcessScanner.parse(text).isEmpty)
    }

    // MARK: - 所属エージェントの特定

    @Test("親を辿って Cursor に行き着く")
    func findsOwner() throws {
        let rows = ProcessScanner.parse(Self.sample)
        let running = ProcessScanner.running(
            [Self.server("chrome-devtools", "npx", ["-y", "chrome-devtools-mcp@latest"])],
            in: rows)
        let found = try #require(running["chrome-devtools"])
        #expect(found.owner == .cursor)
        // npm exec → 本体 → watchdog の数珠つなぎのうち、起点を採る
        #expect(found.pid == 87431)
        #expect(found.elapsed == "18:54")
    }

    /// Codex は Cursor の拡張の中に入っていることがある（実測）。
    /// パスに `cursor` が含まれるからと Cursor 判定すると取り違える。
    @Test("実行ファイル名を優先して Codex を Cursor と誤認しない")
    func executableNameWins() {
        let codexInCursor =
            "/Users/x/.cursor/extensions/openai.chatgpt-26.825/bin/macos-aarch64/codex -c x app-server"
        #expect(ProcessScanner.agent(ofCommand: codexInCursor) == .codex)
        #expect(ProcessScanner.agent(ofCommand: "claude") == .claude)
        #expect(ProcessScanner.agent(ofCommand: "Cursor Helper: mcp-process") == .cursor)
        #expect(ProcessScanner.agent(ofCommand:
            "/Applications/Cursor.app/Contents/MacOS/Cursor") == .cursor)
        #expect(ProcessScanner.agent(ofCommand: "/usr/bin/some-random-daemon") == nil)
    }

    @Test("親が居なくても落ちず、所属不明として返す")
    func orphanProcess() throws {
        let rows = ProcessScanner.parse("""
        99001 99999       10:00 chrome-devtools-mcp
        """)
        let running = ProcessScanner.running(
            [Self.server("chrome-devtools", "npx", ["-y", "chrome-devtools-mcp@latest"])],
            in: rows)
        #expect(try #require(running["chrome-devtools"]).owner == nil)
    }

    @Test("親子が循環していても抜けられる")
    func cyclicParents() {
        let rows = [
            ProcessRow(pid: 1001, ppid: 1002, elapsed: "1:00", command: "chrome-devtools-mcp"),
            ProcessRow(pid: 1002, ppid: 1001, elapsed: "1:00", command: "something-else"),
        ]
        #expect(ProcessScanner.owner(of: rows[0], in: rows) == nil)
    }

    // MARK: - 照合の精度

    @Test("起動していないサーバーは載らない")
    func notRunning() {
        let rows = ProcessScanner.parse(Self.sample)
        let running = ProcessScanner.running(
            [Self.server("supabase", "npx", ["-y", "supabase-mcp-server"])], in: rows)
        #expect(running.isEmpty)
    }

    /// **共通語で照合してはいけない。** `npx` や `node` で当てると
    /// 無関係なプロセスに一致して「実行中」を誤表示する。
    @Test("npx / node のような共通語だけのサーバーは一致させない")
    func genericTokensAreIgnored() {
        // 手掛かりが `npx` と `-y` しか無ければ、残るのはサーバー名だけ
        #expect(ProcessScanner.signatures(of: Self.server("weather", "npx", ["-y"])) == ["weather"])
        let rows = ProcessScanner.parse(Self.sample)
        #expect(ProcessScanner.running([Self.server("weather", "npx", ["-y"])], in: rows).isEmpty)

        // 3 文字以下は落とす（"." や "uv" が全部に一致してしまう）。
        // 手掛かりが 1 つも残らなければ**照合しない** — 誤って「実行中」と出すより無害。
        #expect(ProcessScanner.signatures(of: Self.server("ab", "uv", ["."])).isEmpty)
        #expect(ProcessScanner.running([Self.server("ab", "uv", ["."])], in: rows).isEmpty)
    }

    @Test("@latest を落として照合する")
    func stripsVersion() {
        #expect(ProcessScanner.stripVersion("chrome-devtools-mcp@latest") == "chrome-devtools-mcp")
        #expect(ProcessScanner.stripVersion("chrome-devtools-mcp@1.4.2") == "chrome-devtools-mcp")
        #expect(ProcessScanner.stripVersion("chrome-devtools-mcp") == "chrome-devtools-mcp")
        // スコープ付きパッケージの先頭 @ は落とさない
        #expect(ProcessScanner.stripVersion("@scope/pkg") == "@scope/pkg")
        #expect(ProcessScanner.stripVersion("@scope/pkg@2.0.0") == "@scope/pkg")
    }

    @Test("HTTP の MCP は URL で照合する")
    func httpServer() {
        let server = MCPServer(name: "remote",
                               transport: .http(url: "https://example.com/mcp", headers: [:]))
        #expect(ProcessScanner.signatures(of: server).contains("https://example.com/mcp"))
    }

    /// `ps` が呼べない環境でも一覧は出さなければならない。
    @Test("ps が失敗しても空を返すだけ")
    func psFailureIsNotFatal() {
        let env = Environment.test(home: URL(filePath: "/tmp/fake-home"),
                                   run: { _ in throw Exec.Failure(command: [], code: 1, stderr: "") })
        #expect(ProcessScanner.snapshot(env: env).isEmpty)
    }
}
