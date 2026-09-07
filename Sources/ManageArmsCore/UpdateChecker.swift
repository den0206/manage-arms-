import Foundation

public enum UpdateStatus: Equatable, Sendable {
    case unmanaged          // 取得元が分からない（手で置いたもの等）
    case unknown            // まだチェックしていない
    case upToDate
    case available(sha: String)
    /// 上流が方針転換した時に固定する（7.4）。遅れていても更新しない。
    case pinned(behind: Bool)
}

/// DESIGN.md 7.3 — GitHub API は未認証で 60 リクエスト/時。素朴に作ると詰む。
public enum UpdateChecker {

    /// 明示的な「更新を確認」ボタン + 1 日 1 回のスロットル。
    /// 起動時の自動チェックはしない（3.5 の「常駐しない」と整合）。
    public static let throttle: TimeInterval = 24 * 60 * 60

    /// registry の repo/branch 単位で束ねる。
    /// 同一リポジトリ由来のスキルが何個あっても 1 リクエストで済む。
    public static func repoKey(_ entry: Registry.Entry) -> String? {
        guard let repo = entry.repo else { return nil }
        return "\(repo)#\(entry.branch ?? "main")"
    }

    public static func status(of entry: Registry.Entry, in registry: Registry) -> UpdateStatus {
        guard let key = repoKey(entry) else { return .unmanaged }
        guard let state = registry.repos[key], let latest = state.latestSha else {
            return entry.pinned ? .pinned(behind: false) : .unknown
        }
        let behind = entry.sha != latest
        if entry.pinned { return .pinned(behind: behind) }
        return behind ? .available(sha: latest) : .upToDate
    }

    /// チェックが必要な repo キー。`force` でスロットルを無視する。
    public static func staleKeys(_ registry: Registry, now: Date, force: Bool) -> [String] {
        let keys = Set(registry.resources.filter { !$0.pinned }.compactMap(repoKey))
        return keys.filter { key in
            guard !force, let checked = registry.repos[key]?.checkedAt else { return true }
            return now.timeIntervalSince(checked) >= throttle
        }.sorted()
    }

    /// `GET /repos/{repo}/commits/{branch}` を repo 単位で 1 回だけ叩く。
    ///
    /// ETag を付けて 304 を狙うが、**実測では 304 もレート制限を消費する**（7.3）。
    /// 60 リクエスト/時を守っているのは「repo 単位で束ねる」と「1 日 1 回のスロットル」。
    @discardableResult
    public static func check(
        _ registry: inout Registry, env: Environment, force: Bool = false
    ) async -> [String: (any Error)?] {
        var results: [String: (any Error)?] = [:]
        for key in staleKeys(registry, now: env.now(), force: force) {
            do {
                try await checkOne(key, &registry, env: env)
                results[key] = nil
            } catch {
                results[key] = error
            }
        }
        return results
    }

    static func checkOne(_ key: String, _ registry: inout Registry, env: Environment) async throws {
        let parts = key.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let url = URL(string: "https://api.github.com/repos/\(parts[0])/commits/\(parts[1])")
        else { return }

        var headers = ["Accept": "application/vnd.github+json"]
        if let etag = registry.repos[key]?.etag { headers["If-None-Match"] = etag }

        let result = try await env.httpGet(url, headers)
        var state = registry.repos[key] ?? Registry.RepoState()
        state.checkedAt = env.now()

        switch result.status {
        case 304:
            break                       // 変化なし。本文は転送されない（帯域だけ節約）
        case 200:
            state.etag = result.headers["etag"]
            state.latestSha = try parseSha(result.body)
        case 403, 429:
            throw Failure.rateLimited
        case 404:
            throw Failure.notFound(key)
        default:
            throw Failure.http(result.status)
        }
        registry.repos[key] = state
    }

    static func parseSha(_ data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = object["sha"] as? String, !sha.isEmpty
        else { throw Failure.malformedResponse }
        return sha
    }

    public static func resolve(_ source: GitHubSource, env: Environment,
                               defaultBranch: String = "main") async throws -> String {
        let branch = source.branch ?? defaultBranch
        guard let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.github.com/repos/\(source.repo)/commits/\(encoded)")
        else { throw Failure.malformedResponse }
        let result = try await env.httpGet(url, ["Accept": "application/vnd.github+json"])
        guard result.status == 200 else {
            if result.status == 403 || result.status == 429 { throw Failure.rateLimited }
            if result.status == 404 { throw Failure.notFound("\(source.repo)#\(branch)") }
            throw Failure.http(result.status)
        }
        return try parseSha(result.body)
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case rateLimited
        case notFound(String)
        case http(Int)
        case malformedResponse
        public var description: String {
            switch self {
            case .rateLimited:
                String(localized: "GitHub API のレート制限に達しました（未認証は 60 リクエスト/時）。時間をおいてください")
            case .notFound(let key):
                String(localized: "\(key) が見つかりません。リポジトリ名かブランチ名を確認してください")
            case .http(let code):
                String(localized: "GitHub API が HTTP \(code) を返しました")
            case .malformedResponse:
                String(localized: "GitHub API の応答を解釈できませんでした")
            }
        }
    }
}
