import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.3 — 偽ホームだけを触る。
@Suite("スキルの有効化 / 無効化")
struct SkillManagerTests {

    struct Fixture {
        let env: Environment
        var registry = Registry()
        let fm = FileManager.default

        init() throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-mgr-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)
        }

        /// 有効な状態のスキルを用意する（実体 + Claude symlink + registry）。
        mutating func install(_ name: String) throws {
            let dir = env.skillStore.appending(path: name)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\n---\n"
                .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            registry.upsert(Registry.Entry(name: name, kind: .skill))
            try SkillManager.enable(name, env: env, registry: &registry)
        }

        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path(percentEncoded: false)) }
        func isLink(_ url: URL) -> Bool { WriteGuard.isSymlink(url) }
        func store(_ n: String) -> URL { env.skillStore.appending(path: n) }
        func parked(_ n: String) -> URL { env.disabledStore.appending(path: n) }
        func link(_ n: String) -> URL { env.claudeSkills.appending(path: n) }
    }

    @Test("有効化で実体が置き場に残り Claude symlink が張られる")
    func enableCreatesLink() throws {
        var f = try Fixture()
        try f.install("demo")
        #expect(f.exists(f.store("demo")))
        #expect(f.isLink(f.link("demo")))
        #expect(f.exists(f.link("demo").appending(path: "SKILL.md")))   // リンク先が生きている
    }

    @Test("有効化後は 3 エージェントすべてから見える")
    func enableIsVisibleEverywhere() throws {
        var f = try Fixture()
        try f.install("demo")
        for dir in [".codex", ".cursor", ".gemini"] {
            try f.fm.createDirectory(at: f.env.home.appending(path: dir),
                                     withIntermediateDirectories: true)
        }
        let env = Environment.test(home: f.env.home,
                                   run: { $0.first == "which" ? "/bin/x\n" : "1.0\n" })
        let row = try #require(Inventory.load(env: env).rows.first)
        #expect(row.state[.claude] == .explicit)
        #expect(row.state[.cursor] == .explicit)
        #expect(row.state[.codex] == .explicit)
    }

    /// **最重要**（10.3）。symlink を外して実体まで消したらユーザーのスキルが飛ぶ。
    @Test("無効化しても実体は消えない（退避されるだけ）")
    func disableKeepsContent() throws {
        var f = try Fixture()
        try f.install("demo")
        let body = try Data(contentsOf: f.store("demo").appending(path: "SKILL.md"))

        try SkillManager.disable("demo", env: f.env, registry: &f.registry)

        #expect(!f.exists(f.link("demo")), "symlink が残っている")
        #expect(!f.exists(f.store("demo")), "実体が置き場に残っている")
        #expect(f.exists(f.parked("demo")), "退避されていない")
        let moved = try Data(contentsOf: f.parked("demo").appending(path: "SKILL.md"))
        #expect(moved == body, "中身が変わっている")
    }

    @Test("無効化 → 再有効化の往復で元に戻る")
    func roundTrip() throws {
        var f = try Fixture()
        try f.install("demo")
        try SkillManager.disable("demo", env: f.env, registry: &f.registry)
        try SkillManager.enable("demo", env: f.env, registry: &f.registry)

        #expect(f.exists(f.store("demo")))
        #expect(f.isLink(f.link("demo")))
        #expect(!f.exists(f.parked("demo")))
        #expect(f.registry.entry(named: "demo")?.disabled == false)
    }

    @Test("無効化は registry に記録される")
    func disabledIsRecorded() throws {
        var f = try Fixture()
        try f.install("demo")
        try SkillManager.disable("demo", env: f.env, registry: &f.registry)
        #expect(f.registry.entry(named: "demo")?.disabled == true)
        // 永続化されている
        #expect(Registry.load(env: f.env).entry(named: "demo")?.disabled == true)
    }

    /// Codiff.app のような他ツールの symlink を巻き込まない。
    @Test("他ツールの symlink があると上書きせず失敗する")
    func doesNotClobberForeignSymlink() throws {
        var f = try Fixture()
        try f.fm.createDirectory(at: f.env.claudeSkills, withIntermediateDirectories: true)
        try f.fm.createSymbolicLink(at: f.link("demo"),
                                    withDestinationURL: URL(filePath: "/elsewhere/demo"))
        let dir = f.store("demo")
        try f.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        f.registry.upsert(Registry.Entry(name: "demo", kind: .skill))

        #expect(throws: WriteGuard.Denial.self) {
            try SkillManager.enable("demo", env: f.env, registry: &f.registry)
        }
        // 他ツールの symlink は残っている
        #expect(WriteGuard.symlinkTarget(f.link("demo"))?.path(percentEncoded: false) == "/elsewhere/demo")
    }

    @Test("Claude 側に実体ディレクトリがあると上書きしない")
    func doesNotClobberRealDirectory() throws {
        var f = try Fixture()
        let existing = f.link("demo")
        try f.fm.createDirectory(at: existing, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: existing.appending(path: "SKILL.md"))
        try f.fm.createDirectory(at: f.store("demo"), withIntermediateDirectories: true)
        f.registry.upsert(Registry.Entry(name: "demo", kind: .skill))

        #expect(throws: SkillManager.Failure.self) {
            try SkillManager.enable("demo", env: f.env, registry: &f.registry)
        }
        #expect(try Data(contentsOf: existing.appending(path: "SKILL.md"))
                == Data("keep me".utf8))
    }

    /// registry に無いものは外部管理。無効化させない（9 章）。
    @Test("外部管理スキルは無効化できない")
    func externalCannotBeDisabled() throws {
        var f = try Fixture()
        let dir = f.store("find-skills")
        try f.fm.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: WriteGuard.Denial.notInRegistry("find-skills")) {
            try SkillManager.disable("find-skills", env: f.env, registry: &f.registry)
        }
        #expect(f.exists(dir), "外部管理スキルが動かされた")
    }

    @Test("存在しないスキルは notFound")
    func missing() throws {
        var f = try Fixture()
        #expect(throws: SkillManager.Failure.notFound("nope")) {
            try SkillManager.disable("nope", env: f.env, registry: &f.registry)
        }
        #expect(throws: SkillManager.Failure.notFound("nope")) {
            try SkillManager.enable("nope", env: f.env, registry: &f.registry)
        }
    }

    @Test("退避先に同名があれば上書きせず失敗する")
    func doesNotClobberParked() throws {
        var f = try Fixture()
        try f.install("demo")
        try f.fm.createDirectory(at: f.parked("demo"), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: f.parked("demo").appending(path: "SKILL.md"))

        #expect(throws: SkillManager.Failure.self) {
            try SkillManager.disable("demo", env: f.env, registry: &f.registry)
        }
        #expect(try Data(contentsOf: f.parked("demo").appending(path: "SKILL.md"))
                == Data("old".utf8))
        #expect(f.exists(f.store("demo")), "失敗したのに実体が動いた")
    }
}

