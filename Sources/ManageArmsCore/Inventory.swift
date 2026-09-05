import Foundation

/// マトリクスの 1 行。DESIGN.md 5.2。
public struct ResourceRow: Identifiable, Sendable {
    public let name: String
    public let kind: Kind
    public let summary: String?
    public let detail: String
    public let state: [Agent: State]
    /// 出どころ（DESIGN.md 8 章）。**「自分で入れたもの」と「最初から入っていたもの」を混ぜない。**
    /// 混ぜると、ユーザーは自分が入れたはずのものを見つけられない。
    public let origin: Origin
    /// 実体が退避ディレクトリにある。
    public let isDisabled: Bool
    /// ユーザー全体か、特定のプロジェクトか（DESIGN.md 5.1 / 8 章）。
    public let reach: Reach
    /// 実体が置かれているルート（ホーム相対）。**読み込めないものも含む** —
    /// リンク切れは誰からも見えないので `state` からは追えず、
    /// これが無いと掃除すべきゴミが画面から消える。
    public let roots: [String]
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

    /// 表示順。種別ごとにまとめ、同じ種別なら名前順。
    public static func display(_ a: ResourceRow, _ b: ResourceRow) -> Bool {
        a.kind == b.kind ? a.name < b.name
            : (Kind.allCases.firstIndex(of: a.kind) ?? 0) < (Kind.allCases.firstIndex(of: b.kind) ?? 0)
    }

    /// 使用実績を観測できる行か。**読めるログは Claude のものだけ**（3.9）。
    ///
    /// `~/.cursor/skills-cursor/` にしか無いスキルを「未使用」と出すと嘘になる。
    /// Cursor は実際に使っているかもしれず、こちらに見えていないだけ。
    /// 3.7 の「未検出と非対応を混ぜない」と同じ誤りなので、観測範囲外は別扱いにする。
    public var usageObservable: Bool { state[.claude] == .explicit }

    public init(name: String, kind: Kind, summary: String?, detail: String,
                state: [Agent: State], origin: Origin, isDisabled: Bool,
                roots: [String] = [], reach: Reach = .user,
                update: UpdateStatus = .unmanaged, lastUsed: Date? = nil,
                running: RunningMCP? = nil, canPin: Bool = false) {
        self.name = name; self.kind = kind; self.summary = summary; self.detail = detail
        self.state = state; self.origin = origin; self.isDisabled = isDisabled
        self.roots = roots; self.reach = reach
        self.update = update; self.lastUsed = lastUsed
        self.running = running; self.canPin = canPin
    }

    /// どこで効いているか（DESIGN.md 5.1）。
    ///
    /// **`both` が散らかりの本体。** ユーザー全体に入っているのに
    /// プロジェクトにも個別に入っている状態で、実測では `ponytail@ponytail` が
    /// ユーザー全体 + 3 プロジェクトに同一バージョンで重複していた。
    public enum Reach: Sendable, Equatable {
        case user                  // ユーザー全体だけ
        case projects([String])    // 特定のプロジェクトだけ
        case both([String])        // ユーザー全体にもプロジェクトにも

        public var projectPaths: [String] {
            switch self {
            case .user: []
            case .projects(let p), .both(let p): p
            }
        }

        /// ユーザー全体にも入っているか。
        public var isUserWide: Bool {
            switch self {
            case .user, .both: true
            case .projects:    false
            }
        }

        static func make(user: Bool, projects: [String]) -> Reach {
            let sorted = Array(Set(projects)).sorted()
            if sorted.isEmpty { return .user }
            return user ? .both(sorted) : .projects(sorted)
        }
    }

    /// 出どころ（DESIGN.md 8 章）。
    public enum Origin: Sendable, Equatable {
        /// registry.json に載っている = このアプリで入れた。切り替えと削除ができる（9 章）。
        case managed
        /// ユーザーが自分で入れたが、経路が違う（`claude plugin install` / 他アプリ同梱など）。
        /// **消せないだけで「自分のもの」。** 管理は各 CLI に委譲する（3.1）。
        case user
        /// エージェントに最初から入っている（Cursor の automate など）。
        case bundled
    }

    /// このアプリから切り替え・削除ができるか（9 章）。
    public var isManaged: Bool { origin == .managed }

