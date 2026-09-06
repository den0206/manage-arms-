import Testing
import Foundation
@testable import ManageArmsCore

/// ブラウザ検知の判定（DESIGN.md 6 章 / 10.1）。
/// 実ブラウザと実ネットワークは使わない — ここで確かめるのは純粋関数だけ。
@Suite("ブラウザで見つけた URL の判定")
struct ToolURLTests {

    @Test("カタログページはスキル名まで分かる")
    func catalogPage() throws {
        let lead = try #require(ToolURL.lead("https://www.skills.sh/mattpocock/skills/grilling"))
        #expect(lead.kind == .skill)
        #expect(lead.name == "grilling")
        #expect(lead.source.repo == "mattpocock/skills")
        // 実体のパスが分からないので確認しようがない。カタログ自体が根拠。
        #expect(lead.proofs.isEmpty)
    }

    @Test("カタログのリポジトリページは拾わない（名前が決まらない）")
    func catalogRepoPage() {
        #expect(ToolURL.lead("https://skills.sh/mattpocock/skills") == nil)
    }

    @Test("skills.sh の予約パスを owner/repo と取り違えない")
    func catalogReservedPaths() {
        #expect(ToolURL.lead("https://www.skills.sh/agent/claude-code") == nil)
        #expect(ToolURL.lead("https://www.skills.sh/about/us") == nil)
        // 手貼りの経路（AddSheet）でも同じく弾く。
        #expect(GitHubURL.parse("https://www.skills.sh/agent/claude-code") == nil)
    }

    @Test("サブディレクトリ指定の GitHub URL は SKILL.md の実在で確かめる")
    func skillSubdirectory() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture"))
        #expect(lead.kind == .skill)
        #expect(lead.name == "improve-codebase-architecture")
        #expect(lead.proofs == ["skills/engineering/improve-codebase-architecture/SKILL.md"])
        #expect(lead.proofURLs().map(\.absoluteString) == [
            "https://raw.githubusercontent.com/mattpocock/skills/main/skills/engineering/improve-codebase-architecture/SKILL.md"
        ])
    }

    @Test("SKILL.md 自体を開いていても親ディレクトリの名前を採る")
    func skillFile() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/owner/repo/blob/main/skills/foo/SKILL.md"))
        #expect(lead.kind == .skill)
        #expect(lead.name == "foo")
        #expect(lead.proofs == ["skills/foo/SKILL.md"])
    }

    @Test("Plugin は plugin.json と marketplace.json のどちらかを根拠にする")
    func plugin() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/owner/repo/tree/main/plugins/my-plugin"))
        #expect(lead.kind == .plugin)
        #expect(lead.proofs == ["plugins/my-plugin/.claude-plugin/plugin.json",
                                ".claude-plugin/marketplace.json"])
    }

    @Test("Subagent はファイルを指しているときだけ拾う")
    func subagent() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/owner/repo/blob/main/agents/reviewer.md"))
        #expect(lead.kind == .subagent)
        #expect(lead.name == "reviewer")
        #expect(lead.proofs == ["agents/reviewer.md"])
        // ディレクトリだと中のファイル名が分からず、実在を確かめられない。
        #expect(ToolURL.lead("https://github.com/owner/repo/tree/main/agents") == nil)
    }

    @Test("ただの GitHub 閲覧では通知しない")
    func noise() {
        for url in [
            "https://github.com/owner/repo",                       // リポジトリのトップ
            "https://github.com/owner/repo/tree/main/src/lib",     // 種別の手がかりが無い
            "https://github.com/owner/repo/issues/12",
            "https://news.example.com/skills/foo",                 // 対象ホストではない
            "https://github.com/owner/repo/tree/main",             // ブランチだけ
            "",
        ] {
            #expect(ToolURL.lead(url) == nil, "\(url) を拾ってしまいました")
        }
    }

    @Test("ブランチ名に / を含んでも repo は取り違えない")
    func slashBranch() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/owner/repo/tree/feature/x/skills/foo"))
        #expect(lead.source.repo == "owner/repo")
        #expect(lead.source.branchAmbiguous)
    }

    // MARK: - 通知するかどうか

    @Test("同じ URL は起動中に一度だけ")
    func seenOnce() throws {
        let lead = try #require(ToolURL.lead("https://www.skills.sh/mattpocock/skills/grilling"))
        #expect(ToolURL.shouldNotify(lead, registry: Registry(), seen: []))
        #expect(!ToolURL.shouldNotify(lead, registry: Registry(), seen: [lead.url]))
    }

    @Test("既に入れてあるものは勧めない")
    func alreadyInstalled() throws {
        let lead = try #require(ToolURL.lead(
            "https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture"))
        var registry = Registry()
        registry.upsert(.init(name: "improve-codebase-architecture", kind: .skill,
                              repo: "mattpocock/skills", branch: "main",
                              subdir: "skills/engineering/improve-codebase-architecture"))
        #expect(!ToolURL.shouldNotify(lead, registry: registry, seen: []))

        // 同じリポジトリの**別のスキル**は勧める。カタログ URL は subdir を持たないので、
        // nil 同士を突き合わせると repo が一致するだけで導入済み扱いになってしまう。
        let sibling = try #require(ToolURL.lead("https://www.skills.sh/mattpocock/skills/grill-me"))
        #expect(sibling.source.subdir == nil)
        #expect(ToolURL.shouldNotify(sibling, registry: registry, seen: []))

        // subdir を持たない登録（カタログから入れたもの）でも同じ。
        var catalogInstalled = Registry()
        catalogInstalled.upsert(.init(name: "grilling", kind: .skill, repo: "mattpocock/skills"))
        #expect(ToolURL.shouldNotify(sibling, registry: catalogInstalled, seen: []))
        let same = try #require(ToolURL.lead("https://www.skills.sh/mattpocock/skills/grilling"))
        #expect(!ToolURL.shouldNotify(same, registry: catalogInstalled, seen: []))

        // 別のリポジトリの同名は別物。
        var other = Registry()
        other.upsert(.init(name: "improve-codebase-architecture", kind: .skill, repo: "someone/else"))
        #expect(ToolURL.shouldNotify(lead, registry: other, seen: []))
    }

    // MARK: - 設定

    @Test("検知の設定は既定 OFF で、既定値は registry.json に書き出さない")
    func settingDefaults() throws {
        var registry = Registry()
        #expect(!registry.detectsBrowserURLs)
        let off = try Registry.encoder.encode(registry)
        #expect(!String(decoding: off, as: UTF8.self).contains("browserDetection"))

        registry.browserDetection = true
        let on = try Registry.encoder.encode(registry)
        #expect(String(decoding: on, as: UTF8.self).contains("\"browserDetection\" : true"))
        let restored = try Registry.decoder.decode(Registry.self, from: on)
        #expect(restored.detectsBrowserURLs)
    }
}
