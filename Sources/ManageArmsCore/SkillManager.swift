import Foundation

/// スキルの有効化/無効化。DESIGN.md 3.2。
///
/// 有効/無効は全エージェント一括。Cursor と Codex は `~/.agents/skills/` を直読みするため、
/// エージェント別の on/off は原理的に不可能。
public enum SkillManager {

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notFound(String)
        case alreadyExists(String)
        case rollbackFailed(String)
        public var description: String {
            switch self {
            case .notFound(let n):
                String(localized: "\(n) が見つかりません")
            case .alreadyExists(let p):
                String(localized: "\(p) に既に別のものがあります。上書きしません")
            case .rollbackFailed(let message):
                String(localized: "操作に失敗し、元の状態も完全には復元できませんでした: \(message)")
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
        try Registry.assertReadable(env: env)
        let layout = layout(name, kind: kind, env: env)
        var previous: [URL: URL] = [:]
        for link in layout.links where WriteGuard.isSymlink(link) {
            try WriteGuard.assertMutable(link, env: env, registry: registry)
            if let target = WriteGuard.symlinkTarget(link) { previous[link] = target }
        }
        for link in layout.links where !WriteGuard.isSymlink(link)
            && fm.fileExists(atPath: link.path(percentEncoded: false)) {
            throw SkillManager.Failure.alreadyExists(link.path(percentEncoded: false))
        }
        var changed: [URL] = []
        do {
            for link in layout.links {
                try WriteGuard.assertSafeCreation(link, inside: link.deletingLastPathComponent(),
                                                  anchor: env.home)
                if WriteGuard.isSymlink(link) {
                    try fm.removeItem(at: link)
                }
                try fm.createDirectory(at: link.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: link, withDestinationURL: layout.store)
                changed.append(link)
            }
        } catch {
            let originalError = error
            do {
                for link in changed where WriteGuard.isSymlink(link) { try fm.removeItem(at: link) }
                for (link, target) in previous {
                    if !WriteGuard.isSymlink(link), !fm.fileExists(atPath: link.path) {
                        try fm.createSymbolicLink(at: link, withDestinationURL: target)
                    }
                }
            } catch let rollbackError {
                throw SkillManager.Failure.rollbackFailed("\(originalError); \(rollbackError)")
            }
            throw originalError
        }
    }

    static func enable(_ name: String, kind: Kind, env: Environment,
                       registry: inout Registry) throws {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        try Registry.assertReadable(env: env)
        let layout = layout(name, kind: kind, env: env)
        let originalRegistry = registry
        let wasParked = !fm.fileExists(atPath: layout.store.path)
        let previousLinks = Dictionary(uniqueKeysWithValues: layout.links.compactMap { link in
            WriteGuard.symlinkTarget(link).map { (link, $0) }
        })
        if !fm.fileExists(atPath: layout.store.path(percentEncoded: false)) {
            guard fm.fileExists(atPath: layout.parked.path(percentEncoded: false)) else {
                throw SkillManager.Failure.notFound(name)
            }
            try WriteGuard.assertMutable(layout.parked, env: env, registry: registry)
            try WriteGuard.assertSafeCreation(layout.store,
                                              inside: layout.store.deletingLastPathComponent(),
                                              anchor: env.home)
            try fm.createDirectory(at: layout.store.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: layout.parked, to: layout.store)
        }
        do {
            try link(name, kind: kind, env: env, registry: registry)
            var entry = registry.entry(named: name, kind: kind) ?? Registry.Entry(name: name, kind: kind)
            entry.disabled = false
            let fallback = entry
            registry = try Registry.update(env: env) { latest in
                var current = latest.entry(named: name, kind: kind) ?? fallback
                current.disabled = false
                latest.upsert(current)
            }
        } catch {
            let originalError = error
            registry = originalRegistry
            do {
                for link in layout.links where WriteGuard.isSymlink(link) {
                    if WriteGuard.symlinkTarget(link)?.standardizedFileURL == layout.store.standardizedFileURL {
                        try fm.removeItem(at: link)
                    }
                }
                for (link, target) in previousLinks
                    where !WriteGuard.isSymlink(link) && !fm.fileExists(atPath: link.path) {
                    try fm.createSymbolicLink(at: link, withDestinationURL: target)
                }
                if wasParked, fm.fileExists(atPath: layout.store.path),
                   !fm.fileExists(atPath: layout.parked.path) {
                    try fm.moveItem(at: layout.store, to: layout.parked)
                }
            } catch let rollbackError {
                throw SkillManager.Failure.rollbackFailed("\(originalError); \(rollbackError)")
            }
            throw originalError
        }
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
        try Registry.assertReadable(env: env)
        let layout = layout(name, kind: kind, env: env)
        let originalRegistry = registry

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

        do {
            try WriteGuard.assertSafeCreation(layout.parked,
                                              inside: layout.parked.deletingLastPathComponent(),
                                              anchor: env.home)
            try fm.createDirectory(at: layout.parked.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: layout.store, to: layout.parked)
            for link in links { try fm.removeItem(at: link) }
            var entry = registry.entry(named: name, kind: kind) ?? Registry.Entry(name: name, kind: kind)
            entry.disabled = true
            let fallback = entry
            registry = try Registry.update(env: env) { latest in
                var current = latest.entry(named: name, kind: kind) ?? fallback
                current.disabled = true
                latest.upsert(current)
            }
        } catch {
            let originalError = error
            registry = originalRegistry
            do {
                if fm.fileExists(atPath: layout.parked.path),
                   !fm.fileExists(atPath: layout.store.path) {
                    try fm.moveItem(at: layout.parked, to: layout.store)
                }
                for link in links
                    where !WriteGuard.isSymlink(link) && !fm.fileExists(atPath: link.path) {
                    try fm.createDirectory(at: link.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: link, withDestinationURL: layout.store)
                }
            } catch let rollbackError {
                throw SkillManager.Failure.rollbackFailed("\(originalError); \(rollbackError)")
            }
            throw originalError
        }
    }

    @discardableResult
    static func remove(_ name: String, kind: Kind, env: Environment,
                       registry: inout Registry) throws -> URL? {
        let fm = FileManager.default
        try WriteGuard.assertValidName(name)
        try Registry.assertReadable(env: env)
        let layout = layout(name, kind: kind, env: env)
        let originalRegistry = registry

        // `disable` と同じ理由で、検査を全部先に済ませてから壊す。
        let links = layout.links.filter(WriteGuard.isSymlink)
        let bodies = [layout.store, layout.parked]
            .filter { fm.fileExists(atPath: $0.path(percentEncoded: false)) }
        guard !bodies.isEmpty else { throw SkillManager.Failure.notFound(name) }
        for url in links + bodies {
            try WriteGuard.assertMutable(url, env: env, registry: registry)
        }

        var moved: [(original: URL, trash: URL)] = []
        do {
            for link in links { try fm.removeItem(at: link) }
            for url in bodies {
                var result: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &result)
                if let trash = result as URL? { moved.append((url, trash)) }
            }
            registry = try Registry.update(env: env) { latest in
                latest.resources.removeAll { $0.name == name && $0.kind == kind.rawValue }
            }
        } catch {
            registry = originalRegistry
            do {
                for item in moved.reversed() where fm.fileExists(atPath: item.trash.path) {
                    try fm.moveItem(at: item.trash, to: item.original)
                }
                for link in links
                    where !WriteGuard.isSymlink(link) && !fm.fileExists(atPath: link.path) {
                    try fm.createDirectory(at: link.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                    try fm.createSymbolicLink(at: link, withDestinationURL: layout.store)
                }
            } catch let rollbackError {
                throw SkillManager.Failure.rollbackFailed("\(error); \(rollbackError)")
            }
            throw error
        }
        return moved.last?.trash
    }
}
