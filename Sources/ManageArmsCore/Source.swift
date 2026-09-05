import Foundation

/// 読み取ってよい場所の全列挙。DESIGN.md 3.4 —
/// 除外リストではなくホワイトリストにすることで、新しいディレクトリが増えても踏まない。
///
/// ここに載らないパスは存在しても一生読まない。特に `~/.claude/projects`（129 MB）、
/// `~/.codex/logs_2.sqlite`（44 MB）、`file-history`（17 MB）を踏むと UI が固まる。
public enum Source: Equatable, Sendable {
    case file(Root, String)
    case dir(Root, String)
    case cli([String])

    public enum Root: Sendable { case home, appSupport }
}

extension Source {
    /// 走査対象の全ケース。`SourceTests` がこの列挙を検査する。
    ///
    /// **使用実績ログ（`~/.claude/projects`）はここに入れない。**
    /// 読むのは `UsageScanner` だけで、明示的な「使用状況を分析」からしか呼ばれない
    /// （3.9）。一覧スキャンがあの 140 MB を踏むと 3.4 の前提が崩れる。
    public static let all: [Source] = skills + subagents + mcp + plugins + app

    /// スキルルート。3.2 の実測表に対応する。
    /// `.agents/skills` が実体の置き場、他は他ツール/他エージェントが入れたものの読み取り。
    public static let skills: [Source] = [
        .dir(.home, ".agents/skills"),
        .dir(.home, ".claude/skills"),
        .dir(.home, ".codex/skills"),
        .dir(.home, ".cursor/skills"),
        .dir(.home, ".cursor/skills-cursor"),
        .dir(.home, ".cursor/cloud-skills"),
        .dir(.home, ".grok/skills"),
    ]

    public static let subagents: [Source] = [
        .dir(.home, ".claude/agents"),
        .dir(.home, ".cursor/agents"),
        .dir(.appSupport, "agents"),
    ]

    /// 読み取りは設定ファイルの直読みを優先する。
    /// `claude mcp list` は健全性チェックでネットワークを叩き、JSON 出力も無い（実測）。
    /// Codex だけは設定が `config.toml` なので CLI の JSON を使う。
    public static let mcp: [Source] = [
        .file(.home, ".claude.json"),
        .file(.home, ".cursor/mcp.json"),
        .file(.home, ".gemini/settings.json"),
        .cli(["codex", "mcp", "list", "--json"]),
    ]

    public static let plugins: [Source] = [
        .file(.home, ".claude/plugins/installed_plugins.json"),
        .file(.home, ".claude/plugins/known_marketplaces.json"),
        .cli(["claude", "plugin", "list", "--json"]),
        .cli(["codex", "plugin", "list", "--json"]),
    ]

    /// アプリ自身の保存領域（9 章）。
    public static let app: [Source] = [
        .file(.appSupport, "registry.json"),
        .dir(.appSupport, "disabled-skills"),
        .dir(.appSupport, "disabled-agents"),
        .file(.home, ".agents/.skill-lock.json"),   // 読み取り専用（4.1）
    ]

    /// **静的列挙にできない唯一の例外。** プロジェクトのパスは動的なので
    /// `~/.claude.json` の `projects` キーから取る（DESIGN.md 3.4 / 5.1）。
    /// ここから読んでよいのは各プロジェクトの
    /// `.claude/skills` / `.claude/agents` / `.mcp.json` / `.claude/settings*.json` だけ。
    /// **`~/.claude/projects/`（140 MB のセッションログ）とは別物** — あれは読まない。
    public static func projectPaths(in env: Environment) -> [String] {
        guard let data = try? Data(contentsOf: env.home.appending(path: ".claude.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: Any]
        else { return [] }
        return projects.keys.sorted()
    }

    /// ファイル/ディレクトリのルート相対パス。CLI ケースは nil。
    public var relativePath: String? {
        switch self {
        case .file(_, let p), .dir(_, let p): return p
        case .cli: return nil
        }
    }

    public func url(in env: Environment) -> URL? {
        switch self {
        case .file(let root, let p), .dir(let root, let p):
            let base = root == .home ? env.home : env.appSupport
            return base.appending(path: p)
        case .cli:
            return nil
        }
    }
}