/// `~/Library/Application Support/ManageArms` は必ず空白を含む。
/// `URL.path()` はデフォルトでパーセントエンコードするため、
/// 素朴に使うと `Application%20Support` になり FileManager が全て失敗する。
@Suite("空白を含むパス")
struct SpacedPathTests {

    @Test("空白を含むホームでも有効化 / 無効化が動く")
    func spacesInPath() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage arms space \(UUID().uuidString)")
        let fm = FileManager.default
        let env = Environment.test(home: home)
        let dir = env.skillStore.appending(path: "demo")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: d\n---\n"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        var registry = Registry()
        registry.upsert(Registry.Entry(name: "demo", kind: .skill))
        try SkillManager.enable("demo", env: env, registry: &registry)
        #expect(WriteGuard.isSymlink(env.claudeSkills.appending(path: "demo")))

        try SkillManager.disable("demo", env: env, registry: &registry)
        #expect(fm.fileExists(atPath: env.disabledStore.appending(path: "demo")
                                        .path(percentEncoded: false)))
        // registry.json も空白を含むパスに書けている
        #expect(Registry.load(env: env).entry(named: "demo")?.disabled == true)
    }

    @Test("走査も空白を含むパスで動く")
    func scanWithSpaces() throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage arms scan \(UUID().uuidString)")
        let dir = home.appending(path: ".agents/skills/demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: demo\ndescription: d\n---\n"
            .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let skills = SkillScanner.scan(env: Environment.test(home: home))
        #expect(skills.count == 1)
        #expect(skills.first?.description == "d")
    }
}

/// DESIGN.md 8 章 — 削除。実体はゴミ箱へ移すので Finder から戻せる。
/// **ゴミ箱に入った物はテストの後片付けで消す**（実ユーザーのゴミ箱に残さない）。
@Suite("スキルの削除")
struct SkillRemoveTests {

    @Test("削除で symlink・実体・registry が消える")
    func removes() throws {
        var f = try SkillManagerTests.Fixture()
        try f.install("demo")

        let trashed = try SkillManager.remove("demo", env: f.env, registry: &f.registry)
        #expect(!f.exists(f.store("demo")))
        #expect(!f.isLink(f.link("demo")))
        #expect(f.registry.entry(named: "demo") == nil)
        #expect(Registry.load(env: f.env).entry(named: "demo") == nil)
        try trashed.map { try f.fm.removeItem(at: $0) }
    }

    @Test("無効化中でも削除できる（退避先から消す）")
    func removesParked() throws {
        var f = try SkillManagerTests.Fixture()
        try f.install("demo")
        try SkillManager.disable("demo", env: f.env, registry: &f.registry)

        let trashed = try SkillManager.remove("demo", env: f.env, registry: &f.registry)
        #expect(!f.exists(f.parked("demo")))
        #expect(f.registry.entry(named: "demo") == nil)
        try trashed.map { try f.fm.removeItem(at: $0) }
    }

    @Test("registry に無いものは削除できない（他ツールが入れたスキルを消さない）")
    func refusesForeign() throws {
        let f = try SkillManagerTests.Fixture()
        var registry = Registry()
        let dir = f.env.skillStore.appending(path: "foreign")
        try f.fm.createDirectory(at: dir, withIntermediateDirectories: true)

        #expect(throws: WriteGuard.Denial.notInRegistry("foreign")) {
            try SkillManager.remove("foreign", env: f.env, registry: &registry)
        }
        #expect(f.exists(dir))
    }
}