    /// 「削除するには…」に出す 1 行（DESIGN.md 8 章）。
    ///
    /// **どのスコープを消すのかをコマンドに焼き込む。** 既定に任せると事故る —
    /// `claude plugin remove` の既定は `-s user` なので、プロジェクトの分を
    /// 消したつもりでユーザー全体の分が消える。プロジェクト側は `cd` も付ける。
    ///
    /// - Parameters:
    ///   - agent: どのエージェントの画面か。CLI が違えばコマンドも違う
    ///   - project: プロジェクトのタブなら、そのパス。ユーザー全体のタブなら nil
    ///   - mcpScope: `ProjectScan.mcpScope` の結果（`project` / `local`）
    public func removalCommand(agent: Agent, project: String? = nil,
                               mcpScope: String? = nil) -> String? {
        if origin == .bundled { return nil }        // 消してもエージェントの更新で戻る
        switch kind {
        case .plugin:
            guard let cli = agent.cliName else { return nil }
            guard let project else { return "\(cli) plugin remove \(Self.arg(name)) -s user" }
            return "cd \(Self.quote(project)) && \(cli) plugin remove \(Self.arg(name)) -s local"
        case .mcp:
            // Cursor に CLI は無い。設定ファイルを出す（3.1）。
            guard var argv = MCPCommand.remove(name, from: agent) else {
                return "~/\(agent.configDir)/mcp.json"
            }
            if let project {
                if let i = argv.firstIndex(of: "-s"), i + 1 < argv.count {
                    if let mcpScope { argv[i + 1] = mcpScope } else { argv.removeSubrange(i...(i + 1)) }
                }
                return "cd \(Self.quote(project)) && " + argv.map(Self.arg).joined(separator: " ")
            }
            return argv.map(Self.arg).joined(separator: " ")
        case .skill, .subagent:
            let suffix = kind == .subagent ? ".md" : ""
            let dir = kind == .subagent ? "agents" : "skills"
            if let project {
                return "rm -rf \(Self.quote("\(project)/.claude/\(dir)/\(name)\(suffix)"))"
            }
            guard let root = roots.first(where: { $0.hasPrefix(".") }) else { return nil }
            return "rm -rf ~/\(root)/" + Self.arg(name + suffix)
        }
    }

