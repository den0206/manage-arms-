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
    public var isBundled = false
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
        (try? read(.claude, env: env)) ?? []
    }

    public static func read(_ agent: Agent, env: Environment) throws -> [InstalledPlugin] {
        guard agent == .claude || agent == .codex else { return [] }
        let output = try env.run([agent.cliName!, "plugin", "list", "--json"])
        let object = try JSONSerialization.jsonObject(with: Data(output.utf8))
        let list = agent == .claude ? object as? [[String: Any]] : (object as? [String: Any])?["installed"] as? [[String: Any]]
        guard let list else { throw MCPScanner.ReadFailure("Pluginの一覧をCLIから読み取れません") }
        let auto = autoUpdateMarketplaces(env: env)
        return try list.map { item in
            guard let id = item[agent == .claude ? "id" : "pluginId"] as? String else {
                throw MCPScanner.ReadFailure("Pluginの識別子がありません")
            }
            var plugin = InstalledPlugin(id: id, agent: agent, version: item["version"] as? String,
                scope: item["scope"] as? String ?? "user", projectPath: item["projectPath"] as? String,
                enabled: item["enabled"] as? Bool ?? true,
                autoUpdate: auto.contains(String(id.split(separator: "@").last ?? "")))
            // Codex は自社の既定プラグイン（`openai-curated-remote` の 3 つ）に
            // `installPolicy: INSTALLED_BY_DEFAULT` を付けて返す。実測済み。
            // ユーザーが入れたものと混ぜない — 混ぜると自分で入れた分が埋もれ、
            // 消してもエージェントが入れ直すものに「削除」を出すことになる（3.2 / 8 章）。
            plugin.isBundled = item["isBuiltIn"] as? Bool == true || item["managed"] as? Bool == true
                || item["scope"] as? String == "managed"
                || item["installPolicy"] as? String == "INSTALLED_BY_DEFAULT"
            return plugin
        }
    }

    static func codex(env: Environment) -> [InstalledPlugin] { (try? read(.codex, env: env)) ?? [] }

    /// 同一プラグインが複数プロジェクトに個別インストールされている状態を見つける。
    /// **このアプリ最大の見せ場**（DESIGN.md 5.2）。
    /// 実測: `ponytail@ponytail` v4.9.0 が同一 commit のまま 5 プロジェクトに入っている。
    public static func duplicates(_ plugins: [InstalledPlugin]) -> [String: [InstalledPlugin]] {
        Dictionary(grouping: plugins.filter { $0.scope == "local" }, by: \.id)
            .filter { $0.value.count > 1 }
    }
}

public enum PluginManager {
    public static func add(_ selector: String, source: String = "", to agent: Agent, env: Environment) throws {
        guard [.claude, .codex].contains(agent), !selector.isEmpty, !selector.hasPrefix("-"),
              selector.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "@._-/".contains($0)) }) else {
            throw MCPScanner.ReadFailure("Claude CodeまたはCodexを選び、plugin@marketplace の形式で入力してください")
        }
        let cli = agent.cliName!
        if !source.isEmpty {
            guard !source.hasPrefix("-"), let url = URL(string: source),
                  url.scheme == "https", url.host != nil else {
                throw MCPScanner.ReadFailure("配布元はHTTPSのURLで入力してください")
            }
            _ = try env.run([cli, "plugin", "marketplace", "add", source])
        }
        _ = try env.run(agent == .claude
            ? [cli, "plugin", "install", selector, "-s", "user"]
            : [cli, "plugin", "add", selector])
        guard try PluginScanner.read(agent, env: env).contains(where: { $0.id == selector || $0.id.split(separator: "@").first.map(String.init) == selector }) else {
            throw MCPScanner.ReadFailure("CLIは成功しましたが、Pluginが見つかりません。一覧を更新してエージェント側を確認してください。")
        }
    }

    /// 削除したはずの 1 件を指す述語。実行前後で同じものを見る。
    static func target(_ name: String, project: String?) -> (InstalledPlugin) -> Bool {
        { $0.id == name && $0.projectPath == project && (project != nil || $0.scope == "user") }
    }

    public static func remove(_ name: String, from agent: Agent, project: String? = nil, env: Environment) throws {
        let found = try PluginScanner.read(agent, env: env).filter(target(name, project: project))
        guard found.count == 1, let plugin = found.first, !plugin.isBundled,
              !name.hasPrefix("-") else { throw MCPScanner.ReadFailure("削除対象のPluginが見つからないか、複数該当するか、保護されています") }
        var argv = [agent.cliName!, "plugin", "remove", name]
        if agent == .claude {
            // `project` は `<proj>/.claude/settings.json` = git で共有されるファイル。
            // 消えたことに気づくのは別のマシンや他のメンバー（DESIGN.md 5.2 / 9 章）。
            // アプリが代わりに消してよいのは各 CLI 自身の領域だけ。
            guard ["user", "local"].contains(plugin.scope) else {
                throw MCPScanner.ReadFailure("プロジェクト共有のPluginはアプリからは削除しません。コマンドを実行してください")
            }
            argv += ["-s", plugin.scope]
        }
        if let project {
            _ = try env.run(["sh", "-c", "cd " + ResourceRow.quote(project) + " && " + argv.map(ResourceRow.quote).joined(separator: " ")])
        } else {
            _ = try env.run(argv)
        }
        // **CLI の終了コードを信用しない。** エージェント既定の Plugin は
        // `codex plugin remove` が成功を返しても消えない（実測）。保護メタデータの
        // 名前を当てにいくと、新しい印が付いた瞬間にまた「消えない削除」を出す。
        // どの CLI でも効く保証は、消えたことをもう一度読んで確かめること（3.1）。
        // 読めなかったときは「消えていない」と決めつけない（`MCPManager.remove` と同じ）。
        if let remaining = try? PluginScanner.read(agent, env: env),
           remaining.contains(where: target(name, project: project)) {
            throw MCPScanner.ReadFailure("\(name) は削除されませんでした。エージェントが既定で入れているPluginの可能性があります")
        }
    }
}
