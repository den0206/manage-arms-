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

        public var description: String {
            switch self {
            case .deniedPath(let p):
                "\(p) は保護対象です"
            case .symlinkOutsideStore(let p):
                "\(p) は manage-arms が張った symlink ではありません"
            case .outsideManagedRoots(let p):
                "\(p) は manage-arms の管理外です"
            case .notInRegistry(let n):
                "\(n) は他のツールが管理しています。manage-arms からは変更できません"
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

    /// 削除・移動してよいか。通らなければ throw する。
    ///
    /// 許すのは 2 つだけ:
    ///   1. 自分が張った symlink（リンク先が実体置き場の配下）
    ///   2. registry.json に載っている実体（実体置き場 or 退避ディレクトリの配下）
    public static func assertMutable(
        _ url: URL, env: Environment, registry: Registry
    ) throws {
        let path = url.standardized.path(percentEncoded: false)

        if isDenied(url) { throw Denial.deniedPath(path) }

        if isSymlink(url) {
            guard let target = symlinkTarget(url),
                  env.managedRoots.contains(where: { isInside(target, $0) })
            else { throw Denial.symlinkOutsideStore(path) }
            return
        }

        guard env.managedRoots.contains(where: { isInside(url, $0) }) else {
            throw Denial.outsideManagedRoots(path)
        }
        // Subagent は `<name>.md` なので拡張子を落とす。
        let name = url.pathExtension == "md"
            ? String(url.lastPathComponent.dropLast(3))
            : url.lastPathComponent
        guard registry.entry(named: name) != nil else {
            throw Denial.notInRegistry(name)
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
