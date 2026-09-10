import Foundation

public struct Skill: Equatable, Sendable {
    public let name: String            // ディレクトリ名。frontmatter の name とズレることがある
    public let description: String?
    public let url: URL
    public let root: String            // 見つかったスキルルート（ホーム相対）
    public let status: Status

    /// エージェントが実際に読み込めるか。リンク切れと SKILL.md 欠落は読み込まれない。
    /// マトリクスで「有効」と表示してはいけない。
    public var isLoadable: Bool {
        switch status {
        case .ok, .truncatedFrontmatter, .missingFrontmatter: true
        case .brokenLink, .noSkillFile: false
        }
    }

    public enum Status: Equatable, Sendable {
        case ok
        /// symlink のリンク先が存在しない。`~/.claude/skills/codiff` が実際にこの状態。
        case brokenLink
        /// ディレクトリはあるが SKILL.md が無い。
        case noSkillFile
        /// frontmatter が先頭 4 KB に収まっていない（10.1）。
        case truncatedFrontmatter
        /// `---` で始まっていない。
        case missingFrontmatter
    }
}

public enum SkillScanner {

    /// `Source.skills` の全ルートを走査する。列挙外のパスは触らない（3.4）。
    public static func scan(env: Environment) -> [Skill] {
        Source.skills.flatMap { source -> [Skill] in
            guard let dir = source.url(in: env), let root = source.relativePath else { return [] }
            return scan(root: dir, rootLabel: root)
        }
    }

    public static func scan(root: URL, rootLabel: String) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false)) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") }          // .system / .sync-manifest.json などは対象外
            .sorted()
            .compactMap { read(name: $0, in: root, rootLabel: rootLabel) }
    }

    static func read(name: String, in root: URL, rootLabel: String) -> Skill? {
        let fm = FileManager.default
        let dir = root.appending(path: name)

        // リンク切れ symlink。`fileExists` は辿った先を見るので false になる。
        if let attrs = try? fm.attributesOfItem(atPath: dir.path(percentEncoded: false)),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink,
           !fm.fileExists(atPath: dir.path(percentEncoded: false)) {
            return Skill(name: name, description: nil, url: dir,
                         root: rootLabel, status: .brokenLink)
        }

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path(percentEncoded: false), isDirectory: &isDir), isDir.boolValue else {
            return nil                              // ただのファイルはスキルではない
        }

        let skillFile = dir.appending(path: "SKILL.md")
        guard fm.fileExists(atPath: skillFile.path(percentEncoded: false)) else {
            return Skill(name: name, description: nil, url: dir,
                         root: rootLabel, status: .noSkillFile)
        }

        switch FrontmatterParser.read(skillFile) {
        case .parsed(let fm):
            return Skill(name: name, description: fm.description, url: dir,
                         root: rootLabel, status: .ok)
        case .truncated:
            return Skill(name: name, description: nil, url: dir,
                         root: rootLabel, status: .truncatedFrontmatter)
        case .missing:
            return Skill(name: name, description: nil, url: dir,
                         root: rootLabel, status: .missingFrontmatter)
        }
    }

    /// 同名スキルをまとめる。実体 `~/.agents/skills/x` と Claude symlink
    /// `~/.claude/skills/x` は同じ 1 行として見せる（5.2 のマトリクス行）。
    public static func grouped(_ skills: [Skill]) -> [String: [Skill]] {
        Dictionary(grouping: skills, by: \.name)
    }
}
