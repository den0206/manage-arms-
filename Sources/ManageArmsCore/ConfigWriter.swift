import Foundation

/// Agent 設定ファイルのスカラー値を読み書きする。WriteGuard の第 3 の書き込み経路。
///
/// - 対象: JSON（Claude / Gemini）と TOML スカラー（Codex）
/// - 非対象: hooks 等の配列・認証キー
/// - 読み取り: JSON は深さ 1 まで（key / parent.key）。
///             TOML はトップレベルスカラーと単純セクション（ドットなし・引用符なし）のスカラーを
///             section.key 形式で収集する。動的キー（[projects."/path"] 等）はスキップ。
/// - 競合検出: 書き込み直前にファイル内容を再読し、ロード時と一致しなければ中断
/// - アトミック書き込み: Data.write(to:options:.atomic)
public enum ConfigWriter: Sendable {

    public enum Format: Sendable { case json, toml }

    public enum Value: Sendable, Equatable {
        case string(String)
        case bool(Bool)
    }

    public enum Failure: Error {
        case concurrentModification
        case parseError(String)
    }

    // MARK: - Read（全スカラー）

    /// ファイルを読んで表示できるスカラー値を順番どおりに返す。
    /// JSON は深さ 1 まで（key / parent.key）、配列・深いオブジェクトは省略する。
    /// TOML は先頭セクション前のトップレベルスカラーのみ。
    public static func read(
        from url: URL, format: Format
    ) throws -> (entries: [(key: String, value: Value)], raw: Data) {
        let data = try Data(contentsOf: url)
        let entries: [(String, Value)]
        switch format {
        case .json: entries = try readAllJSON(data: data)
        case .toml: entries = readAllTOML(text: String(decoding: data, as: UTF8.self))
        }
        return (entries, data)
    }

    // MARK: - Write（スカラー追加・更新）

    /// 1 キーを書き換えまたは追加してアトミックに保存する。
    /// `originalData` はロード時の生データ。変更されていれば中断する。
    public static func write(
        key: String, value: Value, to url: URL, format: Format, originalData: Data
    ) throws {
        try WriteGuard.assertConfigFile(url)
        let currentData = try Data(contentsOf: url)
        guard currentData == originalData else { throw Failure.concurrentModification }
        let patched = try patch(data: currentData, key: key, value: value, format: format)
        try patched.write(to: url, options: .atomic)
    }

    // MARK: - Delete

    /// 指定キーを削除してアトミックに保存する。
    /// JSON は dot-path 対応（parent.key）。TOML は key または section.key。
    public static func delete(
        key: String, from url: URL, format: Format, originalData: Data
    ) throws {
        try WriteGuard.assertConfigFile(url)
        let currentData = try Data(contentsOf: url)
        guard currentData == originalData else { throw Failure.concurrentModification }
        let patched: Data
        switch format {
        case .json: patched = try deleteJSON(data: currentData, keyPath: key)
        case .toml: patched = Data(deleteTOML(text: String(decoding: currentData, as: UTF8.self),
                                              key: key).utf8)
        }
        try patched.write(to: url, options: .atomic)
    }

    // MARK: - JSON 読み取り（深さ 1 まで）

