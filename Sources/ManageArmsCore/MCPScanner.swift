import Foundation

public enum MCPScanner {

    /// 読み取りは設定ファイルの直読みを優先する。DESIGN.md 3.1 が禁じているのは**書き込み**で、
    /// `claude mcp list` は健全性チェックのため**ネットワークを叩いて遅い**うえ
    /// JSON 出力が無く、人間向けの整形テキストしか返さない（実測）。
    ///
    /// 読み取り先は `Agent.mcpSource` が持つ。**ここでエージェントを直書きしない** —
    /// 直書きすると、増えたエージェントが黙って欠落する（コンパイラが気づけない）。
    public static func scan(env: Environment) -> [Agent: [MCPServer]] {
        var result: [Agent: [MCPServer]] = [:]
        for agent in Agent.allCases {
            switch agent.mcpSource {
            case .file(let root, let path):
                let base = root == .home ? env.home : env.appSupport
                result[agent] = fromJSON(base.appending(path: path), key: "mcpServers")
            case .cli(let argv):
                result[agent] = fromCLI(argv, env: env)
            case .dir, nil:
                continue                         // 読み取る経路が無いエージェント
            }
        }
        return result
    }

    /// プロジェクト単位の MCP（DESIGN.md 5.1）。プロジェクトの絶対パス → サーバー名 → スコープ。
    ///
    ///   `<proj>/.mcp.json`                            … git 共有（`-s project`）
    ///   `~/.claude.json` の projects[path].mcpServers … そのマシンだけ（`-s local`）
    ///
    /// **スコープまで返すのは、削除コマンドに `-s` を正しく載せるため。**
    /// 取り違えるとユーザー全体の同名サーバーを消す。
    /// 承認済みか（`enabledMcpjsonServers`）までは見ない。登録の有無だけを出す。
    public static func byProject(env: Environment) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for path in Source.projectPaths(in: env) {
            for name in fromJSON(URL(filePath: path).appending(path: ".mcp.json"),
                                 key: "mcpServers").map(\.name) {
                out[path, default: [:]][name] = "project"
            }
        }
        // projects 配下は 98 KB の ~/.claude.json を 1 回だけ読んで拾う。
        if let data = try? Data(contentsOf: env.home.appending(path: ".claude.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = object["projects"] as? [String: Any] {
            for (path, value) in projects {
                let local = (value as? [String: Any])?["mcpServers"] as? [String: Any] ?? [:]
                for name in local.keys { out[path, default: [:]][name] = "local" }
            }
        }
        return out
    }

    static func fromJSON(_ url: URL, key: String) -> [MCPServer] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = object[key] as? [String: Any]
        else { return [] }                       // キーが無いのは正常（未登録）
        return MCPServer.parseAll(["mcpServers": servers])
    }

    /// 設定ファイルを直読みできないエージェント（Codex は `config.toml` で TOML パースが要る）。
    /// 出力は `[{...}]` と `{"name": {...}}` の両方を実測しているので、どちらも受ける。
    static func fromCLI(_ argv: [String], env: Environment) -> [MCPServer] {
        guard let out = try? env.run(argv),
              let data = out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data)
        else { return [] }
        if let array = list as? [[String: Any]] {
            return array.compactMap { item in
                guard let name = item["name"] as? String else { return nil }
                return MCPServer.parse(name: name, item)
            }.sorted { $0.name < $1.name }
        }
        if let object = list as? [String: Any] { return MCPServer.parseAll(object) }
        return []
    }
}

/// 追加 / 削除。3 エージェントは CLI に委譲し、Cursor だけ直接編集する（DESIGN.md 3.1）。
public enum MCPManager {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(Agent)
        case alreadyExists(String)
        public var description: String {
            switch self {
            case .unsupported(let a): "\(a.displayName) は MCP に対応していません"
            case .alreadyExists(let n): "\(n) は既に登録されています"
            }
        }
    }

    public static func add(_ server: MCPServer, to agent: Agent, env: Environment) throws {
        guard agent.supports(.mcp) else { throw Failure.unsupported(agent) }
        if agent == .cursor { return try editCursor(env: env) { $0[server.name] = encode(server) } }
        guard let argv = MCPCommand.add(server, to: agent) else { throw Failure.unsupported(agent) }
        _ = try env.run(argv)
    }

    public static func remove(_ name: String, from agent: Agent, env: Environment) throws {
        guard agent.supports(.mcp) else { throw Failure.unsupported(agent) }
        if agent == .cursor { return try editCursor(env: env) { $0.removeValue(forKey: name) } }
        guard let argv = MCPCommand.remove(name, from: agent) else {
            throw Failure.unsupported(agent)
        }
        _ = try env.run(argv)
    }

    // MARK: - Cursor だけ直接編集

    /// `~/.cursor/mcp.json` は MCP 専用の小さいファイルなので直接編集して安全（3.1）。
    /// `~/.claude.json`（98 KB・全状態が同居）とは事情が違う。
    /// **`mcpServers` 以外のキーは触らない。** 書き込みはアトミック。
    static func editCursor(env: Environment,
                           _ mutate: (inout [String: Any]) -> Void) throws {
        let url = env.home.appending(path: ".cursor/mcp.json")
        var root = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        mutate(&servers)
        root["mcpServers"] = servers

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    static func encode(_ server: MCPServer) -> [String: Any] {
        switch server.transport {
        case .stdio(let command, let args, let env):
            var object: [String: Any] = ["command": command, "args": args]
            if !env.isEmpty { object["env"] = env }
            return object
        case .http(let url, let headers):
            var object: [String: Any] = ["url": url]
            if !headers.isEmpty { object["headers"] = headers }
            return object
        }
    }
}