    /// シェルに渡す 1 語。**リソース名は他ツールが書いたファイル由来**で、
    /// `;` や `$(…)` を含みうる。`runCleanup` はこの文字列を `sh -c` に渡すので、
    /// 素で埋めると任意コマンドが走る。安全な語はそのまま出す（コピーして読む前提）。
    static func arg(_ word: String) -> String {
        let safe = !word.isEmpty && word.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || "@._-+:/".contains($0))
        }
        return safe ? word : quote(word)
    }

    /// パスに空白が入る（`~/Free Projects/...`）。素で出すと動かないコマンドになる。
    static func quote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// プロジェクト側の削除を、**アプリが代わりに実行してよいか**（DESIGN.md 5.2 / 9 章）。
    ///
    /// **ユーザーのリポジトリには書かない。** `<proj>/.claude/skills/` も
    /// `<proj>/.mcp.json` も git で共有されるファイルで、消えたことに気づくのは
    /// 別のマシンや他のメンバー。ここはコマンドを見せるだけにする。
    /// 実行してよいのは、各 CLI が自分の領域（`installed_plugins.json` /
    /// `~/.claude.json`）に持っている登録だけ。
    public func isRemovalExecutable(mcpScope: String?) -> Bool {
        switch kind {
        case .plugin: true
        case .mcp:    mcpScope == "local"      // project スコープは <proj>/.mcp.json の中
        case .skill, .subagent: false          // リポジトリの中のファイル
        }
    }

    /// このアプリの管理下に取り込めるか（DESIGN.md 8 章）。
    ///
    /// **実体を動かさずに済むときだけ取り込む。** `~/.claude/skills/` にある実体を
    /// 勝手に `~/.agents/skills/` へ移すと、他ツールが張った symlink やユーザーの
    /// 想定を壊す。取り込みは registry に 1 行足して Claude 用の symlink を張るだけ、
    /// という**元に戻せる操作**の範囲に閉じる（3.1 / 9 章）。
    public var adoption: Adoption {
        guard origin == .user else { return .unsupported }
        switch kind {
        case .mcp, .plugin:
            // 書き込みは各 CLI に委譲している（3.1）。取り込む先が無い。
            return .unsupported
        case .skill where roots.contains(Environment.skillStoreLabel),
             .subagent where roots.contains(Environment.agentStoreLabel):
            return .possible
        case .skill, .subagent:
            guard let root = roots.first else { return .unsupported }  // プロジェクト限定
            return .needsMove(root)
        }
    }

    public enum Adoption: Sendable, Equatable {
        /// 実体が置き場にある。registry に足すだけで管理下に入る。
        case possible
        /// 実体が別の場所にある。移動が要るのでやらない（理由に置き場を出す）。
        case needsMove(String)
        /// そもそも取り込めない（MCP / Plugin / 同梱 / プロジェクト限定）。
        case unsupported
    }

    /// 置いてあるのにどのエージェントからも読めない（リンク切れ / SKILL.md なし）。
    /// **無効化とは違う** — こちらは事故なので、掃除できるよう画面に出す。
    public var isUnusable: Bool { !isDisabled && !state.values.contains(.explicit) }

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
    /// プロジェクト走査の結果。削除コマンドのスコープ決定に要る。
    public var projectScan = ProjectScan()

    /// 使用実績をいつ集計したか。`nil` = 未集計。
    /// 「未集計」を「未使用」として出さないために要る（DESIGN.md 5.3）。
    public var usageScannedAt: Date? { registry.usage.scannedUpTo }

    /// このエージェントの画面に出す行（DESIGN.md 8 章）。
    ///
    /// 「全部を 1 つの表に出す」のをやめ、エージェントごとに分ける。
    /// 無効化中の管理対象も含める — 誰からも見えない状態なので `state` では拾えないが、
    /// ここで落とすと**再有効化する導線が消える**。
    public func rows(for agent: Agent) -> [ResourceRow] {
        rows.filter { row in
            if row.state[agent] == .explicit { return true }
            if row.isManaged && row.isDisabled && agent.supports(row.kind) { return true }
            // リンク切れ・SKILL.md 欠落は誰からも見えないが、置き場はこのエージェントの下。
            // ここで落とすと、掃除すべきゴミが画面から消える。
            return !Set(row.roots).isDisjoint(with: agent.skillRoots + agent.subagentRoots)
        }
    }

    public static let empty = Inventory(agents: [:], rows: [])

    public init(agents: [Agent: Detection], rows: [ResourceRow], registry: Registry = Registry()) {
        self.agents = agents
        self.rows = rows
        self.registry = registry
    }

    /// 一括削除の計画（DESIGN.md 5.2 / 8 章）。
    /// **実行できるものと、コマンドを見せるだけのものを分けて返す。**
    public func cleanupItems(_ rows: [ResourceRow], agent: Agent, project: String)
        -> [CleanupItem]
    {
        rows.compactMap { row in
            let scope = projectScan.mcpScope(row.name, in: project)
            guard let command = row.removalCommand(agent: agent, project: project,
                                                   mcpScope: scope) else { return nil }
            return CleanupItem(name: row.name, kind: row.kind, project: project,
                               command: command,
                               executable: row.isRemovalExecutable(mcpScope: scope))
        }
    }

    /// スコープごとに分ける（DESIGN.md 8 章）。
    ///
    /// **1 つの表にユーザー全体とプロジェクトを混ぜない。**
    /// 混ぜると「これはどこで効いているのか」を毎行バッジで読み解く羽目になる。
    /// ユーザー全体にもプロジェクトにも入っているもの（`both`）は**両方に出す** —
    /// それが二重に入っている事実そのものだから。
    public func scoped(for agent: Agent) -> Scoped {
        var result = Scoped()
        for row in rows(for: agent).sorted(by: ResourceRow.display) {
            if row.origin == .bundled { result.bundled.append(row); continue }
            if row.reach.isUserWide { result.user.append(row) }
            for path in row.reach.projectPaths {
                result.projects[path, default: []].append(row)
            }
        }
        return result
    }

    /// スコープ別に分けた一覧。
    public struct Scoped: Sendable {
        public var user: [ResourceRow] = []
        var projects: [String: [ResourceRow]] = [:]
        public var bundled: [ResourceRow] = []

        /// プロジェクト名（パスの末尾）順。表示順を UI 側で決めさせない。
        public var byProject: [(path: String, rows: [ResourceRow])] {
            projects
                .map { (path: $0.key, rows: $0.value.sorted(by: ResourceRow.display)) }
                .sorted { ($0.path as NSString).lastPathComponent
                        < ($1.path as NSString).lastPathComponent }
        }
    }

    /// 読み取りだけで組み立てる。キャッシュしない（DESIGN.md 3.5）。
    public static func load(env: Environment, overrides: [Agent: String] = [:]) -> Inventory {
        let agents = Detector.detectAll(env: env, overrides: overrides)
        let registry = Registry.load(env: env)
        let used = registry.usage.lastUsed
        let projects = ProjectScan.load(env: env)
        let rows = skillRows(env: env, agents: agents, registry: registry, projects: projects)
            + subagentRows(env: env, agents: agents, registry: registry, projects: projects)
            + pluginRows(env: env, agents: agents, used: used)
            + mcpRows(env: env, agents: agents, used: used, projects: projects)
        // プロジェクトにしか無いものは上の走査に出てこない（実測: school-clique の
        // .claude/skills 7 件は、この行が無いと 1 つも表示されない）。
        var inventory = Inventory(agents: agents,
                                  rows: rows + projects.onlyRows(existing: rows, used: used),
                                  registry: registry)
        inventory.projectScan = projects
        return inventory
    }

    /// 最終使用日を引く（DESIGN.md 3.9）。
    /// Plugin だけ表記が食い違う — 一覧上の id は `ponytail@ponytail`、
    /// ログ上は `ponytail:ponytail-review` の前半なので `@` の手前で引き直す（spike #15）。
    static func lastUsed(_ name: String, kind: Kind, used: [String: Date]) -> Date? {
        if let date = used[name] { return date }
        guard kind == .plugin, let base = name.split(separator: "@").first else { return nil }
        return used[String(base)]
    }

    static func skillRows(env: Environment, agents: [Agent: Detection], registry: Registry,
                          projects: ProjectScan = ProjectScan()) -> [ResourceRow]
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
                    origin: origin(name, roots: found.map(\.root), registry: registry),
                    isDisabled: found.contains { $0.root == parkedLabel },
                    roots: found.map(\.root),
                    reach: .make(user: true, projects: projects.paths(name, kind: .skill)),
                    update: registry.entry(named: name)
                        .map { UpdateChecker.status(of: $0, in: registry) } ?? .unmanaged,
                    lastUsed: lastUsed(name, kind: .skill, used: registry.usage.lastUsed)
                )
            }
            .sorted { $0.name < $1.name }
    }

    /// スキルの出どころ（DESIGN.md 8 章）。
    /// **エージェント同梱ルートにしか無いものだけを `bundled` にする** —
    /// ユーザーが同名のものを自分の置き場にも持っていれば、それは自分のもの。
    static func origin(_ name: String, roots: [String], registry: Registry)
        -> ResourceRow.Origin
    {
        if registry.entry(named: name) != nil { return .managed }
        let visible = roots.filter { $0 != parkedLabel }
        return !visible.isEmpty && visible.allSatisfy(Agent.bundledSkillRoots.contains)
            ? .bundled : .user
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

    static func subagentRows(env: Environment, agents: [Agent: Detection], registry: Registry,
                             projects: ProjectScan = ProjectScan()) -> [ResourceRow]
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
                    origin: entry?.kind == Kind.subagent.rawValue ? .managed : .user,
                    isDisabled: found.contains { $0.root == parkedLabel },
                    roots: found.map(\.root),
                    reach: .make(user: true, projects: projects.paths(name, kind: .subagent)),
                    update: entry.map { UpdateChecker.status(of: $0, in: registry) } ?? .unmanaged,
                    lastUsed: lastUsed(name, kind: .subagent, used: registry.usage.lastUsed)
                )
            }
            .sorted { $0.name < $1.name }
    }

    // MARK: - MCP

    static func mcpRows(env: Environment, agents: [Agent: Detection], used: [String: Date] = [:],
                        projects: ProjectScan = ProjectScan()) -> [ResourceRow]
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
                // 各エージェントの設定が実体。registry には載せない（4.1）が、
                // 書いたのはユーザー自身なので「自分で入れたもの」に並べる。
                origin: .user,
                isDisabled: false,
                reach: .make(user: true, projects: projects.paths(name, kind: .mcp)),
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
                    // Plugin は各 CLI が管理する（4.1）。入れたのはユーザー自身。
                    origin: .user,
                    isDisabled: false,
                    reach: .make(user: found.contains { $0.scope == "user" },
                                 projects: found.compactMap(\.projectPath)),
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

