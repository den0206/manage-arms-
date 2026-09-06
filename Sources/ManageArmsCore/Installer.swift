import Foundation

/// 確認画面で選ばれた候補を実際に入れる。DESIGN.md 6 章。
public enum Installer {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case alreadyInstalled(String)
        case unsupportedKind(Kind)
        public var description: String {
            switch self {
            case .alreadyInstalled(let n): "\(n) は既に入っています"
            case .unsupportedKind(let k):  "\(k.rawValue) の追加はまだ対応していません"
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
        let isSubagent = candidate.kind == .subagent

        let fm = FileManager.default
        let destination = isSubagent
            ? env.agentStore.appending(path: "\(candidate.name).md")
            : env.skillStore.appending(path: candidate.name)
        guard !fm.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw Failure.alreadyInstalled(candidate.name)
        }

        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.copyItem(at: candidate.localURL, to: destination)

        registry.upsert(Registry.Entry(
            name: candidate.name,
            kind: candidate.kind,
            repo: staging.source.repo,
            branch: staging.source.branch,
            subdir: staging.source.subdir
        ))
        do {
            if isSubagent {
                try SubagentManager.enable(candidate.name, env: env, registry: &registry)
            } else {
                try SkillManager.linkForClaude(candidate.name, env: env, registry: registry)
            }
            try registry.save(env: env)
        } catch {
            // 途中で失敗したら置いた実体を戻す。半端な状態を残さない。
            try? fm.removeItem(at: destination)
            throw error
        }
    }
}
