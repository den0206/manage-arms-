import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.9 / 5.3 / 10.1。
@Suite("使用実績の集計")
struct UsageTests {

    // MARK: - 1 行の解析（10.1 純粋関数）

    static func line(_ json: String) -> Data { Data(json.utf8) }

    @Test("Skill の呼び出しから名前と時刻を取る")
    func parsesSkill() throws {
        let parsed = UsageScanner.parse(Self.line("""
        {"timestamp":"2026-09-04T23:02:11.123Z","message":{"content":\
        [{"type":"tool_use","name":"Skill","input":{"skill":"artifact-design"}}]}}
        """))
        let (date, names) = try #require(parsed)
        #expect(names == ["artifact-design"])
        #expect(date == UsageScanner.date(from: "2026-09-04T23:02:11.123Z"))
    }

    @Test("Codex の明示 Skill 呼び出しを取る")
    func parsesCodexSkill() throws {
        let parsed = UsageScanner.parse(Self.line("""
        {"timestamp":"2026-09-06T04:30:22.976Z","type":"event_msg","payload":{
        "type":"item_completed","item":{"type":"UserMessage","content":
        [{"type":"skill","name":"improve-codebase-architecture","path":"/x/SKILL.md"}]}}}
        """))
        let (_, names) = try #require(parsed)
        #expect(names == ["improve-codebase-architecture"])
    }

    @Test("Codex の暗黙 Skill 読み込みを取る")
    func parsesCodexSkillRead() throws {
        let (_, names) = try #require(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"const r = tools.exec_command({\"cmd\":\"sed -n '1,200p' /Users/me/.agents/skills/grilling/SKILL.md\"})"}}
        """#)))
        #expect(names == ["grilling"])

        let (_, unquotedNames) = try #require(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"tools.exec_command({cmd:\"cat /Users/me/.agents/skills/grilling/SKILL.md\"})"}}
        """#)))
        #expect(unquotedNames == ["grilling"])
    }

