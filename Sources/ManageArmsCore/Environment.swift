import Foundation

/// 外部依存の集約点。テストでは偽のホームを指す `Environment` に差し替える。
/// DESIGN.md 3.8 — protocol ではなく構造体 + クロージャなので実装は 1 つのまま。
public struct Environment: Sendable {
    /// ホームディレクトリ。テストでは一時ディレクトリを指す。
    public var home: URL
    /// アプリ自身の保存領域（registry.json / disabled-skills/）。
    public var appSupport: URL
    /// CLI 実行。標準出力を返す。DESIGN.md 3.7 の解決済み PATH を使う。
    public var run: @Sendable ([String]) throws -> String
    /// 現在時刻。更新チェックのスロットル判定に使う。
    public var now: @Sendable () -> Date
    /// HTTP GET。本文・ステータス・レスポンスヘッダを返す。
    /// テストではネットワークを叩かない（DESIGN.md 10.6）。
    public var httpGet: @Sendable (URL, [String: String]) async throws -> HTTPResult

    public struct HTTPResult: Sendable {
        public let body: Data
        public let status: Int
        public let headers: [String: String]
        public init(body: Data, status: Int, headers: [String: String]) {
            self.body = body; self.status = status; self.headers = headers
        }
    }

    public init(
        home: URL,
        appSupport: URL,
        run: @escaping @Sendable ([String]) throws -> String,
        now: @escaping @Sendable () -> Date,
        httpGet: @escaping @Sendable (URL, [String: String]) async throws -> HTTPResult
    ) {
        self.home = home
        self.appSupport = appSupport
        self.run = run
        self.now = now
        self.httpGet = httpGet
    }
}

extension Environment {
    /// スキル実体の置き場。Cursor と Codex がここを直読みする（DESIGN.md 3.2）。
    public var skillStore: URL { home.appending(path: ".agents/skills") }
    /// 無効化したスキルの退避先（3.2 / 9 章）。実体は消さない。
    public var disabledStore: URL { appSupport.appending(path: "disabled-skills") }
    /// アプリが永続化する唯一のファイル（4.1）。
    public var registryFile: URL { appSupport.appending(path: "registry.json") }
    /// Claude だけは共有ルートを読まないので symlink を張る先。
    public var claudeSkills: URL { home.appending(path: ".claude/skills") }
    /// Subagent の実体。共有ルートの慣習が無いのでアプリ配下に置く（3.2 / 9 章）。
    public var agentStore: URL { appSupport.appending(path: "agents") }
    public var disabledAgentStore: URL { appSupport.appending(path: "disabled-agents") }

    /// 削除・移動してよいルート。ここ以外は触らない（9 章）。
    public var managedRoots: [URL] {
        [skillStore, disabledStore, agentStore, disabledAgentStore]
    }

    /// 保存領域の名前。デバッグビルド（`build-app.sh CONFIG=debug` が bundle id に
    /// `.debug` を付ける）は別ディレクトリに分け、開発中のリビルドが
    /// インストール済みリリース版の `registry.json` を壊さないようにする。
    ///
    /// 分離できるのは `appSupport` 配下だけ。`~/.agents/skills` と `~/.claude/skills` は
    /// home 基準の共有ルートなので（3.2）、デバッグ版でも有効化・無効化は実環境に効く。
    static var appSupportName: String {
        (Bundle.main.bundleIdentifier ?? "").hasSuffix(".debug")
            ? "ManageArms Debug" : "ManageArms"
    }

    /// 実環境。`PATH` は 3.7 の手順で解決したものを全 `Process` に渡す。
    public static let live = Environment(
        home: URL(filePath: NSHomeDirectory()),
        appSupport: URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/\(appSupportName)"),
        run: { try Exec.run($0, path: ShellPath.resolved) },
        now: { Date() },
        httpGet: { url, headers in
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            // ephemeral: ディスクキャッシュを持たない（9 章）。ETag は registry で自前管理する。
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields as? [String: String]) ?? [:]
            return .init(body: data, status: http?.statusCode ?? 0,
                         headers: Dictionary(uniqueKeysWithValues:
                            headers.map { ($0.key.lowercased(), $0.value) }))
        }
    )

    /// テスト用。偽のホームだけを触り、実ユーザーの `~/.claude` には絶対に到達しない。
    public static func test(
        home: URL,
        run: @escaping @Sendable ([String]) throws -> String = { _ in "" },
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 0) },
        httpGet: @escaping @Sendable (URL, [String: String]) async throws -> HTTPResult
            = { _, _ in .init(body: Data(), status: 0, headers: [:]) }
    ) -> Environment {
        Environment(
            home: home,
            appSupport: home.appending(path: "Library/Application Support/ManageArms"),
            run: run,
            now: now,
            httpGet: httpGet
        )
    }
}
