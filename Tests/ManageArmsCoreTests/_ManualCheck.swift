import Foundation
import Testing
@testable import ManageArmsCore

// 手動確認用。実 CLI を起動するため CI には載せない（DESIGN.md 10.6）。
@Suite("手動確認", .disabled(if: ProcessInfo.processInfo.environment["MANUAL"] == nil))
struct ManualCheck {
    @Test("ShellPath が実環境で CLI を見つける")
    func resolvesCLIs() throws {
        let path = ShellPath.resolved
        print("解決した PATH:\n  \(path.replacingOccurrences(of: ":", with: "\n  "))")
        for cli in ["claude", "codex", "gemini"] {
            let found = (try? Exec.run(["which", cli], path: path))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "NOT FOUND"
            print("  \(cli) → \(found)")
            #expect(found != "NOT FOUND")
        }
    }

    @Test("launchd の PATH では見つからない（3.7 の前提の再確認）")
    func launchdPathFails() {
        let launchd = "/usr/bin:/bin:/usr/sbin:/sbin"
        for cli in ["claude", "codex", "gemini"] {
            let found = try? Exec.run(["which", cli], path: launchd)
            #expect(found == nil, "\(cli) が launchd PATH で見つかった — 3.7 の前提が変わった")
        }
    }

    @Test("実環境の検出結果")
    func detectsRealAgents() {
        let result = Detector.detectAll(env: .live)
        for agent in Agent.allCases {
            let state = result[agent]!
            let text: String
            switch state {
            case .detected(let v, let p): text = "検出済み  \(v ?? "─")  \(p ?? "(CLI なし)")"
            case .configOnly:             text = "設定のみ（CLI が見つからない）"
            case .undetected:             text = "未検出"
            case .disabled:               text = "管理対象外"
            }
            print(String(format: "  %-14@ %@", agent.displayName as NSString, text as NSString))
        }
        // 実測（付録）: claude / codex / gemini は導入済み、Cursor は CLI 無しで設定あり
        #expect(result[.claude]?.isUsable == true)
        #expect(result[.cursor] == .detected(version: nil, path: nil))
        #expect(result[.codex]?.isUsable == true)
        #expect(result[.gemini]?.isUsable == true)
    }

    @Test("実機のスキルを走査する")
    func scansRealSkills() {
        let skills = SkillScanner.scan(env: .live)
        let byRoot = Dictionary(grouping: skills, by: \.root)
        print("=== ルート別 ===")
        for root in byRoot.keys.sorted() {
            print("  \(root): \(byRoot[root]!.count) 件")
        }
        print("=== 状態別 ===")
        for (status, group) in Dictionary(grouping: skills, by: { "\($0.status)" }).sorted(by: { $0.key < $1.key }) {
            print("  \(status): \(group.count) 件  \(group.prefix(3).map(\.name).joined(separator: ", "))")
        }
        print("=== description が取れなかったもの ===")
        let noDesc = skills.filter { $0.status == .ok && $0.description == nil }
        print("  \(noDesc.count) 件  \(noDesc.map(\.name).joined(separator: ", "))")
        print("=== サンプル ===")
        for skill in skills.prefix(3) {
            print("  [\(skill.name)] \(skill.description?.prefix(70) ?? "(なし)")…")
        }

        #expect(!skills.isEmpty)
        // status が .ok のものは description が取れているはず（折り畳みスカラー対応の検証）
        #expect(noDesc.isEmpty, "description を取りこぼしている: \(noDesc.map(\.name))")
    }

