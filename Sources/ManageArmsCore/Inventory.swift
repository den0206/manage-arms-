import Foundation

/// マトリクスの 1 行。DESIGN.md 5.2。
public struct ResourceRow: Identifiable, Sendable {
    public let name: String
    public let kind: Kind
    public let summary: String?
    public let detail: String
    public let state: [Agent: State]
    /// registry.json に載っている = manage-arms が管理している。
    /// 載っていないものは他ツール管理。表示のみで操作させない（9 章）。
    public let isManaged: Bool
    /// 実体が退避ディレクトリにある。
    public let isDisabled: Bool
    /// 更新状態（7.6）。
    public let update: UpdateStatus
    /// 最終使用日（3.9）。`nil` は「集計済みだが使用実績なし」。
    /// **未集計との区別は `Inventory.usageScannedAt` が持つ** — 混同させない（5.3）。
    public let lastUsed: Date?
    /// 実行中の MCP（3.9）。MCP 以外は常に `nil` — 他の種別には実行実体が無い。
    public let running: RunningMCP?
    /// `@latest` 指定でピン留めできる MCP（7.2）。
    /// MCP に「更新」は存在しないので、操作列にはこれを出す。
    public let canPin: Bool
    public var id: String { "\(kind.rawValue):\(name)" }

    /// 使用実績を観測できる行か。**読めるログは Claude のものだけ**（3.9）。
    ///
    /// `~/.cursor/skills-cursor/` にしか無いスキルを「未使用」と出すと嘘になる。
    /// Cursor は実際に使っているかもしれず、こちらに見えていないだけ。
    /// 3.7 の「未検出と非対応を混ぜない」と同じ誤りなので、観測範囲外は別扱いにする。
    public var usageObservable: Bool { state[.claude] == .explicit }

    public init(name: String, kind: Kind, summary: String?, detail: String,
                state: [Agent: State], isManaged: Bool, isDisabled: Bool,
                update: UpdateStatus = .unmanaged, lastUsed: Date? = nil,
                running: RunningMCP? = nil, canPin: Bool = false) {
        self.name = name; self.kind = kind; self.summary = summary; self.detail = detail
        self.state = state; self.isManaged = isManaged; self.isDisabled = isDisabled
        self.update = update; self.lastUsed = lastUsed
        self.running = running; self.canPin = canPin
    }

    /// DESIGN.md 4.2。`inherited` はプロジェクトスコープ表示用（v1 では未使用）。
    public enum State: Sendable {
        case absent       // ○ 未導入
        case inherited    // ◐ ユーザー全体から継承
        case explicit     // ● このスコープで明示
        case external     // ◆ 他ツール管理。表示のみ（9 章）
        case undetected   // · エージェント自体が未検出
        case unsupported  // — そのエージェントに種別が無い

        public var symbol: String {
            switch self {
            case .absent: "○"
            case .inherited: "◐"
            case .explicit: "●"
            case .external: "◆"
            case .undetected: "·"
            case .unsupported: "—"
            }
        }
    }
}

public struct Inventory: Sendable {
    public let agents: [Agent: Detection]
    public let rows: [ResourceRow]
    /// 表示に使う registry のスナップショット。更新操作の起点になる。
    public var registry = Registry()

    /// 使用実績をいつ集計したか。`nil` = 未集計。
    /// 「未集計」を「未使用」として出さないために要る（DESIGN.md 5.3）。
    public var usageScannedAt: Date? { registry.usage.scannedUpTo }

    public static let empty = Inventory(agents: [:], rows: [])

    public init(agents: [Agent: Detection], rows: [ResourceRow], registry: Registry = Registry()) {
        self.agents = agents
        self.rows = rows
        self.registry = registry
    }

    /// 読み取りだけで組み立てる。キャッシュしない（DESIGN.md 3.5）。
    public static func load(env: Environment, overrides: [Agent: String] = [:]) -> Inventory {
        let agents = Detector.detectAll(env: env, overrides: overrides)
        let registry = Registry.load(env: env)
        let used = registry.usage.lastUsed
        let rows = skillRows(env: env, agents: agents, registry: registry)
            + subagentRows(env: env, agents: agents, registry: registry)
            + pluginRows(env: env, agents: agents, used: used)
            + mcpRows(env: env, agents: agents, used: used)
        return Inventory(agents: agents, rows: rows, registry: registry)
    }

