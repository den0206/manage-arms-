import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.3 — zip 展開。ネットワークは叩かない（10.6）。
@Suite("zip 展開と種別判定")
struct FetcherTests {

    static func temp() throws -> URL {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-fetch-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `python3 -c` で任意のエントリを持つ zip を作る。
    /// `links` は symlink エントリ（値がリンク先）。GitHub の zipball も同じ形で入る。
    static func makeZip(at url: URL, entries: [String: String],
                        links: [String: String] = [:]) throws {
        let script = """
        import zipfile, sys, json, stat
        with zipfile.ZipFile(sys.argv[1], 'w') as z:
            for name, body in json.loads(sys.argv[2]).items():
                z.writestr(name, body)
            for name, target in json.loads(sys.argv[3]).items():
                info = zipfile.ZipInfo(name)
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                z.writestr(info, target)
        """
        func json(_ value: [String: String]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = ["python3", "-c", script, url.path(percentEncoded: false),
                       try json(entries), try json(links)]
        try p.run()
        p.waitUntilExit()
    }

    @Test("ditto で展開できる")
    func extracts() async throws {
        let dir = try Self.temp()
        let zip = dir.appending(path: "a.zip")
        try Self.makeZip(at: zip, entries: ["repo-main/SKILL.md": "---\nname: x\n---\n"])
        let out = dir.appending(path: "out")
        try await Fetcher.extract(zip, to: out)
        #expect(FileManager.default.fileExists(
            atPath: out.appending(path: "repo-main/SKILL.md").path(percentEncoded: false)))
    }

