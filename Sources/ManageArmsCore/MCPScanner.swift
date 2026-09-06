import Foundation

public enum MCPScanner {

    /// 読み取りは設定ファイルの直読みを優先する。DESIGN.md 3.1 が禁じているのは**書き込み**で、
    /// `claude mcp list` は健全性チェックのため**ネットワークを叩いて遅い**うえ
    /// JSON 出力が無く、人間向けの整形テキストしか返さない（実測）。
    ///
    /// 読み取り先は `Agent.mcpSource` が持つ。**ここでエージェントを直書きしない** —
    /// 直書きすると、増えたエージェントが黙って欠落する（コンパイラが気づけない）。
    public static func scan(env: Environment) -> [Agent: [MCPServer]] {
        Dictionary(uniqueKeysWithValues: Agent.allCases.map { ($0, (try? read($0, env: env)) ?? []) })
    }

    /// 走査・追加・削除の失敗を利用者に見せるための型。
    ///
    /// **`description` は UI にそのまま出るので必ずローカライズする。**
    /// `String` を返すプロパティは SwiftUI が自動で引かないので、
    /// ここで `String(localized:)` を通す（CLAUDE.md「ローカライズ」）。
    /// キーは日本語文字列そのもの。
    public struct ReadFailure: Error, CustomStringConvertible {
        public let description: String
        public init(_ key: String.LocalizationValue) { description = String(localized: key) }
    }

    public static func read(_ agent: Agent, env: Environment) throws -> [MCPServer] {
        switch agent.mcpSource {
        case .file(let root, let path):
            let url = (root == .home ? env.home : env.appSupport).appending(path: path)
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            guard let dictionary = object as? [String: Any] else { throw ReadFailure("MCP設定を読み取れません") }
            guard let servers = dictionary["mcpServers"] else { return [] }
            return try decode(servers)
        case .cli(let argv):
            let output = try env.run(argv)
            let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
            if let array = object as? [[String: Any]] {
                return try array.map { item in
                    guard let name = item["name"] as? String,
                          let server = MCPServer.parse(name: name, item) else { throw ReadFailure("MCPの一覧をCLIから読み取れません") }
                    return server
                }
            }
            if let dict = object as? [String: Any] { return try decode(dict["mcpServers"] ?? dict) }
            throw ReadFailure("MCPの一覧をCLIから読み取れません")
        default: return []
        }
    }

    static func decode(_ object: Any) throws -> [MCPServer] {
        guard let dict = object as? [String: Any] else { throw ReadFailure("MCPサーバー定義を読み取れません") }
        return try dict.sorted { $0.key < $1.key }.map { name, value in
            guard let item = value as? [String: Any], let server = MCPServer.parse(name: name, item) else {
                throw ReadFailure("MCPサーバー定義が不正です")
            }
            return server
        }
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
        try validate(server, for: agent)
        if agent == .cursor {
            return try editCursor(env: env) {
                guard $0[server.name] == nil else { throw Failure.alreadyExists(server.name) }
                $0[server.name] = encode(server)
            }
        }
        guard !(try MCPScanner.read(agent, env: env)).contains(where: { $0.name == server.name }) else {
            throw Failure.alreadyExists(server.name)
        }
        guard let argv = MCPCommand.add(server, to: agent) else { throw Failure.unsupported(agent) }
        _ = try env.run(argv)
    }

    public static func remove(_ name: String, from agent: Agent, env: Environment) throws {
        guard agent.supports(.mcp) else { throw Failure.unsupported(agent) }
        guard !name.isEmpty, !name.hasPrefix("-") else { throw MCPScanner.ReadFailure("MCP接続名が不正です") }
        if try MCPScanner.read(agent, env: env).contains(where: { $0.name == name && $0.isProtected }) {
            throw MCPScanner.ReadFailure("このMCPサーバーはエージェントが管理しています")
        }
        if agent == .cursor { return try editCursor(env: env) { $0.removeValue(forKey: name) } }
        guard let argv = MCPCommand.remove(name, from: agent) else {
            throw Failure.unsupported(agent)
        }
        _ = try env.run(argv)
        // CLI の終了コードを信用せず、消えたことを読んで確かめる（Plugin と同じ理由）。
        // **読めなかったときは「消えていない」と決めつけない。** ここで誤って投げると、
        // remove の直後に add する `MCPPin.pin` が復元前に中断し、
        // 消えたままになる。残っていると確認できたときだけ失敗にする。
        if let remaining = try? MCPScanner.read(agent, env: env),
           remaining.contains(where: { $0.name == name }) {
            throw MCPScanner.ReadFailure("\(name) は削除されませんでした。エージェントが管理している可能性があります")
        }
    }

