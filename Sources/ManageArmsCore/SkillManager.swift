import Foundation

/// スキルの有効化/無効化。DESIGN.md 3.2。
///
/// 有効/無効は全エージェント一括。Cursor と Codex は `~/.agents/skills/` を直読みするため、
/// エージェント別の on/off は原理的に不可能。
public enum SkillManager {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case alreadyExists(String)
        public var description: String {
            switch self {
            case .notFound(let n):      "\(n) が見つかりません"
            case .alreadyExists(let p): "\(p) に既に別のものがあります。上書きしません"
            }
        }
    }

    /// 実体を置き場に戻し、Claude 用の symlink を張り直す。
    public static func enable(_ name: String, env: Environment, registry: inout Registry) throws {
        try ManagedLifecycle.enable(name, kind: .skill, env: env, registry: &registry)
    }

    /// Claude symlink を外し、実体を退避ディレクトリへ移す。**実体は消さない。**
    public static func disable(_ name: String, env: Environment, registry: inout Registry) throws {
        try ManagedLifecycle.disable(name, kind: .skill, env: env, registry: &registry)
    }

    /// Claude だけは共有ルートを読まないので symlink が要る（3.2）。
    /// Cursor / Codex は `~/.agents/skills` を直読みするため何もしない。
    static func linkForClaude(_ name: String, env: Environment, registry: Registry) throws {
        try ManagedLifecycle.link(name, kind: .skill, env: env, registry: registry)
    }
}

extension SkillManager {
    @discardableResult
    public static func removeExisting(_ url: URL, kind: Kind, project: String? = nil,
                                      env: Environment) throws -> URL? {
        try WriteGuard.assertUserArtifact(url, kind: kind, project: project, env: env)
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }

    /// 実体をゴミ箱へ移し、registry から外す。**完全削除しない** —
    /// 初心者が誤って消しても Finder から戻せる状態を残す（DESIGN.md 8 章）。
    /// 戻り値はゴミ箱に入った実体の位置（テストの後片付けに使う）。
    @discardableResult
    public static func remove(_ name: String, env: Environment, registry: inout Registry) throws -> URL? {
        try ManagedLifecycle.remove(name, kind: .skill, env: env, registry: &registry)
    }
}

/// Skill と Subagent に共通する guarded lifecycle。配置差だけを内側に持つ。
enum ManagedLifecycle {
    struct Layout {
        let store: URL
        let parked: URL
        let links: [URL]
    }

    static func layout(_ name: String, kind: Kind, env: Environment) -> Layout {
        if kind == .subagent {
            return Layout(
                store: env.agentStore.appending(path: "\(name).md"),
                parked: env.disabledAgentStore.appending(path: "\(name).md"),
                links: [env.home.appending(path: ".claude/agents/\(name).md"),
                        env.home.appending(path: ".cursor/agents/\(name).md")]
            )
        }
        return Layout(
            store: env.skillStore.appending(path: name),
            parked: env.disabledStore.appending(path: name),
            links: [env.claudeSkills.appending(path: name)]
        )
    }

    static func link(_ name: String, kind: Kind, env: Environment,
                     registry: Registry) throws {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        let layout = layout(name, kind: kind, env: env)
        for link in layout.links {
            if WriteGuard.isSymlink(link) {
                try WriteGuard.assertMutable(link, env: env, registry: registry)
                try fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path(percentEncoded: false)) {
                throw SkillManager.Failure.alreadyExists(link.path(percentEncoded: false))
            }
            try fm.createDirectory(at: link.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: layout.store)
        }
    }

    static func enable(_ name: String, kind: Kind, env: Environment,
                       registry: inout Registry) throws {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        let layout = layout(name, kind: kind, env: env)
        if !fm.fileExists(atPath: layout.store.path(percentEncoded: false)) {
            guard fm.fileExists(atPath: layout.parked.path(percentEncoded: false)) else {
                throw SkillManager.Failure.notFound(name)
            }
            try WriteGuard.assertMutable(layout.parked, env: env, registry: registry)
            try fm.createDirectory(at: layout.store.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: layout.parked, to: layout.store)
        }
        try link(name, kind: kind, env: env, registry: registry)
        var entry = registry.entry(named: name, kind: kind) ?? Registry.Entry(name: name, kind: kind)
        entry.disabled = false
        registry.upsert(entry)
        try registry.save(env: env)
    }

    /// **前提の検査を全部先に済ませてから壊す。**
    /// 以前は symlink を先に外していたため、その後の `guard` で throw すると
    /// 「Claude からは消えたのに registry は有効のまま」という、
    /// 画面から追えない食い違いが残った（`Updater.apply` と同じ規律に揃える）。
    ///
    /// 破壊の順序は **実体の退避 → symlink の解除**。逆にすると、途中で失敗したときに
    /// 「リンクが無いだけ」の見えない状態になる。この順なら残るのはリンク切れで、
    /// 一覧が「読み込めません」として拾える（`ResourceRow.isUnusable`）。
    static func disable(_ name: String, kind: Kind, env: Environment,
                        registry: inout Registry) throws {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        let layout = layout(name, kind: kind, env: env)

        guard fm.fileExists(atPath: layout.store.path(percentEncoded: false)) else {
            throw SkillManager.Failure.notFound(name)
        }
        try WriteGuard.assertMutable(layout.store, env: env, registry: registry)
        guard !fm.fileExists(atPath: layout.parked.path(percentEncoded: false)) else {
            throw SkillManager.Failure.alreadyExists(layout.parked.path(percentEncoded: false))
        }
        let links = layout.links.filter(WriteGuard.isSymlink)
        for link in links {
            try WriteGuard.assertMutable(link, env: env, registry: registry)
        }

        try fm.createDirectory(at: layout.parked.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.moveItem(at: layout.store, to: layout.parked)
        for link in links { try fm.removeItem(at: link) }
        var entry = registry.entry(named: name, kind: kind) ?? Registry.Entry(name: name, kind: kind)
        entry.disabled = true
        registry.upsert(entry)
        try registry.save(env: env)
    }

    @discardableResult
    static func remove(_ name: String, kind: Kind, env: Environment,
                       registry: inout Registry) throws -> URL? {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        let layout = layout(name, kind: kind, env: env)

        // `disable` と同じ理由で、検査を全部先に済ませてから壊す。
        let links = layout.links.filter(WriteGuard.isSymlink)
        let bodies = [layout.store, layout.parked]
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !bodies.isEmpty else { throw SkillManager.Failure.notFound(name) }
        for url in links + bodies {
            try WriteGuard.assertMutable(url, env: env, registry: registry)
        }

        for link in links { try fm.removeItem(at: link) }
        var trashed: URL?
        for url in bodies {
            var result: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &result)
            trashed = result as URL?
        }
        registry.resources.removeAll { $0.name == name && $0.kind == kind.rawValue }
        try registry.save(env: env)
        return trashed
    }
}
