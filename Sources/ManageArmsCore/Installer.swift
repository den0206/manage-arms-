import Foundation

/// 確認画面で選ばれた候補を実際に入れる。DESIGN.md 6 章。
public enum Installer {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case alreadyInstalled(String)
        case unsupportedKind(Kind)
        public var description: String {
            switch self {
            case .alreadyInstalled(let n):
                String(localized: "\(n) は既に入っています")
            case .unsupportedKind(let k):
                String(localized: "\(k.rawValue) の追加はまだ対応していません")
            }
        }
    }

    /// 実体を `~/.agents/skills/` に置き、registry に記録し、Claude 用 symlink を張る。
    /// Cursor と Codex は共有ルートを直読みするので追加作業は無い（3.2）。
    public static func install(
        _ candidate: Candidate,
        from staging: Staging,
        env: Environment,
        registry: inout Registry
    ) throws {
        try Registry.assertReadable(env: env)
        guard candidate.kind == .skill || candidate.kind == .subagent else {
            throw Failure.unsupportedKind(candidate.kind)
        }
        // **作成もガードを通す。** `WriteGuard.assertMutable` は削除・移動しか守らないため、
        // ここを素通しにすると取得先の名乗り 1 つで管理ルートの外へ書ける（9 章）。
        // `Fetcher` でも弾いているが、`deniedNames` と同じ理由で二重にする。
        try WriteGuard.assertValidName(candidate.name)
        try Fetcher.validate(candidate, in: staging)
        let isSubagent = candidate.kind == .subagent

        let fm = FileManager.default
        let originalRegistry = registry
        let destination = isSubagent
            ? env.agentStore.appending(path: "\(candidate.name).md")
            : env.skillStore.appending(path: candidate.name)
        guard !fm.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw Failure.alreadyInstalled(candidate.name)
        }

        let managedRoot = isSubagent ? env.agentStore : env.skillStore
        try WriteGuard.assertSafeCreation(destination, inside: managedRoot, anchor: env.home)
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.copyItem(at: candidate.localURL, to: destination)
        } catch {
            let originalError = error
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                do {
                    try fm.removeItem(at: destination)
                } catch let rollbackError {
                    throw SkillManager.Failure.rollbackFailed("\(originalError); \(rollbackError)")
                }
            }
            throw originalError
        }

        registry.upsert(Registry.Entry(
            name: candidate.name,
            kind: candidate.kind,
            repo: staging.source.repo,
            branch: staging.source.branch,
            subdir: staging.source.subdir,
            sha: staging.resolvedSHA
        ))
        do {
            try ManagedLifecycle.link(candidate.name, kind: candidate.kind,
                                      env: env, registry: registry)
            let entry = registry.entry(named: candidate.name, kind: candidate.kind)!
            registry = try Registry.update(env: env) { latest in
                guard latest.entry(named: candidate.name, kind: candidate.kind) == nil else {
                    throw Failure.alreadyInstalled(candidate.name)
                }
                latest.upsert(entry)
            }
        } catch {
            let originalError = error
            registry = originalRegistry
            let links = isSubagent
                ? [env.home.appending(path: ".claude/agents/\(candidate.name).md"),
                   env.home.appending(path: ".cursor/agents/\(candidate.name).md")]
                : [env.claudeSkills.appending(path: candidate.name)]
            do {
                for link in links where WriteGuard.isSymlink(link) {
                    if WriteGuard.symlinkTarget(link)?.standardizedFileURL == destination.standardizedFileURL {
                        try fm.removeItem(at: link)
                    }
                }
                try fm.removeItem(at: destination)
            } catch let rollbackError {
                throw SkillManager.Failure.rollbackFailed("\(originalError); \(rollbackError)")
            }
            throw originalError
        }
    }
}
