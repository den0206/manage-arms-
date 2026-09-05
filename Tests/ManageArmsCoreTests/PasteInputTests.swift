import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.1 — GitHub URL パース。
@Suite("GitHub URL パース")
struct GitHubURLTests {

    @Test("リポジトリ直下")
    func bareRepo() {
        #expect(GitHubURL.parse("https://github.com/vercel-labs/skills")
                == GitHubSource(repo: "vercel-labs/skills"))
    }

    @Test("末尾スラッシュ")
    func trailingSlash() {
        #expect(GitHubURL.parse("https://github.com/vercel-labs/skills/")
                == GitHubSource(repo: "vercel-labs/skills"))
    }

    @Test(".git 付き")
    func dotGit() {
        #expect(GitHubURL.parse("https://github.com/vercel-labs/skills.git")
                == GitHubSource(repo: "vercel-labs/skills"))
    }

    @Test("スキーム省略")
    func noScheme() {
        #expect(GitHubURL.parse("github.com/vercel-labs/skills")
                == GitHubSource(repo: "vercel-labs/skills"))
    }

    @Test("tree + ブランチのみ")
    func branchOnly() {
        #expect(GitHubURL.parse("https://github.com/vercel-labs/skills/tree/main")
                == GitHubSource(repo: "vercel-labs/skills", branch: "main"))
    }

    /// 実際に使う形。`update-skills.py` の registry と同じ 3 要素になる。
    @Test("tree + サブディレクトリ")
    func subdir() {
        #expect(GitHubURL.parse("https://github.com/vercel-labs/skills/tree/main/skills/find-skills")
                == GitHubSource(repo: "vercel-labs/skills", branch: "main",
                                subdir: "skills/find-skills", branchAmbiguous: true))
    }

    /// SKILL.md を直接開いた URL からも取れること。
    @Test("blob はファイル名を落として親を採る")
    func blobDropsFilename() {
        #expect(GitHubURL.parse(
            "https://github.com/vercel-labs/skills/blob/main/skills/find-skills/SKILL.md")
                == GitHubSource(repo: "vercel-labs/skills", branch: "main",
                                subdir: "skills/find-skills", branchAmbiguous: true))
    }

    /// `feature/x` + `skills/foo` とも `feature` + `x/skills/foo` とも読める。
    /// 確認画面で直せるよう印を立てる（6 章）。
    @Test("ブランチ名に / を含むと曖昧フラグが立つ")
    func ambiguousBranch() {
        let parsed = GitHubURL.parse("https://github.com/o/r/tree/feature/x/skills/foo")
        #expect(parsed?.branch == "feature")
        #expect(parsed?.subdir == "x/skills/foo")
        #expect(parsed?.branchAmbiguous == true)
    }

    @Test("サブディレクトリが無ければ曖昧ではない")
    func notAmbiguous() {
        #expect(GitHubURL.parse("https://github.com/o/r/tree/main")?.branchAmbiguous == false)
    }

    @Test("GitHub 以外は受けない", arguments: [
        "https://gitlab.com/o/r", "https://example.com/o/r",
        "https://github.com/onlyowner", "https://github.com/", "not a url",
        "ftp://github.com/o/r", "https://github.com.evil.com/o/r",
    ])
    func rejects(_ input: String) {
        #expect(GitHubURL.parse(input) == nil)
    }

    @Test("zipball の URL を組み立てる")
    func archiveURL() {
        let source = GitHubSource(repo: "o/r", branch: "dev")
        #expect(source.archiveURL().absoluteString
                == "https://github.com/o/r/archive/refs/heads/dev.zip")
        #expect(GitHubSource(repo: "o/r").archiveURL().absoluteString
                == "https://github.com/o/r/archive/refs/heads/main.zip")
    }
}

/// DESIGN.md 6 章 — 入力欄は 1 つだけ。
@Suite("ペースト入力の種別判定")
struct PasteClassificationTests {

    /// 公式サイトが載せている JSON をそのまま貼れること。
    @Test("mcpServers JSON")
    func mcpJSON() {
        let json = """
        {
          "mcpServers": {
            "chrome-devtools": { "command": "npx", "args": ["-y", "chrome-devtools-mcp@latest"] }
          }
        }
        """
        #expect(PasteInput.classify(json) == .mcpJSON(json))
        #expect(PasteInput.classify("\n\n  \(json)  \n") == .mcpJSON(json))
    }

    @Test("GitHub URL")
    func githubURL() {
        #expect(PasteInput.classify("  https://github.com/o/r  ")
                == .github(GitHubSource(repo: "o/r")))
    }

    @Test("コマンド行", arguments: [
        "npx -y chrome-devtools-mcp@latest",
        "uvx mcp-server-git",
        "/usr/local/bin/my-mcp --flag",
    ])
    func commandLine(_ input: String) {
        guard case .command(let parts) = PasteInput.classify(input) else {
            Issue.record("コマンドとして解釈されなかった: \(input)"); return
        }
        #expect(parts.first == input.split(separator: " ").first.map(String.init))
    }

    @Test("どれでもない入力", arguments: [
        "", "   ", "hello world", "{ \"foo\": 1 }", "これは説明文です",
        "npx\nnpx",                       // 複数行はコマンドとして受けない
    ])
    func unrecognized(_ input: String) {
        #expect(PasteInput.classify(input) == .unrecognized)
    }

    /// JSON でも mcpServers を含まなければ MCP ではない。
    @Test("mcpServers を含まない JSON は受けない")
    func jsonWithoutMCPServers() {
        #expect(PasteInput.classify("{\"servers\": {}}") == .unrecognized)
    }
}
