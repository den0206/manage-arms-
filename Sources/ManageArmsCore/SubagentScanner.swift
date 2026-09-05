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

    static func storeURL(_ name: String, env: Environment) -> URL {
        env.appSupport.appending(path: "agents/\(name).md")
    }
    static func parkedURL(_ name: String, env: Environment) -> URL {
        env.appSupport.appending(path: "disabled-agents/\(name).md")
    }
    static func linkURLs(_ name: String, env: Environment) -> [URL] {
        [env.home.appending(path: ".claude/agents/\(name).md"),
         env.home.appending(path: ".cursor/agents/\(name).md")]
    }

    public static func enable(_ name: String, env: Environment, registry: inout Registry) throws {
        let fm = FileManager.default
        let store = storeURL(name, env: env)
        let parked = parkedURL(name, env: env)

        if !fm.fileExists(atPath: store.path(percentEncoded: false)) {
            guard fm.fileExists(atPath: parked.path(percentEncoded: false)) else {
                throw SkillManager.Failure.notFound(name)
            }
            try WriteGuard.assertMutable(parked, env: env, registry: registry)
            try fm.createDirectory(at: store.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: parked, to: store)
        }

        for link in linkURLs(name, env: env) {
            if WriteGuard.isSymlink(link) {
                try WriteGuard.assertMutable(link, env: env, registry: registry)
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path(percentEncoded: false)) {
                throw SkillManager.Failure.alreadyExists(link.path(percentEncoded: false))
            }
            try fm.createDirectory(at: link.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: store)
        }

        var entry = registry.entry(named: name) ?? Registry.Entry(name: name, kind: .subagent)
        entry.disabled = false
        registry.upsert(entry)
        try registry.save(env: env)
    }

    public static func disable(_ name: String, env: Environment, registry: inout Registry) throws {
        let fm = FileManager.default
        let store = storeURL(name, env: env)

        for link in linkURLs(name, env: env) where WriteGuard.isSymlink(link) {
            try WriteGuard.assertMutable(link, env: env, registry: registry)
            try fm.removeItem(at: link)
        }

        guard fm.fileExists(atPath: store.path(percentEncoded: false)) else {
            throw SkillManager.Failure.notFound(name)
        }
        try WriteGuard.assertMutable(store, env: env, registry: registry)

        let parked = parkedURL(name, env: env)
        guard !fm.fileExists(atPath: parked.path(percentEncoded: false)) else {
            throw SkillManager.Failure.alreadyExists(parked.path(percentEncoded: false))
        }
        try fm.createDirectory(at: parked.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: store, to: parked)

        var entry = registry.entry(named: name) ?? Registry.Entry(name: name, kind: .subagent)
        entry.disabled = true
        registry.upsert(entry)
        try registry.save(env: env)
    }
}
