import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.2 の実測表がコードと一致していること。
@Suite("スキルルートの可視性")
struct SkillVisibilityTests {

    @Test("~/.agents/skills は Cursor と Codex から見え、Claude からは見えない")
    func sharedRoot() {
        let roots: Set<String> = [".agents/skills"]
        #expect(!Agent.claude.sees(rootsContaining: roots))
        #expect(Agent.cursor.sees(rootsContaining: roots))
        #expect(Agent.codex.sees(rootsContaining: roots))
        #expect(!Agent.gemini.sees(rootsContaining: roots))
    }

    @Test("~/.claude/skills は Claude と Cursor から見える（Cursor は他社ディレクトリも読む）")
    func claudeRoot() {
        let roots: Set<String> = [".claude/skills"]
        #expect(Agent.claude.sees(rootsContaining: roots))
        #expect(Agent.cursor.sees(rootsContaining: roots))
        #expect(!Agent.codex.sees(rootsContaining: roots))
    }

    @Test("~/.codex/skills は Codex と Cursor から見える")
    func codexRoot() {
        let roots: Set<String> = [".codex/skills"]
        #expect(!Agent.claude.sees(rootsContaining: roots))
        #expect(Agent.cursor.sees(rootsContaining: roots))
        #expect(Agent.codex.sees(rootsContaining: roots))
    }

    /// 3.2 の配置方針: 実体 = .agents/skills、Claude 用に symlink 1 本。
    /// これで 3 エージェントすべてから見えること。
    @Test("実体 + Claude symlink で 3 エージェントすべてに届く")
    func plannedLayout() {
        let roots: Set<String> = [".agents/skills", ".claude/skills"]
        #expect(Agent.claude.sees(rootsContaining: roots))
        #expect(Agent.cursor.sees(rootsContaining: roots))
        #expect(Agent.codex.sees(rootsContaining: roots))
    }

    @Test("Gemini はどのルートからも見えない（Skills 非対応）")
    func geminiSeesNothing() {
        for source in Source.skills {
            #expect(!Agent.gemini.sees(rootsContaining: [source.relativePath!]))
        }
    }
}

@Suite("マトリクスのセル状態")
struct InventoryCellTests {

    /// 「非対応」は検出状態より優先される。
    /// 同じグレーにすると「Gemini を入れれば使える」と誤解される（3.7）。
    @Test("非対応は検出済みでも unsupported")
    func unsupportedBeatsDetection() {
        let state = Inventory.cell(.gemini, kind: .skill,
                                   detection: .detected(version: "1.0", path: "/x"),
                                   visible: true)
        #expect(state == .unsupported)
    }

    @Test("未検出のエージェントは undetected")
    func undetected() {
        let state = Inventory.cell(.codex, kind: .skill, detection: .undetected, visible: false)
        #expect(state == .undetected)
    }

    /// CLI が PATH から外れただけで設定は生きていることがある。
    /// ここで隠すとユーザーが重複追加する（3.7）。
    @Test("configOnly でもリソースの状態は表示する")
    func configOnlyStillShowsState() {
        #expect(Inventory.cell(.codex, kind: .skill, detection: .configOnly, visible: true)
                == .explicit)
        #expect(Inventory.cell(.codex, kind: .skill, detection: .configOnly, visible: false)
                == .absent)
    }

    @Test("見えていれば explicit、見えなければ absent")
    func visibility() {
        let d = Detection.detected(version: "1", path: "/x")
        #expect(Inventory.cell(.claude, kind: .skill, detection: d, visible: true) == .explicit)
        #expect(Inventory.cell(.claude, kind: .skill, detection: d, visible: false) == .absent)
    }
}

@Suite("Inventory の組み立て")
struct InventoryLoadTests {

    @Test("実体 + symlink のスキルが 1 行にまとまり 3 エージェントで有効になる")
    func singleRowAcrossAgents() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-inv-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in [".agents/skills/demo", ".claude/skills", ".codex", ".cursor", ".gemini"] {
            try fm.createDirectory(at: home.appending(path: dir), withIntermediateDirectories: true)
        }
        try "---\nname: demo\ndescription: a demo skill\n---\n"
            .write(to: home.appending(path: ".agents/skills/demo/SKILL.md"),
                   atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: home.appending(path: ".claude/skills/demo"),
                                  withDestinationURL: home.appending(path: ".agents/skills/demo"))

