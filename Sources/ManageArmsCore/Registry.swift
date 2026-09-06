import Foundation

/// アプリが永続化する唯一のファイル。DESIGN.md 4.1。
/// `~/.agents/.skill-lock.json` は読み取り専用で参照するだけで、ここには書かない。
public struct Registry: Codable, Equatable, Sendable {
    public var resources: [Entry] = []
    public var projects: [String] = []
    /// ETag と更新チェック結果は repo/branch 単位で持つ（7.3 の「リポジトリ単位で束ねる」）。
    public var repos: [String: RepoState] = [:]
    /// 使用実績（3.9）。過去は変化しないのでキャッシュしてよい — 3.5 の唯一の例外。
    public var usage = Usage()
    /// エージェントごとの手動設定（3.7）。キーは `Agent.rawValue`。
    /// **検出結果は保存しない** — 保存してよいのは利用者が決めたことだけ。
    public var agents: [String: AgentSetting] = [:]
    /// ブラウザで開いた Tool のページを検知して通知するか（DESIGN.md 6 章）。
    /// **Optional なのは既定値を書き出さないため** — 触っていない利用者の
    /// registry.json に意味の無い行を増やさない。
    public var browserDetection: Bool?

    /// 既定は OFF。ブラウザ制御の許可（TCC）を伴うので、黙って始めない。
    public var detectsBrowserURLs: Bool { browserDetection ?? false }

    /// 既定は「有効・自動検出のまま」。エントリが無いエージェントもこれになるので、
    /// 対応エージェントが増えたときは何も書かなくても自動で並ぶ。
    public struct AgentSetting: Codable, Equatable, Sendable {
        /// 管理対象にするか。false でもファイルには一切触れない（表示から外すだけ）。
        public var enabled: Bool = true
        /// 手動指定した CLI の実行ファイル。`PATH` 解決に失敗する環境の逃げ道（3.7）。
        public var path: String?

        public init(enabled: Bool = true, path: String? = nil) {
            self.enabled = enabled; self.path = path
        }

        enum CodingKeys: String, CodingKey { case enabled, path }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            path = try c.decodeIfPresent(String.self, forKey: .path)
        }
    }

    public struct Usage: Codable, Equatable, Sendable {
        /// ここまでのログは集計済み。次回はこれより新しいファイルだけ読む。
        /// `nil` は「未集計」。**「一度も使われていない」と区別する**（5.3）。
        public var scannedUpTo: Date?
        public var lastUsed: [String: Date] = [:]
        public init(scannedUpTo: Date? = nil, lastUsed: [String: Date] = [:]) {
            self.scannedUpTo = scannedUpTo; self.lastUsed = lastUsed
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var name: String
        public var kind: String
        public var repo: String?
        public var branch: String?
        public var subdir: String?
        public var sha: String?
        /// 上流が方針転換した時に更新を止める（7.4）。
        public var pinned: Bool = false
        /// 無効化されている（実体が退避ディレクトリにある）。
        public var disabled: Bool = false

        public init(name: String, kind: Kind, repo: String? = nil, branch: String? = nil,
                    subdir: String? = nil, sha: String? = nil,
                    pinned: Bool = false, disabled: Bool = false) {
            self.name = name; self.kind = kind.rawValue
            self.repo = repo; self.branch = branch; self.subdir = subdir; self.sha = sha
            self.pinned = pinned; self.disabled = disabled
        }
    }

    public struct RepoState: Codable, Equatable, Sendable {
        public var etag: String?
        public var latestSha: String?
        public var checkedAt: Date?
        public init(etag: String? = nil, latestSha: String? = nil, checkedAt: Date? = nil) {
            self.etag = etag; self.latestSha = latestSha; self.checkedAt = checkedAt
        }
    }

    public init() {}

    enum CodingKeys: String, CodingKey {
        case resources, repos, usage, projects, agents, browserDetection
    }

    /// **欠けているキーは既定値で埋める。**
    /// 合成された `init(from:)` はキーが 1 つ足りないだけで失敗し、`load` の
    /// フォールバックで空の Registry になる = 導入済みスキルの取得元が全部飛ぶ。
    /// このファイルは今後もフィールドが増える（`repos` → `usage` で 2 度目）ため、
    /// 前のバージョンが書いたファイルを読めることを構造的に保証しておく。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projects = try container.decodeIfPresent([String].self, forKey: .projects) ?? []
        resources = try container.decodeIfPresent([Entry].self, forKey: .resources) ?? []
        repos = try container.decodeIfPresent([String: RepoState].self, forKey: .repos) ?? [:]
        usage = try container.decodeIfPresent(Usage.self, forKey: .usage) ?? Usage()
        agents = try container.decodeIfPresent([String: AgentSetting].self, forKey: .agents) ?? [:]
        browserDetection = try container.decodeIfPresent(Bool.self, forKey: .browserDetection)
    }

    public func setting(_ agent: Agent) -> AgentSetting { agents[agent.rawValue] ?? AgentSetting() }

    /// 手動指定されている CLI パスだけを取り出す（`Detector.detectAll` の `overrides`）。
    public var cliOverrides: [Agent: String] {
        agents.reduce(into: [:]) { result, pair in
            guard let agent = Agent(rawValue: pair.key), let path = pair.value.path else { return }
            result[agent] = path
        }
    }

    public mutating func update(_ agent: Agent, _ change: (inout AgentSetting) -> Void) {
        var setting = setting(agent)
        change(&setting)
        // 既定値に戻ったエントリは残さない（registry.json に意味の無い行を増やさない）。
        agents[agent.rawValue] = setting == AgentSetting() ? nil : setting
    }

    public func entry(named name: String, kind: Kind? = nil) -> Entry? {
        resources.first { $0.name == name && (kind == nil || $0.kind == kind?.rawValue) }
    }

    public mutating func upsert(_ entry: Entry) {
        if let i = resources.firstIndex(where: { $0.name == entry.name && $0.kind == entry.kind }) {
            resources[i] = entry
        } else {
            resources.append(entry)
        }
    }

    // MARK: - 永続化

    /// `load` と違い**壊れていたら投げる**。`load` は既定値で握り潰すので、
    /// そのまま `save` すると利用者の全リソースの出所情報を空で上書きしてしまう。
    public static func read(env: Environment) throws -> Registry {
        guard FileManager.default.fileExists(atPath: env.registryFile.path) else { return Registry() }
        return try decoder.decode(Registry.self, from: Data(contentsOf: env.registryFile))
    }

    /// **壊れた `registry.json` の上に破壊的操作を始めない。**
    /// 実体を移動・削除した後で `save` が落ちると、ファイルは動いたのに
    /// registry には残る、という戻せない食い違いになる。先に落とす。
    public static func assertReadable(env: Environment) throws {
        _ = try read(env: env)
    }

    public static func load(env: Environment) -> Registry {
        guard let data = try? Data(contentsOf: env.registryFile),
              let decoded = try? decoder.decode(Registry.self, from: data)
        else { return Registry() }
        return decoded
    }

    /// アトミックに書く。書き込み中のクラッシュで壊れると
    /// 全リソースの出所情報が飛ぶ（9 章）。
    public func save(env: Environment) throws {
        try Self.assertReadable(env: env)      // 壊れたファイルを空で上書きしない
        try FileManager.default.createDirectory(
            at: env.appSupport, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: env.registryFile, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