    private static func readAllJSON(data: Data) throws -> [(String, Value)] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.parseError("top-level is not an object")
        }
        return collectScalars(from: obj, prefix: "", depth: 0)
    }

    /// 深さ 1 まで再帰してスカラー葉を収集する。配列・深いオブジェクトは省略。
    private static func collectScalars(
        from obj: [String: Any], prefix: String, depth: Int
    ) -> [(String, Value)] {
        var result: [(String, Value)] = []
        for key in obj.keys.sorted() {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            let raw = obj[key]
            if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                result.append((path, .bool(n.boolValue)))
            } else if let s = raw as? String {
                result.append((path, .string(s)))
            } else if let nested = raw as? [String: Any], depth < 1 {
                result += collectScalars(from: nested, prefix: path, depth: depth + 1)
            }
            // 配列（hooks 等）・深いオブジェクト → 省略
        }
        return result
    }

    // MARK: - JSON 書き込み

    private static func patch(data: Data, key: String, value: Value, format: Format) throws -> Data {
        switch format {
        case .json:
            guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.parseError("top-level is not an object")
            }
            setJSON(&obj, keyPath: key, value: value)
            var result = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            result.append(contentsOf: "\n".utf8)
            return result
        case .toml:
            return Data(patchTOML(text: String(decoding: data, as: UTF8.self),
                                  key: key, value: value).utf8)
        }
    }

    private static func setJSON(_ obj: inout [String: Any], keyPath: String, value: Value) {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 {
            switch value {
            case .string(let s): obj[first] = s
            case .bool(let b):   obj[first] = NSNumber(value: b)
            }
            return
        }
        var nested = (obj[first] as? [String: Any]) ?? [:]
        setJSON(&nested, keyPath: parts[1], value: value)
        obj[first] = nested
    }

    private static func deleteJSON(data: Data, keyPath: String) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.parseError("top-level is not an object")
        }
        removeJSON(&obj, keyPath: keyPath)
        var result = try JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        result.append(contentsOf: "\n".utf8)
        return result
    }

    private static func removeJSON(_ obj: inout [String: Any], keyPath: String) {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 { obj.removeValue(forKey: first); return }
        guard var nested = obj[first] as? [String: Any] else { return }
        removeJSON(&nested, keyPath: parts[1])
        obj[first] = nested
    }

    // MARK: - TOML 読み取り（トップレベル + 単純セクション）

    /// トップレベルと単純セクション（ドット・引用符なし）のスカラーを収集する。
    /// セクション内のキーは "section.key" 形式で返す。
    /// 動的キーを持つセクション（[projects."/path"] 等）はスキップ。
    private static func readAllTOML(text: String) -> [(String, Value)] {
        var result: [(String, Value)] = []
        var currentSection: String? = nil
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                currentSection = simpleTOMLSectionName(trimmed)
                continue
            }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let (k, v) = parseTOMLScalarLine(trimmed) {
                let fullKey = currentSection.map { "\($0).\(k)" } ?? k
                result.append((fullKey, v))
            }
        }
        return result
    }

    /// `[section]` ヘッダから単純なセクション名を返す。
    /// ドット・引用符を含む動的セクションは nil（スキップ扱い）。
    private static func simpleTOMLSectionName(_ headerLine: String) -> String? {
        guard let closeIdx = headerLine.firstIndex(of: "]") else { return nil }
        let name = String(headerLine[headerLine.index(after: headerLine.startIndex)..<closeIdx])
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("."), !name.contains("\""), !name.contains("'") else {
            return nil
        }
        return name
    }

    private static func parseTOMLScalarLine(_ line: String) -> (String, Value)? {
        guard let eqIdx = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
        let rhs = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if rhs == "true"  { return (key, .bool(true)) }
        if rhs == "false" { return (key, .bool(false)) }
        if rhs.hasPrefix("\""), rhs.hasSuffix("\""), rhs.count >= 2 {
            return (key, .string(String(rhs.dropFirst().dropLast())))
        }
        return nil  // 配列・インラインテーブル等は省略
    }

    private static func tomlLine(key: String, value: Value) -> String {
        switch value {
        case .string(let s):
            let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "\"", with: "\\\"")
            return "\(key) = \"\(escaped)\""
        case .bool(let b):
            return "\(key) = \(b ? "true" : "false")"
        }
    }

    // MARK: - TOML 書き込み

    /// key が "section.subkey" ならセクション内を、それ以外はトップレベルを更新する。
    private static func patchTOML(text: String, key: String, value: Value) -> String {
        if let dotIdx = key.firstIndex(of: ".") {
            let section = String(key[..<dotIdx])
            let subkey  = String(key[key.index(after: dotIdx)...])
            return patchTOMLSection(text: text, section: section,
                                    subkey: subkey, newLine: tomlLine(key: subkey, value: value))
        }
        return patchTOMLTopLevel(text: text, key: key, newLine: tomlLine(key: key, value: value))
    }

    private static func patchTOMLTopLevel(text: String, key: String, newLine: String) -> String {
        var inSection = false
        var patched = false
        var lines: [String] = text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inSection = true; return line }
            if inSection || patched { return line }
            guard let (k, _) = parseTOMLScalarLine(trimmed), k == key else { return line }
            patched = true
            return newLine
        }
        if !patched {
            if let sectionIdx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[")
            }) {
                lines.insert(newLine, at: sectionIdx)
            } else {
                while lines.last?.isEmpty == true { lines.removeLast() }
                lines.append(newLine)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 指定セクション内のキーを更新。セクションがなければ末尾に作成。
    private static func patchTOMLSection(
        text: String, section: String, subkey: String, newLine: String
    ) -> String {
        var lines = text.components(separatedBy: "\n")
        var inTarget = false
        var patched = false
        var targetIdx: Int? = nil
        var nextSectionIdx: Int? = nil

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") else {
                if inTarget && !patched {
                    if let (k, _) = parseTOMLScalarLine(trimmed), k == subkey {
                        lines[i] = newLine
                        patched = true
                    }
                }
                continue
            }
            if let name = simpleTOMLSectionName(trimmed), name == section {
                inTarget = true; targetIdx = i
            } else if inTarget && !patched {
                nextSectionIdx = i; inTarget = false
            } else {
                inTarget = false
            }
        }

        if !patched {
            if let insertAt = nextSectionIdx {
                lines.insert(newLine, at: insertAt)
            } else if targetIdx != nil {
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                lines.append(newLine)
            } else {
                while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
                lines.append("")
                lines.append("[\(section)]")
                lines.append(newLine)
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - TOML 削除

    private static func deleteTOML(text: String, key: String) -> String {
        if let dotIdx = key.firstIndex(of: ".") {
            let section = String(key[..<dotIdx])
            let subkey  = String(key[key.index(after: dotIdx)...])
            return deleteTOMLSection(text: text, section: section, subkey: subkey)
        }
        var inSection = false
        var deleted = false
        let lines: [String?] = text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { inSection = true; return line }
            if inSection || deleted { return line }
            if let (k, _) = parseTOMLScalarLine(trimmed), k == key {
                deleted = true; return nil
            }
            return line
        }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private static func deleteTOMLSection(text: String, section: String, subkey: String) -> String {
        var inTarget = false
        var deleted = false
        let lines: [String?] = text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") && !trimmed.hasPrefix("[[") {
                inTarget = (simpleTOMLSectionName(trimmed) == section)
                return line
            }
            if inTarget && !deleted {
                if let (k, _) = parseTOMLScalarLine(trimmed), k == subkey {
                    deleted = true; return nil
                }
            }
            return line
        }
        return lines.compactMap { $0 }.joined(separator: "\n")
    }
}
