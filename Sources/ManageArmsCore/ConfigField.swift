import Foundation

extension Agent {
    /// GUI でドロップダウンにできる既知キーのヒント。ラベルや固定リストは持たない。
    /// ここにないキーは TextField で自由入力できる。
    public var configPickerHints: [String: [String]] {
        switch self {
        case .claude:
            return [
                "effortLevel":             ["low", "medium", "high", "xhigh", "max"],
                "theme":                   ["light", "dark", "system"],
                "permissions.defaultMode": ["auto", "acceptEdits", "manual",
                                           "bypassPermissions", "dontAsk", "plan"],
            ]
        case .codex:
            return [
                "model_reasoning_effort": ["low", "medium", "high"],
            ]
        case .cursor, .gemini:
            return [:]
        }
    }
}