        let env = Environment.test(home: home, run: { command in
            if command.first == "which" { return "/bin/\(command[1])\n" }
            return "1.0.0\n"
        })
        let inv = Inventory.load(env: env)

        #expect(inv.rows.count == 1)
        let row = try #require(inv.rows.first)
        #expect(row.name == "demo")
        #expect(row.summary == "a demo skill")
        #expect(row.state[.claude] == .explicit)
        #expect(row.state[.cursor] == .explicit)
        #expect(row.state[.codex] == .explicit)
        #expect(row.state[.gemini] == .unsupported)   // 未検出ではなく非対応
    }
}

@Suite("読み込めないスキルは有効にしない")
struct UnloadableSkillTests {

    static func home(_ setup: (URL) throws -> Void) throws -> Environment {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-broken-\(UUID().uuidString)")
        let fm = FileManager.default
        for dir in [".claude/skills", ".codex", ".cursor", ".gemini"] {
            try fm.createDirectory(at: home.appending(path: dir), withIntermediateDirectories: true)
        }
        try setup(home)
        return Environment.test(home: home, run: { c in
            c.first == "which" ? "/bin/\(c[1])\n" : "1.0.0\n"
        })
    }

    /// `~/.claude/skills/codiff` が実際にこの状態。
    /// ディレクトリに存在しても Claude は読み込めないので ● にしてはいけない。
    @Test("リンク切れ symlink は absent")
    func brokenLinkIsAbsent() throws {
        let env = try Self.home { home in
            try FileManager.default.createSymbolicLink(
                at: home.appending(path: ".claude/skills/codiff"),
                withDestinationURL: URL(filePath: "/nonexistent/codiff"))
        }
        let row = try #require(Inventory.load(env: env).rows.first)
        #expect(row.name == "codiff")
        #expect(row.state[.claude] == .absent, "リンク切れを有効と表示している")
        #expect(row.state[.cursor] == .absent, "Cursor も .claude/skills を読むが実体が無い")
        #expect(row.detail.contains("リンク切れ"))
    }

    @Test("SKILL.md が無いディレクトリも absent")
    func noSkillFileIsAbsent() throws {
        let env = try Self.home { home in
            try FileManager.default.createDirectory(
                at: home.appending(path: ".claude/skills/empty"), withIntermediateDirectories: true)
        }
        let row = try #require(Inventory.load(env: env).rows.first)
        #expect(row.state[.claude] == .absent)
    }

    /// frontmatter が壊れていてもファイルは存在するので、エージェントは読む。
    @Test("frontmatter が無くてもファイルがあれば有効")
    func missingFrontmatterStillLoadable() throws {
        let env = try Self.home { home in
            let dir = home.appending(path: ".claude/skills/bare")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "# no frontmatter\n".write(to: dir.appending(path: "SKILL.md"),
                                          atomically: true, encoding: .utf8)
        }
        let row = try #require(Inventory.load(env: env).rows.first)
        #expect(row.state[.claude] == .explicit)
    }
}

/// DESIGN.md 8 章 — エージェントごとに 1 画面。
@Suite("エージェントごとの一覧")
struct AgentRowsTests {

    func row(_ name: String, kind: Kind = .skill,
             state: [Agent: ResourceRow.State],
             origin: ResourceRow.Origin = .managed, disabled: Bool = false) -> ResourceRow {
        ResourceRow(name: name, kind: kind, summary: nil, detail: "",
                    state: state, origin: origin, isDisabled: disabled)
    }

    @Test("そのエージェントに入っているものだけ出る")
    func filtersByAgent() {
        let inventory = Inventory(agents: [:], rows: [
            row("both", state: [.claude: .explicit, .cursor: .explicit]),
            row("cursor-only", state: [.claude: .absent, .cursor: .explicit]),
        ])
        #expect(inventory.rows(for: .claude).map(\.name) == ["both"])
        #expect(inventory.rows(for: .cursor).map(\.name) == ["both", "cursor-only"])
    }

