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

    public var isUsable: Bool { if case .detected = self { true } else { false } }
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

        guard let path = override ?? which(cli, env: env) else {
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