    @Test("Codex の Skill ファイル操作を使用と誤認しない")
    func ignoresCodexSkillWrite() {
        #expect(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"git add /Users/me/.agents/skills/grilling/SKILL.md"}}
        """#)) == nil)
        #expect(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"tools.exec_command({cmd:\"cat > /Users/me/.agents/skills/grilling/SKILL.md\"})"}}
        """#)) == nil)
        #expect(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"tools.exec_command({cmd:\"sed -i '' /Users/me/.agents/skills/grilling/SKILL.md\"})"}}
        """#)) == nil)
    }

    @Test("Codex の patch 内にある Skill 例を使用と誤認しない")
    func ignoresCodexSkillExampleInPatch() {
        #expect(UsageScanner.parse(Self.line(#"""
        {"timestamp":"2026-09-06T04:30:38Z","payload":{"type":"custom_tool_call",
        "name":"exec","input":"const patch = \"sed /x/cursor-skill/SKILL.md\"; tools.apply_patch(patch)"}}
        """#)) == nil)
    }

    @Test("Cursor の Skill 読み込みは transcript の更新時刻を使う")
    func parsesCursorSkillRead() throws {
        let fallback = Date(timeIntervalSince1970: 1_800_000_000)
        let (date, names) = try #require(UsageScanner.parse(Self.line("""
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read",
        "input":{"path":"/Users/me/.cursor/skills-cursor/create-rule/SKILL.md"}}]}}
        """), fallbackDate: fallback))
        #expect(date == fallback)
        #expect(names == ["create-rule"])
    }

    /// プラグイン由来は `ponytail:ponytail-review` の形で記録される（実測）。
    /// Plugin 行の最終使用日に使うため、前半も名前として数える（spike #15）。
    @Test("プラグイン由来はプラグイン名でも数える")
    func parsesPluginPrefix() throws {
        let (_, names) = try #require(UsageScanner.parse(Self.line("""
        {"timestamp":"2026-08-23T12:50:00Z","message":{"content":\
        [{"type":"tool_use","name":"Skill","input":{"skill":"ponytail:ponytail-review"}}]}}
        """)))
        #expect(names == ["ponytail:ponytail-review", "ponytail"])
    }

    @Test("MCP のツール名からサーバー名を取る")
    func parsesMCP() throws {
        let (_, names) = try #require(UsageScanner.parse(Self.line("""
        {"timestamp":"2026-09-01T00:00:00Z","message":{"content":\
        [{"type":"tool_use","name":"mcp__chrome-devtools__take_snapshot"}]}}
        """)))
        #expect(names == ["chrome-devtools"])
    }

    /// 読む対象は他社製品の出力で予告なく書式が変わる（10.5）。落ちてはいけない。
    @Test("壊れた行・想定外の形でもクラッシュしない", arguments: [
        "",
        "{",
        "null",
        "[1,2,3]",
        #"{"timestamp":"2026-09-01T00:00:00Z"}"#,
        #"{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"x"}}]}}"#,  // 時刻なし
        #"{"timestamp":"どう見ても日付ではない","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"x"}}]}}"#,
        #"{"timestamp":"2026-09-01T00:00:00Z","message":{"content":[{"type":"tool_use","name":"Skill","input":"文字列"}]}}"#,
        #"{"timestamp":"2026-09-01T00:00:00Z","message":{"content":"配列ではない"}}"#,
        #"{"timestamp":"2026-09-01T00:00:00Z","message":{"content":[{"type":"text","text":"Skill の話をしただけ"}]}}"#,
    ])
    func toleratesGarbage(_ json: String) {
        #expect(UsageScanner.parse(Self.line(json)) == nil)
    }

    /// 小数部を持つ行と持たない行が混在する（実測）。
    @Test("小数秒あり / なしの両方を読む")
    func parsesBothTimestampForms() {
        #expect(UsageScanner.date(from: "2026-09-04T23:02:11.123Z") != nil)
        #expect(UsageScanner.date(from: "2026-09-04T23:02:11Z") != nil)
        #expect(UsageScanner.date(from: "2026-09-04") == nil)
    }

    // MARK: - 走査（10.3 偽ホームで実行）

    static func fixture(_ files: [String: String]) throws -> (Environment, URL) {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "usage-\(UUID().uuidString)")
        for (path, body) in files {
            let url = home.appending(path: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return (Environment.test(home: home), home)
    }

    static func skillLine(_ name: String, _ stamp: String) -> String {
        """
        {"timestamp":"\(stamp)","message":{"content":\
        [{"type":"tool_use","name":"Skill","input":{"skill":"\(name)"}}]}}
        """
    }

    @Test("複数セッションから最も新しい使用日を採る")
    func picksLatest() throws {
        let (env, home) = try Self.fixture([
            ".claude/projects/a/s1.jsonl": Self.skillLine("alpha", "2026-01-01T00:00:00Z"),
            ".claude/projects/b/s2.jsonl": Self.skillLine("alpha", "2026-05-05T00:00:00Z")
                + "\n" + Self.skillLine("beta", "2026-02-02T00:00:00Z"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let found = UsageScanner.scan(env: env)
        #expect(found["alpha"] == UsageScanner.date(from: "2026-05-05T00:00:00Z"))
        #expect(found["beta"] == UsageScanner.date(from: "2026-02-02T00:00:00Z"))
        #expect(found.count == 2)
    }

    @Test("Claude・Codex・Cursor のログをまとめて走査する")
    func scansEverySupportedAgent() throws {
        let cursor = """
        {"role":"assistant","message":{"content":[{"type":"tool_use","name":"Read",\
        "input":{"path":"/x/cursor-skill/SKILL.md"}}]}}
        """
        let codex = """
        {"timestamp":"2026-09-06T00:00:00Z","payload":{"type":"item_completed",\
        "item":{"content":[{"type":"skill","name":"codex-skill"}]}}}
        """
        let (env, home) = try Self.fixture([
            ".claude/projects/a/s.jsonl": Self.skillLine("claude-skill", "2026-01-01T00:00:00Z"),
            ".codex/sessions/2026/09/06/rollout.jsonl": codex,
            ".cursor/projects/a/agent-transcripts/id/id.jsonl": cursor,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(UsageScanner.scan(env: env).keys.sorted()
                == ["claude-skill", "codex-skill", "cursor-skill"])
    }

    @Test("jsonl 以外は読まない")
    func ignoresOtherFiles() throws {
        let (env, home) = try Self.fixture([
            ".claude/projects/a/notes.txt": Self.skillLine("alpha", "2026-01-01T00:00:00Z"),
            ".claude/projects/a/s.jsonl": Self.skillLine("beta", "2026-01-01T00:00:00Z"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(UsageScanner.scan(env: env).keys.sorted() == ["beta"])
    }

    /// 増分スキャン。前回以降に書かれたログだけ読む（3.9）。
    @Test("since より古いログは読み飛ばす")
    func incrementalSkipsOldFiles() throws {
        let (env, home) = try Self.fixture([
            ".claude/projects/a/s.jsonl": Self.skillLine("alpha", "2026-01-01T00:00:00Z"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(UsageScanner.scan(env: env, since: nil).count == 1)
        // ファイルの mtime は「今」なので、未来を指定すれば読み飛ばされる
        #expect(UsageScanner.scan(env: env, since: Date().addingTimeInterval(60)).isEmpty)
    }

    @Test("refreshed は前回の結果を残したまま新しい分を足す")
    func refreshedMerges() throws {
        let (env, home) = try Self.fixture([
            ".claude/projects/a/s.jsonl": Self.skillLine("alpha", "2026-01-01T00:00:00Z"),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        var registry = Registry()
        // 前回すでに拾っていた別のスキル
        registry.usage.lastUsed["old"] = UsageScanner.date(from: "2025-01-01T00:00:00Z")

        registry = UsageScanner.refreshed(registry, env: env)
        #expect(registry.usage.lastUsed["old"] != nil, "前回の集計結果が消えている")
        #expect(registry.usage.lastUsed["alpha"] != nil)
        #expect(registry.usage.scannedUpTo != nil, "未集計のままだと 5.3 の区別ができない")
        #expect(registry.usage.scannedSources.keys.sorted() == ["claude", "codex", "cursor"])
    }

    @Test("旧 registry の走査時刻で新しい Agent の履歴を読み飛ばさない")
    func rescansNewSourcesAfterUpgrade() throws {
        let codex = """
        {"timestamp":"2026-09-06T00:00:00Z","payload":{"type":"item_completed",\
        "item":{"content":[{"type":"skill","name":"codex-skill"}]}}}
        """
        let (env, home) = try Self.fixture([
            ".codex/sessions/2026/09/06/rollout.jsonl": codex,
        ])
        defer { try? FileManager.default.removeItem(at: home) }
        var registry = Registry()
        registry.usage.scannedUpTo = Date.distantFuture

        registry = UsageScanner.refreshed(registry, env: env)
        #expect(registry.usage.lastUsed["codex-skill"] != nil)
    }

    @Test("ログが 1 つも無くても集計済みにはなる")
    func emptyStillMarksScanned() throws {
        let (env, home) = try Self.fixture([:])
        defer { try? FileManager.default.removeItem(at: home) }
        let registry = UsageScanner.refreshed(Registry(), env: env)
        #expect(registry.usage.lastUsed.isEmpty)
        // ここが nil のままだと全行が永遠に「未集計」表示になる
        #expect(registry.usage.scannedUpTo != nil)
    }

    // MARK: - 走査範囲（10.2 の生命線）

    /// 使用実績ログは `Source.all` に載せない。載ると一覧スキャンが全履歴を踏む。
    @Test("使用実績ログは通常の走査対象に含まれない")
    func logRootsAreOutsideSourceAll() {
        let env = Environment.test(home: URL(filePath: "/tmp/fake-home"))
        let listed = Set(Source.all.compactMap { $0.url(in: env)?.path(percentEncoded: false) })
        for root in UsageScanner.logRoots(env: env) {
            let path = root.path(percentEncoded: false)
            #expect(!listed.contains(path), "\(path) が Source.all に載っている")
            // 3.4 が踏まないと決めた領域であることの確認（逆向きの assert）
            #expect(SourceTests.forbidden.contains { path.contains($0) })
        }
    }

    // MARK: - 表示の区別（5.3）

    static func row(_ name: String, kind: Kind = .skill,
                    claude: ResourceRow.State, cursor: ResourceRow.State = .absent,
                    codex: ResourceRow.State = .absent, lastUsed: Date? = nil) -> ResourceRow {
        ResourceRow(name: name, kind: kind, summary: nil, detail: "",
                    state: [.claude: claude, .cursor: cursor, .codex: codex],
                    origin: .managed, isDisabled: false,
                    lastUsed: lastUsed)
    }

    @Test("ログ対応 Agent のどれかから見える行は使用実績を観測できる")
    func unobservableRows() {
        #expect(Self.row("a", claude: .explicit).usageObservable)
        #expect(!Self.row("b", claude: .absent).usageObservable)
        #expect(!Self.row("c", claude: .unsupported).usageObservable)
        #expect(!Self.row("d", claude: .undetected).usageObservable)
        #expect(Self.row("e", claude: .absent, cursor: .explicit).usageObservable)
        #expect(Self.row("f", claude: .absent, codex: .explicit).usageObservable)
    }

    /// Plugin だけ一覧上の id とログ上の名前が食い違う（spike #15）。
    @Test("Plugin は @ の手前で最終使用日を引く")
    func pluginNameLookup() {
        let when = Date(timeIntervalSince1970: 1_000)
        let used = ["ponytail": when, "swift-lsp@claude-plugins-official": when]
        #expect(Inventory.lastUsed("ponytail@ponytail", kind: .plugin, used: used) == when)
        #expect(Inventory.lastUsed("swift-lsp@claude-plugins-official",
                                   kind: .plugin, used: used) == when)
        // Skill は id をそのまま引く。@ で切ってはいけない
        #expect(Inventory.lastUsed("ponytail@ponytail", kind: .skill, used: used) == nil)
        #expect(Inventory.lastUsed("unknown@x", kind: .plugin, used: used) == nil)
    }

    // MARK: - registry.json の後方互換

    /// `usage` を足したことで、前のバージョンが書いたファイルが読めなくなると
    /// 導入済みスキルの取得元が全部飛ぶ（`load` が空にフォールバックするため）。
    @Test("usage キーが無い registry.json も読める")
    func decodesOlderRegistry() throws {
        let old = #"""
        {"resources":[{"name":"a","kind":"skill","repo":"o/r","pinned":false,"disabled":false}]}
        """#
        let registry = try Registry.decoder.decode(Registry.self, from: Data(old.utf8))
        #expect(registry.resources.count == 1, "前バージョンの registry.json を読み落とした")
        #expect(registry.repos.isEmpty)
        #expect(registry.usage.scannedUpTo == nil)
    }

    @Test("往復しても内容が変わらない")
    func roundTrips() throws {
        var registry = Registry()
        registry.upsert(Registry.Entry(name: "a", kind: .skill, repo: "o/r"))
        registry.usage.lastUsed["a"] = Date(timeIntervalSince1970: 1_700_000_000)
        registry.usage.scannedUpTo = Date(timeIntervalSince1970: 1_700_000_100)
        registry.usage.scannedSources["claude"] = Date(timeIntervalSince1970: 1_700_000_100)

        let data = try Registry.encoder.encode(registry)
        #expect(try Registry.decoder.decode(Registry.self, from: data) == registry)
    }
}

/// DESIGN.md 4.1 / 9 章 — **唯一の永続ファイルを単調増加させない。**
@Suite("使用実績の件数")
struct UsageHistoryTests {

    func history(_ count: Int) -> [String: Date] {
        Dictionary(uniqueKeysWithValues: (0..<count).map {
            ("skill-\($0)", Date(timeIntervalSince1970: TimeInterval($0)))
        })
    }

    @Test("上限までは何も落とさない")
    func keepsAllUnderLimit() {
        let all = history(UsageScanner.historyLimit)
        #expect(UsageScanner.bounded(all).count == UsageScanner.historyLimit)
    }

    @Test("上限を超えたら古い方から落とす")
    func dropsOldest() {
        let all = history(UsageScanner.historyLimit + 10)
        let kept = UsageScanner.bounded(all)
        #expect(kept.count == UsageScanner.historyLimit)
        // 新しい方（添字が大きいほど新しい）が残る
        #expect(kept["skill-\(UsageScanner.historyLimit + 9)"] != nil, "最新が落ちた")
        #expect(kept["skill-0"] == nil, "最古が残っている")
    }
}