    /// 無効化すると走査ルートから消える = どのエージェントからも見えない。
    /// ここで落とすと再有効化する導線が無くなる。
    @Test("無効化中の管理対象は残る（再有効化の導線）")
    func keepsDisabled() {
        let inventory = Inventory(agents: [:], rows: [
            row("parked", state: [.claude: .absent], disabled: true),
        ])
        #expect(inventory.rows(for: .claude).map(\.name) == ["parked"])
        // Gemini に Skills は無いので、無効化中でも出さない。
        #expect(inventory.rows(for: .gemini).isEmpty)
    }

    @Test("他ツール管理のものは無効化中でも出さない（そもそも触れない）")
    func ignoresForeignParked() {
        let inventory = Inventory(agents: [:], rows: [
            row("foreign", state: [.claude: .absent], origin: .user, disabled: true),
        ])
        #expect(inventory.rows(for: .claude).isEmpty)
    }
}

/// DESIGN.md 8 章 — 「自分で入れたもの」と「最初から入っていたもの」を混ぜない。
@Suite("スキルの出どころ")
struct SkillOriginTests {

    @Test("Cursor 同梱のルートにしか無いものは bundled")
    func bundled() {
        #expect(Inventory.origin("automate", roots: [".cursor/skills-cursor"],
                                 registry: Registry()) == .bundled)
        #expect(Inventory.origin("canvas", roots: [".cursor/cloud-skills"],
                                 registry: Registry()) == .bundled)
    }

    @Test("自分の置き場にもあれば自分のもの")
    func userRoot() {
        #expect(Inventory.origin("automate",
                                 roots: [".cursor/skills-cursor", ".agents/skills"],
                                 registry: Registry()) == .user)
        #expect(Inventory.origin("find-skills", roots: [".agents/skills"],
                                 registry: Registry()) == .user)
    }

    @Test("registry に載っていても同梱ルートは保護する")
    func managedWins() {
        var registry = Registry()
        registry.upsert(Registry.Entry(name: "automate", kind: .skill))
        #expect(Inventory.origin("automate", roots: [".cursor/skills-cursor"],
                                 registry: registry) == .bundled)
    }

    /// 退避中は走査ルートから消え、残るのは退避ラベルだけ。
    /// これを「同梱」と誤判定すると、無効化した瞬間に自分のものでなくなる。
    @Test("退避中のラベルだけでは bundled にしない")
    func parkedIsNotBundled() {
        #expect(Inventory.origin("demo", roots: [Inventory.parkedLabel],
                                 registry: Registry()) == .user)
    }
}

/// リンク切れは誰からも見えない。**それでも掃除できるよう画面に残す**（DESIGN.md 8 章）。
@Suite("読み込めないリソース")
struct UnusableRowTests {

    @Test("リンク切れのスキルは、置き場を持つエージェントの画面に出る")
    func brokenLinkStaysVisible() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-broken-\(UUID().uuidString)")
        let fm = FileManager.default
        let skills = home.appending(path: ".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: skills.appending(path: "codiff"),
                                  withDestinationURL: home.appending(path: "gone/codiff"))

        let env = Environment.test(home: home, run: { $0.first == "which" ? "/bin/x\n" : "1.0\n" })
        let inventory = Inventory.load(env: env)
        let row = try #require(inventory.rows.first { $0.name == "codiff" })
        #expect(row.state[.claude] != .explicit)          // 誰からも読めない
        #expect(row.isUnusable)
        #expect(inventory.rows(for: .claude).map(\.name) == ["codiff"])
    }
}

/// DESIGN.md 5.1 / 8 章 — ユーザー全体とプロジェクトを分けて出す。
@Suite("プロジェクトスコープ")
struct ProjectScopeTests {

    struct Fixture {
        let env: Environment
        let project: URL
        let fm = FileManager.default