    /// 実環境での有効化 / 無効化の往復。検証用スキルだけを触る。
    @Test("実環境で有効化 / 無効化が動く")
    func realRoundTrip() throws {
        let name = "zz-manage-arms-demo"
        let env = Environment.live
        var registry = Registry.load(env: env)
        // 検証用スキル以外は絶対に触らない。名前が固定であることが安全の根拠。
        guard name.hasPrefix("zz-manage-arms-"), registry.entry(named: name) != nil else {
            print("  スキップ: 検証用スキル \(name) が registry にありません")
            return
        }
        let fm = FileManager.default
        let link = env.claudeSkills.appending(path: name)
        let store = env.skillStore.appending(path: name)
        let parked = env.disabledStore.appending(path: name)

        try SkillManager.enable(name, env: env, registry: &registry)
        print("  有効化: symlink=\(WriteGuard.isSymlink(link)) 実体=\(fm.fileExists(atPath: store.path(percentEncoded: false)))")
        #expect(WriteGuard.isSymlink(link))
        #expect(fm.fileExists(atPath: link.appending(path: "SKILL.md").path(percentEncoded: false)))

        try SkillManager.disable(name, env: env, registry: &registry)
        print("  無効化: symlink=\(fm.fileExists(atPath: link.path(percentEncoded: false))) 退避=\(fm.fileExists(atPath: parked.path(percentEncoded: false)))")
        #expect(!fm.fileExists(atPath: link.path(percentEncoded: false)))
        #expect(fm.fileExists(atPath: parked.path(percentEncoded: false)))

        try SkillManager.enable(name, env: env, registry: &registry)
        #expect(WriteGuard.isSymlink(link))
        #expect(fm.fileExists(atPath: store.path(percentEncoded: false)))
        print("  再有効化: OK")
    }

