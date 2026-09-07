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

    /// **`.claude` という名前のディレクトリはどこにでも作れる。**
    /// 名前だけ見ていると、走査もしていない場所の設定を書き換えうる。
    @Test("読んでいない場所の .claude は拒否する")
    func rejectsUnknownRoot() throws {
        let home = URL(filePath: "/tmp/x")
        let known = [home, URL(filePath: "/tmp/x/work/app")]
        try PermissionWriter.assertWritable(
            home.appending(path: ".claude/settings.json"), under: known)
        try PermissionWriter.assertWritable(
            URL(filePath: "/tmp/x/work/app/.claude/settings.local.json"), under: known)
        #expect(throws: PermissionWriter.Denial.self) {
            try PermissionWriter.assertWritable(
                URL(filePath: "/tmp/x/Downloads/untrusted/.claude/settings.json"), under: known)
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
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: backups[0])) as? [String: String])
        let content = try #require(envelope["content"])
        let body = String(decoding: Data(base64Encoded: content) ?? Data(), as: UTF8.self)
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

/// DESIGN.md 9 章 / CLAUDE.md「ストレージの規律」。
/// **リソース管理アプリが自分でディスクを汚したら本末転倒。**
/// 以前はここが編集のたびに 1 ファイル増え続け、消す導線も無かった。
@Suite("権限バックアップの世代")
struct PermissionBackupTests {

    /// 進められる時計。`Environment.test` の `now` は epoch 0 固定なので、
    /// そのままだと世代のファイル名が全部同じになって上書きしてしまう。
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 0)
        func now() -> Date { lock.withLock { value } }
        func advance() { lock.withLock { value = value.addingTimeInterval(60) } }
    }

    func backupNames(_ env: Environment) -> [String] {
        let dir = env.appSupport.appending(path: PermissionWriter.backupDirectory)
        return ((try? FileManager.default.contentsOfDirectory(
            atPath: dir.path(percentEncoded: false))) ?? []).sorted()
    }

    /// 同じ偽ホームを何度も編集できる小さな道具立て。
    struct Session {
        let env: Environment
        let root: URL
        let entry: PermissionEntry
        let clock: Clock

        /// 1 回の編集 = 1 世代。時計を進めないとファイル名が衝突して上書きになる。
        func edit(times count: Int) throws {
            for _ in 0..<count {
                clock.advance()
                try PermissionWriter.remove([entry], env: env)
            }
        }
    }

    func session() throws -> Session {
        let (base, root) = try PermissionTests.fixture { _ in [
            ".claude/settings.json": #"{"permissions":{"allow":["WebSearch"]}}"#,
        ] }
        let clock = Clock()
        var env = base
        env.now = { clock.now() }
        let entry = try #require(PermissionScanner.scan(projects: [], env: env).first)
        return Session(env: env, root: root, entry: entry, clock: clock)
    }

    @Test("編集のたびに増え続けない（上限まで刈る）")
    func keepsBoundedGenerations() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: PermissionWriter.generations + 4)
        #expect(backupNames(s.env).count == PermissionWriter.generations)
    }

    @Test("同じ時刻の連続保存でも上書きしない")
    func sameSecondDoesNotCollide() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try PermissionWriter.remove([s.entry], env: s.env)
        try PermissionWriter.remove([s.entry], env: s.env)
        #expect(backupNames(s.env).count == 2)
    }

    @Test("バックアップは所有者だけが読める")
    func ownerOnlyPermissions() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try PermissionWriter.remove([s.entry], env: s.env)
        let directory = s.env.appSupport.appending(path: PermissionWriter.backupDirectory)
        let name = try #require(backupNames(s.env).first)
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try FileManager.default.attributesOfItem(
            atPath: directory.appending(path: name).path)[.posixPermissions] as? NSNumber
        #expect(dirMode?.intValue == 0o700)
        #expect(fileMode?.intValue == 0o600)
    }

    /// **残すのは新しい方。** 目的は「直前の編集に戻せること」なので、
    /// 古い方から捨てないと意味が無い。
    @Test("残るのは新しい世代")
    func keepsNewest() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: PermissionWriter.generations + 2)
        let names = backupNames(s.env)
        #expect(names.count == PermissionWriter.generations)
        #expect(names.contains { $0.contains("1970-01-01T00-07-00Z") }, "最後の編集が消えている")
        #expect(names.contains { $0.contains("1970-01-01T00-03-00Z") }, "古い方から捨てていない")
    }

    /// **帰属を判定できないものは消さない。** 0.1.0 が書いた旧形式の名前は
    /// 区切り（`__`）を持たないので、世代刈りの対象にしない。
    @Test("旧形式のバックアップには触らない")
    func leavesLegacyAlone() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: 1)
        let dir = s.env.appSupport.appending(path: PermissionWriter.backupDirectory)
        let legacy = dir.appending(path: "1970-01-01T00-00-00Z-Users-me--claude-settings.json")
        try Data("old".utf8).write(to: legacy)

        try s.edit(times: PermissionWriter.generations + 3)
        #expect(FileManager.default.fileExists(atPath: legacy.path(percentEncoded: false)),
                "旧形式のバックアップを消してしまった")
        // 自分の形式のものは上限まで刈られている
        #expect(backupNames(s.env).count == PermissionWriter.generations + 1)
    }

    // MARK: - ガード

    @Test("保存領域の外は消させない")
    func guardsOutside() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: 1)
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertAppBackup(s.env.home.appending(path: ".claude/settings.json"),
                                           env: s.env)
        }
    }

    @Test("ディレクトリは消させない（中身ごと飛ぶ）")
    func guardsDirectories() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: 1)
        let dir = s.env.appSupport.appending(path: PermissionWriter.backupDirectory)
            .appending(path: "nested")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: WriteGuard.Denial.self) {
            try WriteGuard.assertAppBackup(dir, env: s.env)
        }
    }

    @Test("自分が作ったバックアップは通る")
    func allowsOwnBackup() throws {
        let s = try session()
        defer { try? FileManager.default.removeItem(at: s.root) }
        try s.edit(times: 1)
        let dir = s.env.appSupport.appending(path: PermissionWriter.backupDirectory)
        let name = try #require(backupNames(s.env).first)
        try WriteGuard.assertAppBackup(dir.appending(path: name), env: s.env)
    }
}
