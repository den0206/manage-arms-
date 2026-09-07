import Foundation

/// 触ってよい対象の限定。DESIGN.md 9 章。
///
/// 「触ってはいけないパスの列挙」ではなく「触ってよい対象の限定」にしてある。
/// 新しいリソース種別を足しても安全側に倒れる。
public enum WriteGuard {

    public enum Denial: Error, Equatable, CustomStringConvertible {
        /// 二重チェックに引っかかった。認証ファイル等。
        case deniedPath(String)
        /// symlink のリンク先が実体置き場の外を指している。自分が張ったものではない。
        case symlinkOutsideStore(String)
        /// 実体置き場でも退避ディレクトリでもない場所。
        case outsideManagedRoots(String)
        /// registry.json に載っていない。他ツールが入れたもの（外部管理）。
        case notInRegistry(String)
        /// 取得物が名乗った名前がパス要素として使えない（`..` / `/` を含む等）。
        case invalidName(String)
        /// 書き込み先までの既存ディレクトリに symlink が含まれる。
        case unsafeParent(String)

        public var description: String {
            switch self {
            case .deniedPath(let p):
                String(localized: "\(p) は保護対象です")
            case .symlinkOutsideStore(let p):
                String(localized: "\(p) は manage-arms が張った symlink ではありません")
            case .outsideManagedRoots(let p):
                String(localized: "\(p) は manage-arms の管理外です")
            case .notInRegistry(let n):
                String(localized: "\(n) は他のツールが管理しています。manage-arms からは変更できません")
            case .invalidName(let n):
                String(localized: "\(n) は名前として使えません（取得元の指定を確認してください）")
            case .unsafeParent(let p):
                String(localized: "\(p) の親ディレクトリに安全でないシンボリックリンクがあります")
            }
        }
    }

    /// ホワイトリストに通っても無条件で拒否する。
    /// ホワイトリストの実装ミス 1 つで到達しうる場所なので二重にする（9 章）。
    /// `~/.codex/auth.json` は認証トークンで、誤爆すると全ログインが飛ぶ。
    static let deniedNames: Set<String> = [
        "auth.json", "oauth_creds.json", "settings.json",
        "settings.local.json", ".claude.json", "config.toml", "mcp.json",
    ]
    static let deniedExtensions: Set<String> = ["sqlite", "sqlite-wal", "sqlite-shm"]

