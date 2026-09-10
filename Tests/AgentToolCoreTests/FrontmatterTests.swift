import Foundation
import Testing
@testable import AgentToolCore

///  — frontmatter パース。
@Suite("frontmatter パース")
struct FrontmatterTests {

    @Test("素朴な key: value")
    func plain() {
        let r = FrontmatterParser.parse("""
        ---
        name: find-skills
        description: Helps users discover and install agent skills.
        ---

        # Body
        """)
        #expect(r == .parsed(Frontmatter(name: "find-skills",
                                         description: "Helps users discover and install agent skills.")))
    }

    /// 実在するスキルの大半がこの形式（実測: 26 件中 24 件）。
    /// これを落とすと Cursor 由来のスキルが全部 description 無しになる。
    @Test("YAML 折り畳みスカラー >- が畳まれる")
    func foldedScalar() {
        let r = FrontmatterParser.parse("""
        ---
        name: create-subagent
        description: >-
          Create custom subagents for specialized AI tasks. Use when you want to create
          a new type of subagent, set up task-specific agents.
        disable-model-invocation: true
        ---
        """)
        #expect(r == .parsed(Frontmatter(
            name: "create-subagent",
            description: "Create custom subagents for specialized AI tasks. Use when you want to create a new type of subagent, set up task-specific agents.")))
    }

    @Test("リテラルスカラー | は改行を保つ")
    func literalScalar() {
        let r = FrontmatterParser.parse("""
        ---
        description: |
          line one
          line two
        ---
        """)
        guard case .parsed(let fm) = r else { Issue.record("parsed でない"); return }
        #expect(fm.description == "line one\nline two")
    }

    @Test("CRLF")
    func crlf() {
        let r = FrontmatterParser.parse("---\r\nname: x\r\ndescription: y\r\n---\r\n")
        #expect(r == .parsed(Frontmatter(name: "x", description: "y")))
    }

    /// 本文中の `---` を閉じ区切りと誤認しないこと。
    @Test("本文中の --- に引っかからない")
    func dashesInBody() {
        let r = FrontmatterParser.parse("""
        ---
        name: x
        description: y
        ---

        # Heading
        ---
        more body
        """)
        #expect(r == .parsed(Frontmatter(name: "x", description: "y")))
    }

    @Test("--- で始まらなければ missing")
    func noFrontmatter() {
        #expect(FrontmatterParser.parse("# Just a heading\n") == .missing)
        #expect(FrontmatterParser.parse("") == .missing)
    }

    /// 4 KB しか読まない設計の副作用。「description 無し」と混同してはいけない。
    @Test("閉じ --- が範囲内に無ければ truncated")
    func truncated() {
        let long = String(repeating: "x", count: 5000)
        #expect(FrontmatterParser.parse("---\ndescription: \(long)") == .truncated)
    }

    @Test("description 欠落")
    func missingDescription() {
        let r = FrontmatterParser.parse("---\nname: x\n---\n")
        #expect(r == .parsed(Frontmatter(name: "x", description: nil)))
    }

    @Test("引用符を外す")
    func quotes() {
        let r = FrontmatterParser.parse("---\nname: \"x\"\ndescription: 'y'\n---\n")
        #expect(r == .parsed(Frontmatter(name: "x", description: "y")))
    }

    /// description に `:` が含まれる場合、最初の `:` だけで分割すること。
    @Test("値にコロンが含まれる")
    func colonInValue() {
        let r = FrontmatterParser.parse("---\ndescription: Use when: the user asks\n---\n")
        guard case .parsed(let fm) = r else { Issue.record("parsed でない"); return }
        #expect(fm.description == "Use when: the user asks")
    }

    /// 実ファイル経由でも先頭 4 KB しか読まないこと。
    @Test("4 KB 境界で frontmatter が切れる実ファイル")
    func truncatedRealFile() throws {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "SKILL.md")
        // 4 KB を超えた位置に閉じ --- がある
        try ("---\nname: x\ndescription: \(String(repeating: "y", count: 5000))\n---\n")
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(FrontmatterParser.read(file) == .truncated)
    }
}

/// 先頭 4 KB しか読まない設計の副作用（）。
@Suite("4 KB 境界")
struct FrontmatterBoundaryTests {

    /// **日本語は 1 字 3 バイト。** 境界が字の途中に落ちると
    /// `String(decoding:)` が U+FFFD を置き、説明文の最後の 1 字が「�」になる。
    @Test("末尾で切れた UTF-8 の断片は捨てる")
    func dropsPartialScalar() {
        let full = Data("あい".utf8)                    // 6 バイト
        #expect(FrontmatterParser.droppingPartialScalar(full) == full)
        for cut in 1...2 {                              // 「い」を途中で切る
            let partial = full.dropLast(cut)
            let cleaned = FrontmatterParser.droppingPartialScalar(Data(partial))
            #expect(String(decoding: cleaned, as: UTF8.self) == "あ",
                    "\(cut) バイト欠けで置換文字が残った")
        }
    }

    @Test("ASCII の途中では何も落とさない")
    func keepsASCII() {
        let data = Data("name: demo".utf8)
        #expect(FrontmatterParser.droppingPartialScalar(data) == data)
    }

    @Test("空でも落ちない")
    func handlesEmpty() {
        #expect(FrontmatterParser.droppingPartialScalar(Data()).isEmpty)
    }
}
