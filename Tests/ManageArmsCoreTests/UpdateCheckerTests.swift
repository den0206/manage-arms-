import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.1 / 7.3 — 更新判定。ネットワークは叩かない。
@Suite("更新チェック")
struct UpdateCheckerTests {

    static func entry(_ name: String, repo: String? = "o/r", branch: String? = "main",
                      sha: String? = "old", pinned: Bool = false) -> Registry.Entry {
        Registry.Entry(name: name, kind: .skill, repo: repo, branch: branch,
                       sha: sha, pinned: pinned)
    }

    /// 同一リポジトリ由来のスキルが何個あっても 1 リクエストで済むこと。
    @Test("repo/branch 単位で束ねる")
    func bundlesByRepo() {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        registry.upsert(Self.entry("b"))                              // 同じ repo#branch
        registry.upsert(Self.entry("c", repo: "o/r", branch: "dev"))  // 別ブランチ
        registry.upsert(Self.entry("d", repo: "x/y"))
        let keys = UpdateChecker.staleKeys(registry, now: Date(), force: true)
        #expect(keys == ["o/r#dev", "o/r#main", "x/y#main"])
    }

    /// メニューバーのバッジ用。固定中は「更新しない」と決めたものなので数えない。
    @Test("更新があるものが1つでもあればバッジを出す")
    func hasAvailable() {
        var registry = Registry()
        registry.repos["o/r#main"] = Registry.RepoState(latestSha: "new")
        #expect(!UpdateChecker.hasAvailable(registry))
        registry.upsert(Self.entry("current", sha: "new"))
        #expect(!UpdateChecker.hasAvailable(registry))
        registry.upsert(Self.entry("pinned", sha: "old", pinned: true))
        #expect(!UpdateChecker.hasAvailable(registry))
        registry.upsert(Self.entry("behind", sha: "old"))
        #expect(UpdateChecker.hasAvailable(registry))
    }

    @Test("取得元が無いものはチェック対象にしない")
    func skipsUnmanaged() {
        var registry = Registry()
        registry.upsert(Self.entry("local", repo: nil))
        #expect(UpdateChecker.staleKeys(registry, now: Date(), force: true).isEmpty)
    }

    @Test("固定中はチェックしない")
    func skipsPinned() {
        var registry = Registry()
        registry.upsert(Self.entry("p", pinned: true))
        #expect(UpdateChecker.staleKeys(registry, now: Date(), force: true).isEmpty)
    }

    /// 起動時の自動チェックはしない。1 日 1 回のスロットル（7.3）。
    @Test("24 時間以内に確認済みならスキップ、force なら実行")
    func throttles() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        registry.repos["o/r#main"] = .init(checkedAt: now.addingTimeInterval(-3600))
        #expect(UpdateChecker.staleKeys(registry, now: now, force: false).isEmpty)
        #expect(UpdateChecker.staleKeys(registry, now: now, force: true) == ["o/r#main"])

