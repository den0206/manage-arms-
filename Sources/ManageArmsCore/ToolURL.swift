import Foundation

/// ブラウザで開いているページが「追加できる Tool」かどうかの判定結果（DESIGN.md 6 章）。
///
/// **URL だけでは種別は確定しない**（種別判定は取得した中身を見るのが原則）。
/// パス名で候補にし、`proofs` の実在を確かめてから通知する。
public struct ToolLead: Equatable, Sendable, Identifiable {
    public let url: String
    public let source: GitHubSource
    public let kind: Kind
    public let name: String
    /// `raw.githubusercontent.com` 上のパス。**どれか 1 つでも 200 なら本物**。
    /// 空 = 確認不要（カタログページは配布物そのものが Skill だと分かっている）。
    public let proofs: [String]

    public var id: String { url }

    /// 実在確認に投げる URL。zip は落とさない — 見ているだけで数 MB は取らない。
    public func proofURLs(defaultBranch: String = "main") -> [URL] {
        proofs.compactMap {
            let path = $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0
            return URL(string:
                "https://raw.githubusercontent.com/\(source.repo)/\(source.branch ?? defaultBranch)/\(path)")
        }
    }
}

public enum ToolURL {

    /// URL 文字列 → 通知候補。**MCP は URL に手がかりが無いので拾わない**
    /// （公式サイトの JSON をコピペする既存導線が最頻で、URL 検知に向かない）。
    ///
    /// 拾う形:
    ///   https://skills.sh/owner/repo/skill              → Skill（カタログ）
    ///   .../tree|blob/main/skills/foo                   → Skill
    ///   .../tree|blob/main/plugins/foo                  → Plugin
    ///   .../blob/main/agents/foo.md                     → Subagent
    public static func lead(_ raw: String) -> ToolLead? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // カタログページ。3 番目のセグメントがスキル名（リポジトリのトップは拾わない —
        // 名前が決まらず、通知に出すものが無い）。
        if let catalog = GitHubURL.catalog(text) {
            guard let skill = catalog.skill else { return nil }
            return ToolLead(url: text, source: catalog.source, kind: .skill,
                            name: skill, proofs: [])
        }

        guard let parts = GitHubURL.components(text), parts.branch != nil,
              !parts.path.isEmpty, let kind = kind(of: parts.path)
        else { return nil }
        guard let source = GitHubURL.parse(text) else { return nil }

        let directory = parts.isFile ? Array(parts.path.dropLast()) : parts.path
        let file = parts.path.joined(separator: "/")
        let proofs: [String]
        switch kind {
        case .skill:
            proofs = [parts.isFile ? file : file + "/SKILL.md"]
        case .plugin:
            // リポジトリ直下の marketplace.json も根拠にする（plugin.json を
            // 各プラグインに置かない配布物があるため）。
            proofs = [parts.isFile ? file : file + "/.claude-plugin/plugin.json",
                      ".claude-plugin/marketplace.json"]
        case .subagent:
            // Subagent は .md ファイル 1 つ。ディレクトリを指されても中身の
            // ファイル名が分からず確認できないので、その場合は通知しない。
            guard parts.isFile else { return nil }
            proofs = [file]
        case .mcp:
            return nil
        }

        let name = (parts.isFile && kind == .subagent
                    ? parts.path.last.map { $0.replacingOccurrences(of: ".md", with: "") }
                    : directory.last) ?? source.repo
        return ToolLead(url: text, source: source, kind: kind, name: name, proofs: proofs)
    }

    /// パス名だけで種別を当てる。ネットワークを使わない絞り込み。
    static func kind(of path: [String]) -> Kind? {
        let lower = Set(path.map { $0.lowercased() })
        if lower.contains(".claude-plugin") || lower.contains("plugins") { return .plugin }
        if lower.contains("agents") || lower.contains("subagents") { return .subagent }
        if lower.contains("skills") { return .skill }
        return nil
    }

    /// 通知してよいか。**既に入れてあるものを毎回勧めない**のが一番効く抑止。
    /// `seen` は起動中だけのメモリ（永続ファイルを増やさない）。
    public static func shouldNotify(_ lead: ToolLead, registry: Registry, seen: Set<String>) -> Bool {
        guard !seen.contains(lead.url) else { return false }
        return !registry.resources.contains { entry in
            entry.repo == lead.source.repo
                && (entry.name == lead.name || entry.subdir == lead.source.subdir)
        }
    }
}
