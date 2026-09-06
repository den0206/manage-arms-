import Foundation

/// 読み取ってよい場所の全列挙。DESIGN.md 3.4 —
/// 除外リストではなくホワイトリストにすることで、新しいディレクトリが増えても踏まない。
///
/// ここに載らないパスは存在しても一生読まない。特に各 Agent のセッションログや
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
    /// **使用実績ログ（Claude / Codex / Cursor）はここに入れない。**
    /// 読むのは `UsageScanner` だけで、明示的な「使用状況を分析」からしか呼ばれない
    /// （3.9）。一覧スキャンが大量の履歴を踏むと 3.4 の前提が崩れる。
    public static let all: [Source] = skills + subagents + mcp + plugins + app

    /// 走査するスキルルート。**各 `Agent.skillRoots` の和集合**（3.2 の実測表）。
    ///
    /// エージェントを増やしても、ここには何も書かない —
    /// `Agent.skillRoots` に足せば走査対象になる。**二重管理をすると、
    /// 片方だけ足したときに「宣言はあるのに一生読まれないルート」が静かにできる。**
    public static let skills: [Source] = homeDirs(Agent.allCases.flatMap(\.skillRoots))

    /// `Agent.subagentRoots` の和集合 + アプリ自身の実体置き場（3.2 / 9 章）。
    public static let subagents: [Source] =
        homeDirs(Agent.allCases.flatMap(\.subagentRoots)) + [.dir(.appSupport, "agents")]

    /// 読み取りは設定ファイルの直読みを優先する（`Agent.mcpSource`）。
    /// `claude mcp list` は健全性チェックでネットワークを叩き、JSON 出力も無い（実測）。
    /// Codex だけは設定が `config.toml` なので CLI の JSON を使う。
    public static let mcp: [Source] = Agent.allCases.compactMap(\.mcpSource)

    public static let plugins: [Source] = Agent.allCases.flatMap(\.pluginSources)

    /// ホーム相対ルートの列挙を重複なく畳む。順序は安定させる（走査順が結果に出る）。
    static func homeDirs(_ paths: [String]) -> [Source] {
        Set(paths).sorted().map { .dir(.home, $0) }
    }

    /// アプリ自身の保存領域（9 章）。
    public static let app: [Source] = [
        .file(.appSupport, "registry.json"),
        .dir(.appSupport, "disabled-skills"),
        .dir(.appSupport, "disabled-agents"),
        .file(.home, ".agents/.skill-lock.json"),   // 読み取り専用（4.1）
    ]

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
