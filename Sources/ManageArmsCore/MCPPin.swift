import Foundation

/// `@latest` のピン留め。DESIGN.md 7.2。
///
/// **MCP に必要なのは更新機能ではなくピン留め管理。**
/// `npx -y foo-mcp@latest` は起動のたびに npm から最新を取るため、
/// アプリが「更新」する余地が無い（押しても何も起きない偽ボタンになる）。
/// 代わりに、いま動いているバージョンに固定できるようにする。
public enum MCPPin {

    /// GUI からの入口。CLI による読み直しもメインアクターの外で行う。
    public static func pin(named name: String, in agent: Agent, env: Environment) async throws {
        let server = try await Task.detached {
            guard let server = try MCPScanner.read(agent, env: env).first(where: { $0.name == name }),
                  !server.isProtected else {
                throw MCPScanner.ReadFailure("MCPサーバーが見つからないか保護されています")
            }
            return server
        }.value
        try await pin(server, in: [agent], env: env)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFloating(String)
        case notNPM(String)
        case lookupFailed(String, Int)

        public var description: String {
            switch self {
            case .notFloating(let n):
                String(localized: "\(n) は既にバージョンが固定されています")
            case .notNPM(let n):
                String(localized: "\(n) は npm パッケージではないため、固定するバージョンを調べられません")
            case .lookupFailed(let p, let s):
                String(localized: "npm レジストリから \(p) の版を取得できませんでした（HTTP \(s)）")
            }
        }
    }

    /// `chrome-devtools-mcp@latest` → `chrome-devtools-mcp@1.8.0` に置き換えた新しい定義。
    /// **純粋関数**にしてテストする（10.1）。書き込みは呼び出し側。
    public static func pinned(_ server: MCPServer, to version: String) -> MCPServer? {
        guard case .stdio(let command, let args, let env) = server.transport,
              server.floatingPackage != nil
        else { return nil }
        return MCPServer(name: server.name, transport: .stdio(
            command: replacingLatest(command, with: version),
            args: args.map { replacingLatest($0, with: version) },
            env: env))
    }

    static func replacingLatest(_ token: String, with version: String) -> String {
        guard token.hasSuffix("@latest") else { return token }
        return String(token.dropLast("latest".count)) + version
    }

    /// npm レジストリの最新版。`GET /<pkg>/latest` は 5 KB 程度で済む（実測）。
    ///
    /// GitHub と違いレート制限は厳しくないが、**起動時には呼ばない**。
    /// ユーザーが「ピン留め」を押した時だけ 1 回（7.3 と同じ姿勢）。
    public static func latestVersion(ofPackage package: String, env: Environment) async throws
        -> String
    {
        let escaped = package.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? package
        guard let url = URL(string: "https://registry.npmjs.org/\(escaped)/latest") else {
            throw Failure.notNPM(package)
        }
        let result = try await env.httpGet(url, ["Accept": "application/json"])
        guard result.status == 200 else {
            throw Failure.lookupFailed(package, result.status)
        }
        guard let object = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              let version = object["version"] as? String
        else { throw Failure.lookupFailed(package, result.status) }
        return version
    }

    /// 調べて、置き換えて、登録し直す。
    ///
    /// **登録し直しは remove → add。** `claude mcp` に「差し替え」が無く、
    /// Cursor も `mcp.json` の当該キーを上書きするだけなので、どちらも同じ手順で済む。
    /// 失敗したら元の定義で登録し直す — 消えたままにしない。
    public static func pin(_ server: MCPServer, in agents: [Agent], env: Environment) async throws {
        guard !server.isProtected else { throw MCPScanner.ReadFailure("このMCPサーバーはエージェントが管理しています") }
        guard let package = server.floatingPackage else { throw Failure.notFloating(server.name) }
        let version = try await latestVersion(ofPackage: package, env: env)
        guard let updated = pinned(server, to: version) else {
            throw Failure.notFloating(server.name)
        }
        guard agents.count == 1, let agent = agents.first else {
            throw MCPScanner.ReadFailure("MCPの固定はエージェントを1つ選んでください")
        }
        try await Task.detached {
            try replace(server, with: updated, in: agent, env: env)
        }.value
    }

    private static func replace(_ server: MCPServer, with updated: MCPServer,
                                in agent: Agent, env: Environment) throws {
        if agent == .cursor {
            try MCPManager.editCursor(env: env) { servers in
                guard var definition = servers[server.name] as? [String: Any],
                      MCPServer.parse(name: server.name, definition) == server else {
                    throw MCPScanner.ReadFailure("MCP設定が変更されています。一覧を更新してから固定してください")
                }
                definition["command"] = updated.command
                definition["args"] = updated.args
                servers[server.name] = definition
            }
            return
        }
        try MCPManager.remove(server.name, from: agent, env: env)
        do {
            try MCPManager.add(updated, to: agent, env: env)
        } catch {
            let failure = error
            do { try MCPManager.add(server, to: agent, env: env) }
            catch { throw MCPScanner.ReadFailure("固定に失敗し、元の設定の復元にも失敗しました：\(String(describing: failure)) / \(String(describing: error))。元のMCP設定を手で登録し直してください。") }
            throw failure
        }
    }
}