        init(claudeJSON: (URL) -> [String: Any] = { _ in [:] }) throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-proj-\(UUID().uuidString)")
            project = home.appending(path: "work/demo-app")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            var root = claudeJSON(project)
            // プロジェクト一覧の入り口は ~/.claude.json の projects キー（3.4 の例外）。
            root["projects"] = (root["projects"] as? [String: Any])
                ?? [project.path(percentEncoded: false): [String: Any]()]
            let data = try JSONSerialization.data(withJSONObject: root)
            try data.write(to: home.appending(path: ".claude.json"))
            env = Environment.test(home: home, run: { $0.first == "which" ? "/bin/x\n" : "1.0\n" })
        }

        func writeSkill(_ name: String, at dir: URL) throws {
            let skill = dir.appending(path: name)
            try fm.createDirectory(at: skill, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: プロジェクト用\n---\n"
                .write(to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
    }

    @Test("プロジェクトにしか無いスキルも一覧に出る")
    func projectOnlySkill() throws {
        let f = try Fixture()
        try f.writeSkill("repo-rules", at: f.project.appending(path: ".claude/skills"))

        let inventory = Inventory.load(env: f.env)
        let row = try #require(inventory.rows.first { $0.name == "repo-rules" })
        #expect(row.reach == .projects([f.project.path(percentEncoded: false)]))
        #expect(row.summary == "プロジェクト用")
        #expect(row.state[.claude] == .explicit)
        // Claude の画面にだけ出す（他エージェントがプロジェクト配下を読むかは未実測）。
        #expect(inventory.rows(for: .claude).contains { $0.name == "repo-rules" })
        #expect(!inventory.rows(for: .codex).contains { $0.name == "repo-rules" })
    }

    /// **散らかりの検出**（5.2）。ユーザー全体にあるのにプロジェクトにも入っている。
    @Test("ユーザー全体とプロジェクトの両方にあれば both")
    func duplicated() throws {
        let f = try Fixture()
        try f.writeSkill("codiff", at: f.env.home.appending(path: ".agents/skills"))
        try f.writeSkill("codiff", at: f.project.appending(path: ".claude/skills"))

        let row = try #require(Inventory.load(env: f.env).rows.first { $0.name == "codiff" })
        #expect(row.reach == .both([f.project.path(percentEncoded: false)]))
    }

    @Test("プロジェクトの .mcp.json と ~/.claude.json の projects 配下を両方読む")
    func projectMCP() throws {
        let f = try Fixture(claudeJSON: { project in
            ["projects": [project.path(percentEncoded: false):
                            ["mcpServers": ["local-only": ["command": "npx"]]]]]
        })
        try JSONSerialization
            .data(withJSONObject: ["mcpServers": ["shared": ["command": "npx"]]])
            .write(to: f.project.appending(path: ".mcp.json"))

        let found = MCPScanner.byProject(env: f.env)[f.project.path(percentEncoded: false)]
        // スコープまで返す（削除コマンドの `-s` に載せるため）。
        #expect(found == ["local-only": "local", "shared": "project"])
        let rows = Inventory.load(env: f.env).rows
        #expect(rows.contains { $0.name == "shared" && $0.kind == .mcp })
        #expect(rows.contains { $0.name == "local-only" && $0.kind == .mcp })
    }

    @Test("プロジェクトが 1 つも無ければ何も読まない")
    func noProjects() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-noproj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = Environment.test(home: home)
        #expect(Source.projectPaths(in: env).isEmpty)
        #expect(ProjectScan.load(env: env).paths("x", kind: .skill).isEmpty)
    }
}

/// DESIGN.md 8 章 — ユーザー全体とプロジェクトを 1 つの表に混ぜない。
@Suite("スコープ別の分割")
struct ScopedRowsTests {

    func row(_ name: String, kind: Kind = .skill, reach: ResourceRow.Reach,
             origin: ResourceRow.Origin = .user) -> ResourceRow {
        ResourceRow(name: name, kind: kind, summary: nil, detail: "",
                    state: [.claude: .explicit], origin: origin, isDisabled: false,
                    reach: reach)
    }

