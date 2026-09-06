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

    /// **静的列挙にできない唯一の例外。** プロジェクトのパスは動的なので
    /// `~/.claude.json` の `projects` キーから取る（DESIGN.md 3.4 / 5.1）。
    /// ここから読んでよいのは各プロジェクトの
    /// `.claude/skills` / `.claude/agents` / `.mcp.json` / `.claude/settings*.json` だけ
    /// （スキルはサブディレクトリの `.claude/skills` も含む。`projectSkillRoots`）。
    /// **`~/.claude/projects/`（140 MB のセッションログ）とは別物** — あれは読まない。
    /// `registry.projects` も合流させるが、**足す導線はもう無い**（DESIGN.md 15）。
    /// 既に値がある人のデータを黙って無視しないために読み取りだけ残す。
    public static func projectPaths(in env: Environment) -> [String] {
        var paths = Set(Registry.load(env: env).projects)
        if let data = try? Data(contentsOf: env.home.appending(path: ".claude.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let projects = object["projects"] as? [String: Any] {
            paths.formUnion(projects.keys)
        }
        return paths.sorted()
    }

    /// プロジェクト内のスキルルート。**ルート直下の `.claude/skills` だけではない。**
    /// Claude Code は作業ディレクトリ下のサブディレクトリの `.claude/skills` も読む
    /// （monorepo のパッケージが自前のスキルを持てる。公式ドキュメント「スキルが存在する場所」）。
    /// 見えているものを見えているとおりに出すため、こちらも同じ場所を読む。
    ///
    /// 3.4 のホワイトリストを広げる操作なので、上限を固定で持つ:
    /// **プロジェクト直下から 3 段まで**、隠しディレクトリと依存物の置き場には降りない。
    /// 途中で読むのはディレクトリ名だけで、`.claude/skills` 以外は一切開かない。
    ///
    /// 戻り値の `prefix` はプロジェクトルートからの相対サブディレクトリ（直下は `""`）。
    /// Claude の修飾名 `apps/web:deploy` の左半分になる。
    ///
    /// ponytail: 深さ 3 + 固定の除外名。取りこぼす配置が出たら、深さを上げる前に実測する。
    public static func projectSkillRoots(_ project: String) -> [(prefix: String, url: URL)] {
        var found: [(prefix: String, url: URL)] = []
        walk(URL(filePath: project), prefix: "", depth: projectSkillDepth, into: &found)
        return found
    }

    /// `apps/web:deploy` → (`apps/web`, `deploy`)。修飾されていなければ左は空。
    /// `:` を区切りに使うのは Claude 自身の規約（プラグインの名前空間と同じ）で、
    /// スキルのディレクトリ名には現れない前提。
    public static func splitQualified(_ name: String) -> (subdir: String, name: String) {
        guard let i = name.lastIndex(of: ":") else { return ("", name) }
        return (String(name[name.startIndex..<i]), String(name[name.index(after: i)...]))
    }

    static let projectSkillDepth = 3

    /// 降りない場所。数万エントリある一方でスキルは 1 つも無い。
    static let notWalked: Set<String> = ["node_modules", "Pods", "vendor", "target",
                                         "dist", "build", "out"]

    static func walk(_ dir: URL, prefix: String, depth: Int,
                     into found: inout [(prefix: String, url: URL)]) {
        let fm = FileManager.default
        let skills = dir.appending(path: ".claude/skills")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: skills.path(percentEncoded: false), isDirectory: &isDir),
           isDir.boolValue {
            found.append((prefix, skills))
        }
        guard depth > 0 else { return }
        let children = (try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false)))?
            .filter { !$0.hasPrefix(".") && !notWalked.contains($0) }.sorted() ?? []
        for child in children {
            let url = dir.appending(path: child)
            guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir),
                  isDir.boolValue else { continue }
            walk(url, prefix: prefix.isEmpty ? child : "\(prefix)/\(child)",
                 depth: depth - 1, into: &found)
        }
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
