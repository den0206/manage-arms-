import Foundation

public enum Agent: String, CaseIterable, Identifiable, Sendable {
    case claude, cursor, codex, gemini

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex:  "Codex"
        case .gemini: "Gemini CLI"
        }
    }

    /// Cursor には CLI が無い（`cursor-agent` は存在しない）。
    /// これは異常ではないので「未検出」とは扱わない。。
    public var cliName: String? {
        switch self {
        case .claude: "claude"
        case .cursor: nil
        case .codex:  "codex"
        case .gemini: "gemini"
        }
    }

    /// ホーム相対の設定ディレクトリ。存在確認にだけ使い、走査はしない
    /// （`~/.claude` 直下には 129 MB の projects/ がある。）。
    public var configDir: String {
        switch self {
        case .claude: ".claude"
        case .cursor: ".cursor"
        case .codex:  ".codex"
        case .gemini: ".gemini"
        }
    }
}

/// Hooks / Commands / Rules は**対象外**（「やらないこと」）。
/// 横断ビューが無くて困るのは MCP / Skills / Subagents / Plugins の 4 つで、
/// 残りは各 CLI の設定を直接見た方が早い。
public enum Kind: String, CaseIterable, Sendable {
    case mcp, skill, subagent, plugin
}

extension Agent {
    /// の対応表。
    /// 「非対応」と「未検出」を混ぜないために必要 — 同じグレーで出すと
    /// ユーザーは「入れれば使えるようになる」と誤解する（3.7）。
    public func supports(_ kind: Kind) -> Bool {
        switch self {
        case .claude: return true                                   // 全種別
        case .cursor: return true
        case .codex:  return kind != .subagent                      // Subagent の概念が無い
        case .gemini: return kind == .mcp
        }
    }
}

extension Agent {
    /// このエージェントが実際に走査するスキルルート（ホーム相対）。
    ///  の実測表そのもの。Cursor は他エージェントのディレクトリも読む。
    public var skillRoots: [String] {
        switch self {
        case .claude:
            [".claude/skills"]
        case .cursor:
            [".cursor/skills", ".cursor/skills-cursor", ".cursor/cloud-skills",
             ".claude/skills", ".codex/skills", ".grok/skills", ".agents/skills"]
        case .codex:
            [".codex/skills", ".codex/skills/.system", ".agents/skills"]
        case .gemini:
            []
        }
    }

    /// エージェントに**最初から入っている**スキルのルート（）。
    /// Cursor は自前のスキル（automate / autopilot / canvas …）を `skills-cursor` に同梱し、
    /// `cloud-skills` は Cursor 側が同期する。**ユーザーが入れたものと混ぜない** —
    /// 混ぜると自分が入れたものが 20 件の同梱スキルに埋もれる。
    public static let bundledSkillRoots: Set<String> = [
        ".cursor/skills-cursor", ".cursor/cloud-skills", ".codex/skills/.system",
    ]

    /// 指定のルート群に置かれたスキルが、このエージェントから見えるか。
    public func sees(rootsContaining roots: Set<String>) -> Bool {
        !Set(skillRoots).isDisjoint(with: roots)
    }
}

extension Agent {
    /// Subagent の走査先。Skills と違って**共有ルートの慣習が無い**（）。
    /// Cursor も `.cursor/agents` しか読まない（他社ディレクトリは走査しない）。
    public var subagentRoots: [String] {
        switch self {
        case .claude: [".claude/agents"]
        case .cursor: [".cursor/agents"]
        case .codex, .gemini: []
        }
    }
}

extension Agent {
    /// MCP の読み取り元（）。設定ファイルの直読みを優先し、
    /// Codex だけ設定が `config.toml` なので CLI の JSON を使う。
    /// **`.file` は `mcpServers` キーで読まれる**（`MCPScanner.scan`）。
    /// 別のキーを使うエージェントはここに足すだけでは読めない。
    /// `nil` は「読み取る経路が無い」— `supports(.mcp)` が false のエージェント。
    ///
    /// **`Source.mcp` はここから導出される。** 二重に書かない。
    public var mcpSource: Source? {
        switch self {
        case .claude: .file(.home, ".claude.json")            // key: mcpServers
        case .cursor: .file(.home, ".cursor/mcp.json")
        case .gemini: .file(.home, ".gemini/settings.json")
        case .codex:  .cli(["codex", "mcp", "list", "--json"])
        }
    }

    /// プラグインの読み取り元（）。書き込みは CLI に委譲する。
    /// Cursor は `~/.cursor/plugins/` を持つが**読み取り経路が未実測**なので空にする
    /// （3.7 — 推測で埋めない）。`Source.plugins` はここから導出される。
    public var pluginSources: [Source] {
        switch self {
        case .claude:
            [.file(.home, ".claude/plugins/installed_plugins.json"),
             .file(.home, ".claude/plugins/known_marketplaces.json"),
             .cli(["claude", "plugin", "list", "--json"])]
        case .codex:
            [.cli(["codex", "plugin", "list", "--json"])]
        case .cursor, .gemini:
            []
        }
    }

    /// `ps` の行からエージェントを見分ける手掛かり。**実行ファイル名（`cliName`）で
    /// 当てられないものだけ**ここに書く（）。
    /// Cursor は CLI を持たず、アプリ本体とヘルパープロセスの名前でしか判別できない。
    ///
    /// **そのエージェントのプロセスにしか現れない語だけを載せる。** 部分一致なので、
    /// `/Cursor` のような広い語を入れると
    /// `node …/Library/Application Support/Cursor/foo.js` を Cursor のものと誤って言う。
    /// 所属は表示にしか使わないが、**間違った持ち主を名乗るのは分からないより悪い**
    /// （3.9 の「Codex を Cursor と取り違えない」と同じ理由）。
    /// 実測のプロセス `/Applications/Cursor.app/Contents/MacOS/Cursor` は
    /// `Cursor.app/` で拾える。
    public var processMarkers: [String] {
        switch self {
        case .claude, .codex, .gemini: []
        case .cursor: ["Cursor.app/", "Cursor Helper"]
        }
    }
}