    @Test("ユーザー全体・プロジェクト・同梱が別々になる")
    func splits() {
        let inventory = Inventory(agents: [:], rows: [
            row("everywhere", reach: .user),
            row("only-here", reach: .projects(["/w/app"])),
            row("automate", reach: .user, origin: .bundled),
        ])
        let scoped = inventory.scoped(for: .claude)
        #expect(scoped.user.map(\.name) == ["everywhere"])
        #expect(scoped.bundled.map(\.name) == ["automate"])
        #expect(scoped.byProject.map(\.path) == ["/w/app"])
        #expect(scoped.byProject.first?.rows.map(\.name) == ["only-here"])
    }

    /// 二重に入っている事実そのものを見せたいので、**両方の表に出す**。
    @Test("ユーザー全体とプロジェクトの両方にあるものは両方に出る")
    func duplicateAppearsTwice() {
        let inventory = Inventory(agents: [:], rows: [
            row("ponytail", kind: .plugin, reach: .both(["/w/a", "/w/b"])),
        ])
        let scoped = inventory.scoped(for: .claude)
        #expect(scoped.user.map(\.name) == ["ponytail"])
        #expect(scoped.byProject.map(\.path) == ["/w/a", "/w/b"])
        #expect(scoped.byProject.allSatisfy { $0.rows.count == 1 })
    }

    @Test("プロジェクトはフォルダ名順、中身は種別順")
    func ordering() {
        let inventory = Inventory(agents: [:], rows: [
            row("zzz", kind: .skill, reach: .projects(["/w/beta"])),
            row("aaa", kind: .mcp, reach: .projects(["/w/beta"])),
            row("mid", reach: .projects(["/w/alpha"])),
        ])
        let scoped = inventory.scoped(for: .claude)
        #expect(scoped.byProject.map(\.path) == ["/w/alpha", "/w/beta"])
        // Kind.allCases は mcp → skill の順。
        #expect(scoped.byProject.last?.rows.map(\.name) == ["aaa", "zzz"])
    }
}

/// DESIGN.md 8 章 —「削除するには…」に出す 1 行。
/// **どのスコープを消すのかをコマンドに焼き込む。**
/// 既定に任せると、プロジェクトの分を消したつもりでユーザー全体が消える。
@Suite("削除コマンドの組み立て")
struct RemovalCommandTests {

    func row(_ name: String, kind: Kind, roots: [String] = [],
             origin: ResourceRow.Origin = .user) -> ResourceRow {
        ResourceRow(name: name, kind: kind, summary: nil, detail: "",
                    state: [:], origin: origin, isDisabled: false, roots: roots)
    }

