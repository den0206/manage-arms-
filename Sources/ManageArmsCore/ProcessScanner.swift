import Foundation

/// `ps` の 1 行。
public struct ProcessRow: Equatable, Sendable {
    public let pid: Int32
    public let ppid: Int32
    /// `etime` そのまま。`18:54` / `02:10:33` / `3-04:05:06`。
    /// 自前で秒に直さない — 表示にしか使わないうえ、書式が増えても壊れない。
    public let elapsed: String
    public let command: String

    public init(pid: Int32, ppid: Int32, elapsed: String, command: String) {
        self.pid = pid; self.ppid = ppid; self.elapsed = elapsed; self.command = command
    }
}

/// 実行中の MCP サーバー 1 件。
public struct RunningMCP: Equatable, Sendable {
    /// 親を辿って特定できたエージェント。辿り着けなければ `nil`。
    public let owner: Agent?
    public let elapsed: String
    public let pid: Int32
}

/// MCP が実際に起動しているかを見る。DESIGN.md 3.9。
///
/// **MCP だけが「今この瞬間の状態」を持つ。** Skills / Plugins には実行実体が無く、
/// 「使用中」は 1 ターンで消えるイベントにしかならない（そちらは `UsageScanner`）。
///
/// `ps` を 1 回叩くだけなので常駐もポーリングも要らない。
/// `didBecomeActive` の再スキャンに相乗りさせる（3.5 と衝突しない）。
public enum ProcessScanner {

    public static func snapshot(env: Environment) -> [ProcessRow] {
        guard let out = try? env.run(["ps", "-eo", "pid,ppid,etime,command"]) else { return [] }
        return parse(out)
    }

    /// `  87139 87070       18:58 Cursor Helper: mcp-process`
    /// コマンドは空白を含むので、先頭 3 列だけ切り出して残りを丸ごと使う。
    static func parse(_ output: String) -> [ProcessRow] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, omittingEmptySubsequences: true) {
                $0 == " " || $0 == "\t"
            }
            guard fields.count == 4,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1])
            else { return nil }                       // ヘッダ行はここで落ちる
            return ProcessRow(pid: pid, ppid: ppid,
                              elapsed: String(fields[2]), command: String(fields[3]))
        }
    }

    // MARK: - 登録済みサーバーとの突き合わせ

    /// 「MCP らしいプロセス」を当てにいくのではなく、**登録済みの設定から探す**。
    /// UI が答えたい問いは「この登録済みサーバーは動いているか」であって
    /// 「動いている MCP を全部挙げよ」ではない。
    public static func running(_ servers: [MCPServer], in rows: [ProcessRow])
        -> [String: RunningMCP]
    {
        var result: [String: RunningMCP] = [:]
        for server in servers {
            let tokens = signatures(of: server)
            guard !tokens.isEmpty else { continue }
            let matched = rows.filter { row in tokens.contains { row.command.contains($0) } }
            guard !matched.isEmpty else { continue }

            // 同じサーバーが npm exec → 本体 → watchdog と数珠つなぎになる（実測）。
            // 一致した集合の中で親を持たないものが起点で、稼働時間もそれが正しい。
            let pids = Set(matched.map(\.pid))
            let root = matched.first { !pids.contains($0.ppid) } ?? matched[0]
            result[server.name] = RunningMCP(
                owner: owner(of: root, in: rows), elapsed: root.elapsed, pid: root.pid)
        }
        return result
    }

    /// プロセスを一意に指す語。`npx -y chrome-devtools-mcp@latest` なら
    /// `chrome-devtools-mcp` が拾える。
    ///
    /// **`npx` や `-y` のような共通語で照合してはいけない** — 無関係なプロセスに当たる。
    /// 3 文字以下も切る（`.` や `uv` が全部に一致するため）。
    static func signatures(of server: MCPServer) -> [String] {
        var tokens: [String] = []
        for token in server.args where !token.hasPrefix("-") {
            tokens.append(stripVersion(token))
        }
        if let command = server.command {
            tokens.append(stripVersion((command as NSString).lastPathComponent))
        }
        if case .http(let url, _) = server.transport { tokens.append(url) }
        // サーバー名そのものは最後の手掛かり。設定に固有の語が無いことがある。
        tokens.append(server.name)
        return tokens.filter { $0.count > 3 && !generic.contains($0) }
    }

    /// パッケージ実行系はコマンド行に現れても対象を絞らない。
    static let generic: Set<String> = [
        "npx", "npm", "exec", "node", "uvx", "uv", "run", "python", "python3",
        "deno", "bunx", "docker", "pipx", "-y", "--yes", "latest",
    ]

    /// `chrome-devtools-mcp@latest` → `chrome-devtools-mcp`。
    /// スコープ付き（`@scope/pkg@1.2.3`）の先頭 `@` は落とさない。
    static func stripVersion(_ token: String) -> String {
        guard let at = token.lastIndex(of: "@"), at != token.startIndex else { return token }
        return String(token[token.startIndex..<at])
    }

    // MARK: - 所属エージェントの特定

    /// 親を辿ってエージェントに行き着くか見る。実測:
    /// `chrome-devtools-mcp` → `npm exec` → `Cursor Helper: mcp-process` → `Cursor.app`
    static func owner(of row: ProcessRow, in rows: [ProcessRow]) -> Agent? {
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var current: ProcessRow? = row
        var depth = 0
        while let node = current, depth < 24 {         // 循環しても抜けられるようにする
            if let agent = agent(ofCommand: node.command) { return agent }
            guard node.ppid > 1 else { return nil }
            current = byPID[node.ppid]
            depth += 1
        }
        return nil
    }

    /// **実行ファイル名を先に見る。** Codex は Cursor の拡張の中に入っていることがあり
    /// （実測: `~/.cursor/extensions/openai.chatgpt-…/bin/…/codex`）、
    /// パスに `cursor` が含まれるからと先に Cursor と判定すると取り違える。
    ///
    /// 手掛かりは `Agent.cliName` / `Agent.processMarkers` が持つ。
    /// ここでエージェント名を直書きすると、増えたぶんが黙って `nil` になる。
    static func agent(ofCommand command: String) -> Agent? {
        let executable = command.split(separator: " ").first.map(String.init) ?? command
        let name = (executable as NSString).lastPathComponent
        if let byCLI = Agent.allCases.first(where: { $0.cliName == name }) { return byCLI }
        return Agent.allCases.first { agent in
            agent.processMarkers.contains { command.contains($0) }
        }
    }
}
