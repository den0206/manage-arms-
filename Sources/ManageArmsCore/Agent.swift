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
    /// これは異常ではないので「未検出」とは扱わない。DESIGN.md 8 章。
    public var cliName: String? {
        switch self {
        case .claude: "claude"
        case .cursor: nil
        case .codex:  "codex"
        case .gemini: "gemini"
        }
    }

    /// ホーム相対の設定ディレクトリ。存在確認にだけ使い、走査はしない
    /// （`~/.claude` 直下には 129 MB の projects/ がある。DESIGN.md 3.4）。
    public var configDir: String {
        switch self {
        case .claude: ".claude"
        case .cursor: ".cursor"
        case .codex:  ".codex"
        case .gemini: ".gemini"
        }
    }
}

/// Hooks / Commands / Rules は**対象外**（DESIGN.md 1 章「やらないこと」）。
/// 横断ビューが無くて困るのは MCP / Skills / Subagents / Plugins の 4 つで、
/// 残りは各 CLI の設定を直接見た方が早い。
public enum Kind: String, CaseIterable, Sendable {
    case mcp, skill, subagent, plugin
}

extension Agent {
    /// DESIGN.md 2 章の対応表。
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
    /// DESIGN.md 3.2 の実測表そのもの。Cursor は他エージェントのディレクトリも読む。
    public var skillRoots: [String] {
        switch self {
        case .claude:
            [".claude/skills"]
        case .cursor:
            [".cursor/skills", ".cursor/skills-cursor", ".cursor/cloud-skills",
             ".claude/skills", ".codex/skills", ".grok/skills", ".agents/skills"]
        case .codex:
            [".codex/skills", ".agents/skills"]
        case .gemini:
            []
        }
    }

    /// 指定のルート群に置かれたスキルが、このエージェントから見えるか。
    public func sees(rootsContaining roots: Set<String>) -> Bool {
        !Set(skillRoots).isDisjoint(with: roots)
    }
}

extension Agent {
    /// Subagent の走査先。Skills と違って**共有ルートの慣習が無い**（DESIGN.md 3.2）。
    /// Cursor も `.cursor/agents` しか読まない（他社ディレクトリは走査しない）。
    public var subagentRoots: [String] {
        switch self {
        case .claude: [".claude/agents"]
        case .cursor: [".cursor/agents"]
        case .codex, .gemini: []
        }
    }
}
