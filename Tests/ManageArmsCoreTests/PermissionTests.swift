import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 8 章 / 9 章。**他人の設定ファイルを書き換える唯一の場所**なので厚く書く。
@Suite("権限の横断掃除")
struct PermissionTests {

    /// 偽ホームに `~/.claude.json`（projects キー）と各プロジェクトの設定を作る。
    ///
    /// **home を先に決めてから中身を組み立てる。** `~/.claude.json` の `projects` は
    /// 絶対パスなので、home が確定する前に書くと実ファイルの場所とズレて何も読めなくなる。
    static func fixture(_ build: (URL) -> [String: String]) throws -> (Environment, URL) {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "perm-\(UUID().uuidString)")
        for (path, body) in build(home) {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return (Environment.test(home: home), home)
    }

    static func claudeJSON(_ projects: [String]) -> String {
        let entries = projects.map { "\"\($0)\":{\"allowedTools\":[]}" }.joined(separator: ",")
        return "{\"numStartups\":1,\"projects\":{\(entries)}}"
    }

    // MARK: - 読み取り

    @Test("ユーザー全体とプロジェクトを横断して読む")
    func scansAcrossScopes() throws {
        let (env, root) = try Self.fixture { home in [
            ".claude.json": Self.claudeJSON(
                [home.appending(path: "work/app").path(percentEncoded: false)]),
            ".claude/settings.json": #"{"permissions":{"allow":["WebSearch"]}}"#,
            "work/app/.claude/settings.local.json":
                #"{"permissions":{"allow":["Bash(npm test)","WebSearch"],"deny":["Bash(rm:*)"]}}"#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = PermissionScanner.scan(env: env)
        #expect(found.count == 4)
        #expect(found.filter { $0.project == nil }.map(\.value) == ["WebSearch"])
        #expect(found.filter { $0.bucket == .deny }.map(\.value) == ["Bash(rm:*)"])
        // 同じ値が 2 スコープにある = 重複だが、ユーザー全体は数えない
        #expect(PermissionScanner.duplicates(found).isEmpty)
    }

    /// 実測: `Bash(git -C /Users/…/secondary-simulator log --oneline -15)`。
    /// **判定はハードコードした `/Users/` ではなく `env.home` を基準にする。**
    @Test("マシン固有の絶対パスを含むものを使い捨てと判定する")
    func flagsMachineSpecific() throws {
        let (env, root) = try Self.fixture { home in [
            ".claude.json": Self.claudeJSON([]),
            ".claude/settings.json": """
            {"permissions":{"allow":["Bash(npm test)",\
            "Bash(git -C \(home.path(percentEncoded: false))/app log)"]}}
            """,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = PermissionScanner.scan(env: env)
        #expect(found.count == 2)
        #expect(found.filter(\.isMachineSpecific).count == 1)
        #expect(found.first { $0.value == "Bash(npm test)" }?.isMachineSpecific == false)
    }

    @Test("複数プロジェクトの重複を数える")
    func countsDuplicates() throws {
        let (env, root) = try Self.fixture { home in [
            ".claude.json": Self.claudeJSON([
                home.appending(path: "a").path(percentEncoded: false),
                home.appending(path: "b").path(percentEncoded: false),
            ]),
            "a/.claude/settings.local.json": #"{"permissions":{"allow":["WebSearch","X"]}}"#,
            "b/.claude/settings.local.json": #"{"permissions":{"allow":["WebSearch"]}}"#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let dupes = PermissionScanner.duplicates(PermissionScanner.scan(env: env))
        #expect(dupes["WebSearch"]?.count == 2)
        #expect(dupes["X"] == nil)
    }

    @Test("permissions が無い・壊れたファイルでも落ちない", arguments: [
        "{}", "{\"permissions\":{}}", "{\"permissions\":[]}", "{", "null",
        #"{"permissions":{"allow":"文字列"}}"#,
        #"{"permissions":{"allow":[1,2]}}"#,
    ])
    func toleratesGarbage(_ body: String) throws {
        let (env, root) = try Self.fixture { _ in [
            ".claude.json": Self.claudeJSON([]),
            ".claude/settings.json": body,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PermissionScanner.scan(env: env).isEmpty)
    }

    // MARK: - 書き込みのガード（9 章の例外）

    @Test("settings 以外のファイルは拒否する", arguments: [
        "/tmp/x/.claude/auth.json",
        "/tmp/x/.claude/mcp.json",
        "/tmp/x/.claude/.claude.json",
        "/tmp/x/.claude/config.toml",
    ])
    func rejectsOtherFiles(_ path: String) {
        #expect(throws: PermissionWriter.Denial.self) {
            try PermissionWriter.assertWritable(URL(filePath: path))
        }
    }

    /// **`.claude` の外にある同名ファイルを書き換えない。**
    @Test("`.claude` ディレクトリの外は拒否する", arguments: [
        "/tmp/x/settings.json",
        "/tmp/x/.cursor/settings.json",
        "/tmp/x/.claude/nested/settings.json",
    ])
    func rejectsOutsideClaudeDir(_ path: String) {
        #expect(throws: PermissionWriter.Denial.self) {
            try PermissionWriter.assertWritable(URL(filePath: path))
        }
    }

    @Test("正しい場所の settings は通る", arguments: [
        "/tmp/x/.claude/settings.json",
        "/tmp/x/.claude/settings.local.json",
    ])
    func acceptsSettings(_ path: String) throws {
        try PermissionWriter.assertWritable(URL(filePath: path))
    }

    /// `..` で `.claude` の外に抜けられないこと。
    @Test("パス細工で抜けられない")
    func rejectsTraversal() {
        #expect(throws: PermissionWriter.Denial.self) {
            try PermissionWriter.assertWritable(
                URL(filePath: "/tmp/x/.claude/../.ssh/settings.json"))
        }
    }

    // MARK: - 削除（10.3 偽ホームで実行）

    /// **`permissions` 以外のキーを壊さないこと。**
    /// 実測で `enabledPlugins` / `hooks` / `extraKnownMarketplaces` が同居している。
    @Test("他のキーを保ったまま削除する")
    func preservesOtherKeys() throws {
        let (env, root) = try Self.fixture { home in [
            ".claude.json": Self.claudeJSON(
                [home.appending(path: "app").path(percentEncoded: false)]),
            "app/.claude/settings.local.json": #"""
            {"enabledPlugins":{"ponytail":true},"hooks":{"Stop":[]},
             "permissions":{"allow":["Bash(a)","Bash(b)"],"deny":["Bash(rm:*)"]}}
            """#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = PermissionScanner.scan(env: env)
        let doomed = found.filter { $0.value == "Bash(a)" }
        #expect(doomed.count == 1)
        try PermissionWriter.remove(doomed, env: env)

        let after = try Data(contentsOf: found[0].file)
        let object = try #require(
            try JSONSerialization.jsonObject(with: after) as? [String: Any])
        #expect(object["enabledPlugins"] != nil, "enabledPlugins が消えた")
        #expect(object["hooks"] != nil, "hooks が消えた")
        let permissions = try #require(object["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Bash(b)"])
        #expect(permissions["deny"] as? [String] == ["Bash(rm:*)"], "deny を巻き込んだ")
    }

    @Test("複数ファイルにまたがる削除")
    func removesAcrossFiles() throws {
        let (env, root) = try Self.fixture { home in [
            ".claude.json": Self.claudeJSON([
                home.appending(path: "a").path(percentEncoded: false),
                home.appending(path: "b").path(percentEncoded: false),
            ]),
            "a/.claude/settings.local.json": #"{"permissions":{"allow":["X","keep"]}}"#,
            "b/.claude/settings.local.json": #"{"permissions":{"allow":["X"]}}"#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = PermissionScanner.scan(env: env)
        try PermissionWriter.remove(found.filter { $0.value == "X" }, env: env)
        #expect(PermissionScanner.scan(env: env).map(\.value) == ["keep"])
    }

    /// **戻せること。** 他人の設定を書き換える唯一の場所なので必須（9 章）。
    @Test("削除前の内容がバックアップされる")
    func writesBackup() throws {
        let (env, root) = try Self.fixture { _ in [
            ".claude.json": Self.claudeJSON([]),
            ".claude/settings.json": #"{"permissions":{"allow":["X","Y"]}}"#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }

        let found = PermissionScanner.scan(env: env)
        try PermissionWriter.remove(found.filter { $0.value == "X" }, env: env)

        let dir = env.appSupport.appending(path: "permission-backups")
        let backups = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        // バックアップは編集「前」の中身
        let body = try String(contentsOf: backups[0], encoding: .utf8)
        #expect(body.contains("\"X\""))
        #expect(body.contains("\"Y\""))
        // バックアップはアプリの保存領域に置く。プロジェクトを汚さない。
        // macOS では `/var` が `/private/var` への symlink なので、
        // 列挙で返る解決済みパスと `env.appSupport` を揃えてから比べる。
        #expect(WriteGuard.isInside(backups[0].resolvingSymlinksInPath(),
                                    env.appSupport.resolvingSymlinksInPath()))
    }

    @Test("空の指定では何も書かない")
    func emptyIsNoop() throws {
        let (env, root) = try Self.fixture { _ in [
            ".claude.json": Self.claudeJSON([]),
            ".claude/settings.json": #"{"permissions":{"allow":["X"]}}"#,
        ] }
        defer { try? FileManager.default.removeItem(at: root) }
        try PermissionWriter.remove([], env: env)
        #expect(!FileManager.default.fileExists(
            atPath: env.appSupport.appending(path: "permission-backups")
                .path(percentEncoded: false)))
        #expect(PermissionScanner.scan(env: env).count == 1)
    }

    /// 走査範囲（10.2）。権限は `Source.all` に載せず専用の入り口から読む。
    @Test("読む対象は settings 2 種だけで、禁止領域を踏まない")
    func staysOutOfForbidden() {
        for name in PermissionScanner.fileNames {
            for word in SourceTests.forbidden {
                #expect(!name.contains(word))
            }
        }
        #expect(PermissionScanner.fileNames == ["settings.json", "settings.local.json"])
    }
}