    public static func removeProject(_ name: String, project: String, env: Environment) throws {
        guard !name.isEmpty, !name.hasPrefix("-"), let scope = ProjectScan.load(env: env).mcpScope(name, in: project) else {
            throw MCPScanner.ReadFailure("MCPの適用範囲が不明です。変更していません")
        }
        let url = scope == "project" ? URL(filePath: project).appending(path: ".mcp.json") : env.home.appending(path: ".claude.json")
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw MCPScanner.ReadFailure("プロジェクトのMCP設定を読み取れません")
        }
        if scope == "local" {
            guard let projects = root["projects"] as? [String: [String: Any]], let entry = projects[project] else {
                throw MCPScanner.ReadFailure("プロジェクトの設定が見つかりません")
            }
            root = entry
        }
        guard let servers = root["mcpServers"] as? [String: [String: Any]], let definition = servers[name],
              let server = MCPServer.parse(name: name, definition), !server.isProtected else {
            throw MCPScanner.ReadFailure("MCPサーバーが見つからないか保護されています")
        }
        let argv = ["claude", "mcp", "remove", name, "-s", scope]
        _ = try env.run(["sh", "-c", "cd " + ResourceRow.quote(project) + " && " + argv.map(ResourceRow.quote).joined(separator: " ")])
        // `byProject` は project と local を 1 つの表に畳むので、同名が両方にあると
        // 消した側の有無を nil では判定できない。**消したスコープが残っているか**で見る。
        guard MCPScanner.byProject(env: env)[project]?[name] != scope else {
            throw MCPScanner.ReadFailure("\(name) は削除されませんでした。エージェントが管理している可能性があります")
        }
    }

    public static func validate(_ server: MCPServer, for agent: Agent) throws {
        guard !server.isProtected else { throw MCPScanner.ReadFailure("このMCPサーバーはエージェントが管理しています") }
        guard !server.name.isEmpty, !server.name.hasPrefix("-"),
              server.name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) }) else {
            throw MCPScanner.ReadFailure("MCP接続名は英数字・ハイフン・アンダースコアで入力してください")
        }
        switch server.transport {
        case .http(let address, let headers):
            guard let url = URL(string: address), ["https", "http"].contains(url.scheme), url.host != nil else {
                throw MCPScanner.ReadFailure("MCPの接続先はHTTPまたはHTTPSのURLで入力してください")
            }
            if agent == .codex && !headers.isEmpty {
                throw MCPScanner.ReadFailure("Codex CLIはこのHTTPヘッダを登録できません。先にCodex側で認証を設定してください。")
            }
        case .stdio(let command, _, _):
            guard !command.isEmpty, !command.hasPrefix("-") else { throw MCPScanner.ReadFailure("MCPの起動コマンドを入力してください") }
        }
    }

    // MARK: - Cursor だけ直接編集

    /// `~/.cursor/mcp.json` は MCP 専用の小さいファイルなので直接編集して安全（3.1）。
    /// `~/.claude.json`（98 KB・全状態が同居）とは事情が違う。
    /// **`mcpServers` 以外のキーは触らない。** 書き込みはアトミック。
    static func editCursor(env: Environment,
                           _ mutate: (inout [String: Any]) throws -> Void) throws {
        let url = env.home.appending(path: ".cursor/mcp.json")
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
                throw MCPScanner.ReadFailure("Cursorの設定を読み取れません。変更していません")
            }
            root = decoded
        }
        if let existing = root["mcpServers"], !(existing is [String: Any]) {
            throw MCPScanner.ReadFailure("CursorのmcpServersを読み取れません。変更していません")
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        try mutate(&servers)
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
