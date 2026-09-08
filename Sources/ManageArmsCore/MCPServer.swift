import Foundation

/// MCP サーバ 1 件。実測した 2 形式に対応する。
///   Claude:  {"type":"stdio","command":"npx","args":[...],"env":{}}
///   Cursor:  {"command":"npx","args":[...]}
public struct MCPServer: Equatable, Sendable {
    public let name: String
    public let transport: Transport
    public var isProtected = false
    public var enabled = true

    public enum Transport: Equatable, Sendable {
        case stdio(command: String, args: [String], env: [String: String])
        case http(url: String, headers: [String: String])
    }

    public var command: String? {
        if case .stdio(let c, _, _) = transport { return c }
        return nil
    }
    public var args: [String] {
        if case .stdio(_, let a, _) = transport { return a }
        return []
    }
    public var env: [String: String] {
        if case .stdio(_, _, let e) = transport { return e }
        return [:]
    }
    public var url: String? {
        if case .http(let u, _) = transport { return u }
        return nil
    }

    /// 1 行の要約。UI の説明欄に出す。
    public var summary: String {
        switch transport {
        case .stdio(let command, let arguments, _):
            return ([command] + Self.redacted(arguments)).joined(separator: " ")
        case .http(let address, _):
            guard var components = URLComponents(string: address) else { return "[redacted URL]" }
            components.user = nil
            components.password = nil
            components.query = components.query == nil ? nil : "[redacted]"
            components.fragment = nil
            return components.string ?? "[redacted URL]"
        }
    }

    static func redacted(_ arguments: [String]) -> [String] {
        let flags = Set(["--token", "--api-key", "--apikey", "--secret", "--password",
                         "--authorization", "-H", "--header"])
        var hideNext = false
        return arguments.map { argument in
            defer { hideNext = flags.contains(argument.lowercased()) }
            if hideNext { return "[redacted]" }
            let lower = argument.lowercased()
            if flags.contains(lower) { return argument }
            if flags.contains(where: { lower.hasPrefix($0 + "=") }) {
                return String(argument.prefix(while: { $0 != "=" })) + "=[redacted]"
            }
            if lower.hasPrefix("authorization:") { return "Authorization: [redacted]" }
            return argument
        }
    }

    /// `@latest` 指定は起動のたびに最新を取るため、アプリが更新する余地が無い。
    /// **サイレントに壊れる可能性があるのでピン留めを促す**（DESIGN.md 7.2）。
    public var floatingPackage: String? {
        for token in args where token.hasSuffix("@latest") {
            return String(token.dropLast("@latest".count))
        }
        if let command, command.hasSuffix("@latest") {
            return String(command.dropLast("@latest".count))
        }
        return nil
    }

    /// `{"name": {...}}` を解釈する。`url` があれば HTTP、無ければ stdio。
    public static func parse(name: String, _ raw: [String: Any]) -> MCPServer? {
        let object = (raw["transport"] as? [String: Any]) ?? raw
        var server: MCPServer

        if let url = object["url"] as? String {
            if let headers = object["headers"], !(headers is NSNull), !(headers is [String: String]) { return nil }
            server = MCPServer(name: name, transport: .http(
                url: url, headers: object["headers"] as? [String: String] ?? [:]))
        } else {
            guard let command = object["command"] as? String else { return nil }
            if let args = object["args"], !(args is NSNull), !(args is [String]) { return nil }
            if let env = object["env"], !(env is NSNull), !(env is [String: String]) { return nil }
            server = MCPServer(name: name, transport: .stdio(command: command,
                args: object["args"] as? [String] ?? [], env: object["env"] as? [String: String] ?? [:]))
        }
        server.isProtected = raw["isBuiltIn"] as? Bool == true || raw["managed"] as? Bool == true
        server.enabled = raw["enabled"] as? Bool ?? true
        return server
    }

    /// `{"mcpServers": {...}}` あるいは `{...}` から一括で読む。
    public static func parseAll(_ container: [String: Any]) -> [MCPServer] {
        let servers = (container["mcpServers"] as? [String: Any]) ?? container
        return servers.compactMap { name, value in
            guard let object = value as? [String: Any] else { return nil }
            return parse(name: name, object)
        }
        .sorted { $0.name < $1.name }
    }
}

/// 各 CLI に渡す引数を組み立てる。**純粋関数**にしてテストする（DESIGN.md 10.4）。
public enum MCPCommand {

    /// ⚠️ claude と gemini は既定スコープが local / project。
    /// ユーザー全体に入れるには `-s user` が要る（実測）。
    public static func add(_ server: MCPServer, to agent: Agent) -> [String]? {
        switch agent {
        case .claude: claudeAdd(server)
        case .gemini: geminiAdd(server)
        case .codex:  codexAdd(server)
        case .cursor: nil            // CLI が無い。mcp.json を直接編集する（3.1）
        }
    }

    public static func remove(_ name: String, from agent: Agent) -> [String]? {
        switch agent {
        case .claude: ["claude", "mcp", "remove", name, "-s", "user"]
        case .gemini: ["gemini", "mcp", "remove", name, "-s", "user"]
        case .codex:  ["codex", "mcp", "remove", name]
        case .cursor: nil
        }
    }

    /// `claude mcp add -s user <name> [-e K=V] -- <command> [args...]`
    /// `claude mcp add -s user <name> -t http <url> [-H h]`
    /// **名前は可変長の `-e` / `-H` より前に置く。** 後ろに置くと名前が
    /// 直前のフラグの値として食われる。
    static func claudeAdd(_ server: MCPServer) -> [String] {
        var argv = ["claude", "mcp", "add", "-s", "user", server.name]
        switch server.transport {
        case .stdio(let command, let args, let env):
            argv += env.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
            argv += ["--", command] + args      // Name must precede variadic -e.
        case .http(let url, let headers):
            argv += ["-t", "http", url]
            argv += headers.sorted { $0.key < $1.key }.flatMap { ["-H", "\($0.key): \($0.value)"] }
        }
        return argv
    }

