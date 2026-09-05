import Foundation

/// セッションログから「最後にいつ使われたか」を集計する。DESIGN.md 3.9。
///
/// **`Source.all` には絶対に載せない。** ここが読むのは `~/.claude/projects`（140 MB）で、
/// 3.4 が踏まないと決めた領域そのもの。一覧スキャンの経路からは呼ばれず、
/// 明示的な「使用状況を分析」からしか到達しない（10.2 が経路を検査する）。
///
/// リアルタイム検知ではない。Skills / Plugins には実行実体が無く「使用中」は
/// 1 ターンで消える瞬間的イベントにしかならないため、点灯ではなく最終使用日を出す。
public enum UsageScanner {

    /// 使用実績ログのルート。
    ///
    /// Codex（`~/.codex/sessions/**/rollout-*.jsonl`）は `type: function_call` を使う
    /// 別形式で、スキル呼び出しの表現が確認できていないため対象外（spike #15）。
    /// 対応するまで Codex 由来の使用実績は出さない — 出せないことと
    /// 「使われていない」ことを混同させない（5.3）。
    public static func logRoots(env: Environment) -> [URL] {
        [env.home.appending(path: ".claude/projects")]
    }

    /// 名前 → 最終使用日。
    ///
    /// `since` を渡すと、それより新しいログだけを読む（増分スキャン）。
    /// セッションログは追記のみで、書き終わったファイルは後から変わらないため
    /// 前回以前の集計結果をそのまま使い回せる（3.9 が 3.5 の例外を認めている理由）。
    public static func scan(env: Environment, since: Date? = nil) -> [String: Date] {
        var found: [String: Date] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        for root in logRoots(env: env) {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                if let since, let modified = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified <= since { continue }
                merge(file: url, into: &found)
            }
        }
        return found
    }

    /// 増分スキャンして registry を更新する。呼び出し側はこれだけ使えばよい。
    ///
    /// 初回はログ全体（実測 140 MB）を読むため、明示的な操作からバックグラウンドで
    /// 呼ぶこと。起動時には走らせない（3.9 / 7.3 の「常駐しない」と同じ理由）。
    /// `inout` ではなく値を返す。全走査は数秒かかるためメインスレッドの外で回す必要があり、
    /// `inout` は `Task.detached` に渡せない。
    public static func refreshed(_ registry: Registry, env: Environment) -> Registry {
        // 走査中に書かれた行を取りこぼさないよう、開始時刻を基準にする。
        let startedAt = env.now()
        var updated = registry
        for (name, date) in scan(env: env, since: registry.usage.scannedUpTo)
        where updated.usage.lastUsed[name] == nil || updated.usage.lastUsed[name]! < date {
            updated.usage.lastUsed[name] = date
        }
        updated.usage.scannedUpTo = startedAt
        return updated
    }

    /// 1 ファイル読む。`mappedIfSafe` で最大 10 MB のログでも RSS に載せない（9 章）。
    static func merge(file url: URL, into found: inout [String: Date]) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // 候補行だけ JSON にかける。大半の行は tool_use を含まない。
            guard line.range(of: skillMarker) != nil || line.range(of: mcpMarker) != nil
            else { continue }
            guard let (date, names) = parse(Data(line)) else { continue }
            for name in names where found[name] == nil || found[name]! < date {
                found[name] = date
            }
        }
    }

    static let skillMarker = Data("\"Skill\"".utf8)
    static let mcpMarker = Data("mcp__".utf8)

    /// 1 行を解析して (時刻, 使われた名前) を返す。
    ///
    /// `Codable` ではなく `JSONSerialization` で書く。読む対象は他社製品の出力で
    /// **予告なく書式が変わる**（10.5）。1 つのキーの型が変わっただけで
    /// 行ごと落ちる `Codable` より、辞書を歩いて取れるものだけ取る方が壊れにくい。
    static func parse(_ line: Data) -> (Date, [String])? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }

        let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        var names: [String] = []
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let tool = block["name"] as? String else { continue }
            if tool == "Skill" {
                guard let skill = (block["input"] as? [String: Any])?["skill"] as? String
                else { continue }
                names.append(skill)
                // プラグイン由来は `ponytail:ponytail-review` の形で記録される（実測）。
                // 前半をプラグイン名としても数え、Plugin 行の最終使用日に使う（spike #15）。
                if let plugin = skill.split(separator: ":").first, plugin.count < skill.count {
                    names.append(String(plugin))
                }
            } else if tool.hasPrefix("mcp__") {
                // `mcp__chrome-devtools__take_snapshot` → `chrome-devtools`
                let server = tool.dropFirst(5).components(separatedBy: "__").first ?? ""
                if !server.isEmpty { names.append(server) }
            }
        }
        // 日付の解析は本当に当たった行だけで行う。`ISO8601DateFormatter` は
        // Sendable でなく static に置けないので、都度作る方を選ぶ。
        // 全履歴でも当たるのは数十行なので生成コストは問題にならない。
        guard !names.isEmpty,
              let stamp = object["timestamp"] as? String,
              let date = date(from: stamp)
        else { return nil }
        return (date, names)
    }

    /// Claude のタイムスタンプは秒の小数部を持つ行と持たない行が混在する。
    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
