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
