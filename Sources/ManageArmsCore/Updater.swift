import Foundation

/// DESIGN.md 7.4 — Skills の中身は**プロンプト**。黙って差し替えると
/// エージェントの挙動が変わり、原因追跡が不可能になる。更新は diff を見せてから。
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case added, removed }
    public let kind: Kind
    public let text: String
}

public struct UpdatePreview: Sendable {
    public let name: String
    public let oldSha: String?
    public let newSha: String?
    public let staging: Staging
    public let candidate: Candidate
    public let diff: [DiffLine]

    public var hasChanges: Bool { !diff.isEmpty }
    public func discard() { staging.discard() }
}

public enum Updater {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notManaged(String)
        case pinned(String)
        case candidateMissing(String)
        public var description: String {
            switch self {
            case .notManaged(let n):       "\(n) は取得元が分からないため更新できません"
            case .pinned(let n):           "\(n) は固定中です"
            case .candidateMissing(let n): "取得したアーカイブに \(n) が見つかりません"
            }
        }
    }

    /// 取得して差分を作る。**まだ適用しない。**
    public static func preview(
        _ entry: Registry.Entry, env: Environment, registry: Registry
    ) async throws -> UpdatePreview {
        guard let repo = entry.repo else { throw Failure.notManaged(entry.name) }
        guard !entry.pinned else { throw Failure.pinned(entry.name) }
        try WriteGuard.assertValidName(entry.name)

        let source = GitHubSource(repo: repo, branch: entry.branch, subdir: entry.subdir)
        let staging = try await Fetcher.stage(source)
        guard let candidate = staging.candidates.first(where: { $0.name == entry.name && $0.kind.rawValue == entry.kind }) else {
            staging.discard()
            throw Failure.candidateMissing(entry.name)
        }

        let current = entry.kind == Kind.subagent.rawValue
            ? (entry.disabled ? env.disabledAgentStore : env.agentStore).appending(path: "\(entry.name).md")
            : (entry.disabled ? env.disabledStore : env.skillStore).appending(path: entry.name).appending(path: "SKILL.md")
        return UpdatePreview(
            name: entry.name,
            oldSha: entry.sha,
            newSha: registry.repos[UpdateChecker.repoKey(entry) ?? ""]?.latestSha,
            staging: staging,
            candidate: candidate,
            diff: diff(old: text(of: current),
                       new: text(of: candidate.kind == .subagent ? candidate.localURL : candidate.localURL.appending(path: "SKILL.md")))
        )
    }

    /// 一時ディレクトリに展開済みのものと差し替える。失敗したら元に戻す（7.4）。
    public static func apply(
        _ preview: UpdatePreview, env: Environment, registry: inout Registry
    ) throws {
        let fm = FileManager.default

        guard var entry = registry.entry(named: preview.name, kind: preview.candidate.kind) else {
            throw Failure.notManaged(preview.name)
        }
        try WriteGuard.assertValidName(entry.name)
        let destination = entry.kind == Kind.subagent.rawValue
            ? (entry.disabled ? env.disabledAgentStore : env.agentStore).appending(path: "\(entry.name).md")
            : (entry.disabled ? env.disabledStore : env.skillStore).appending(path: entry.name)
        guard !entry.pinned else { throw Failure.pinned(entry.name) }
        try WriteGuard.assertMutable(destination, env: env, registry: registry)

        // 旧実体を一時退避してから入れ替える。消してから入れると失敗時に戻せない。
        let backup = preview.staging.root.appending(path: "backup-\(preview.name)")
        let hadExisting = fm.fileExists(atPath: destination.path(percentEncoded: false))
        if hadExisting { try fm.moveItem(at: destination, to: backup) }

        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: preview.candidate.localURL, to: destination)
        } catch {
            if hadExisting {
                try? fm.removeItem(at: destination)
                try? fm.moveItem(at: backup, to: destination)
            }
            throw error
        }

        entry.sha = preview.newSha ?? entry.sha
        registry.upsert(entry)
        try registry.save(env: env)
        preview.discard()
    }

    // MARK: - 差分

    static func text(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// stdlib の `CollectionDifference` で足りる。差分アルゴリズムは自前で書かない。
    static func diff(old: [String], new: [String]) -> [DiffLine] {
        new.difference(from: old)
            .sorted { a, b in a.offsetValue < b.offsetValue }
            .map { change in
                switch change {
                case .insert(_, let text, _): DiffLine(kind: .added, text: text)
                case .remove(_, let text, _): DiffLine(kind: .removed, text: text)
                }
            }
    }
}

private extension CollectionDifference<String>.Change {
    var offsetValue: Int {
        switch self {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }
}
