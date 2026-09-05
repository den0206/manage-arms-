import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.2 — Subagent は単一の `.md`。共有ルートが無いので symlink は 2 本。
@Suite("Subagent の走査")
struct SubagentScannerTests {

    struct Fixture {
        let env: Environment
        let fm = FileManager.default
        init() throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-sub-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)
        }
        @discardableResult
        func write(_ root: String, _ file: String, _ body: String) throws -> URL {
            let dir = env.home.appending(path: root)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appending(path: file)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    /// 実在する形式（school-clique の typescript-reviewer.md）。
    static let real = """
        ---
        name: typescript-reviewer
        description: Expert TypeScript code reviewer specializing in type safety.
        tools: ["Read", "Grep", "Glob", "Bash"]
        model: sonnet
        ---

        You are a senior TypeScript engineer.
        """

    @Test("frontmatter から description を取る")
    func reads() throws {
        let f = try Fixture()
        try f.write(".claude/agents", "typescript-reviewer.md", Self.real)
        let found = SubagentScanner.scan(env: f.env)
        #expect(found.count == 1)
        #expect(found.first?.name == "typescript-reviewer")
        #expect(found.first?.description
                == "Expert TypeScript code reviewer specializing in type safety.")
        #expect(found.first?.status == .ok)
    }

    /// 識別子はファイル名。frontmatter の name とズレたら
    /// 有効化 / 無効化がファイルを見つけられなくなる。
    @Test("識別子はファイル名（frontmatter の name ではない）")
    func nameFromFilename() throws {
        let f = try Fixture()
        try f.write(".claude/agents", "on-disk-name.md",
                    "---\nname: different-in-frontmatter\ndescription: d\n---\n")
        #expect(SubagentScanner.scan(env: f.env).first?.name == "on-disk-name")
    }

    @Test(".md 以外は拾わない")
    func onlyMarkdown() throws {
        let f = try Fixture()
        try f.write(".claude/agents", "README.txt", "x")
        try f.write(".claude/agents", ".hidden.md", "x")
        #expect(SubagentScanner.scan(env: f.env).isEmpty)
    }

    @Test("リンク切れ symlink を brokenLink として報告する")
    func brokenLink() throws {
        let f = try Fixture()
        let dir = f.env.home.appending(path: ".claude/agents")
        try f.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try f.fm.createSymbolicLink(at: dir.appending(path: "gone.md"),
                                    withDestinationURL: URL(filePath: "/nope/gone.md"))
        let found = SubagentScanner.scan(env: f.env)
        #expect(found.first?.status == .brokenLink)
        #expect(found.first?.isLoadable == false)
    }

    /// Cursor は Skills では他社ディレクトリを読むが、Subagent では読まない。
    @Test("Cursor の走査先は .cursor/agents だけ")
    func cursorReadsOnlyItsOwn() {
        #expect(Agent.cursor.subagentRoots == [".cursor/agents"])
        #expect(Agent.claude.subagentRoots == [".claude/agents"])
        #expect(Agent.codex.subagentRoots.isEmpty)
        #expect(Agent.gemini.subagentRoots.isEmpty)
    }
}

@Suite("Subagent の有効化 / 無効化")
struct SubagentManagerTests {

    struct Fixture {
        let env: Environment
        var registry = Registry()
        let fm = FileManager.default

