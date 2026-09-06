import Foundation

/// Subagent は単一の `.md`。frontmatter に `name` / `description` / `tools` / `model` を持つ。
public struct Subagent: Equatable, Sendable {
    public let name: String
    public let description: String?
    public let url: URL
    public let root: String
    public let status: Skill.Status

    public var isLoadable: Bool {
        switch status {
        case .ok, .truncatedFrontmatter, .missingFrontmatter: true
        case .brokenLink, .noSkillFile: false
        }
    }
}

public enum SubagentScanner {

    public static func scan(env: Environment) -> [Subagent] {
        Source.subagents.flatMap { source -> [Subagent] in
            guard let dir = source.url(in: env), let root = source.relativePath else { return [] }
            return scan(root: dir, rootLabel: root)
        }
    }

    public static func scan(root: URL, rootLabel: String) -> [Subagent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        else { return [] }
        return entries
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
            .sorted()
            .compactMap { read(file: $0, in: root, rootLabel: rootLabel) }
    }

    static func read(file: String, in root: URL, rootLabel: String) -> Subagent? {
        let fm = FileManager.default
        let url = root.appending(path: file)
        let name = String(file.dropLast(3))          // .md を落とす

        // リンク切れ symlink。ディレクトリではなくファイルなので Skill 側とは別処理。
        if WriteGuard.isSymlink(url), !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            return Subagent(name: name, description: nil, url: url,
                            root: rootLabel, status: .brokenLink)
        }
        guard fm.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }

        switch FrontmatterParser.read(url) {
        case .parsed(let matter):
            // 識別子はファイル名。frontmatter の name とズレると
            // 有効化 / 無効化がファイルを見つけられなくなる。
            return Subagent(name: name, description: matter.description,
                            url: url, root: rootLabel, status: .ok)
        case .truncated:
            return Subagent(name: name, description: nil, url: url,
                            root: rootLabel, status: .truncatedFrontmatter)
        case .missing:
            return Subagent(name: name, description: nil, url: url,
                            root: rootLabel, status: .missingFrontmatter)
        }
    }
}

/// Skills と同じ考え方だが、**共有ルートが無いので symlink は 2 本**（Claude と Cursor）。
public enum SubagentManager {
    public static func enable(_ name: String, env: Environment, registry: inout Registry) throws {
        try ManagedLifecycle.enable(name, kind: .subagent, env: env, registry: &registry)
    }

    public static func disable(_ name: String, env: Environment, registry: inout Registry) throws {
        try ManagedLifecycle.disable(name, kind: .subagent, env: env, registry: &registry)
    }

    /// symlink（Claude / Cursor の 2 本）を外し、実体をゴミ箱へ移して registry から外す。
    /// Skill と同じ方針 — **完全削除しない**（DESIGN.md 8 章）。
    @discardableResult
    public static func remove(_ name: String, env: Environment, registry: inout Registry) throws -> URL? {
        try ManagedLifecycle.remove(name, kind: .subagent, env: env, registry: &registry)
    }
}
