import Foundation
import Testing
@testable import AgentToolCore

///  — 更新は差分を見せてから適用する。
@Suite("更新の差分と適用")
struct UpdaterTests {

    @Test("行の追加と削除を拾う")
    func diffsLines() {
        let old = ["---", "name: x", "Always use Tailwind v3 syntax", "---"]
        let new = ["---", "name: x", "Always use Tailwind v4 syntax", "---"]
        let diff = Updater.diff(old: old, new: new)
        #expect(diff.contains(DiffLine(kind: .removed, text: "Always use Tailwind v3 syntax")))
        #expect(diff.contains(DiffLine(kind: .added, text: "Always use Tailwind v4 syntax")))
        #expect(diff.count == 2)
    }

    @Test("変化が無ければ空")
    func noDiff() {
        #expect(Updater.diff(old: ["a", "b"], new: ["a", "b"]).isEmpty)
    }

    @Test("SKILL.md が同じでも scripts の変更を拾う")
    func detectsWholeTreeChanges() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        let old = root.appending(path: "old"), new = root.appending(path: "new")
        for directory in [old, new] {
            try FileManager.default.createDirectory(at: directory.appending(path: "scripts"),
                                                    withIntermediateDirectories: true)
            try "same".write(to: directory.appending(path: "SKILL.md"),
                             atomically: true, encoding: .utf8)
        }
        try "old".write(to: old.appending(path: "scripts/run.sh"), atomically: true,
                        encoding: .utf8)
        try "new".write(to: new.appending(path: "scripts/run.sh"), atomically: true,
                        encoding: .utf8)
        let diff = try Updater.treeDiff(old: Updater.manifest(of: old),
                                        new: Updater.manifest(of: new))
        #expect(diff.contains { $0.text.contains("scripts/run.sh") })
    }

    @Test("適用中の staging は画面から破棄できない")
    func stagingOwnership() throws {
        let root = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = Staging(root: root, source: .init(repo: "o/r"), candidates: [])
        #expect(staging.claimForApply())
        staging.discard()
        #expect(FileManager.default.fileExists(atPath: root.path))
        staging.releaseAfterFailure()
        staging.discard()
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("CRLF は差分に出ない")
    func crlfNormalized() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = dir.appending(path: "a.md"), b = dir.appending(path: "b.md")
        try "line1\r\nline2\r\n".write(to: a, atomically: true, encoding: .utf8)
        try "line1\nline2\n".write(to: b, atomically: true, encoding: .utf8)
        #expect(Updater.diff(old: Updater.text(of: a), new: Updater.text(of: b)).isEmpty)
    }

    @Test("読めないファイルは空行配列として扱う")
    func missingFile() {
        #expect(Updater.text(of: URL(filePath: "/nonexistent/x.md")).isEmpty)
    }

    // MARK: - 適用

    struct Fixture {
        let env: Environment
        var registry = Registry()
        let staging: Staging
        let candidate: Candidate

        init(newBody: String) throws {
            let home = URL(filePath: NSTemporaryDirectory())
                .appending(path: "manage-arms-upd-\(UUID().uuidString)")
            let fm = FileManager.default
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            env = Environment.test(home: home)

            // 既存の実体
            let store = env.skillStore.appending(path: "demo")
            try fm.createDirectory(at: store, withIntermediateDirectories: true)
            try "---\nname: demo\ndescription: old\n---\n"
                .write(to: store.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
            registry.upsert(Registry.Entry(name: "demo", kind: .skill, repo: "o/r",
                                           branch: "main", sha: "old"))
            registry.repos["o/r#main"] = .init(latestSha: "new")
            try registry.save(env: env)

            // 取得済みの新しい中身
            let root = home.appending(path: "staging")
            let local = root.appending(path: "demo")
            try fm.createDirectory(at: local, withIntermediateDirectories: true)
            try newBody.write(to: local.appending(path: "SKILL.md"),
                              atomically: true, encoding: .utf8)
            candidate = Candidate(kind: .skill, name: "demo", description: "new", localURL: local)
            staging = Staging(root: root, source: GitHubSource(repo: "o/r", branch: "main"),
                              candidates: [candidate])
        }

        func body() throws -> String {
            try String(contentsOf: env.skillStore.appending(path: "demo/SKILL.md"),
                       encoding: .utf8)
        }
    }

    @Test("適用で中身が差し替わり sha が更新される")
    func applies() throws {
        var f = try Fixture(newBody: "---\nname: demo\ndescription: new\n---\n")
        let preview = UpdatePreview(name: "demo", oldSha: "old", newSha: "new",
                                    staging: f.staging, candidate: f.candidate,
                                    diff: [DiffLine(kind: .added, text: "x")])
        try Updater.apply(preview, env: f.env, registry: &f.registry)

        #expect(try f.body().contains("description: new"))
        #expect(f.registry.entry(named: "demo")?.sha == "new")
        #expect(Registry.load(env: f.env).entry(named: "demo")?.sha == "new")
        // 一時ディレクトリは片付く
        #expect(!FileManager.default.fileExists(
            atPath: f.staging.root.path(percentEncoded: false)))
    }

    /// 失敗したら元の中身に戻ること。プロンプトが消えるのが一番困る。
    @Test("差し替えに失敗したら旧実体を戻す")
    func rollsBack() throws {
        var f = try Fixture(newBody: "---\nname: demo\n---\n")
        // コピー元を消して失敗させる
        try FileManager.default.removeItem(at: f.candidate.localURL)
        let preview = UpdatePreview(name: "demo", oldSha: "old", newSha: "new",
                                    staging: f.staging, candidate: f.candidate, diff: [])

        #expect(throws: (any Error).self) {
            try Updater.apply(preview, env: f.env, registry: &f.registry)
        }
        #expect(try f.body().contains("description: old"), "旧実体が戻っていない")
        #expect(f.registry.entry(named: "demo")?.sha == "old")
    }

    /// registry に無いものは触らない（9 章）。
    @Test("外部管理スキルには適用できない")
    func rejectsExternal() throws {
        var f = try Fixture(newBody: "x")
        f.registry = Registry()   // 登録を消す
        let preview = UpdatePreview(name: "demo", oldSha: nil, newSha: "new",
                                    staging: f.staging, candidate: f.candidate, diff: [])
        #expect(throws: (any Error).self) {
            try Updater.apply(preview, env: f.env, registry: &f.registry)
        }
        #expect(try f.body().contains("description: old"))
    }

    @Test("固定中は preview を作らせない")
    func refusesPinned() async {
        var registry = Registry()
        let entry = Registry.Entry(name: "p", kind: .skill, repo: "o/r", pinned: true)
        registry.upsert(entry)
        await #expect(throws: Updater.Failure.pinned("p")) {
            try await Updater.preview(entry, env: .test(home: URL(filePath: "/tmp")),
                                      registry: registry)
        }
    }

    @Test("取得元が無ければ更新できない")
    func refusesUnmanaged() async {
        let entry = Registry.Entry(name: "local", kind: .skill)
        await #expect(throws: Updater.Failure.notManaged("local")) {
            try await Updater.preview(entry, env: .test(home: URL(filePath: "/tmp")),
                                      registry: Registry())
        }
    }
}