    /// spike #13 で `ditto` の安全性は確認済みだが、
    /// OS 更新で挙動が変わった時に気づくためリグレッションとして残す（10.3）。
    @Test("Zip Slip — ../ を含むエントリが展開先の外に出ない")
    func zipSlip() async throws {
        let dir = try Self.temp()
        let zip = dir.appending(path: "slip.zip")
        try Self.makeZip(at: zip, entries: [
            "ok.txt": "fine",
            "../escaped.txt": "ESCAPED",
            "a/../../escaped2.txt": "ESCAPED",
        ])
        let out = dir.appending(path: "out")
        try await Fetcher.extract(zip, to: out)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dir.appending(path: "escaped.txt")
                                          .path(percentEncoded: false)),
                "展開先の外に書き出された")
        #expect(!fm.fileExists(atPath: dir.appending(path: "escaped2.txt")
                                          .path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: out.appending(path: "ok.txt").path(percentEncoded: false)))
    }

    @Test("zipball の <repo>-<branch>/ を 1 段剥がす")
    func stripsTopLevel() throws {
        let dir = try Self.temp()
        let inner = dir.appending(path: "skills-main")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(try Fetcher.singleTopLevel(of: dir).lastPathComponent == "skills-main")
    }

    @Test("トップレベルが複数なら剥がさない")
    func keepsMultipleTopLevel() throws {
        let dir = try Self.temp()
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(
                at: dir.appending(path: name), withIntermediateDirectories: true)
        }
        #expect(try Fetcher.singleTopLevel(of: dir) == dir)
    }

    /// `stage()` はアーカイブ全体を strict 検査しない。取り出さない場所
    /// （ルートの `AGENTS.md` → `CLAUDE.md` 等）が symlink でも導入は通る。
    /// symlink 自体は候補にならず、実体として入るものは `validate` が改めて弾く。
    @Test("取り出さない場所の symlink で展開と種別判定を落とさない")
    func extractsAlongsideSymlink() async throws {
        let dir = try Self.temp()
        let zip = dir.appending(path: "link.zip")
        try Self.makeZip(at: zip,
                         entries: ["repo-main/CLAUDE.md": "# guide\n",
                                   "repo-main/skills/x/SKILL.md": "---\nname: x\n---\n"],
                         links: ["repo-main/AGENTS.md": "CLAUDE.md"])
        let out = dir.appending(path: "out")
        await #expect(throws: Never.self) { try await Fetcher.extract(zip, to: out) }

        let base = try Fetcher.singleTopLevel(of: out)
        // 前提: ditto が symlink を symlink のまま展開している
        #expect(WriteGuard.isSymlink(base.appending(path: "AGENTS.md")))
        #expect(Fetcher.identify(base).map(\.name) == ["x"])
    }

    @Test("symlink の SKILL.md は読まない")
    func ignoresSymlinkedSkillFile() throws {
        let dir = try Self.temp()
        let outside = dir.appending(path: "secret.md")
        try "---\nname: leaked\ndescription: secret\n---\n".write(
            to: outside, atomically: true, encoding: .utf8)
        let base = dir.appending(path: "pkg")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appending(path: "SKILL.md"),
                                                   withDestinationURL: outside)
        #expect(Fetcher.identify(base).isEmpty)
    }

    @Test("展開物の symlink を拒否する")
    func rejectsExtractedSymlink() throws {
        let root = try Self.temp()
        let target = root.appending(path: "target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"),
                                                   withDestinationURL: target)
        #expect(throws: Fetcher.Failure.self) {
            try Fetcher.validateExtractedTree(root)
        }
        // アーカイブ全体の走査では上限だけを見る（取り出さない symlink で失敗させない）
        #expect(throws: Never.self) {
            try Fetcher.validateExtractedTree(root, strict: false)
        }
    }

    // MARK: - 種別判定（README のテキストからは推測しない）

    @Test("SKILL.md があれば skill。frontmatter の name を採る")
    func identifiesSkill() throws {
        let dir = try Self.temp()
        try "---\nname: ui-ux-pro-max\ndescription: >-\n  A skill\n---\n"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let found = Fetcher.identify(dir)
        #expect(found.count == 1)
        #expect(found.first?.kind == .skill)
        #expect(found.first?.name == "ui-ux-pro-max")
        #expect(found.first?.description == "A skill")
    }

    @Test("plugin.json があれば plugin")
    func identifiesPlugin() throws {
        let dir = try Self.temp()
        let meta = dir.appending(path: ".claude-plugin")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try "{}".write(to: meta.appending(path: "plugin.json"), atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).first?.kind == .plugin)
    }

    /// リポジトリ直下を貼られた場合、1 階層下に複数のスキルが並ぶことがある。
    @Test("サブディレクトリに並んだ複数スキルを拾う")
    func identifiesMultiple() throws {
        let dir = try Self.temp()
        for name in ["alpha", "beta"] {
            let sub = dir.appending(path: name)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\n---\n"
                .write(to: sub.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        }
        try FileManager.default.createDirectory(
            at: dir.appending(path: "docs"), withIntermediateDirectories: true)   // 無視される
        let found = Fetcher.identify(dir)
        #expect(found.map(\.name) == ["alpha", "beta"])
    }

    /// mattpocock/skills は `skills/<category>/<name>/SKILL.md`。
    /// 1 階層しか見ないと 37 個のスキルが 1 つも出てこない。
    @Test("2 段下に並んだスキルも拾う")
    func identifiesNested() throws {
        let dir = try Self.temp()
        let leaf = dir.appending(path: "skills/productivity/grilling")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try "---\nname: grilling\ndescription: d\n---\n"
            .write(to: leaf.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).map(\.name) == ["grilling"])
    }

    /// marketplace 兼スキル置き場のリポジトリ。plugin.json で打ち切ると
    /// 中のスキルが 1 つも選べなくなる。
    @Test("plugin.json があってもスキルを打ち切らない")
    func pluginDoesNotHideSkills() throws {
        let dir = try Self.temp()
        let meta = dir.appending(path: ".claude-plugin")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try "{}".write(to: meta.appending(path: "plugin.json"), atomically: true, encoding: .utf8)
        let leaf = dir.appending(path: "skills/productivity/grilling")
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        try "---\nname: grilling\ndescription: d\n---\n"
            .write(to: leaf.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let found = Fetcher.identify(dir)
        #expect(found.map(\.kind) == [.plugin, .skill])
        #expect(found.last?.name == "grilling")
    }

    /// 下層の `.md` まで frontmatter を読むと、ただの文書が候補に混ざる。
    @Test("Subagent の判定は指されたディレクトリ直下だけ")
    func subagentsAreNotSearchedDeep() throws {
        let dir = try Self.temp()
        let docs = dir.appending(path: "docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "---\nname: notes\ntools: Read\n---\n"
            .write(to: docs.appending(path: "notes.md"), atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).isEmpty)
    }

    /// frontmatter が危険な名前を名乗ったら、ディレクトリ名に落として拾う。
    /// **候補ごと捨てない** — 中身は正しいスキルかもしれない。
    @Test("危険な name を名乗る SKILL.md はディレクトリ名で拾う")
    func fallsBackToDirectoryName() throws {
        let dir = try Self.temp().appending(path: "grilling")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: ../../evil\ndescription: d\n---\n"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).map(\.name) == ["grilling"])
    }

    @Test("何も無ければ候補ゼロ")
    func identifiesNothing() throws {
        let dir = try Self.temp()
        try "# readme".write(to: dir.appending(path: "README.md"),
                             atomically: true, encoding: .utf8)
        #expect(Fetcher.identify(dir).isEmpty)
    }

    @Test("discard で一時ディレクトリが消える")
    func discardCleansUp() throws {
        let dir = try Self.temp()
        let staging = Staging(root: dir, source: GitHubSource(repo: "o/r"), candidates: [])
        staging.discard()
        #expect(!FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }
}

/// DESIGN.md 6 章 — 確認後の導入。
@Suite("導入")
struct InstallerTests {

    struct Fixture {
        let env: Environment
        var registry = Registry()
        let staging: Staging
        let candidate: Candidate

        init(name: String = "demo", description: String? = "d") throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-inst-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)

            let root = home.appending(path: "staging")
            let local = root.appending(path: name)
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: \(description ?? "")\n---\n"
                .write(to: local.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

            candidate = Candidate(kind: .skill, name: name,
                                  description: description, localURL: local)
            staging = Staging(root: root,
                              source: GitHubSource(repo: "o/r", branch: "main", subdir: "s/\(name)"),
                              candidates: [candidate])
        }
    }

    /// **F-1 の回帰テスト。** frontmatter の `name` は取得先が書いた文字列なので、
    /// そのままパスに使うと管理ルートの外へ書ける（9 章の作成方向の穴）。
    @Test("名前がパスに解決される候補は導入しない")
    func rejectsTraversalName() throws {
        var f = try Fixture()
        let evil = Candidate(kind: .skill, name: "../../.claude/skills/evil",
                             description: nil, localURL: f.candidate.localURL)
        #expect(throws: WriteGuard.Denial.self) {
            try Installer.install(evil, from: f.staging, env: f.env, registry: &f.registry)
        }
        // 管理ルートの外に何も作られていない
        let escaped = f.env.home.appending(path: ".claude/skills/evil")
        #expect(!FileManager.default.fileExists(atPath: escaped.path(percentEncoded: false)))
        #expect(f.registry.resources.isEmpty)
    }

    @Test("実体が置かれ registry に取得元が記録され Claude symlink が張られる")
    func installs() throws {
        var f = try Fixture()
        try Installer.install(f.candidate, from: f.staging, env: f.env, registry: &f.registry)

        let store = f.env.skillStore.appending(path: "demo")
        #expect(FileManager.default.fileExists(
            atPath: store.appending(path: "SKILL.md").path(percentEncoded: false)))
        #expect(WriteGuard.isSymlink(f.env.claudeSkills.appending(path: "demo")))

        let entry = try #require(f.registry.entry(named: "demo"))
        #expect(entry.repo == "o/r")
        #expect(entry.branch == "main")
        #expect(entry.subdir == "s/demo")
        // 永続化されている
        #expect(Registry.load(env: f.env).entry(named: "demo")?.repo == "o/r")
    }

    @Test("導入後は 3 エージェントすべてから見える")
    func visibleAfterInstall() throws {
        var f = try Fixture()
        try Installer.install(f.candidate, from: f.staging, env: f.env, registry: &f.registry)
        for dir in [".codex", ".cursor", ".gemini"] {
            try FileManager.default.createDirectory(
                at: f.env.home.appending(path: dir), withIntermediateDirectories: true)
        }
        let env = Environment.test(home: f.env.home,
                                   run: { $0.first == "which" ? "/bin/x\n" : "1.0\n" })
        let row = try #require(Inventory.load(env: env).rows.first { $0.name == "demo" })
        #expect(row.state[.claude] == .explicit)
        #expect(row.state[.cursor] == .explicit)
        #expect(row.state[.codex] == .explicit)
        #expect(row.isManaged, "registry に載っているので操作できるはず")
    }

    @Test("同名が既にあれば上書きせず失敗する")
    func doesNotOverwrite() throws {
        var f = try Fixture()
        let store = f.env.skillStore.appending(path: "demo")
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: store.appending(path: "SKILL.md"))

        #expect(throws: Installer.Failure.alreadyInstalled("demo")) {
            try Installer.install(f.candidate, from: f.staging, env: f.env, registry: &f.registry)
        }
        #expect(try Data(contentsOf: store.appending(path: "SKILL.md")) == Data("keep".utf8))
    }

    /// Claude 側に他ツールの symlink があると失敗する。半端な状態を残さないこと。
    @Test("失敗したら置いた実体を戻す")
    func rollsBackOnFailure() throws {
        var f = try Fixture()
        try FileManager.default.createDirectory(
            at: f.env.claudeSkills, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: f.env.claudeSkills.appending(path: "demo"),
            withDestinationURL: URL(filePath: "/elsewhere/demo"))

        #expect(throws: (any Error).self) {
            try Installer.install(f.candidate, from: f.staging, env: f.env, registry: &f.registry)
        }
        #expect(!FileManager.default.fileExists(
            atPath: f.env.skillStore.appending(path: "demo").path(percentEncoded: false)),
                "失敗したのに実体が残っている")
    }

    @Test("Skill 以外はまだ入れない")
    func skillOnly() throws {
        var f = try Fixture()
        let plugin = Candidate(kind: .plugin, name: "p", description: nil,
                               localURL: f.candidate.localURL)
        #expect(throws: Installer.Failure.unsupportedKind(.plugin)) {
            try Installer.install(plugin, from: f.staging, env: f.env, registry: &f.registry)
        }
    }
}
