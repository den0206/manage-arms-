import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 9 章 / 10.3 — ホワイトリストの外に出ないこと。
/// ここが破られるとユーザーのデータが消える。
@Suite("触ってよい対象の限定")
struct WriteGuardTests {

    struct Fixture {
        let env: Environment
        var registry = Registry()

        init() throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-guard-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)
        }

        @discardableResult
        mutating func managedSkill(_ name: String) throws -> URL {
            let dir = env.skillStore.appending(path: name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: d\n---\n"
                .write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            registry.upsert(Registry.Entry(name: name, kind: .skill))
            return dir
        }

        func makeDir(_ url: URL) throws -> URL {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    @Test("registry に載っている実体は触れる")
    func managedIsMutable() throws {
        var f = try Fixture()
        let dir = try f.managedSkill("mine")
        #expect(throws: Never.self) {
            try WriteGuard.assertMutable(dir, env: f.env, registry: f.registry)
        }
    }

    /// `vercel-labs/skills` が入れた `find-skills` 等。表示のみ・操作不可。
    @Test("registry に無い外部スキルは拒否される")
    func externalSkillRejected() throws {
        let f = try Fixture()
        let dir = try f.makeDir(f.env.skillStore.appending(path: "find-skills"))
        #expect(throws: WriteGuard.Denial.notInRegistry("find-skills")) {
            try WriteGuard.assertMutable(dir, env: f.env, registry: f.registry)
        }
    }

    @Test("実体置き場の外は拒否される")
    func outsideStoreRejected() throws {
        var f = try Fixture()
        f.registry.upsert(Registry.Entry(name: "skills", kind: .skill))
        let outside = try f.makeDir(f.env.home.appending(path: ".cursor/skills-cursor/canvas"))
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(outside, env: f.env, registry: f.registry)
        }
    }

    @Test("自分が張った symlink は触れる")
    func ownSymlinkIsMutable() throws {
        var f = try Fixture()
        let target = try f.managedSkill("mine")
        let link = f.env.claudeSkills.appending(path: "mine")
        _ = try f.makeDir(f.env.claudeSkills)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: Never.self) {
            try WriteGuard.assertMutable(link, env: f.env, registry: f.registry)
        }
    }

    /// Codiff.app が張ったような他ツールの symlink には触らない。
    @Test("実体置き場の外を指す symlink は拒否される")
    func foreignSymlinkRejected() throws {
        let f = try Fixture()
        let link = f.env.claudeSkills.appending(path: "codiff")
        _ = try f.makeDir(f.env.claudeSkills)
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: URL(filePath: "/Applications/Codiff.app/skills/codiff"))
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(link, env: f.env, registry: f.registry)
        }
    }

    /// ホワイトリストの実装ミス 1 つで到達しうる場所（9 章の二重チェック）。
    @Test("無条件拒否のパス", arguments: [
        ".codex/auth.json", ".gemini/oauth_creds.json", ".claude/settings.json",
        ".claude.json", ".codex/config.toml", ".cursor/mcp.json",
        ".codex/logs_2.sqlite", ".claude/settings.local.json",
    ])
    func deniedPaths(_ relative: String) throws {
        let f = try Fixture()
        let url = f.env.home.appending(path: relative)
        #expect(throws: WriteGuard.Denial.deniedPath(url.standardized.path(percentEncoded: false))) {
            try WriteGuard.assertMutable(url, env: f.env, registry: f.registry)
        }
    }

    /// `..` で実体置き場から抜けられないこと。
    @Test("パス境界を跨ぐ .. は拒否される")
    func traversalRejected() throws {
        var f = try Fixture()
        f.registry.upsert(Registry.Entry(name: "auth.json", kind: .skill))
        let escape = f.env.skillStore.appending(path: "../../.codex/auth.json")
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(escape, env: f.env, registry: f.registry)
        }
    }

    /// 前方一致だけだと `.agents/skills-other` が通ってしまう。
    @Test("接頭辞が同じだけの別ディレクトリは拒否される")
    func siblingPrefixRejected() throws {
        var f = try Fixture()
        f.registry.upsert(Registry.Entry(name: "x", kind: .skill))
        let sibling = f.env.home.appending(path: ".agents/skills-other/x")
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(sibling, env: f.env, registry: f.registry)
        }
    }

    @Test("安全なリソース名は変更せず受け入れる", arguments: ["demo", "my skill", "日本語", "demo.md"])
    func acceptsResourceName(_ name: String) throws {
        try WriteGuard.assertValidName(name)
    }

    @Test("空や制御文字のリソース名を拒否する", arguments: ["", " ", "bad\u{0000}name", "bad\nname"])
    func rejectsEmptyOrControlName(_ name: String) {
        #expect(throws: WriteGuard.Denial.invalidName(name)) {
            try WriteGuard.assertValidName(name)
        }
    }

    @Test("管理ルートの symlink 越しに実体を変更しない")
    func rejectsRedirectedManagedRoot() throws {
        var f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.env.home) }
        let outside = try f.makeDir(f.env.home.appending(path: "outside"))
        _ = try f.makeDir(outside.appending(path: "mine"))
        _ = try f.makeDir(f.env.skillStore.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: f.env.skillStore, withDestinationURL: outside)
        f.registry.upsert(Registry.Entry(name: "mine", kind: .skill))
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(f.env.skillStore.appending(path: "mine"), env: f.env, registry: f.registry)
        }
    }

    @Test("管理ルート内を経由して外に出る二段 symlink を拒否する")
    func rejectsChainedSymlink() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.env.home) }
        let outside = try f.makeDir(f.env.home.appending(path: "outside"))
        _ = try f.makeDir(f.env.skillStore)
        _ = try f.makeDir(f.env.claudeSkills)
        let target = f.env.skillStore.appending(path: "mine")
        let link = f.env.claudeSkills.appending(path: "mine")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(link, env: f.env, registry: f.registry)
        }
    }

    @Test("管理リンクでも未知の配置場所には触れない")
    func rejectsLinkOutsideKnownRoots() throws {
        var f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.env.home) }
        let target = try f.managedSkill("mine")
        let link = f.env.home.appending(path: "foreign-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertMutable(link, env: f.env, registry: f.registry)
        }
    }

    @Test(".md で終わる Skill も保存先で種別を判定する")
    func skillWithMarkdownSuffix() throws {
        var f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.env.home) }
        _ = try f.managedSkill("demo.md")
        try SkillManager.disable("demo.md", env: f.env, registry: &f.registry)
        try SkillManager.enable("demo.md", env: f.env, registry: &f.registry)
        #expect(f.registry.entry(named: "demo.md", kind: .skill)?.disabled == false)
    }

    @Test("有効化でも不正な名前を実体移動やリンク作成より先に拒否する")
    func enableRejectsTraversal() throws {
        var f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.env.home) }
        let name = "../../escaped"
        _ = try f.makeDir(f.env.home.appending(path: "escaped"))
        f.registry.upsert(Registry.Entry(name: name, kind: .skill))
        #expect(throws: WriteGuard.Denial.invalidName(name)) {
            try SkillManager.enable(name, env: f.env, registry: &f.registry)
        }
        #expect(!FileManager.default.fileExists(atPath: f.env.registryFile.path))
        #expect(!FileManager.default.fileExists(atPath: f.env.claudeSkills.path))
    }
}
