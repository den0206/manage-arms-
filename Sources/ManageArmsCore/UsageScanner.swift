import Foundation

/// セッションログから「最後にいつ使われたか」を集計する。DESIGN.md 3.9。
///
/// **`Source.all` には絶対に載せない。** ここが読むセッションログは
/// 3.4 が踏まないと決めた領域そのもの。一覧スキャンの経路からは呼ばれず、
/// 明示的な「使用状況を分析」からしか到達しない（10.2 が経路を検査する）。
///
/// リアルタイム検知ではない。Skills / Plugins には実行実体が無く「使用中」は
/// 1 ターンで消える瞬間的イベントにしかならないため、点灯ではなく最終使用日を出す。
public enum UsageScanner {
    static let lineLimit = 1024 * 1024
    static let scannedFileLimit = 10_000
    static let scanTimeLimit: TimeInterval = 30

    struct LogSource {
        let id: String
        let root: URL
        let usesFileDate: Bool
    }

    static func logSources(env: Environment) -> [LogSource] {
        [
            LogSource(id: Agent.claude.rawValue,
                      root: env.home.appending(path: ".claude/projects"), usesFileDate: false),
            LogSource(id: Agent.codex.rawValue,
                      root: env.home.appending(path: ".codex/sessions"), usesFileDate: false),
            // Cursor の transcript は行に時刻が無い。最終使用日はファイル更新時刻になる。
            // ponytail: Cursor が行時刻を保存したら、その値を parse して mtime 近似を外す。
            LogSource(id: Agent.cursor.rawValue,
                      root: env.home.appending(path: ".cursor/projects"), usesFileDate: true),
        ]
    }

    /// 使用実績ログのルート。通常の一覧走査には混ぜない（3.4 / 10.2）。
    public static func logRoots(env: Environment) -> [URL] {
        logSources(env: env).map(\.root)
    }

    /// 名前 → 最終使用日。
    ///
    /// `since` を渡すと、それより新しいログだけを読む（増分スキャン）。
    /// セッションログは追記のみで、書き終わったファイルは後から変わらないため
    /// 前回以前の集計結果をそのまま使い回せる（3.9 が 3.5 の例外を認めている理由）。
    public static func scan(env: Environment, since: Date? = nil) -> [String: Date] {
        var found: [String: Date] = [:]
        for source in logSources(env: env) {
            scan(source, since: since, into: &found)
        }
        return bounded(found)
    }