/// プロジェクト単位に入っているもの（DESIGN.md 5.1 / 8 章）。
///
/// **プロジェクトのパスは動的で `Source` の静的列挙に載らない**ので、
/// `PermissionScanner` と同じ入り口（`Source.projectPaths`）を使い、
/// 各プロジェクトの `.claude/skills` / `.claude/agents` / `.mcp.json` **だけ**を読む。
/// 読むのは frontmatter の 4 KB まで（9 章）。実測 19 プロジェクトで 15 スキル。
public struct ProjectScan: Sendable {
    /// 種別 → 名前 → プロジェクトの絶対パス。
    var byKind: [Kind: [String: [String]]] = [:]
    /// プロジェクトにしか無いものの説明。一覧に出すために持つ。
    var summaries: [String: String] = [:]
    /// MCP のスコープ（プロジェクトパス → 名前 → `project` / `local`）。
    /// 削除コマンドの `-s` に載せる（間違えるとユーザー全体を消す）。
    var mcpScopes: [String: [String: String]] = [:]

    public init() {}

    public func paths(_ name: String, kind: Kind) -> [String] {
        byKind[kind]?[name] ?? []
    }

    /// そのプロジェクトでの MCP のスコープ。分からなければ nil（`-s` を付けない）。
    public func mcpScope(_ name: String, in project: String) -> String? {
        mcpScopes[project]?[name]
    }