        init() throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-subm-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)
        }

        mutating func install(_ name: String) throws {
            let store = env.agentStore.appending(path: "\(name).md")
            try fm.createDirectory(at: env.agentStore, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\ntools: [\"Read\"]\n---\n"
                .write(to: store, atomically: true, encoding: .utf8)
            registry.upsert(Registry.Entry(name: name, kind: .subagent))
            try SubagentManager.enable(name, env: env, registry: &registry)
        }
        func claudeLink(_ n: String) -> URL { env.home.appending(path: ".claude/agents/\(n).md") }
        func cursorLink(_ n: String) -> URL { env.home.appending(path: ".cursor/agents/\(n).md") }
        func store(_ n: String) -> URL { env.agentStore.appending(path: "\(n).md") }
        func parked(_ n: String) -> URL { env.disabledAgentStore.appending(path: "\(n).md") }
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path(percentEncoded: false)) }
    }

    @Test("有効化で symlink が 2 本張られる")
    func createsTwoLinks() throws {
        var f = try Fixture()
        try f.install("reviewer")
        #expect(WriteGuard.isSymlink(f.claudeLink("reviewer")))
        #expect(WriteGuard.isSymlink(f.cursorLink("reviewer")))
        #expect(f.exists(f.claudeLink("reviewer")))   // リンク先が生きている
    }

    @Test("有効化後は Claude と Cursor から見える。Codex / Gemini は非対応")
    func visibility() throws {
        var f = try Fixture()
        try f.install("reviewer")
        for dir in [".codex", ".cursor", ".gemini", ".claude"] {
            try? f.fm.createDirectory(at: f.env.home.appending(path: dir),
                                      withIntermediateDirectories: true)
        }
        let env = Environment.test(home: f.env.home,
                                   run: { $0.first == "which" ? "/bin/x\n" : "1.0\n" })
        let row = try #require(Inventory.load(env: env).rows.first { $0.kind == .subagent })
        #expect(row.state[.claude] == .explicit)
        #expect(row.state[.cursor] == .explicit)
        #expect(row.state[.codex] == .unsupported)
        #expect(row.state[.gemini] == .unsupported)
    }

    /// Skills と同じく最重要。symlink を外して実体を消してはいけない。
    @Test("無効化しても実体は消えない")
    func disableKeepsContent() throws {
        var f = try Fixture()
        try f.install("reviewer")
        let body = try Data(contentsOf: f.store("reviewer"))

        try SubagentManager.disable("reviewer", env: f.env, registry: &f.registry)
        #expect(!f.exists(f.claudeLink("reviewer")))
        #expect(!f.exists(f.cursorLink("reviewer")))
        #expect(!f.exists(f.store("reviewer")))
        #expect(try Data(contentsOf: f.parked("reviewer")) == body)
    }

    @Test("往復で元に戻る")
    func roundTrip() throws {
        var f = try Fixture()
        try f.install("reviewer")
        try SubagentManager.disable("reviewer", env: f.env, registry: &f.registry)
        try SubagentManager.enable("reviewer", env: f.env, registry: &f.registry)
        #expect(f.exists(f.store("reviewer")))
        #expect(WriteGuard.isSymlink(f.claudeLink("reviewer")))
        #expect(!f.exists(f.parked("reviewer")))
    }

    @Test("registry に無いものは無効化できない")
    func externalProtected() throws {
        var f = try Fixture()
        try f.fm.createDirectory(at: f.env.agentStore, withIntermediateDirectories: true)
        try "---\nname: x\n---\n".write(to: f.store("outsider"),
                                        atomically: true, encoding: .utf8)
        #expect(throws: WriteGuard.Denial.notInRegistry("outsider")) {
            try SubagentManager.disable("outsider", env: f.env, registry: &f.registry)
        }
        #expect(f.exists(f.store("outsider")))
    }

    @Test("既存の実体ファイルは上書きしない")
    func doesNotClobber() throws {
        var f = try Fixture()
        let link = f.claudeLink("reviewer")
        try f.fm.createDirectory(at: link.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: link)
        try f.fm.createDirectory(at: f.env.agentStore, withIntermediateDirectories: true)
        try "---\nname: reviewer\n---\n".write(to: f.store("reviewer"),
                                               atomically: true, encoding: .utf8)
        f.registry.upsert(Registry.Entry(name: "reviewer", kind: .subagent))

        #expect(throws: SkillManager.Failure.self) {
            try SubagentManager.enable("reviewer", env: f.env, registry: &f.registry)
        }
        #expect(try Data(contentsOf: link) == Data("keep".utf8))
    }
}

/// DESIGN.md 6 章 — 取得した中身を見て種別を決める。README からは推測しない。
@Suite("Subagent の判定と導入")
struct SubagentIdentifyTests {

    static func temp() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("frontmatter に tools があれば subagent")
    func identifiesSubagent() throws {
        let dir = try Self.temp()
        try """
        ---
        name: reviewer
        description: Reviews code.
        tools: ["Read", "Grep"]
        ---
        """.write(to: dir.appending(path: "reviewer.md"), atomically: true, encoding: .utf8)
        let found = Fetcher.identify(dir)
        #expect(found.count == 1)
        #expect(found.first?.kind == .subagent)
        #expect(found.first?.name == "reviewer")
        #expect(found.first?.description == "Reviews code.")
    }

    /// tools が無い `.md` は subagent ではない。README.md を誤検出しないこと。
    @Test("tools が無ければ subagent ではない")
    func requiresTools() throws {
        let dir = try Self.temp()
        try "---\nname: x\ndescription: d\n---\n"
            .write(to: dir.appending(path: "note.md"), atomically: true, encoding: .utf8)
        try "# readme".write(to: dir.appending(path: "README.md"),
                             atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).isEmpty)
    }

    /// SKILL.md がある場合はスキルが優先。両方拾って重複させない。
    @Test("SKILL.md があればスキルとして扱う")
    func skillWins() throws {
        let dir = try Self.temp()
        try "---\nname: s\ndescription: d\n---\n"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: a\ntools: [\"Read\"]\n---\n"
            .write(to: dir.appending(path: "agent.md"), atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).map(\.kind) == [.skill])
    }

    @Test("導入すると実体が App Support に置かれ symlink が 2 本張られる")
    func installs() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-subi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let env = Environment.test(home: home)

        let staged = try Self.temp()
        let file = staged.appending(path: "reviewer.md")
        try "---\nname: reviewer\ndescription: d\ntools: [\"Read\"]\n---\n"
            .write(to: file, atomically: true, encoding: .utf8)
        let candidate = Candidate(kind: .subagent, name: "reviewer", description: "d",
                                  localURL: file)
        let staging = Staging(root: staged, source: GitHubSource(repo: "o/r", branch: "main"),
                              candidates: [candidate])

        var registry = Registry()
        try Installer.install(candidate, from: staging, env: env, registry: &registry)

        let fm = FileManager.default
        #expect(fm.fileExists(atPath: env.agentStore.appending(path: "reviewer.md")
                                        .path(percentEncoded: false)))
        #expect(WriteGuard.isSymlink(home.appending(path: ".claude/agents/reviewer.md")))
        #expect(WriteGuard.isSymlink(home.appending(path: ".cursor/agents/reviewer.md")))
        #expect(registry.entry(named: "reviewer")?.repo == "o/r")
    }
}