    /// 取得物が名乗った名前を、そのままパス要素に使ってよいか。**純粋関数**（10.1）。
    ///
    /// **名前は取得先リポジトリの `SKILL.md` frontmatter 由来**で、こちらの管理下にない。
    /// `../../../.claude` のような名前を `skillStore.appending(path:)` に渡すと
    /// FileManager がパスを解決するため、管理ルートの外へ書けてしまう。
    /// `assertMutable` は**削除・移動**しか守らないので、9 章のホワイトリストには
    /// 作成方向の穴が空く。ここがその穴を塞ぐ。
    ///
    /// 落とすのは危険なものだけで、文字種は絞らない — 実在するスキル名を
    /// 勝手に弾くと、正しい取得物が入らなくなる方の事故になる。
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255 else { return false }
        guard name != ".", name != ".." else { return false }
        guard !name.hasPrefix(".") else { return false }        // 隠しファイルを作らせない
        guard !name.contains("/"), !name.contains("\\") else { return false }
        // `apps/web:deploy` の区切り。名前に含むと修飾名と区別できなくなる。
        guard !name.contains(":") else { return false }
        // 改行や NUL を含む名前は、表示にもパスにも使えない。
        guard !name.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control
        }) else { return false }
        return !isDenied(URL(filePath: name))
    }

    /// 通らなければ throw する。**作成の直前に必ず通す。**
    public static func assertValidName(_ name: String) throws {
        guard isValidName(name) else { throw Denial.invalidName(name) }
    }

    /// 削除・移動してよいか。通らなければ throw する。
    ///
    /// 許すのは 2 つだけ:
    ///   1. 自分が張った symlink（リンク先が実体置き場の配下）
    ///   2. registry.json に載っている実体（実体置き場 or 退避ディレクトリの配下）
    public static func assertMutable(
        _ url: URL, env: Environment, registry: Registry
    ) throws {
        try Registry.assertReadable(env: env)
        let path = url.standardized.path(percentEncoded: false)

        try assertNotBundled(url, env: env)
        if isDenied(url) { throw Denial.deniedPath(path) }

        if isSymlink(url) {
            guard let target = symlinkTarget(url),
                  env.managedRoots.contains(where: { isInside(target, $0) })
            else { throw Denial.symlinkOutsideStore(path) }
            return
        }

        guard let managedRoot = env.managedRoots.first(where: { isInside(url, $0) }) else {
            throw Denial.outsideManagedRoots(path)
        }
        try assertSafeCreation(url, inside: managedRoot, anchor: env.home)
        // Subagent は `<name>.md` なので拡張子を落とす。
        let name = url.pathExtension == "md"
            ? String(url.lastPathComponent.dropLast(3))
            : url.lastPathComponent
        let kind: Kind = url.pathExtension == "md" ? .subagent : .skill
        guard registry.entry(named: name, kind: kind) != nil else {
            throw Denial.notInRegistry(name)
        }
    }

    /// 作成・移動先の途中にある symlink を拒否する。文字列上の配下判定だけでは、
    /// `~/.agents/skills -> /outside` のような付け替えで管理外へ到達するため。
    public static func assertSafeCreation(_ url: URL, inside root: URL,
                                          anchor: URL? = nil) throws {
        let trusted = (anchor ?? root).standardizedFileURL
        let target = url.standardizedFileURL
        let boundary = root.standardizedFileURL
        guard target.path == boundary.path || isInside(target, boundary),
              boundary.path == trusted.path || isInside(boundary, trusted) else {
            throw Denial.outsideManagedRoots(target.path)
        }

        let trustedParts = trusted.pathComponents
        let targetParts = target.deletingLastPathComponent().pathComponents
        guard targetParts.starts(with: trustedParts) else {
            throw Denial.outsideManagedRoots(target.path)
        }
        var current = trusted
        for component in targetParts.dropFirst(trustedParts.count) {
            current.append(path: component)
            guard FileManager.default.fileExists(atPath: current.path) else { continue }
            if isSymlink(current) { throw Denial.unsafeParent(current.path) }
        }
    }

    /// Installed artifacts may be removed regardless of who installed them.
    /// Only a direct child of a known resource directory is eligible; never follow a link to delete its target.
    public static func assertUserArtifact(_ url: URL, kind: Kind, project: String? = nil,
                                          env: Environment) throws {
        guard kind == .skill || kind == .subagent else { throw Denial.deniedPath(url.path) }
        try assertNotBundled(url, env: env)
        if let project {
            let known = Set(ProjectScan.projectPaths(in: env).compactMap(ProjectScan.identity))
            guard let identity = ProjectScan.identity(project), known.contains(identity) else {
                throw Denial.outsideManagedRoots(url.path)
            }
        }
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let base = (project.map { URL(filePath: $0) } ?? env.home).standardizedFileURL
        // `dropFirst` は parent が base の下にある前提でしか意味を持たない。
        // 外にあるパスを渡されると出鱈目な suffix が出るので、先に境界を確かめる。
        guard isInside(parent, base) || parent.path == base.path else {
            throw Denial.outsideManagedRoots(url.path)
        }
        let suffix = String(parent.path.dropFirst(base.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let expected = base.resolvingSymlinksInPath().appending(path: suffix).standardizedFileURL
        guard isManagedParent(suffix, kind: kind, inProject: project != nil),
              parent.resolvingSymlinksInPath().path == expected.path,
              !url.lastPathComponent.hasPrefix("."), !isDenied(url),
              kind != .subagent || url.pathExtension == "md" else {
            throw Denial.outsideManagedRoots(url.path)
        }
    }

    /// 削除してよい親ディレクトリか（ホーム相対 / プロジェクト相対）。**純粋関数**（10.1）。
    ///
    /// **許可ルートを列挙し直さずに判定する。** 以前はプロジェクト側で
    /// `ProjectScan.skillRoots(project)` を呼んでいたが、あれはプロジェクト配下を
    /// 深さ 3 まで歩く I/O で、UI の `removableFiles` から **1 行ずつ**呼ばれていた
    /// （実測 0.16 秒 × 350 行 = 56 秒、しかも body 評価のたびにメインスレッド上で）。
    /// `ProjectScan.walk` が作りうる形をそのまま述語にすれば、同じ集合を歩かずに引ける。
    ///
    /// 判定する集合は変えない — プロジェクトのスキルはサブディレクトリの
    /// `.claude/skills` まで、サブエージェントは直下の `.claude/agents` だけ。
    static func isManagedParent(_ relative: String, kind: Kind, inProject: Bool) -> Bool {
        guard kind == .skill || kind == .subagent else { return false }
        guard inProject else {
            let labels = kind == .skill ? Agent.allCases.flatMap(\.skillRoots)
                                        : Agent.allCases.flatMap(\.subagentRoots)
            return labels.contains(relative) && !Agent.bundledSkillRoots.contains(relative)
        }
        let leaf = kind == .skill ? ".claude/skills" : ".claude/agents"
        if relative == leaf { return true }
        guard kind == .skill, relative.hasSuffix("/" + leaf) else { return false }
        return ProjectScan.isWalkablePrefix(String(relative.dropLast(leaf.count + 1)))
    }

    /// アプリ自身が作ったバックアップだけを消してよい（9 章）。
    ///
    /// `PermissionWriter` は世代を上限まで刈るために削除を要る唯一の場所で、
    /// `check-invariants.sh` の削除許可リストに載る 3 つ目のファイルになる。
    /// **許可リストに載せるだけでは中身が空でも通ってしまう**ので、
    /// `SkillManager` / `Updater` が `assertMutable` を必ず呼ぶのと同じ形で、
    /// ここを通すことを検査スクリプト側でも要求する。
    ///
    /// 許すのは自分の保存領域直下の**通常ファイル**だけ。ディレクトリと symlink は
    /// 辿った先を消しうるので拒否する。
    public static func assertAppBackup(_ url: URL, env: Environment) throws {
        let root = env.appSupport.appending(path: PermissionWriter.backupDirectory)
        guard isInside(url, root) else {
            throw Denial.outsideManagedRoots(url.standardized.path(percentEncoded: false))
        }
        guard !isSymlink(url) else {
            throw Denial.symlinkOutsideStore(url.standardized.path(percentEncoded: false))
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDir),
              !isDir.boolValue else {
            throw Denial.deniedPath(url.standardized.path(percentEncoded: false))
        }
    }

    static func assertNotBundled(_ url: URL, env: Environment) throws {
        let protected = Agent.bundledSkillRoots.map { env.home.appending(path: $0) }
            + [env.home.appending(path: ".codex/plugins"), env.home.appending(path: ".claude/plugins"),
               env.home.appending(path: ".cursor/plugins")]
        let paths = [url.standardizedFileURL, url.resolvingSymlinksInPath()]
        guard !paths.contains(where: { path in protected.contains { path.path == $0.path || isInside(path, $0) } }) else {
            throw Denial.deniedPath(url.path)
        }
    }

    // MARK: - 判定

    static func isDenied(_ url: URL) -> Bool {
        deniedNames.contains(url.lastPathComponent)
            || deniedExtensions.contains(url.pathExtension)
    }

    static func isSymlink(_ url: URL) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// リンク先を絶対パスで返す。相対 symlink も解決する。
    static func symlinkTarget(_ url: URL) -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path(percentEncoded: false))
        else { return nil }
        let target = dest.hasPrefix("/")
            ? URL(filePath: dest)
            : url.deletingLastPathComponent().appending(path: dest)
        return target.standardized
    }

    /// `..` で抜けられないよう、パス境界を見て判定する。
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let path = url.standardized.path(percentEncoded: false)
        var rootPath = root.standardized.path(percentEncoded: false)
        if !rootPath.hasSuffix("/") { rootPath += "/" }
        return path.hasPrefix(rootPath)
    }
}