    mutating func add(_ name: String, kind: Kind, project: String, summary: String?) {
        byKind[kind, default: [:]][name, default: []].append(project)
        if let summary, summaries["\(kind.rawValue):\(name)"] == nil {
            summaries["\(kind.rawValue):\(name)"] = summary
        }
    }

    public static func load(env: Environment) -> ProjectScan {
        var scan = ProjectScan()
        let mcp = MCPScanner.byProject(env: env)
        for path in Source.projectPaths(in: env) {
            let root = URL(filePath: path)
            for skill in SkillScanner.scan(root: root.appending(path: ".claude/skills"),
                                           rootLabel: path) where skill.isLoadable {
                scan.add(skill.name, kind: .skill, project: path, summary: skill.description)
            }
            for agent in SubagentScanner.scan(root: root.appending(path: ".claude/agents"),
                                              rootLabel: path) where agent.isLoadable {
                scan.add(agent.name, kind: .subagent, project: path, summary: agent.description)
            }
            for (name, scope) in mcp[path] ?? [:] {
                scan.add(name, kind: .mcp, project: path, summary: nil)
                scan.mcpScopes[path, default: [:]][name] = scope
            }
        }
        return scan
    }

    /// ユーザー全体の走査に出てこない = **そのプロジェクトにしか無いもの**。
    /// 行を作らないと画面から完全に消える（実測: school-clique の 7 スキル）。
    ///
    /// 見えるのは Claude だけとする。`<proj>/.claude/` を他エージェントが読むかは
    /// 未実測で、3.7 の「非対応と未検出を混ぜない」に倣って**推測で埋めない**。
    func onlyRows(existing: [ResourceRow], used: [String: Date]) -> [ResourceRow] {
        let known = Set(existing.map(\.id))
        return byKind.flatMap { kind, byName -> [ResourceRow] in
            byName.compactMap { name, projects in
                guard !known.contains("\(kind.rawValue):\(name)") else { return nil }
                var state: [Agent: ResourceRow.State] = [:]
                for agent in Agent.allCases {
                    state[agent] = agent == .claude
                        ? .explicit
                        : (agent.supports(kind) ? .absent : .unsupported)
                }
                return ResourceRow(
                    name: name, kind: kind,
                    summary: summaries["\(kind.rawValue):\(name)"],
                    detail: projects.sorted().joined(separator: " / "),
                    state: state, origin: .user, isDisabled: false,
                    reach: .make(user: false, projects: projects),
                    lastUsed: Inventory.lastUsed(name, kind: kind, used: used)
                )
            }
        }
        .sorted { $0.name < $1.name }
    }
}

/// 一括削除の 1 項目（DESIGN.md 5.2）。
public struct CleanupItem: Identifiable, Sendable, Equatable {
    public let name: String
    public let kind: Kind
    public let project: String
    public let command: String
    /// アプリが代わりに実行してよいか（`ResourceRow.isRemovalExecutable`）。
    public let executable: Bool
    public var id: String { "\(project)|\(kind.rawValue):\(name)" }
    public var projectName: String { (project as NSString).lastPathComponent }
}
