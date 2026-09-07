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
    public var running: RunningMCP?
    public var ownerAgent: Agent? = nil
    /// `@latest` 指定でピン留めできる MCP（7.2）。
    /// MCP に「更新」は存在しないので、操作列にはこれを出す。
    public let canPin: Bool
    public var id: String { "\(kind.rawValue):\(name)" + (ownerAgent.map { ":" + $0.rawValue } ?? "") }

    /// 表示順。種別ごとにまとめ、同じ種別なら名前順。
    public static func display(_ a: ResourceRow, _ b: ResourceRow) -> Bool {
        a.kind == b.kind ? a.name < b.name
            : (Kind.allCases.firstIndex(of: a.kind) ?? 0) < (Kind.allCases.firstIndex(of: b.kind) ?? 0)
    }

    /// 使用実績を観測できる行か。ログを読める Agent のどれかから見えればよい（3.9）。
    public var usageObservable: Bool {
        [Agent.claude, .cursor, .codex].contains { state[$0] == .explicit }
    }

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
            if agent == .codex { return "codex plugin remove \(Self.arg(name))" }
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
                // `apps/web:deploy` はサブディレクトリの `.claude/skills` に居る。
                // 素で埋めると存在しないパスを消せと言うことになる。
                let (sub, leaf) = ProjectScan.splitQualified(name)
                let base = sub.isEmpty ? project : "\(project)/\(sub)"
                return "rm -rf \(Self.quote("\(base)/.claude/\(dir)/\(leaf)\(suffix)"))"
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

    /// 一括削除シート（`cleanupItems`）で、**アプリが代わりに実行してよいか**
    /// （DESIGN.md 5.2 / 9 章）。
    ///
    /// **まとめてリポジトリを書き換えない。** `<proj>/.claude/skills/` も
    /// `<proj>/.mcp.json` も git で共有されるファイルで、消えたことに気づくのは
    /// 別のマシンや他のメンバー。ここはコマンドを見せるだけにする。
    /// 実行してよいのは、各 CLI が自分の領域（`installed_plugins.json` /
    /// `~/.claude.json`）に持っている登録だけ。
    ///
    /// **1 件ずつの削除は別経路**（`SkillManager.removeExisting`、DESIGN.md 15）。
    /// そちらはパスを 1 つ選ばせ、`WriteGuard.assertUserArtifact` で検証してから
    /// ゴミ箱へ移す。共有ファイルであることは確認ダイアログで明示する。
    ///
    /// **`agent` を見るのは、実行できる CLI がエージェントごとに違うから。**
    /// プロジェクト単位の MCP を消せるのは `claude mcp remove -s local` だけで、
    /// `~/.claude.json` の中身。他のエージェントには同じ置き場も CLI も無い
    /// （`MCPScanner.byProject` が読むのも Claude の 2 か所だけ）。
    public func isRemovalExecutable(agent: Agent, mcpScope: String?) -> Bool {
        switch kind {
        case .plugin: agent.cliName != nil     // CLI が無ければ実行しようがない
        case .mcp:    agent == .claude && mcpScope == "local"
        case .skill, .subagent: false          // リポジトリの中のファイル
        }
    }

    /// UI にファイル配置と安全判定を再実装させない。
    public func removableFiles(agent: Agent, project: String? = nil,
                               env: Environment) -> [URL] {
        guard kind == .skill || kind == .subagent else { return [] }
        let suffix = kind == .subagent ? ".md" : ""
        let (subdir, leaf) = ProjectScan.splitQualified(name)
        let candidates: [URL]
        if let project {
            let dir = kind == .skill ? ".claude/skills" : ".claude/agents"
            candidates = [URL(filePath: project)
                .appending(path: subdir.isEmpty ? dir : "\(subdir)/\(dir)")]
        } else {
            let allowed = kind == .skill ? agent.skillRoots : agent.subagentRoots
            candidates = roots.filter(allowed.contains).map { env.home.appending(path: $0) }
        }
        // 表示中の Inventory だけから候補を作る。削除直前には最新の Registry と
        // 実体パスを `Inventory.removeExisting` が再検査する。
        return candidates.map { $0.appending(path: leaf + suffix) }
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
    public var rows: [ResourceRow]
    public var issues: [String] = []
    public var mcpServers: [Agent: [MCPServer]] = [:]
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
            if let owner = row.ownerAgent { return owner == agent }
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
            return CleanupItem(name: row.name, kind: row.kind, agent: agent, project: project,
                               command: command,
                               executable: row.isRemovalExecutable(agent: agent, mcpScope: scope))
        }
    }

    public static func toggle(_ row: ResourceRow, env: Environment) throws {
        var registry = try Registry.read(env: env)
        switch (row.kind, row.isDisabled) {
        case (.subagent, true):  try SubagentManager.enable(row.name, env: env, registry: &registry)
        case (.subagent, false): try SubagentManager.disable(row.name, env: env, registry: &registry)
        case (.skill, true):     try SkillManager.enable(row.name, env: env, registry: &registry)
        case (.skill, false):    try SkillManager.disable(row.name, env: env, registry: &registry)
        default:                 throw Installer.Failure.unsupportedKind(row.kind)
        }
    }

    @discardableResult
    public static func remove(_ row: ResourceRow, env: Environment) throws -> URL? {
        var registry = try Registry.read(env: env)
        switch row.kind {
        case .subagent: return try SubagentManager.remove(row.name, env: env, registry: &registry)
        case .skill:    return try SkillManager.remove(row.name, env: env, registry: &registry)
        default:        throw Installer.Failure.unsupportedKind(row.kind)
        }
    }

    @discardableResult
    public static func removeExisting(_ row: ResourceRow, agent: Agent, project: String?,
                                      file: URL? = nil, env: Environment) throws -> URL? {
        if let file {
            return try SkillManager.removeExisting(file, kind: row.kind, project: project, env: env)
        } else if row.kind == .plugin {
            try PluginManager.remove(row.name, from: agent, project: project, env: env)
        } else if row.kind == .mcp {
            if let project {
                // 対応範囲の判定は `MCPManager.removeProject` が持つ（二重に書かない）。
                try MCPManager.removeProject(row.name, from: agent, project: project, env: env)
            } else {
                try MCPManager.remove(row.name, from: agent, env: env)
            }
        }
        return nil
    }

    /// **表示したコマンドと同じことをする。** 以前は `agent` を `.claude` に決め打ちして
    /// いたため、Codex の画面で `codex plugin remove …` と見せながら
    /// `claude plugin remove` を走らせ、的外れなエラーで失敗していた。
    /// どのエージェントに対する削除かは `CleanupItem` が持つ。
    public static func runCleanup(_ items: [CleanupItem], env: Environment) -> [String] {
        items.filter(\.executable).compactMap { item in
            do {
                if item.kind == .plugin {
                    try PluginManager.remove(item.name, from: item.agent,
                                             project: item.project, env: env)
                } else if item.kind == .mcp {
                    try MCPManager.removeProject(item.name, from: item.agent,
                                                 project: item.project, env: env)
                }
                return nil
            } catch { return "\(item.name): \(error)" }
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

    /// 読み取りだけで組み立てる。**ファイル走査はキャッシュしない**（DESIGN.md 3.5）。
    ///
    /// CLI 由来の結果だけは `CLIScan` が数分だけ持つ（3.5 が明示的に求めている間引き）。
    /// `forceCLI` は明示的な再読み込みと、こちらが設定を書き換えた直後に立てる —
    /// 押した操作が反映されないのは、待たされるより悪い。
    public static func load(env: Environment, forceCLI: Bool = false) -> Inventory {
        let registry = Registry.load(env: env)
        // 手動指定のパスと有効/無効は registry.json が持つ（3.7）。
        // 無効にしたエージェントは走査そのものをしない。
        let cli = CLIScan.snapshot(env: env, registry: registry, force: forceCLI)
        let agents = cli.agents
        let used = registry.usage.lastUsed
        let projects = ProjectScan.load(env: env, registry: registry)
        var issues = cli.issues
        do { try Registry.assertReadable(env: env) } catch { issues.append("Registry: \(error)") }
        var servers: [Agent: [MCPServer]] = [:]
        let plugins = cli.plugins
        for agent in Agent.allCases where agents[agent]?.isActive == true {
            // 設定ファイル直読みは毎回やる。**アプリ自身が `~/.cursor/mcp.json` を書く**ので、
            // ここを間引くと自分の書き込みが数分反映されない（3.1 / 不変条件5）。
            if case .cli = agent.mcpSource {
                servers[agent] = cli.mcp[agent] ?? []
            } else {
                do { servers[agent] = try MCPScanner.read(agent, env: env) }
                catch { issues.append("\(agent.displayName) MCP: \(error)") }
            }
        }
        let rows = skillRows(env: env, agents: agents, registry: registry, projects: projects)
            + subagentRows(env: env, agents: agents, registry: registry, projects: projects)
            + pluginRows(env: env, agents: agents, used: used, installed: plugins)
            + mcpRows(env: env, agents: agents, used: used, projects: projects, scanned: servers)
        // プロジェクトにしか無いものは上の走査に出てこない（実測: school-clique の
        // .claude/skills 7 件は、この行が無いと 1 つも表示されない）。
        var inventory = Inventory(agents: agents,
                                  rows: rows + projects.onlyRows(existing: rows, used: used),
                                  registry: registry)
        inventory.projectScan = projects
        inventory.issues = issues
        inventory.mcpServers = servers
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
                    update: registry.entry(named: name, kind: .skill)
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
        let visible = roots.filter { $0 != parkedLabel }
        if !visible.isEmpty && visible.allSatisfy(Agent.bundledSkillRoots.contains) { return .bundled }
        return registry.entry(named: name, kind: .skill) != nil ? .managed : .user
    }

    /// 「非対応」と「未検出」を混ぜない（DESIGN.md 3.7）。順序が意味を持つ。
    static func cell(_ agent: Agent, kind: Kind, detection: Detection, visible: Bool)
        -> ResourceRow.State
    {
        if !agent.supports(kind) { return .unsupported }   // 検出状態と独立
        if !detection.isActive { return .undetected }
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
                let entry = registry.entry(named: name, kind: .subagent)
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
                        projects: ProjectScan = ProjectScan(), scanned: [Agent: [MCPServer]]? = nil) -> [ResourceRow] {
        let byAgent = scanned ?? MCPScanner.scan(env: env)
        return Agent.allCases.flatMap { agent in
            (byAgent[agent] ?? []).map { server in
                var row = ResourceRow(name: server.name, kind: .mcp, summary: server.summary,
                    detail: mcpDetail(server), state: [agent: server.enabled ? .explicit : .absent],
                    origin: server.isProtected ? .bundled : .user, isDisabled: !server.enabled,
                    reach: .make(user: true, projects: agent == .claude ? projects.paths(server.name, kind: .mcp) : []),
                    lastUsed: used[server.name], canPin: server.floatingPackage != nil && !server.isProtected)
                row.ownerAgent = agent
                return row
            }
        }
    }

    /// MCP に更新機能は無い。必要なのはピン留め管理（DESIGN.md 7.2）。
    static func mcpDetail(_ server: MCPServer?) -> String {
        guard let server else { return "" }
        if let package = server.floatingPackage {
            return String(localized: "⚠️ \(package)@latest — 起動ごとに最新を取得（サイレントに壊れる可能性）")
        }
        if case .http = server.transport { return "HTTP" }
        return String(localized: "バージョン固定済み")
    }

    // MARK: - Plugins（読み取りのみ。書き込みは CLI に委譲。3.1）

    static func pluginRows(env: Environment, agents: [Agent: Detection], used: [String: Date] = [:],
                           installed: [InstalledPlugin]? = nil) -> [ResourceRow] {
        let plugins = installed ?? PluginScanner.scan(env: env)
        return Agent.allCases.flatMap { agent in
            Dictionary(grouping: plugins.filter { $0.agent == agent }, by: \.id).map { id, found in
                var row = ResourceRow(name: id, kind: .plugin,
                    summary: found.first?.version.map { "v\($0)" }, detail: pluginDetail(id, found, duplicates: PluginScanner.duplicates(found)),
                    state: Dictionary(uniqueKeysWithValues: Agent.allCases.map {
                        ($0, $0 == agent ? (found.contains(where: \.enabled) ? .explicit : .absent) : ($0.supports(.plugin) ? .absent : .unsupported))
                    }),
                    origin: found.contains(where: \.isBundled) ? .bundled : .user,
                    isDisabled: !found.contains(where: \.enabled),
                    reach: .make(user: found.contains { $0.scope == "user" }, projects: found.compactMap(\.projectPath)),
                    lastUsed: lastUsed(id, kind: .plugin, used: used))
                row.ownerAgent = agent
                return row
            }
        }
    }

    static func pluginDetail(_ id: String, _ found: [InstalledPlugin],
                             duplicates: [String: [InstalledPlugin]]) -> String {
        var parts: [String] = []
        if let dupes = duplicates[id] {
            parts.append(String(localized: "⚠️ \(dupes.count) プロジェクトに重複導入"))
        } else if let scope = found.first?.scope {
            parts.append(scope == "user"
                ? String(localized: "ユーザー全体") : String(localized: "このプロジェクト"))
        }
        if found.contains(where: \.autoUpdate) { parts.append(String(localized: "自動更新")) }
        return parts.joined(separator: " · ")
    }

    /// 退避中であることを示す擬似ルート名。**`roots` の値としても使う**ので、
    /// 実在のルート（`.agents/skills` など）と衝突しない文字列にしておく。
    static let parkedLabel = String(localized: "無効化（退避中）")

    static func detail(_ found: [Skill]) -> String {
        found.map { skill in
            switch skill.status {
            case .ok: skill.root
            case .brokenLink:
                String(localized: "\(skill.root)（リンク切れ）")
            case .noSkillFile:
                String(localized: "\(skill.root)（SKILL.md なし）")
            case .truncatedFrontmatter:
                String(localized: "\(skill.root)（frontmatter が 4 KB を超過）")
            case .missingFrontmatter:
                String(localized: "\(skill.root)（frontmatter なし）")
            }
        }
        .sorted()
        .joined(separator: " / ")
    }
}

/// プロジェクト単位に入っているもの（DESIGN.md 5.1 / 8 章）。
///
/// **プロジェクトのパスは動的で `Source` の静的列挙に載らない**ので、
/// project の列挙・Skill の探索・MCP scope をこの module に集約し、
/// 各プロジェクトの `.claude/skills` / `.claude/agents` / `.mcp.json` **だけ**を読む。
/// 読むのは frontmatter の 4 KB まで（9 章）。実測 19 プロジェクトで 15 スキル。
public struct ProjectScan: Sendable {
    /// `~/.claude.json` と既存 registry から得た、信頼するプロジェクト一覧。
    public var projects: [String] = []
    /// `projects` に載っているが走査しないもの（`isProject` が落とした分）。
    /// 設定画面に出して「登録したのに一覧に出ない」を説明する。
    public var ignoredProjects: [String] = []
    /// 利用者が明示的に走査から除いたもの。自動除外（ホーム・ルート）とは別管理で、
    /// 設定画面から復元できる。
    public var userIgnoredProjects: [String] = []
    /// 種別 → 名前 → プロジェクトの絶対パス。
    var byKind: [Kind: [String: [String]]] = [:]
    /// プロジェクトにしか無いものの説明。一覧に出すために持つ。
    var summaries: [String: String] = [:]
    /// MCP のスコープ（プロジェクトパス → 名前 → `project` / `local`）。
    /// 削除コマンドの `-s` に載せる（間違えるとユーザー全体を消す）。
    var mcpScopes: [String: [String: String]] = [:]

    public init() {}

    /// **静的列挙にできない唯一の例外。** `~/.claude.json` の `projects` と、
    /// 旧版が registry に残したプロジェクトだけを使う（DESIGN.md 3.4 / 5.1 / 15）。
    public static func projectPaths(in env: Environment) -> [String] {
        projectPaths(in: env, registry: Registry.load(env: env))
    }

    static func projectPaths(in env: Environment, registry: Registry) -> [String] {
        partitioned(in: env, registry: registry).used
    }

    public static func identity(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let resolved = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
            .standardizedFileURL.path(percentEncoded: false)
        return resolved.count > 1 && resolved.hasSuffix("/")
            ? String(resolved.dropLast()) : resolved
    }


    /// 走査するものと、走査しないものに分ける。
    ///
    /// **落としたものを黙って捨てない。** 除外したことを設定画面に出さないと、
    /// 利用者は「登録したのに一覧に出ない」を原因不明のまま抱えることになる。
    ///
    /// - `used`: 走査する
    /// - `autoIgnored`: ホーム・ルートなど自動除外（復元不可）
    /// - `userIgnored`: 利用者が明示的に除外（設定画面から復元可能）
    static func partitioned(in env: Environment, registry: Registry)
        -> (used: [String], autoIgnored: [String], userIgnored: [String])
    {
        var paths = Set(registry.projects)
        if let data = try? Data(contentsOf: env.home.appending(path: ".claude.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = object["projects"] as? [String: Any] {
            paths.formUnion(projects.keys)
        }
        let home = identity(env.home.path(percentEncoded: false)) ?? env.home.path
        let userExcluded = Set(registry.excludedProjects.compactMap(identity))
        var split = (used: [String](), autoIgnored: [String](), userIgnored: [String]())
        var seen: Set<String> = []
        for path in paths.sorted() {
            guard let key = identity(path), seen.insert(key).inserted else {
                split.autoIgnored.append(path)
                continue
            }
            if !isProject(key, home: home) { split.autoIgnored.append(path) }
            else if userExcluded.contains(key) { split.userIgnored.append(key) }
            else { split.used.append(key) }
        }
        return split
    }

    /// プロジェクトとして走査してよいパスか。**純粋関数**（10.1）。
    ///
    /// **ホーム自身とルートはプロジェクトではない。** 信じると `skillRoots` が
    /// ホーム配下を深さ 3 まで歩き、他の全プロジェクトの `.claude/skills` を
    /// 1 つの偽プロジェクトに吸い込む（理由と実測は DESIGN.md 5.1）。
    static func isProject(_ path: String, home: String) -> Bool {
        guard let candidate = identity(path), let home = identity(home) else { return false }
        return candidate != "/" && candidate != home
    }

    /// プロジェクト直下から 3 段までの `.claude/skills` だけを読む。
    /// ponytail: 深さ 3 + 固定の除外名。取りこぼす配置が出たら実測して見直す。
    public static func skillRoots(_ project: String) -> [(prefix: String, url: URL)] {
        var found: [(prefix: String, url: URL)] = []
        walk(URL(filePath: project), prefix: "", depth: skillDepth, into: &found)
        return found
    }

    /// `apps/web:deploy` → (`apps/web`, `deploy`)。修飾されていなければ左は空。
    public static func splitQualified(_ name: String) -> (subdir: String, name: String) {
        guard let i = name.lastIndex(of: ":") else { return ("", name) }
        return (String(name[name.startIndex..<i]), String(name[name.index(after: i)...]))
    }

    static let skillDepth = 3
    static let notWalked: Set<String> = ["node_modules", "Pods", "vendor", "target",
                                         "dist", "build", "out"]

    /// `walk` が `skillRoots` の prefix として返しうる形か。**純粋関数**（10.1）。
    ///
    /// 走査し直さずに「そのパスは走査対象だったか」を答えるために要る。
    /// `WriteGuard.assertUserArtifact` はこれを使って、プロジェクト配下を
    /// 歩かずに削除可否を判定する（歩くと UI の body 評価が行数ぶん止まる）。
    static func isWalkablePrefix(_ prefix: String) -> Bool {
        guard !prefix.isEmpty else { return true }
        let parts = prefix.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= skillDepth else { return false }
        return parts.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !notWalked.contains(String($0))
        }
    }

    static func walk(_ dir: URL, prefix: String, depth: Int,
                     into found: inout [(prefix: String, url: URL)]) {
        let fm = FileManager.default
        let skills = dir.appending(path: ".claude/skills")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: skills.path(percentEncoded: false), isDirectory: &isDir),
           isDir.boolValue {
            found.append((prefix, skills))
        }
        guard depth > 0 else { return }
        let children = (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))?
            .filter { !$0.hasPrefix(".") && !notWalked.contains($0) }.sorted() ?? []
        for child in children {
            let url = dir.appending(path: child)
            guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir),
                  isDir.boolValue else { continue }
            walk(url, prefix: prefix.isEmpty ? child : "\(prefix)/\(child)",
                 depth: depth - 1, into: &found)
        }
    }

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
        load(env: env, registry: Registry.load(env: env))
    }

    static func load(env: Environment, registry: Registry) -> ProjectScan {
        var scan = ProjectScan()
        let split = partitioned(in: env, registry: registry)
        scan.projects = split.used
        scan.ignoredProjects = split.autoIgnored
        scan.userIgnoredProjects = split.userIgnored
        let mcp = MCPScanner.byProject(projects: scan.projects, env: env)
        for path in scan.projects {
            let root = URL(filePath: path)
            // サブディレクトリの `.claude/skills` も読む。
            var byName: [String: [(prefix: String, description: String?)]] = [:]
            for (prefix, dir) in skillRoots(path) {
                for skill in SkillScanner.scan(root: dir, rootLabel: path) where skill.isLoadable {
                    byName[skill.name, default: []].append((prefix, skill.description))
                }
            }
            for (name, entries) in byName {
                // Claude が修飾名 `apps/web:deploy` を使うのは**同名が競合したときだけ**。
                // 競合が無ければ `/deploy` で呼べるので、勝手に修飾すると呼び出し名を偽る。
                let qualify = entries.count > 1
                for entry in entries {
                    let display = qualify && !entry.prefix.isEmpty
                        ? "\(entry.prefix):\(name)" : name
                    scan.add(display, kind: .skill, project: path, summary: entry.description)
                }
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
        let known = Set(existing.filter { $0.ownerAgent == nil || $0.ownerAgent == .claude }.map { "\($0.kind.rawValue):\($0.name)" })
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
    /// どのエージェントに対する削除か。**`command` と実行を食い違わせないために持つ。**
    public let agent: Agent
    public let project: String
    public let command: String
    /// アプリが代わりに実行してよいか（`ResourceRow.isRemovalExecutable`）。
    public let executable: Bool
    public var id: String { "\(project)|\(agent.rawValue)|\(kind.rawValue):\(name)" }
    public var projectName: String { (project as NSString).lastPathComponent }
}