    /// `gemini mcp add -s user <name> <commandOrUrl> [args...]`
    /// `--` を受けないので、コマンドと引数を位置引数で渡す。
    /// `claudeAdd` と同じく、名前は可変長の `-e` / `-H` より前に置く。
    static func geminiAdd(_ server: MCPServer) -> [String] {
        var argv = ["gemini", "mcp", "add", "-s", "user", server.name]
        switch server.transport {
        case .stdio(let command, let args, let env):
            argv += env.sorted { $0.key < $1.key }.flatMap { ["-e", "\($0.key)=\($0.value)"] }
            argv += [command] + args
        case .http(let url, let headers):
            argv += ["-t", "http", url]
            argv += headers.sorted { $0.key < $1.key }.flatMap { ["-H", "\($0.key): \($0.value)"] }
        }
        return argv
    }

    /// `codex mcp add [--env K=V] <NAME> (--url <URL> | -- <COMMAND>...)`
    static func codexAdd(_ server: MCPServer) -> [String] {
        var argv = ["codex", "mcp", "add"]
        switch server.transport {
        case .stdio(let command, let args, let env):
            argv += env.sorted { $0.key < $1.key }.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            argv += [server.name, "--", command] + args
        case .http(let url, _):
            argv += [server.name, "--url", url]     // ヘッダ指定のオプションは無い
        }
        return argv
    }

    // MARK: - `claude mcp add-json` の生成コマンド（AddSheet の MCP パネル）
    //
    // 貼られた JSON を **アプリからは書かない**（不変条件 1）。代わりに
    // `claude mcp add-json <name> '<json>'` を組み立ててコピーさせる。
    // 純粋関数にして単体テストする（DESIGN.md 10.4）。

    /// 生成結果。UI が「行き止まりにしない」ために、抽出した既定の名前も返す。
    public struct AddJSONCommand: Equatable, Sendable {
        public let name: String
        public let command: String
        public init(name: String, command: String) {
            self.name = name; self.command = command
        }
    }

    /// 入力 JSON を解釈して `claude mcp add-json <name> '<json>'` を作る。
    /// - Parameters:
    ///   - json: 貼られた文字列。次の 3 形の JSON を受ける:
    ///     - `{"mcpServers": {"<name>": {...}}}`
    ///     - `{"<name>": {"command": ..., ...}}` / `{"<name>": {"url": ..., ...}}`
    ///     - `{"command": ..., ...}` / `{"url": ..., ...}`（名前は override 必須）
    ///   - overrideName: 空でなければこの値を優先する。ユーザーが編集した名前用。
    /// - Returns: `nil` は「入力が JSON として壊れているか、名前を決められない」。
    public static func addJSONCommand(_ json: String, name overrideName: String? = nil) -> AddJSONCommand? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let (extractedName, payload) = extractServer(object)
        guard let payload else { return nil }
        let candidate = overrideName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = candidate.isEmpty ? (extractedName ?? "") : candidate
        guard !name.isEmpty else { return nil }
        // ソート済みキーで安定した出力にする（テストが順序に依存しないため）。
        // `.withoutEscapingSlashes` を必ず付ける — 既定は `/` を `\/` に化けさせるため、
        // URL が入る場合に `"https:\/\/…"` となり、コピー先のシェルで読めない見た目になる。
        guard let normalized = try? JSONSerialization.data(withJSONObject: payload,
                                                           options: [.sortedKeys,
                                                                     .withoutEscapingSlashes]),
              let jsonString = String(data: normalized, encoding: .utf8)
        else { return nil }
        // シェルのシングルクォート内では `'` を `'\''` に置換する（唯一のエスケープ経路）。
        let escapedJSON = jsonString.replacingOccurrences(of: "'", with: "'\\''")
        let escapedName = shellArg(name)
        return AddJSONCommand(name: name,
                              command: "claude mcp add-json \(escapedName) '\(escapedJSON)'")
    }

    /// 入力 JSON から (名前, サーバー定義) を抽出する。**純粋関数**。
    /// wrapper（`mcpServers`）→ 名前付き 1 件 → 素の定義、の順に見る。
    static func extractServer(_ object: [String: Any]) -> (name: String?, server: [String: Any]?) {
        if let servers = object["mcpServers"] as? [String: Any] {
            // 複数入っていても先頭の 1 件を扱う。UI 側で名前を編集すれば
            // 取り違えは避けられる（v1 の MCP 追加も 1 件ずつ）。
            let sorted = servers.sorted { $0.key < $1.key }
            guard let first = sorted.first, let dict = first.value as? [String: Any]
            else { return (nil, nil) }
            return (first.key, dict)
        }
        // {"command": ..., ...} / {"url": ..., ...}
        if object["command"] != nil || object["url"] != nil {
            return (nil, object)
        }
        // {"<name>": {"command": ...}} — 名前を key として持つ形。
        let sorted = object.sorted { $0.key < $1.key }
        if let first = sorted.first,
           let dict = first.value as? [String: Any],
           dict["command"] != nil || dict["url"] != nil {
            return (first.key, dict)
        }
        return (nil, nil)
    }

    /// シェルの 1 語として安全か判定してから引用する。`Inventory.arg` と同じ規則。
    /// 名前は他ツールの JSON 由来なので、素で埋めると任意コマンドを走らせる余地が残る。
    static func shellArg(_ word: String) -> String {
        let safe = !word.isEmpty && word.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "@._-+:/".contains($0))
        }
        return safe ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
