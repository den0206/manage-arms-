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
        let fm = FileManager.default
        let store = env.skillStore.appending(path: name)
        let parked = env.disabledStore.appending(path: name)

        if !fm.fileExists(atPath: store.path(percentEncoded: false)) {
            guard fm.fileExists(atPath: parked.path(percentEncoded: false)) else { throw Failure.notFound(name) }
            try WriteGuard.assertMutable(parked, env: env, registry: registry)
            try fm.createDirectory(at: env.skillStore, withIntermediateDirectories: true)
            try fm.moveItem(at: parked, to: store)
        }

        try linkForClaude(name, env: env, registry: registry)

        var entry = registry.entry(named: name) ?? Registry.Entry(name: name, kind: .skill)
        entry.disabled = false
        registry.upsert(entry)
        try registry.save(env: env)
    }

    /// Claude symlink を外し、実体を退避ディレクトリへ移す。**実体は消さない。**
    public static func disable(_ name: String, env: Environment, registry: inout Registry) throws {
        let fm = FileManager.default
        let store = env.skillStore.appending(path: name)
        let link = env.claudeSkills.appending(path: name)

        // symlink だけを消す。リンク先の実体は巻き込まない。
        // trashItem ではなく removeItem — ゴミ箱にリンク切れを残しても意味が無い。
        if WriteGuard.isSymlink(link) {
            try WriteGuard.assertMutable(link, env: env, registry: registry)
            try fm.removeItem(at: link)
        }

        guard fm.fileExists(atPath: store.path(percentEncoded: false)) else { throw Failure.notFound(name) }
        try WriteGuard.assertMutable(store, env: env, registry: registry)

        let parked = env.disabledStore.appending(path: name)
        guard !fm.fileExists(atPath: parked.path(percentEncoded: false)) else {
            throw Failure.alreadyExists(parked.path(percentEncoded: false))
        }
        try fm.createDirectory(at: env.disabledStore, withIntermediateDirectories: true)
        try fm.moveItem(at: store, to: parked)

        var entry = registry.entry(named: name) ?? Registry.Entry(name: name, kind: .skill)
        entry.disabled = true
        registry.upsert(entry)
        try registry.save(env: env)
    }

    /// Claude だけは共有ルートを読まないので symlink が要る（3.2）。
    /// Cursor / Codex は `~/.agents/skills` を直読みするため何もしない。
    static func linkForClaude(_ name: String, env: Environment, registry: Registry) throws {
        let fm = FileManager.default
        let link = env.claudeSkills.appending(path: name)
        let target = env.skillStore.appending(path: name)

        if WriteGuard.isSymlink(link) {
            // 自分が張ったものだけ張り替える。他ツールの symlink は触らない。
            try WriteGuard.assertMutable(link, env: env, registry: registry)
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path(percentEncoded: false)) {
            throw Failure.alreadyExists(link.path(percentEncoded: false))   // 実体がある場合は上書きしない
        }

        try fm.createDirectory(at: env.claudeSkills, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
    }
}

extension SkillManager {
    /// ユーザーが自分で入れたスキルを、このアプリの管理下に取り込む（DESIGN.md 8 章）。
    ///
    /// **ファイルは 1 バイトも動かさない。** 実体は既に `~/.agents/skills/` にあるので、
    /// registry に 1 行足して Claude 用の symlink を張るだけ。
    /// 取り込むと有効/無効の切り替えと削除ができるようになる（`WriteGuard` が通る）。
    /// 取得元が分からないので**更新はできない**（`repo` が nil = `.unknown`）。
    public static func adopt(_ name: String, env: Environment, registry: inout Registry) throws {
        guard registry.entry(named: name) == nil else { throw Failure.alreadyExists(name) }
        guard FileManager.default.fileExists(
            atPath: env.skillStore.appending(path: name).path(percentEncoded: false))
        else { throw Failure.notFound(name) }

        registry.upsert(Registry.Entry(name: name, kind: .skill))
        do {
            // 他ツールが張った symlink が居座っていれば WriteGuard が弾く。
            // その場合は取り込まない（横取りしない）。
            try linkForClaude(name, env: env, registry: registry)
        } catch {
            registry.resources.removeAll { $0.name == name }
            throw error
        }
        try registry.save(env: env)
    }

    /// 実体をゴミ箱へ移し、registry から外す。**完全削除しない** —
    /// 初心者が誤って消しても Finder から戻せる状態を残す（DESIGN.md 8 章）。
    /// 戻り値はゴミ箱に入った実体の位置（テストの後片付けに使う）。
    @discardableResult
    public static func remove(_ name: String, env: Environment, registry: inout Registry) throws -> URL? {
        let fm = FileManager.default
        let link = env.claudeSkills.appending(path: name)
        if WriteGuard.isSymlink(link) {
            try WriteGuard.assertMutable(link, env: env, registry: registry)
            try fm.removeItem(at: link)
        }

        // 有効なら実体置き場、無効なら退避先にある。どちらか片方だけが存在する。
        var trashed: URL?
        for url in [env.skillStore.appending(path: name), env.disabledStore.appending(path: name)]
        where fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try WriteGuard.assertMutable(url, env: env, registry: registry)
            var result: NSURL?
            try fm.trashItem(at: url, resultingItemURL: &result)
            trashed = result as URL?
        }
        guard trashed != nil else { throw Failure.notFound(name) }

        registry.resources.removeAll { $0.name == name }
        try registry.save(env: env)
        return trashed
    }
}
