import Foundation

/// GitHub 上の取得元。DESIGN.md 4.1 の registry スキーマに対応する。
public struct GitHubSource: Equatable, Sendable {
    public var repo: String          // "owner/name"
    public var branch: String?       // nil = デフォルトブランチ
    public var subdir: String?       // nil = リポジトリ直下
    /// ブランチ名に "/" を含む可能性があり、branch と subdir の境界が確定できない。
    /// `tree/feature/x/skills/foo` は `feature/x` + `skills/foo` とも
    /// `feature` + `x/skills/foo` とも読める。確認画面で直せるようにする（6 章）。
    public var branchAmbiguous: Bool = false

    public init(repo: String, branch: String? = nil, subdir: String? = nil,
                branchAmbiguous: Bool = false) {
        self.repo = repo; self.branch = branch
        self.subdir = subdir; self.branchAmbiguous = branchAmbiguous
    }

    /// zipball の URL。`git clone` は使わない（3.3）。
    public func archiveURL(defaultBranch: String = "main") -> URL {
        URL(string: "https://github.com/\(repo)/archive/refs/heads/\(branch ?? defaultBranch).zip")!
    }
}

/// 入力欄は 1 つだけ。ペーストされた文字列を見て分岐する（DESIGN.md 6 章）。
public enum PasteInput: Equatable, Sendable {
    /// 公式サイトが載せている JSON をそのままコピペできる。最頻の導線。
    case mcpJSON(String)
    case github(GitHubSource)
    /// `npx -y foo-mcp` などのコマンド行。
    case command([String])
    case unrecognized

    public static func classify(_ raw: String) -> PasteInput {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unrecognized }

        if text.hasPrefix("{"), text.contains("mcpServers") { return .mcpJSON(text) }
        if let source = GitHubURL.parse(text) { return .github(source) }
        if let command = parseCommand(text) { return .command(command) }
        return .unrecognized
    }

    /// 実行ファイルらしき先頭トークンを持つ 1 行だけをコマンドとして受ける。
    static func parseCommand(_ text: String) -> [String]? {
        guard !text.contains("\n") else { return nil }
        guard let parts = commandWords(text) else { return nil }
        guard let head = parts.first else { return nil }
        let runners = ["npx", "uvx", "uv", "bunx", "pnpm", "node", "python", "python3", "deno"]
        guard runners.contains(head) || head.hasPrefix("/") || head.hasPrefix("./") else {
            return nil
        }
        return parts
    }
    /// Tokenize quoted arguments without evaluating shell syntax.
    static func commandWords(_ text: String) -> [String]? {
        var words: [String] = [], word = ""
        var quote: Character?, escaped = false, started = false
        for character in text {
            if escaped { word.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { word.append(character) }
                continue
            }
            if character == "'" || character == "\"" { quote = character; started = true; continue }
            if "|;&<>`$\n\r".contains(character) { return nil }
            if character.isWhitespace {
                if started { words.append(word); word = ""; started = false }
            } else { word.append(character); started = true }
        }
        guard quote == nil, !escaped else { return nil }
        if started { words.append(word) }
        return words
    }

    public static func mcpServers(_ raw: String, name: String) throws -> [MCPServer] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("{") {
            let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
            guard let dict = object as? [String: Any] else { throw MCPScanner.ReadFailure("MCP設定はJSONオブジェクトで入力してください") }
            if dict["command"] != nil || dict["url"] != nil {
                guard let server = MCPServer.parse(name: name, dict) else { throw MCPScanner.ReadFailure("MCPの定義を読み取れません") }
                return [server]
            }
            return try MCPScanner.decode(dict["mcpServers"] ?? dict)
        }
        if let url = URL(string: text), ["http", "https"].contains(url.scheme), url.host != nil {
            return [MCPServer(name: name, transport: .http(url: text, headers: [:]))]
        }
        guard let words = parseCommand(text), let command = words.first else {
            throw MCPScanner.ReadFailure("MCP設定JSON・HTTPのURL・引用符付きの起動コマンドのいずれかを入力してください。シェルの式は使えません")
        }
        return [MCPServer(name: name, transport: .stdio(command: command, args: Array(words.dropFirst()), env: [:]))]
    }

}

public enum GitHubURL {

    /// 受ける形:
    ///   https://github.com/owner/repo
    ///   https://github.com/owner/repo.git
    ///   github.com/owner/repo                       (スキーム省略)
    ///   .../tree/main                               (ブランチのみ)
    ///   .../tree/main/skills/foo                    (サブディレクトリ)
    ///   .../blob/main/skills/foo/SKILL.md           (ファイル指定 → 親を採る)
    public static func parse(_ raw: String) -> GitHubSource? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("github.com/") || text.hasPrefix("www.github.com/") {
            text = "https://" + text
        }
        guard let url = URL(string: text),
              let host = url.host()?.lowercased(),
              host == "github.com" || host == "www.github.com",
              url.scheme == "https" || url.scheme == "http"
        else { return nil }

        var parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }

        let owner = parts.removeFirst()
        var name = parts.removeFirst()
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        guard !owner.isEmpty, !name.isEmpty else { return nil }
        let repo = "\(owner)/\(name)"

        guard let marker = parts.first, marker == "tree" || marker == "blob" else {
            return parts.isEmpty ? GitHubSource(repo: repo) : nil
        }
        let isFile = marker == "blob"
        parts.removeFirst()
        guard let branch = parts.first else { return GitHubSource(repo: repo) }
        parts.removeFirst()

        // ブランチ名に "/" を含むと境界が決まらない。先頭 1 個をブランチと仮定し、
        // 確認画面で直せるよう印を付ける。
        var path = parts
        if isFile { path = Array(path.dropLast()) }   // SKILL.md → 親ディレクトリ

        return GitHubSource(
            repo: repo,
            branch: branch,
            subdir: path.isEmpty ? nil : path.joined(separator: "/"),
            branchAmbiguous: !parts.isEmpty
        )
    }
}