        registry.repos["o/r#main"] = .init(checkedAt: now.addingTimeInterval(-25 * 3600))
        #expect(UpdateChecker.staleKeys(registry, now: now, force: false) == ["o/r#main"])
    }

    // MARK: - 状態

    @Test("sha が違えば更新あり")
    func availableWhenBehind() {
        var registry = Registry()
        let e = Self.entry("a", sha: "old")
        registry.upsert(e)
        registry.repos["o/r#main"] = .init(latestSha: "new")
        #expect(UpdateChecker.status(of: e, in: registry) == .available(sha: "new"))
    }

    @Test("sha が同じなら最新")
    func upToDate() {
        var registry = Registry()
        let e = Self.entry("a", sha: "same")
        registry.upsert(e)
        registry.repos["o/r#main"] = .init(latestSha: "same")
        #expect(UpdateChecker.status(of: e, in: registry) == .upToDate)
    }

    @Test("sha 不明は最新版とみなさない")
    func unknownInstalledSHA() {
        var registry = Registry()
        let entry = Self.entry("a", sha: nil)
        registry.repos["o/r#main"] = .init(latestSha: "new")
        #expect(UpdateChecker.status(of: entry, in: registry) == .available(sha: "new"))
    }

    @Test("未チェックは unknown")
    func unknown() {
        let e = Self.entry("a")
        #expect(UpdateChecker.status(of: e, in: Registry()) == .unknown)
    }

    @Test("取得元が無ければ unmanaged")
    func unmanaged() {
        #expect(UpdateChecker.status(of: Self.entry("a", repo: nil), in: Registry()) == .unmanaged)
    }

    /// 固定中でも「遅れている」ことは見せる。更新はしない（7.6 の 📌 表示）。
    @Test("固定中は遅れていても pinned")
    func pinnedShowsBehind() {
        var registry = Registry()
        let e = Self.entry("a", sha: "old", pinned: true)
        registry.upsert(e)
        registry.repos["o/r#main"] = .init(latestSha: "new")
        #expect(UpdateChecker.status(of: e, in: registry) == .pinned(behind: true))
    }

    // MARK: - HTTP

    static func env(_ handler: @escaping @Sendable (URL, [String: String])
                    -> Environment.HTTPResult) -> Environment {
        Environment.test(home: URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString),
                         now: { Date(timeIntervalSince1970: 1_000_000) },
                         httpGet: { url, headers in handler(url, headers) })
    }

    @Test("200 なら sha と ETag を保存する")
    func stores200() async throws {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        let env = Self.env { url, _ in
            #expect(url.absoluteString == "https://api.github.com/repos/o/r/commits/main")
            return .init(body: Data(#"{"sha":"abc123"}"#.utf8), status: 200,
                         headers: ["etag": "W/\"tag1\""])
        }
        await UpdateChecker.check(&registry, env: env, force: true)
        #expect(registry.repos["o/r#main"]?.latestSha == "abc123")
        #expect(registry.repos["o/r#main"]?.etag == "W/\"tag1\"")
        #expect(registry.repos["o/r#main"]?.checkedAt != nil)
    }

    /// **304 はレート制限を消費しない**（7.3）。ETag を必ず送ること。
    @Test("2 回目は If-None-Match を送り 304 なら sha を保持する")
    func sends304() async throws {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        registry.repos["o/r#main"] = .init(etag: "W/\"tag1\"", latestSha: "abc123",
                                           checkedAt: Date(timeIntervalSince1970: 0))
        let sentEtag = Locked<String?>(nil)
        let env = Self.env { _, headers in
            sentEtag.value = headers["If-None-Match"]
            return .init(body: Data(), status: 304, headers: [:])
        }
        await UpdateChecker.check(&registry, env: env, force: true)
        #expect(sentEtag.value == "W/\"tag1\"")
        #expect(registry.repos["o/r#main"]?.latestSha == "abc123")   // 保持される
        #expect(registry.repos["o/r#main"]?.checkedAt == Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("レート制限は専用のエラーにする", arguments: [403, 429])
    func rateLimited(_ status: Int) async {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        let env = Self.env { _, _ in .init(body: Data(), status: status, headers: [:]) }
        let results = await UpdateChecker.check(&registry, env: env, force: true)
        #expect(results["o/r#main"] as? UpdateChecker.Failure == .rateLimited)
    }

    @Test("404 はリポジトリ名かブランチ名の誤りとして伝える")
    func notFound() async {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        let env = Self.env { _, _ in .init(body: Data(), status: 404, headers: [:]) }
        let results = await UpdateChecker.check(&registry, env: env, force: true)
        #expect(results["o/r#main"] as? UpdateChecker.Failure == .notFound("o/r#main"))
    }

    @Test("壊れた JSON でもクラッシュしない")
    func malformed() async {
        var registry = Registry()
        registry.upsert(Self.entry("a"))
        let env = Self.env { _, _ in
            .init(body: Data("not json".utf8), status: 200, headers: [:])
        }
        let results = await UpdateChecker.check(&registry, env: env, force: true)
        #expect(results["o/r#main"] as? UpdateChecker.Failure == .malformedResponse)
        #expect(registry.repos["o/r#main"] == nil)   // 壊れた値を書き込まない
    }
}

/// テスト用の小さなロック付きボックス。
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