    @Test("プロジェクトのタブでは cd と -s local が付く（ユーザー全体を消さない）")
    func projectPlugin() {
        let plugin = row("ponytail@ponytail", kind: .plugin)
        #expect(plugin.removalCommand(agent: .claude, project: "/w/auto-free")
                == "cd '/w/auto-free' && claude plugin remove ponytail@ponytail -s local")
        // ユーザー全体のタブでは、逆に user を明示する。
        #expect(plugin.removalCommand(agent: .claude)
                == "claude plugin remove ponytail@ponytail -s user")
        #expect(plugin.removalCommand(agent: .codex)
                == "codex plugin remove ponytail@ponytail")
    }

    @Test("MCP はスキャンで分かったスコープを載せる")
    func projectMCP() {
        let mcp = row("chrome-devtools", kind: .mcp)
        #expect(mcp.removalCommand(agent: .claude, project: "/w/app", mcpScope: "project")
                == "cd '/w/app' && claude mcp remove chrome-devtools -s project")
        #expect(mcp.removalCommand(agent: .claude, project: "/w/app", mcpScope: "local")
                == "cd '/w/app' && claude mcp remove chrome-devtools -s local")
        // スコープが分からなければ -s を付けない（CLI に在る方から消させる）。
        #expect(mcp.removalCommand(agent: .claude, project: "/w/app")
                == "cd '/w/app' && claude mcp remove chrome-devtools")
        #expect(mcp.removalCommand(agent: .claude) == "claude mcp remove chrome-devtools -s user")
    }

    @Test("Cursor は CLI が無いので設定ファイルを出す")
    func cursorHasNoCLI() {
        #expect(row("chrome-devtools", kind: .mcp).removalCommand(agent: .cursor)
                == "~/.cursor/mcp.json")
        #expect(row("x", kind: .plugin).removalCommand(agent: .cursor) == nil)
    }

    @Test("スキルはパス。プロジェクトのものは絶対パスで、空白があっても壊れない")
    func skills() {
        let skill = row("codiff", kind: .skill, roots: [".agents/skills"])
        #expect(skill.removalCommand(agent: .claude) == "rm -rf ~/.agents/skills/codiff")
        #expect(skill.removalCommand(agent: .claude, project: "/w/Free Projects/app")
                == "rm -rf '/w/Free Projects/app/.claude/skills/codiff'")
        let sub = row("reviewer", kind: .subagent, roots: [".claude/agents"])
        #expect(sub.removalCommand(agent: .claude) == "rm -rf ~/.claude/agents/reviewer.md")
    }

    @Test("同梱のものにはコマンドを出さない")
    func bundled() {
        #expect(row("automate", kind: .skill, roots: [".cursor/skills-cursor"],
                    origin: .bundled).removalCommand(agent: .cursor) == nil)
    }

    /// リソース名は他ツールが書いたファイル由来で、`runCleanup` は組み立てた文字列を
    /// `sh -c` に渡す。素で埋めると任意コマンドが走る。
    @Test("名前にシェルの特殊文字が入っていても引用される")
    func quotesHostileNames() {
        #expect(row("a; rm -rf ~", kind: .plugin).removalCommand(agent: .claude)
                == "claude plugin remove 'a; rm -rf ~' -s user")
        #expect(row("$(id)", kind: .skill, roots: [".agents/skills"])
                    .removalCommand(agent: .claude) == "rm -rf ~/.agents/skills/'$(id)'")
    }
}

/// DESIGN.md 5.2 — プロジェクトからの一括削除。
/// **ユーザーのリポジトリの中身はアプリから消さない。**
@Suite("一括削除の計画")
struct CleanupPlanTests {

    func row(_ name: String, kind: Kind, reach: ResourceRow.Reach) -> ResourceRow {
        ResourceRow(name: name, kind: kind, summary: nil, detail: "",
                    state: [:], origin: .user, isDisabled: false, reach: reach)
    }

    @Test("実行してよいのは CLI が自分の領域に持っている登録だけ")
    func executability() {
        let plugin = row("ponytail@ponytail", kind: .plugin, reach: .projects(["/w/a"]))
        #expect(plugin.isRemovalExecutable(mcpScope: nil))
        let mcp = row("chrome-devtools", kind: .mcp, reach: .projects(["/w/a"]))
        #expect(mcp.isRemovalExecutable(mcpScope: "local"))
        // <proj>/.mcp.json は git 共有のファイル。消したことが他の人にも及ぶ。
        #expect(!mcp.isRemovalExecutable(mcpScope: "project"))
        #expect(!row("x", kind: .skill, reach: .projects(["/w/a"])).isRemovalExecutable(mcpScope: nil))
        #expect(!row("y", kind: .subagent, reach: .projects(["/w/a"])).isRemovalExecutable(mcpScope: nil))
    }

    @Test("計画にはスコープ付きのコマンドが入り、実行可否で分かれる")
    func plan() {
        var inventory = Inventory(agents: [:], rows: [])
        var scan = ProjectScan()
        scan.mcpScopes["/w/a"] = ["shared": "project"]
        inventory.projectScan = scan

        let rows = [row("ponytail@ponytail", kind: .plugin, reach: .projects(["/w/a"])),
                    row("shared", kind: .mcp, reach: .projects(["/w/a"])),
                    row("repo-rules", kind: .skill, reach: .projects(["/w/a"]))]
        let items = inventory.cleanupItems(rows, agent: .claude, project: "/w/a")

        #expect(items.map(\.executable) == [true, false, false])
        #expect(items[0].command == "cd '/w/a' && claude plugin remove ponytail@ponytail -s local")
        #expect(items[1].command == "cd '/w/a' && claude mcp remove shared -s project")
        #expect(items[2].command == "rm -rf '/w/a/.claude/skills/repo-rules'")
    }
}
