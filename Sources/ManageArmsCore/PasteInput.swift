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
    ///   https://skills.sh/owner/repo/skill           (カタログ → owner/repo を採る)
    public static func parse(_ raw: String) -> GitHubSource? {
        if let catalog = catalog(raw) { return catalog.source }
        guard let parts = components(raw) else { return nil }
        guard let branch = parts.branch else { return GitHubSource(repo: parts.repo) }

        // ブランチ名に "/" を含むと境界が決まらない。先頭 1 個をブランチと仮定し、
        // 確認画面で直せるよう印を付ける。
        var path = parts.path
        if parts.isFile { path = Array(path.dropLast()) }   // SKILL.md → 親ディレクトリ

        return GitHubSource(
            repo: parts.repo,
            branch: branch,
            subdir: path.isEmpty ? nil : path.joined(separator: "/"),
            branchAmbiguous: !parts.path.isEmpty
        )
    }

    /// URL を repo / branch / それ以降のパスに割る。`parse` は subdir だけを使うが、
    /// ブラウザ検知（`ToolURL`）は blob のファイル名まで要る（`agents/foo.md` の実在確認）。
    /// **同じ解釈を 2 か所に書かない。**
    public struct Components: Equatable, Sendable {
        public let repo: String
        public let branch: String?
        /// ブランチより後ろの全セグメント。blob ならファイル名を含む。
        public let path: [String]
        public let isFile: Bool
    }

    public static func components(_ raw: String) -> Components? {
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
            // /issues や /pulls はリポジトリの指定ではない。
            return parts.isEmpty ? Components(repo: repo, branch: nil, path: [], isFile: false) : nil
        }
        let isFile = marker == "blob"
        parts.removeFirst()
        guard let branch = parts.first else {
            return Components(repo: repo, branch: nil, path: [], isFile: false)
        }
        parts.removeFirst()
        return Components(repo: repo, branch: branch, path: parts, isFile: isFile)
    }

    /// skills.sh のようなカタログページ。配布しているのは GitHub なので owner/repo を採る。
    ///
    /// `skills.sh/<owner>/<repo>/<skill>` の 3 番目は**ディレクトリ名であってパスではない**
    /// （`grilling` の実体は `skills/productivity/grilling`）ので subdir にはできない。
    /// 取得後の候補一覧を絞り込むヒントとしてだけ返す。
    /// ページの HTML から GitHub リンクを拾う方法は採らない — ページ構造の変更で
    /// 静かに壊れるうえ、取得物の中身以外から推測しない方針（6 章）に反する。
    static func catalog(_ raw: String) -> (source: GitHubSource, skill: String?)? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("skills.sh/") || text.hasPrefix("www.skills.sh/") {
            text = "https://" + text
        }
        guard let url = URL(string: text),
              let host = url.host()?.lowercased(),
              host == "skills.sh" || host == "www.skills.sh",
              url.scheme == "https" || url.scheme == "http"
        else { return nil }

        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !reserved.contains(parts[0].lowercased()) else { return nil }
        return (GitHubSource(repo: "\(parts[0])/\(parts[1])"),
                parts.count >= 3 ? parts[2] : nil)
    }

    /// skills.sh の予約パス。`skills.sh/agent/claude-code` は owner/repo ではないので、
    /// repo として受けると存在しないリポジトリを取得しに行く。
    static let reserved: Set<String> = [
        "about", "agent", "agents", "api", "docs", "login", "new", "search",
        "terms", "privacy", "_next", "favicon.ico",
    ]

    /// カタログ URL に含まれるスキル名。候補一覧の初期絞り込みに使う。
    public static func skillHint(_ raw: String) -> String? { catalog(raw)?.skill }
}