    /// 最終使用日を引く（DESIGN.md 3.9）。
    /// Plugin だけ表記が食い違う — 一覧上の id は `ponytail@ponytail`、
    /// ログ上は `ponytail:ponytail-review` の前半なので `@` の手前で引き直す（spike #15）。
    static func lastUsed(_ name: String, kind: Kind, used: [String: Date]) -> Date? {
        if let date = used[name] { return date }
        guard kind == .plugin, let base = name.split(separator: "@").first else { return nil }
        return used[String(base)]
    }

    static func skillRows(env: Environment, agents: [Agent: Detection], registry: Registry)
        -> [ResourceRow]
    {
        // 無効化したスキルは走査ルートから消えるので、退避先も併せて読む。
        // これが無いと再有効化する手段がなくなる（3.4 の Source に載せてある理由）。
        let parked = SkillScanner.scan(root: env.disabledStore, rootLabel: parkedLabel)
        return SkillScanner.grouped(SkillScanner.scan(env: env) + parked)
            .map { name, found in
                // リンク切れ・SKILL.md 欠落は「有効」にしない。
                // 退避中のものはどのエージェントからも見えない。
                let roots = Set(found.filter { $0.isLoadable && $0.root != parkedLabel }
                                     .map(\.root))
                var state: [Agent: ResourceRow.State] = [:]
                for agent in Agent.allCases {
                    state[agent] = cell(agent, kind: .skill,
                                        detection: agents[agent] ?? .undetected,
                                        visible: agent.sees(rootsContaining: roots))
                }
                return ResourceRow(
                    name: name,
                    kind: .skill,
                    summary: found.compactMap(\.description).first,
                    detail: detail(found),
                    state: state,
                    isManaged: registry.entry(named: name) != nil,
                    isDisabled: found.contains { $0.root == parkedLabel },
                    update: registry.entry(named: name)
                        .map { UpdateChecker.status(of: $0, in: registry) } ?? .unmanaged,
                    lastUsed: lastUsed(name, kind: .skill, used: registry.usage.lastUsed)
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// 「非対応」と「未検出」を混ぜない（DESIGN.md 3.7）。順序が意味を持つ。
    static func cell(_ agent: Agent, kind: Kind, detection: Detection, visible: Bool)
        -> ResourceRow.State
    {
        if !agent.supports(kind) { return .unsupported }   // 検出状態と独立
        if detection == .undetected { return .undetected }
        return visible ? .explicit : .absent
    }

    // MARK: - Subagents（DESIGN.md 3.2）

    static func subagentRows(env: Environment, agents: [Agent: Detection], registry: Registry)
        -> [ResourceRow]
    {
        let parked = SubagentScanner.scan(root: env.disabledAgentStore, rootLabel: parkedLabel)
        return Dictionary(grouping: SubagentScanner.scan(env: env) + parked, by: \.name)
            .map { name, found in
                let roots = Set(found.filter { $0.isLoadable && $0.root != parkedLabel }
                                     .map(\.root))
                var state: [Agent: ResourceRow.State] = [:]
                for agent in Agent.allCases {
                    state[agent] = cell(agent, kind: .subagent,
                                        detection: agents[agent] ?? .undetected,
                                        visible: !Set(agent.subagentRoots).isDisjoint(with: roots))
                }
                let entry = registry.entry(named: name)
                return ResourceRow(
                    name: name, kind: .subagent,
                    summary: found.compactMap(\.description).first,
                    detail: found.map(\.root).sorted().joined(separator: " / "),
                    state: state,
                    isManaged: entry?.kind == Kind.subagent.rawValue,
                    isDisabled: found.contains { $0.root == parkedLabel },
                    update: entry.map { UpdateChecker.status(of: $0, in: registry) } ?? .unmanaged,
                    lastUsed: lastUsed(name, kind: .subagent, used: registry.usage.lastUsed)
                )
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: - MCP

    static func mcpRows(env: Environment, agents: [Agent: Detection], used: [String: Date] = [:])
        -> [ResourceRow]
    {
        let byAgent = MCPScanner.scan(env: env)
        let names = Set(byAgent.values.flatMap { $0.map(\.name) })
        // 「登録されているのに起動していない」ズレは設定ファイルを見ても分からない（3.9）。
        let live = ProcessScanner.running(byAgent.values.flatMap { $0 },
                                          in: ProcessScanner.snapshot(env: env))
        return names.map { name in
            var state: [Agent: ResourceRow.State] = [:]
            for agent in Agent.allCases {
                state[agent] = cell(agent, kind: .mcp,
                                    detection: agents[agent] ?? .undetected,
                                    visible: byAgent[agent]?.contains { $0.name == name } ?? false)
            }
            let server = byAgent.values.flatMap { $0 }.first { $0.name == name }
            return ResourceRow(
                name: name, kind: .mcp,
                summary: server?.summary,
                detail: mcpDetail(server),
                state: state,
                // 各エージェントの設定が実体。registry には載せない（4.1）。
                isManaged: false,
                isDisabled: false,
                update: .unmanaged,
                lastUsed: lastUsed(name, kind: .mcp, used: used),
                running: live[name],
                canPin: server?.floatingPackage != nil
            )
        }
        .sorted { $0.name < $1.name }
    }

    /// MCP に更新機能は無い。必要なのはピン留め管理（DESIGN.md 7.2）。
    static func mcpDetail(_ server: MCPServer?) -> String {
        guard let server else { return "" }
        if let package = server.floatingPackage {
            return "⚠️ \(package)@latest — 起動ごとに最新を取得（サイレントに壊れる可能性）"
        }
        if case .http = server.transport { return "HTTP" }
        return "バージョン固定済み"
    }

    // MARK: - Plugins（読み取りのみ。書き込みは CLI に委譲。3.1）

    static func pluginRows(env: Environment, agents: [Agent: Detection],
                           used: [String: Date] = [:]) -> [ResourceRow] {
        let plugins = PluginScanner.scan(env: env)
        let duplicates = PluginScanner.duplicates(plugins)
        return Dictionary(grouping: plugins, by: \.id)
            .map { id, found in
                var state: [Agent: ResourceRow.State] = [:]
                for agent in Agent.allCases {
                    let installed = found.contains { $0.agent == agent && $0.enabled }
                    state[agent] = cell(agent, kind: .plugin,
                                        detection: agents[agent] ?? .undetected,
                                        visible: installed)
                }
                return ResourceRow(
                    name: id, kind: .plugin,
                    summary: found.first?.version.map { "v\($0)" },
                    detail: pluginDetail(id, found, duplicates: duplicates),
                    state: state,
                    // Plugin は各 CLI が管理する。アプリは registry に載せない（4.1）。
                    isManaged: false,
                    isDisabled: false,
                    update: found.contains(where: \.autoUpdate) ? .unmanaged : .unknown,
                    lastUsed: lastUsed(id, kind: .plugin, used: used)
                )
            }
            .sorted { $0.name < $1.name }
    }

    static func pluginDetail(_ id: String, _ found: [InstalledPlugin],
                             duplicates: [String: [InstalledPlugin]]) -> String {
        var parts: [String] = []
        if let dupes = duplicates[id] {
            parts.append("⚠️ \(dupes.count) プロジェクトに重複導入")
        } else if let scope = found.first?.scope {
            parts.append(scope == "user" ? "ユーザー全体" : "このプロジェクト")
        }
        if found.contains(where: \.autoUpdate) { parts.append("自動更新") }
        return parts.joined(separator: " · ")
    }

    static let parkedLabel = "無効化（退避中）"

    static func detail(_ found: [Skill]) -> String {
        found.map { skill in
            switch skill.status {
            case .ok: skill.root
            case .brokenLink: "\(skill.root)（リンク切れ）"
            case .noSkillFile: "\(skill.root)（SKILL.md なし）"
            case .truncatedFrontmatter: "\(skill.root)（frontmatter が 4 KB を超過）"
            case .missingFrontmatter: "\(skill.root)（frontmatter なし）"
            }
        }
        .sorted()
        .joined(separator: " / ")
    }
}