    /// 実在する外部スキルに手を出さないこと。
    /// **判定のみ。実環境を変更する操作は手動テストでも呼ばない。**
    /// （registry の中身次第で本当に無効化してしまうため）
    @Test("実環境の外部スキルは判定で拒否される")
    func realExternalIsProtected() {
        let env = Environment.live
        let registry = Registry.load(env: env)
        for name in ["find-skills"] where registry.entry(named: name) == nil {
            let url = env.skillStore.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
            else { continue }
            #expect(throws: WriteGuard.Denial.notInRegistry(name)) {
                try WriteGuard.assertMutable(url, env: env, registry: registry)
            }
        }
    }

    /// 実際に GitHub から取得する。ネットワークを使うのでスイートには載せない（10.6）。
    @Test("実際の zip 取得と種別判定")
    func realFetch() async throws {
        let input = "https://github.com/vercel-labs/skills/tree/main/skills/find-skills"
        guard case .github(let source) = PasteInput.classify(input) else {
            Issue.record("URL として解釈されなかった"); return
        }
        print("  解釈: repo=\(source.repo) branch=\(source.branch ?? "-") subdir=\(source.subdir ?? "-") 曖昧=\(source.branchAmbiguous)")

        let staged = try await Fetcher.stage(source)
        defer { staged.discard() }
        for c in staged.candidates {
            print("  候補: [\(c.kind.rawValue)] \(c.name) — \(c.description?.prefix(60) ?? "(説明なし)")…")
        }
        #expect(staged.candidates.count == 1)
        #expect(staged.candidates.first?.kind == .skill)
        #expect(staged.candidates.first?.name == "find-skills")
        #expect(staged.candidates.first?.description != nil)
    }

    @Test("サイズ上限を超えるリポジトリは拒否される")
    func realSizeLimit() async {
        // torvalds/linux の zipball は数百 MB
        let source = GitHubSource(repo: "torvalds/linux", branch: "master")
        do {
            let staged = try await Fetcher.stage(source)
            staged.discard()
            Issue.record("上限を超えたのに成功した")
        } catch let failure as Fetcher.Failure {
            print("  拒否: \(failure)")
            if case .tooLarge = failure {} else { Issue.record("想定外のエラー: \(failure)") }
        } catch {
            Issue.record("想定外のエラー: \(error)")
        }
    }

    /// 実際の GitHub API を叩く。**304 がレート制限を消費しないこと**を確認する（7.3）。
    @Test("ETag の往復とレート制限の消費")
    func realETagRoundTrip() async throws {
        var registry = Registry()
        registry.upsert(Registry.Entry(name: "find-skills", kind: .skill,
                                       repo: "vercel-labs/skills", branch: "main"))
        let env = Environment.live

        func remaining() async -> String {
            let url = URL(string: "https://api.github.com/rate_limit")!
            let r = try? await env.httpGet(url, [:])
            return r?.headers["x-ratelimit-remaining"] ?? "?"
        }

        let before = await remaining()
        var errors = await UpdateChecker.check(&registry, env: env, force: true)
        #expect(errors["vercel-labs/skills#main"] == nil)
        let state = try #require(registry.repos["vercel-labs/skills#main"])
        print("  1 回目: sha=\(state.latestSha?.prefix(7) ?? "-") etag=\(state.etag?.prefix(20) ?? "-")")
        #expect(state.latestSha != nil)
        #expect(state.etag != nil)
        let afterFirst = await remaining()

        errors = await UpdateChecker.check(&registry, env: env, force: true)
        #expect(errors["vercel-labs/skills#main"] == nil)
        #expect(registry.repos["vercel-labs/skills#main"]?.latestSha == state.latestSha)
        let afterSecond = await remaining()

        // 実測: 304 もレート制限を 1 消費する（GitHub の従来の記載と異なる）。
        // ここは GitHub 側の挙動なので assert せず、変化に気づけるよう記録だけする。
        print("  レート制限の残り: \(before) → \(afterFirst)（200）→ \(afterSecond)（304）")
    }

    /// 実機のプラグインを読む。読み取りのみ。
    @Test("実環境のプラグインと重複検出")
    func realPlugins() {
        let plugins = PluginScanner.scan(env: .live)
        for p in plugins.sorted(by: { $0.id < $1.id }) {
            print("  [\(p.agent.rawValue)] \(p.id) v\(p.version ?? "-") scope=\(p.scope) auto=\(p.autoUpdate) \(p.projectPath.map { "→ " + $0 } ?? "")")
        }
        let dupes = PluginScanner.duplicates(plugins)
        for (id, group) in dupes.sorted(by: { $0.key < $1.key }) {
            print("  ⚠️ \(id) が \(group.count) プロジェクトに個別導入されています")
        }
        #expect(!plugins.isEmpty)
    }

    /// 実機のセッションログを集計する。読み取りのみ（DESIGN.md 3.9）。
    /// 全走査は 140 MB を読むためスイートには載せない。
    @Test("実環境の使用実績と未使用の洗い出し")
    func realUsage() {
        let env = Environment.live
        var registry = Registry()

        let started = Date()
        registry = UsageScanner.refreshed(registry, env: env)
        let full = Date().timeIntervalSince(started)

        print(String(format: "  全走査 %.2f 秒 / 検出 %d 件", full, registry.usage.lastUsed.count))
        for (name, date) in registry.usage.lastUsed.sorted(by: { $0.value > $1.value }).prefix(12) {
            print("    \(date.formatted(date: .numeric, time: .shortened))  \(name)")
        }

        // 2 回目は増分。前回以降に書かれたログだけ読む（3.9）。
        let incremental = Date()
        registry = UsageScanner.refreshed(registry, env: env)
        let delta = Date().timeIntervalSince(incremental)
        print(String(format: "  増分スキャン %.3f 秒", delta))
        #expect(delta < full, "増分が全走査より遅い — mtime による絞り込みが効いていない")

        // 「入れたまま一度も使っていない」— このアプリの本題（3.9 / 5.3）
        let installed = SkillScanner.scan(env: env)
        let names = Set(installed.map(\.name))
        let unused = names.subtracting(registry.usage.lastUsed.keys).sorted()
        print("  インストール済み \(names.count) 件 / うち使用実績なし \(unused.count) 件")
        print("    \(unused.prefix(10).joined(separator: ", "))")

        #expect(!registry.usage.lastUsed.isEmpty, "使用実績が 1 件も取れない — ログ形式が変わった可能性")
        #expect(registry.usage.scannedUpTo != nil)
    }

    /// 実機で動いている MCP を検出する。読み取りのみ（DESIGN.md 3.9）。
    @Test("実環境の MCP 実行状態")
    func realRunningMCP() {
        let env = Environment.live
        let byAgent = MCPScanner.scan(env: env)
        let servers = byAgent.values.flatMap { $0 }
        let rows = ProcessScanner.snapshot(env: env)
        print("  ps: \(rows.count) プロセス / 登録済み MCP: \(servers.count) 件")

        let live = ProcessScanner.running(servers, in: rows)
        for server in servers.sorted(by: { $0.name < $1.name }) {
            if let running = live[server.name] {
                print("    ● \(server.name) — \(running.owner?.displayName ?? "所属不明")"
                      + " · 稼働 \(running.elapsed) · pid \(running.pid)")
            } else {
                print("    ○ \(server.name) — 停止中（\(server.summary)）")
            }
        }
        #expect(!rows.isEmpty, "ps が読めていない")
        // 実測（付録）: Cursor に chrome-devtools が 1 件。起動していれば Cursor が親。
        if let running = live["chrome-devtools"] {
            #expect(running.owner == .cursor)
        }
    }

    /// 実際の npm レジストリを叩く。**書き込み先は偽ホーム** —
    /// ユーザーの `~/.cursor/mcp.json` は絶対に触らない（DESIGN.md 10 章の前提）。
    @Test("実際の npm でピン留めが通る")
    func realPin() async throws {
        let home = URL(filePath: NSTemporaryDirectory())
            .appending(path: "pin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        // httpGet だけ実物、home は一時ディレクトリ
        let env = Environment(home: home, appSupport: home.appending(path: "app"),
                              run: { _ in "" }, now: { Date() },
                              httpGet: Environment.live.httpGet)

        let version = try await MCPPin.latestVersion(ofPackage: "chrome-devtools-mcp", env: env)
        print("  npm の最新版: chrome-devtools-mcp@\(version)")
        #expect(version.first?.isNumber == true)

        let server = MCPServer(name: "chrome-devtools", transport: .stdio(
            command: "npx", args: ["-y", "chrome-devtools-mcp@latest"], env: [:]))
        try await MCPPin.pin(server, in: [.cursor], env: env)

        let written = try String(contentsOf: home.appending(path: ".cursor/mcp.json"),
                                 encoding: .utf8)
        print("  書き込まれた定義:\n\(written)")
        #expect(written.contains("chrome-devtools-mcp@\(version)"))
        #expect(!written.contains("@latest"), "@latest が残っている")

        // 書き戻した結果を読み直すと floating でなくなっている = ボタンが消える
        let reread = MCPScanner.scan(env: env)[.cursor] ?? []
        #expect(reread.first?.floatingPackage == nil)
    }

    /// 実機の権限を横断で読む。**読み取りのみ。削除は絶対に呼ばない。**
    @Test("実環境の権限の散らかり")
    func realPermissions() {
        let env = Environment.live
        let entries = PermissionScanner.scan(env: env)
        let projects = Set(entries.compactMap(\.project))
        print("  \(entries.count) 件 / \(projects.count) プロジェクト")

        let disposable = entries.filter(\.isMachineSpecific)
        print("  マシン固有（使い捨て候補）: \(disposable.count) 件")
        for e in disposable.prefix(5) { print("    [\(e.scopeName)] \(e.value.prefix(88))") }

        let dupes = PermissionScanner.duplicates(entries)
        print("  重複: \(dupes.count) 種類 / \(dupes.values.map(\.count).reduce(0,+)) 件")
        for (value, group) in dupes.sorted(by: { $0.value.count > $1.value.count }).prefix(5) {
            print("    \(group.count)× \(value.prefix(70))")
        }

        // 書き込みガードが実ファイルを通すことの確認（書き込みはしない）
        for entry in entries.prefix(20) {
            #expect(throws: Never.self) { try PermissionWriter.assertWritable(entry.file) }
        }
        #expect(!entries.isEmpty)
    }

    /// 実機の Subagent を読む。読み取りのみ。
    @Test("実環境の Subagent")
    func realSubagents() {
        let found = SubagentScanner.scan(env: .live)
        print("  ユーザースコープの Subagent: \(found.count) 件")
        for a in found { print("    \(a.name) [\(a.root)] \(a.status)") }
    }
}