    /// 安定したパス順で歩き、打ち切った位置を返す。nil だけが完了を表す。
    @discardableResult
    static func scan(_ source: LogSource, since: Date?, into found: inout [String: Date],
                     progress: Registry.Usage.Progress? = nil, startedAt: Date = Date(),
                     maxFiles: Int = scannedFileLimit,
                     clock: () -> Date = Date.init) -> Registry.Usage.Progress? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.root.path) else { return nil }
        let deadline = clock().addingTimeInterval(scanTimeLimit)
        var cursor = progress ?? .init(startedAt: startedAt, file: "", offset: nil)
        var scannedFiles = 0
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey,
                                        .isSymbolicLinkKey, .contentModificationDateKey]
        func permitted() -> Bool { clock() < deadline && !Task.isCancelled }
        func before(_ a: String, _ b: String) -> Bool {
            a.split(separator: "/").lexicographicallyPrecedes(b.split(separator: "/"))
        }
        func walk(_ directory: URL, prefix: String, depth: Int) throws -> Bool {
            guard permitted(), depth < 64 else { return false }
            let children = try fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: Array(keys)).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for url in children {
                guard permitted() else { return false }
                let relative = prefix.isEmpty ? url.lastPathComponent : prefix + "/" + url.lastPathComponent
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    // 再開位置より前の完了済みサブツリーは歩き直さない。
                    if before(relative, cursor.file), !cursor.file.hasPrefix(relative + "/") { continue }
                    if try walk(url, prefix: relative, depth: depth + 1) == false { return false }
                } else if values.isRegularFile == true, url.pathExtension == "jsonl" {
                    if before(relative, cursor.file) || (relative == cursor.file && cursor.offset == nil) { continue }
                    if let since, let modified = values.contentModificationDate, modified <= since { continue }
                    guard scannedFiles < maxFiles else { return false }
                    scannedFiles += 1
                    let resume = relative == cursor.file ? cursor : nil
                    cursor.file = relative
                    cursor.offset = resume?.offset ?? 0
                    cursor.discardingLongLine = resume?.discardingLongLine ?? false
                    let position = read(file: url,
                        fallbackDate: source.usesFileDate ? values.contentModificationDate : nil,
                        into: &found, offset: cursor.offset ?? 0,
                        discarding: cursor.discardingLongLine, permitted: permitted)
                    cursor.offset = position?.offset
                    cursor.discardingLongLine = position?.discarding ?? false
                    if position != nil { return false }
                }
            }
            return true
        }
        do { return try walk(source.root, prefix: "", depth: 0) ? nil : cursor }
        catch {
            // 読めなかったディレクトリを完了扱いにせず、次回もう一度試す。
            return .init(startedAt: cursor.startedAt, file: "", offset: nil)
        }
    }

    /// 増分スキャンして registry を更新する。呼び出し側はこれだけ使えばよい。
    ///
    /// 初回は複数 Agent のログ全体を読むため、明示的な操作からバックグラウンドで
    /// 呼ぶこと。起動時には走らせない（3.9 / 7.3 の「常駐しない」と同じ理由）。
    /// `inout` ではなく値を返す。全走査は数秒かかるためメインスレッドの外で回す必要があり、
    /// `inout` は `Task.detached` に渡せない。
    public static func refreshed(_ registry: Registry, env: Environment) -> Registry {
        refreshed(registry, env: env, maxFiles: scannedFileLimit, clock: Date.init)
    }

    static func refreshed(_ registry: Registry, env: Environment, maxFiles: Int,
                          clock: () -> Date) -> Registry {
        let startedAt = env.now()
        var updated = registry
        for source in logSources(env: env) {
            var found: [String: Date] = [:]
            let previous = registry.usage.pendingSources[source.id]
            let pending = scan(source, since: registry.usage.scannedSources[source.id], into: &found,
                               progress: previous, startedAt: startedAt, maxFiles: maxFiles, clock: clock)
            for (name, date) in found
            where updated.usage.lastUsed[name] == nil || updated.usage.lastUsed[name]! < date {
                updated.usage.lastUsed[name] = date
            }
            updated.usage.pendingSources[source.id] = pending
            if pending == nil {
                // 複数回に分かれた走査は最初の開始時刻までを完了とする。
                updated.usage.scannedSources[source.id] = previous?.startedAt ?? startedAt
            }
        }
        if updated.usage.pendingSources.isEmpty {
            updated.usage.scannedUpTo = updated.usage.scannedSources.values.min()
        }
        updated.usage.lastUsed = bounded(updated.usage.lastUsed)
        return updated
    }

    /// `lastUsed` に残す件数の上限。
    ///
    /// **唯一の永続ファイルを単調増加させない**（DESIGN.md 4.1 / 9 章）。
    /// キーは「そのとき使われた名前」なので、消したリソースの分も残り続ける。
    /// 消えたものを消えたと知る術がここには無い（一覧は別経路）ので、
    /// 件数で頭を押さえて古い方から捨てる — 用途は「最終使用日」の表示だけで、
    /// 古い記録ほど画面に出ても意味が薄い。
    static let historyLimit = 2000

    static func bounded(_ lastUsed: [String: Date]) -> [String: Date] {
        guard lastUsed.count > historyLimit else { return lastUsed }
        let kept = lastUsed.sorted { $0.value > $1.value }.prefix(historyLimit)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    /// 固定バッファで逐次読む。巨大な 1 行は解析せず捨てる。
    static func merge(file url: URL, fallbackDate: Date?, into found: inout [String: Date]) {
        _ = read(file: url, fallbackDate: fallbackDate, into: &found,
                 offset: 0, discarding: false, permitted: { true })
        found = bounded(found)
    }

    /// 読み取り中にも期限を確認する。未完の行は次回のために読み戻せる位置を返す。
    static func read(file url: URL, fallbackDate: Date?, into found: inout [String: Date],
                     offset: UInt64, discarding: Bool, permitted: () -> Bool)
        -> (offset: UInt64, discarding: Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (offset, discarding) }
        defer { try? handle.close() }
        var position = offset
        var pending = Data()
        var discardingLongLine = discarding
        do {
            let size = try handle.seekToEnd()
            if position > size { position = 0; discardingLongLine = false }
            try handle.seek(toOffset: position)
            while permitted() {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                    if !discardingLongLine, !pending.isEmpty {
                        merge(line: pending, fallbackDate: fallbackDate, into: &found)
                    }
                    return nil
                }
                position += UInt64(chunk.count)
                pending.append(chunk)
                while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    guard permitted() else { return (position - UInt64(pending.count), discardingLongLine) }
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    if !discardingLongLine { merge(line: line, fallbackDate: fallbackDate, into: &found) }
                    discardingLongLine = false
                }
                if pending.count > lineLimit {
                    pending.removeAll(keepingCapacity: true)
                    discardingLongLine = true
                }
            }
        } catch { /* 元の完了時刻を進めず、同じ位置から再試行する。 */ }
        return (position - UInt64(pending.count), discardingLongLine)
    }

    private static func merge(line: Data, fallbackDate: Date?,
                              into found: inout [String: Date]) {
        guard line.count <= lineLimit else { return }
        // 候補行だけ JSON にかける。大半の行は tool_use を含まない。
        guard line.range(of: skillMarker) != nil || line.range(of: codexSkillMarker) != nil
                || line.range(of: skillPathMarker) != nil
                || line.range(of: mcpMarker) != nil
        else { return }
        guard let (date, names) = parse(line, fallbackDate: fallbackDate) else { return }
        for name in names where found[name] == nil || found[name]! < date {
            found[name] = date
        }
        if found.count > historyLimit * 2 { found = bounded(found) }
    }

    static let skillMarker = Data("\"Skill\"".utf8)
    static let codexSkillMarker = Data("\"type\":\"skill\"".utf8)
    static let skillPathMarker = Data("SKILL.md".utf8)
    static let mcpMarker = Data("mcp__".utf8)

    /// 1 行を解析して (時刻, 使われた名前) を返す。
    ///
    /// `Codable` ではなく `JSONSerialization` で書く。読む対象は他社製品の出力で
    /// **予告なく書式が変わる**（10.5）。1 つのキーの型が変わっただけで
    /// 行ごと落ちる `Codable` より、辞書を歩いて取れるものだけ取る方が壊れにくい。
    static func parse(_ line: Data, fallbackDate: Date? = nil) -> (Date, [String])? {
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
            } else if tool == "Read",
                      let path = (block["input"] as? [String: Any])?["path"] as? String {
                names += skillNames(in: path)
            }
        }
        collectCodexSkills(in: object, into: &names)
        if let payload = object["payload"] as? [String: Any],
           let type = payload["type"] as? String,
           ["custom_tool_call", "function_call"].contains(type),
           let tool = payload["name"] as? String,
           ["exec", "exec_command"].contains(tool),
           let input = (payload["input"] ?? payload["arguments"]) as? String {
            for command in commands(in: input)
            where isSkillRead(command) {
                names += skillNames(in: command)
            }
        }
        // 日付の解析は本当に当たった行だけで行う。`ISO8601DateFormatter` は
        // Sendable でなく static に置けないので、都度作る方を選ぶ。
        // 全履歴でも当たるのは数十行なので生成コストは問題にならない。
        guard !names.isEmpty,
              let date = (object["timestamp"] as? String).flatMap(date(from:)) ?? fallbackDate
        else { return nil }
        var seen: Set<String> = []
        return (date, names.filter { seen.insert($0).inserted })
    }

    /// Codex の明示呼び出しは UserMessage 内の `{type:"skill", name:"…"}` に残る。
    static func collectCodexSkills(in value: Any, into names: inout [String]) {
        if let object = value as? [String: Any] {
            if object["type"] as? String == "skill", let name = object["name"] as? String {
                names.append(name)
                if let plugin = name.split(separator: ":").first, plugin.count < name.count {
                    names.append(String(plugin))
                }
            }
            for child in object.values { collectCodexSkills(in: child, into: &names) }
        } else if let array = value as? [Any] {
            for child in array { collectCodexSkills(in: child, into: &names) }
        }
    }

    /// `…/<skill>/SKILL.md` から skill 名だけを取る。絶対パスや引用符には依存しない。
    static func skillNames(in text: String) -> [String] {
        var rest = text[...]
        var names: [String] = []
        while let marker = rest.range(of: "/SKILL.md") {
            let prefix = rest[..<marker.lowerBound]
            if let slash = prefix.lastIndex(of: "/") {
                let name = prefix[prefix.index(after: slash)...]
                if !name.isEmpty && !name.contains(where: { $0.isWhitespace || $0 == "\"" }) {
                    names.append(String(name))
                }
            }
            rest = rest[marker.upperBound...]
        }
        return names
    }

    /// Codex の `exec` は JS の中に `{cmd:"…"}` または `{"cmd":"…"}` を持つ。
    /// tool input 全体を見ると
    /// patch やテストデータ中の SKILL.md まで誤認するため、実行コマンドだけを戻す。
    static func commands(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|[,{]\s*)(?:cmd|"cmd")\s*:\s*("(?:\\.|[^"\\])*")"#)
        else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length))
            .compactMap { match in
                let literal = source.substring(with: match.range(at: 1))
                return try? JSONDecoder().decode(String.self, from: Data(literal.utf8))
            }
    }

    /// 既存の shell tokenizer で書き込み・連結コマンドを拒否し、単純な読み取りだけ数える。
    static func isSkillRead(_ command: String) -> Bool {
        guard let words = PasteInput.commandWords(command), let first = words.first else { return false }
        let executable = (first as NSString).lastPathComponent
        guard ["sed", "cat", "head", "tail", "less"].contains(executable) else { return false }
        if executable == "sed" {
            return !words.dropFirst().contains {
                $0.hasPrefix("--in-place")
                    || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.dropFirst().contains("i"))
            }
        }
        return true
    }

    /// Claude のタイムスタンプは秒の小数部を持つ行と持たない行が混在する。
    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
