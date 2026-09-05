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
}
