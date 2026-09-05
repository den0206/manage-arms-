import Foundation

/// 導入済みプラグイン。DESIGN.md 3.1 に従い、**読むのは CLI の JSON 出力**で
/// 書き込みは `claude plugin` / `codex plugin` に委譲する。
public struct InstalledPlugin: Equatable, Sendable {
    public let id: String            // "name@marketplace"
    public let agent: Agent
    public let version: String?
    public let scope: String         // user / local
    public let projectPath: String?
    public let enabled: Bool
    /// marketplace 側で自動更新が有効。アプリは手を出さない（7.5）。
    public let autoUpdate: Bool
}

public enum PluginScanner {

    /// **エージェントを直書きせず `Agent.allCases` を回す。** `default` を置かないので、
    /// エージェントが増えたらここがコンパイルエラーになり、読み取り経路の要否を必ず決めさせる。
    public static func scan(env: Environment) -> [InstalledPlugin] {
        let auto = autoUpdateMarketplaces(env: env)
        return Agent.allCases.flatMap { agent -> [InstalledPlugin] in
            switch agent {
            case .claude: claude(env: env, autoUpdate: auto)
            case .codex:  codex(env: env)
            // Cursor は `~/.cursor/plugins/` を持つが読み取り経路が未実測（3.7 — 推測で埋めない）。
            case .cursor, .gemini: []
            }
        }
    }

    /// `~/.claude/plugins/known_marketplaces.json` の `autoUpdate` を拾う。
    /// これが true のプラグインは Claude Code が既に自動更新している（7.5）。
    static func autoUpdateMarketplaces(env: Environment) -> Set<String> {
        let url = env.home.appending(path: ".claude/plugins/known_marketplaces.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(object.compactMap { key, value in
            (value as? [String: Any])?["autoUpdate"] as? Bool == true ? key : nil
        })
    }

    static func claude(env: Environment, autoUpdate: Set<String>) -> [InstalledPlugin] {
        guard let out = try? env.run(["claude", "plugin", "list", "--json"]),
              let data = out.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let marketplace = id.split(separator: "@").last.map(String.init) ?? ""
            return InstalledPlugin(
                id: id, agent: .claude,
                version: item["version"] as? String,
                scope: item["scope"] as? String ?? "user",
                projectPath: item["projectPath"] as? String,
                enabled: item["enabled"] as? Bool ?? true,
                autoUpdate: autoUpdate.contains(marketplace)
            )
        }
    }

    /// Codex は `{"installed": [...], "available": [...]}`。導入済みだけ見る。
    static func codex(env: Environment) -> [InstalledPlugin] {
        guard let out = try? env.run(["codex", "plugin", "list", "--json"]),
              let data = out.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["installed"] as? [[String: Any]]
        else { return [] }
        return list.compactMap { item in
            guard let id = item["pluginId"] as? String else { return nil }
            return InstalledPlugin(
                id: id, agent: .codex,
                version: item["version"] as? String,
                scope: "user", projectPath: nil,
                enabled: item["enabled"] as? Bool ?? true,
                autoUpdate: false
            )
        }
    }

    /// 同一プラグインが複数プロジェクトに個別インストールされている状態を見つける。
    /// **このアプリ最大の見せ場**（DESIGN.md 5.2）。
    /// 実測: `ponytail@ponytail` v4.9.0 が同一 commit のまま 5 プロジェクトに入っている。
    public static func duplicates(_ plugins: [InstalledPlugin]) -> [String: [InstalledPlugin]] {
        Dictionary(grouping: plugins.filter { $0.scope == "local" }, by: \.id)
            .filter { $0.value.count > 1 }
    }
}
