import Foundation

/// Frequently used scalar settings; unknown keys remain editable in the advanced section.
public struct ConfigField: Identifiable, Sendable {
    public var id: String { key }
    public let key: String
    public let detail: String
    public var options: [String] = []
    public var isBool: Bool = false
}

extension Agent {
    public var configReferenceURL: URL? {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/settings")
        case .codex: URL(string: "https://developers.openai.com/codex/config-reference")
        case .cursor, .gemini: nil
        }
    }

    // Reviewed against the official references above on 2026-09-08.
    // Existing values remain selectable even if absent from the suggestions.
    public var configFields: [ConfigField] {
        switch self {
        case .claude:
            [
                .init(key: "model", detail: "Model ID or alias."),
                .init(key: "effortLevel", detail: "Reasoning effort; supported levels depend on the model.",
                      options: ["low", "medium", "high", "xhigh"]),
                .init(key: "language", detail: "Preferred response language, e.g. japanese or english."),
                .init(key: "permissions.defaultMode", detail: "Initial permission mode. bypassPermissions skips approval prompts.",
                      options: ["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"]),
                .init(key: "alwaysThinkingEnabled", detail: "Enable extended thinking for sessions.", isBool: true),
                .init(key: "spinnerTipsEnabled", detail: "Show tips while processing.", isBool: true),
            ]
        case .codex:
            [
                .init(key: "model", detail: "Model ID or alias."),
                .init(key: "model_reasoning_effort", detail: "Reasoning effort; supported levels depend on the model.",
                      options: ["minimal", "low", "medium", "high", "xhigh"]),
                .init(key: "model_verbosity", detail: "Response detail for supported models.", options: ["low", "medium", "high"]),
                .init(key: "personality", detail: "Communication style for supported models.",
                      options: ["none", "friendly", "pragmatic"]),
                .init(key: "approval_policy", detail: "When to request approval. never disables approval prompts.",
                      options: ["untrusted", "on-request", "never"]),
                .init(key: "sandbox_mode", detail: "Execution boundary. danger-full-access removes sandbox protection.",
                      options: ["read-only", "workspace-write", "danger-full-access"]),
                .init(key: "sandbox_workspace_write.network_access", detail: "Allow outbound connections in workspace-write mode.", isBool: true),
            ]
        case .cursor, .gemini: []
        }
    }
}
