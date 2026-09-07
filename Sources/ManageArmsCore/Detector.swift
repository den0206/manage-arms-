import Foundation

/// エージェントの検出結果。DESIGN.md 3.7 の 4 状態のうち
/// `unsupported` はリソース種別ごとの話なので `Agent.supports(_:)` が持つ。
public enum Detection: Equatable, Sendable {
    /// CLI があり実行できる。Cursor は CLI が無いので version / path は nil。
    case detected(version: String?, path: String?)
    /// 設定ディレクトリはあるが CLI が見つからない。
    /// 既存リソースは読み取り表示し、変更操作だけ無効化する（3.7）。
    case configOnly
    /// CLI も設定ディレクトリも無い。
    case undetected
    /// 利用者が管理対象から外した。検出結果ではなく意思表示なので、
    /// **「未検出」と別の文言で出す** — 同じ灰色にすると「入れ直せば直る」と誤解する（3.7）。
    case disabled

    public var isUsable: Bool { if case .detected = self { true } else { false } }

    /// 走査・表示の対象か。未検出と無効はどちらも中身を読まない。
    public var isActive: Bool { self != .undetected && self != .disabled }
}

public enum Detector {

    /// 全エージェントを検出する。`overrides` は ⚙️ エージェント画面での手動パス指定。
    /// `PATH` 解決に失敗する環境があるため、この逃げ道が無いと詰む（3.7）。
    public static func detectAll(
        env: Environment,
        overrides: [Agent: String] = [:]
    ) -> [Agent: Detection] {
        var result: [Agent: Detection] = [:]
        for agent in Agent.allCases {
            result[agent] = detect(agent, env: env, override: overrides[agent])
        }
        return result
    }

    public static func detect(_ agent: Agent, env: Environment, override: String? = nil) -> Detection {
        let hasConfig = configDirExists(agent, env: env)

        // Cursor は CLI を持たない。設定ディレクトリの有無だけで判定する。
        guard let cli = agent.cliName else {
            return hasConfig ? .detected(version: nil, path: nil) : .undetected
        }

        // 手動指定は毎回実在を確かめる。アンインストールや Homebrew の移動で消えても
        // 「検出済み」のままになると、緑の表示のまま全操作が失敗する（3.7）。
        // 消えていたら指定が無かったものとして `PATH` 解決に戻る。
        let manual = override.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
        guard let path = manual ?? which(cli, env: env) else {
            return hasConfig ? .configOnly : .undetected
        }
        return .detected(version: version(of: path, env: env), path: path)
    }

    static func configDirExists(_ agent: Agent, env: Environment) -> Bool {
        var isDir: ObjCBool = false
        let url = env.home.appending(path: agent.configDir)
        let exists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    static func which(_ cli: String, env: Environment) -> String? {
        guard let out = try? env.run(["which", cli]) else { return nil }
        let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// バージョンが取れなくても「検出済み・バージョン不明」として扱う（3.7）。
    static func version(of path: String, env: Environment) -> String? {
        guard let out = try? env.run([path, "--version"]) else { return nil }
        return parseVersion(out)
    }

    /// 出力書式がバラバラなので緩くパースする。実測:
    ///   `2.1.236 (Claude Code)` / `codex-cli 0.153.2` / `0.46.0`
    public static func parseVersion(_ output: String) -> String? {
        let line = output.split(separator: "\n").first.map(String.init) ?? output
        for token in line.split(whereSeparator: { " \t()".contains($0) }) {
            let candidate = token.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return candidate
            }
        }
        return nil
    }
}

/// CLI 呼び出しの間引き。DESIGN.md 3.5。
///
/// ファイル走査はアクティブ化のたびに走らせてよいが、**CLI は node 起動を伴い秒単位**。
/// 1 回の `Inventory.load` は `which` × 3・`--version` × 3・`codex mcp list --json`・
/// `claude/codex plugin list --json` で **10 プロセス**を起こす。これが
/// `didBecomeActive` のたびに走ると、アプリに戻るだけで数秒固まる。
///
/// **不変条件5「キャッシュしない」の例外はここだけ。** 3.5 が
/// 「CLI 呼び出しは前回から一定間隔（数分）空いた時だけ再実行する」と定めており、
/// これはその実装。ファイル由来の結果は 1 つも持たない — 抱えるのは
/// CLI に訊かないと分からないことだけで、ウィンドウを閉じたら捨てる
/// （`AppModel.releaseForBackground` が `clear()` を呼ぶ）。
public enum CLIScan {

