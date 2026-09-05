import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.3 — 偽ホームだけを触る。実ユーザーの ~/.claude には到達しない。
@Suite("スキル走査")
struct SkillScannerTests {

    struct Fixture {
        let home: URL
        let env: Environment

        init() throws {
            home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-scan-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)
        }

        @discardableResult
        func skill(_ root: String, _ name: String, body: String) throws -> URL {
            let dir = home.appending(path: "\(root)/\(name)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try body.write(to: dir.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            return dir
        }

        func dir(_ path: String) throws -> URL {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    static func valid(_ name: String) -> String {
        "---\nname: \(name)\ndescription: desc of \(name)\n---\n\nbody\n"
    }

    @Test("実体ルートのスキルを読む")
    func readsStore() throws {
        let f = try Fixture()
        try f.skill(".agents/skills", "alpha", body: Self.valid("alpha"))
        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.count == 1)
        #expect(skills.first?.name == "alpha")
        #expect(skills.first?.description == "desc of alpha")
        #expect(skills.first?.status == .ok)
        #expect(skills.first?.root == ".agents/skills")
    }

    @Test("7 つのスキルルートすべてを走査する")
    func scansEveryRoot() throws {
        let f = try Fixture()
        for source in Source.skills {
            try f.skill(source.relativePath!, "s", body: Self.valid("s"))
        }
        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.count == Source.skills.count)
        #expect(Set(skills.map(\.root)) == Set(Source.skills.compactMap(\.relativePath)))
    }

    /// `~/.claude/skills/codiff` が実際にこの状態にある（付録）。
    /// クラッシュせず「リンク切れ」と表示できること。
    @Test("リンク切れ symlink を brokenLink として報告する")
    func brokenSymlink() throws {
        let f = try Fixture()
        let root = try f.dir(".claude/skills")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "gone"),
            withDestinationURL: URL(filePath: "/nonexistent/path/gone"))
        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.count == 1)
        #expect(skills.first?.status == .brokenLink)
        #expect(skills.first?.name == "gone")
    }

    @Test("生きている symlink は普通に読める")
    func liveSymlink() throws {
        let f = try Fixture()
        let target = try f.skill(".agents/skills", "shared", body: Self.valid("shared"))
        let root = try f.dir(".claude/skills")
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "shared"), withDestinationURL: target)

        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.count == 2)
        #expect(skills.allSatisfy { $0.status == .ok })
        // 同名は 1 行にまとまる（5.2 のマトリクス行）
        let groups = SkillScanner.grouped(skills)
        #expect(groups.count == 1)
        #expect(groups["shared"]?.count == 2)
        #expect(Set(groups["shared"]!.map(\.root)) == [".agents/skills", ".claude/skills"])
    }

    @Test("SKILL.md が無いディレクトリは noSkillFile")
    func noSkillFile() throws {
        let f = try Fixture()
        try f.dir(".agents/skills/empty")
        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.first?.status == .noSkillFile)
    }

    @Test("frontmatter が無ければ missingFrontmatter")
    func missingFrontmatter() throws {
        let f = try Fixture()
        try f.skill(".agents/skills", "bare", body: "# no frontmatter\n")
        #expect(SkillScanner.scan(env: f.env).first?.status == .missingFrontmatter)
    }

    @Test("4 KB に収まらない frontmatter は truncatedFrontmatter")
    func truncatedFrontmatter() throws {
        let f = try Fixture()
        try f.skill(".agents/skills", "big",
                    body: "---\ndescription: \(String(repeating: "z", count: 5000))\n---\n")
        #expect(SkillScanner.scan(env: f.env).first?.status == .truncatedFrontmatter)
    }

    /// Cursor の `.sync-manifest.json` / Codex の `.system` を拾わないこと。
    @Test("ドット始まりのエントリは無視する")
    func ignoresDotEntries() throws {
        let f = try Fixture()
        let root = try f.dir(".codex/skills")
        try f.dir(".codex/skills/.system/imagegen")
        try Data().write(to: root.appending(path: ".sync-manifest.json"))
        try f.skill(".codex/skills", "real", body: Self.valid("real"))
        let skills = SkillScanner.scan(env: f.env)
        #expect(skills.map(\.name) == ["real"])
    }

    @Test("ルートが存在しなくてもクラッシュしない")
    func missingRoots() throws {
        let f = try Fixture()
        #expect(SkillScanner.scan(env: f.env).isEmpty)
    }

    @Test("ディレクトリでないファイルはスキルとして拾わない")
    func ignoresPlainFiles() throws {
        let f = try Fixture()
        let root = try f.dir(".agents/skills")
        try Data().write(to: root.appending(path: "README.md"))
        #expect(SkillScanner.scan(env: f.env).isEmpty)
    }
}
