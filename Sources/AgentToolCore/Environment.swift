import Foundation

/// 外部依存の集約点。テストでは偽のホームを指す `Environment` に差し替える。
/// protocol ではなく構造体 + クロージャなので実装は 1 つのまま。
public struct Environment: Sendable {
    /// ホームディレクトリ。テストでは一時ディレクトリを指す。
    public var home: URL
    /// アプリ自身の保存領域（registry.json / disabled-skills/）。
    public var appSupport: URL
    /// CLI 実行。標準出力を返す。 の解決済み PATH を使う。
    public var run: @Sendable ([String]) throws -> String
    /// 現在時刻。更新チェックのスロットル判定に使う。
    public var now: @Sendable () -> Date
    /// HTTP GET。本文・ステータス・レスポンスヘッダを返す。
    /// テストではネットワークを叩かない（）。
    public var httpGet: @Sendable (URL, [String: String]) async throws -> HTTPResult
    /// 解決済みの手動 CLI パス（3.7）。`nil` は「まだ読んでいない = registry から読む」。
    ///
    /// **走査の入口で 1 回だけ読んで持ち回る。** ここが nil のままだと
    /// `command(_:for:)` が CLI を起こすたびに registry.json を読み直すことになり、
    /// `CLIScan` の 1 回の走査で 6〜8 回になる。
    /// 単発の操作（追加・削除・ピン留め）は nil のままでよい — 押した時点の
    /// 最新の設定を読む方が正しい。
    public var cliOverrides: [Agent: String]? = nil

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
    /// 走査の入口で 1 回だけ registry を読み、以降の CLI 呼び出しに持ち回る。
    /// **エントリが無いエージェント = 手動指定なし**として扱う（読み直さない）。
    public func resolvingCLIOverrides(_ overrides: [Agent: String]) -> Environment {
        var resolved = self
        resolved.cliOverrides = overrides
        return resolved
    }

    /// 手動指定された CLI は検出だけでなく、すべての実操作で同じ実体を使う。
    public func command(_ command: [String], for agent: Agent) -> [String] {
        guard !command.isEmpty else { return command }
        // `cliOverrides` が入っていればそれが答え。**辞書にエントリが無いエージェントは
        // 「手動指定なし」**であって、「まだ読んでいない」ではない
        // （ここで registry へ読みに戻ると、持ち回らせた意味が無くなる）。
        let manual: String?
        if let overrides = cliOverrides {
            manual = overrides[agent]
        } else {
            manual = Registry.load(env: self).setting(agent).path
        }
        guard let manual, FileManager.default.isExecutableFile(atPath: manual) else {
            return command
        }
        var resolved = command
        resolved[0] = manual
        return resolved
    }

    public func runCLI(_ command: [String], for agent: Agent) throws -> String {
        try run(self.command(command, for: agent))
    }

    /// スキル実体の置き場。Cursor と Codex がここを直読みする（）。
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

    /// 手動確認用の実環境。拡張からの呼び出しでは `globalStorageUri` を明示して組み立てる。
    public static let live = Environment(
        home: URL(filePath: NSHomeDirectory()),
        appSupport: URL(filePath: NSHomeDirectory())
            .appending(path: "Library/Application Support/AgentTool"),
        run: { try Exec.run($0, path: ShellPath.resolved) },
        now: { Date() },
        httpGet: { url, headers in
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            return try await BoundedHTTPClient.get(request, limit: 2 * 1024 * 1024)
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
            appSupport: home.appending(path: "Library/Application Support/AgentTool"),
            run: run,
            now: now,
            httpGet: httpGet
        )
    }
}

private final class BoundedHTTPClient: NSObject, URLSessionDataDelegate,
                                       @unchecked Sendable {
    struct TooLarge: Error {}
    let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<Environment.HTTPResult, any Error>?

    init(limit: Int) { self.limit = limit }

    static func get(_ request: URLRequest, limit: Int) async throws -> Environment.HTTPResult {
        let client = BoundedHTTPClient(limit: limit)
        let session = URLSession(configuration: .ephemeral, delegate: client, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await client.run(request, session: session)
    }

    func run(_ request: URLRequest, session: URLSession) async throws -> Environment.HTTPResult {
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              response.expectedContentLength <= 0 || response.expectedContentLength <= Int64(limit)
        else { completionHandler(.cancel); finish(.failure(TooLarge())); return }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive chunk: Data) {
        let exceeded = lock.withLock { () -> Bool in
            guard data.count + chunk.count <= limit else { return true }
            data.append(chunk)
            return false
        }
        if exceeded { dataTask.cancel(); finish(.failure(TooLarge())) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)); return }
        let result = lock.withLock { () -> Environment.HTTPResult in
            let fields = (response?.allHeaderFields as? [String: String]) ?? [:]
            return .init(body: data, status: response?.statusCode ?? 0,
                         headers: Dictionary(uniqueKeysWithValues:
                            fields.map { ($0.key.lowercased(), $0.value) }))
        }
        finish(.success(result))
    }

    private func finish(_ result: Result<Environment.HTTPResult, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Environment.HTTPResult, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