    /// 再実行までの間隔。DESIGN.md 3.5 の「数分」。
    public static let interval: TimeInterval = 180

    /// CLI に訊かないと分からないものだけ。ファイル由来の結果は入れない。
    public struct Snapshot: Sendable {
        public var at: Date
        public var agents: [Agent: Detection]
        /// `Agent.mcpSource` が `.cli` のエージェントの分だけ。
        public var mcp: [Agent: [MCPServer]]
        public var plugins: [InstalledPlugin]
        public var issues: [String]
        /// 取り直しの要否を決める入力。**これが変わったら間隔を待たない** —
        /// 管理対象の切り替えや CLI パスの手動指定は、押した直後に効かないと
        /// 「設定したのに変わらない」に見える。
        var key: Key
    }

    /// 走査結果が依存する入力。**`home` を含めるのが要**（10.3）—
    /// テストは偽のホームごとに別の結果を見る必要があり、
    /// ここを落とすと 1 つのテストの結果が別のテストに漏れる。
    struct Key: Hashable, Sendable {
        let home: String
        let enabled: Set<Agent>
        let overrides: [Agent: String]

        init(env: Environment, registry: Registry) {
            home = env.home.standardized.path(percentEncoded: false)
            enabled = Set(Agent.allCases.filter { registry.setting($0).enabled })
            overrides = registry.cliOverrides
        }
    }

    /// **1 枠ではなく key ごとに持つ。** 実利用ではホームが 1 つなので実質 1 件だが、
    /// 1 枠だと偽ホームを使う並列テストが互いの結果を追い出し合う（10.3）。
    private final class Store: @unchecked Sendable {
        /// 上限。ここに載るのは小さな構造体だけで、超えたら古い方から捨てる。
        static let capacity = 64

        private let lock = NSLock()
        private var snapshots: [Key: Snapshot] = [:]
        private var generation: UInt64 = 0

        func value(_ key: Key) -> Snapshot? { lock.withLock { snapshots[key] } }

        func token() -> UInt64 { lock.withLock { generation } }

        func set(_ snapshot: Snapshot, token: UInt64) {
            lock.withLock {
                guard token == generation else { return }
                snapshots[snapshot.key] = snapshot
                guard snapshots.count > Self.capacity else { return }
                let oldest = snapshots.min { $0.value.at < $1.value.at }?.key
                if let oldest { snapshots.removeValue(forKey: oldest) }
            }
        }

        func clear() {
            lock.withLock {
                snapshots.removeAll()
                generation &+= 1
            }
        }
    }

    private static let store = Store()

    /// 前回から `interval` 以内で設定も変わっていなければ、そのまま返す。
    /// `force` は明示的な再読み込みと、こちらが設定を書き換えた直後に使う。
    public static func snapshot(env: Environment, registry: Registry,
                                force: Bool = false) -> Snapshot {
        let key = Key(env: env, registry: registry)
        if !force, let cached = store.value(key),
           env.now().timeIntervalSince(cached.at) < interval {
            return cached
        }
        let token = store.token()
        let fresh = scan(env: env, registry: registry, key: key)
        store.set(fresh, token: token)
        return fresh
    }

    /// ウィンドウを閉じたら捨てる（3.5 / 9 章）。次に開いたときは取り直す。
    public static func clear() { store.clear() }

    private static func scan(env base: Environment, registry: Registry, key: Key) -> Snapshot {
        // 手動指定のパスはここで 1 回だけ解決して持ち回る。
        // 以降の `runCLI` が registry.json を読み直さなくなる（走査 1 回で 6〜8 回）。
        let env = base.resolvingCLIOverrides(key.overrides)
        var agents = Detector.detectAll(env: env, overrides: key.overrides)
        for agent in Agent.allCases where !key.enabled.contains(agent) {
            agents[agent] = .disabled
        }
        var mcp: [Agent: [MCPServer]] = [:]
        var plugins: [InstalledPlugin] = []
        var issues: [String] = []
        for agent in Agent.allCases where agents[agent]?.isActive == true {
            if case .cli = agent.mcpSource {
                do { mcp[agent] = try MCPScanner.read(agent, env: env) }
                catch { issues.append("\(agent.displayName) MCP: \(error)") }
            }
            if agent == .claude || agent == .codex {
                do { plugins += try PluginScanner.read(agent, env: env) }
                catch { issues.append("\(agent.displayName) Plugins: \(error)") }
            }
        }
        return Snapshot(at: env.now(), agents: agents, mcp: mcp,
                        plugins: plugins, issues: issues, key: key)
    }
}
