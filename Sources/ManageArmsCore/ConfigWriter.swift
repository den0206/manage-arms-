import Foundation

/// Agent 設定ファイルのスカラー値を読み書きする。WriteGuard の第 3 の書き込み経路。
///
/// - 対象: JSON（Claude / Gemini）と TOML スカラー（Codex）
/// - 非対象: hooks 等の配列・認証キー
/// - 読み取り: JSON は深さ 1 まで（key / parent.key）。
///             TOML はドット付き・引用符付きパスを保持し、整数・小数も収集する。
///             配列テーブルとコンテナ値はフォーム編集の対象外。
/// - 競合検出: 書き込み直前にファイル内容を再読し、ロード時と一致しなければ中断
/// - アトミック書き込み: Data.write(to:options:.atomic)
public enum ConfigWriter: Sendable {

    public enum Format: Sendable { case json, toml }

    public enum Value: Sendable, Equatable {
        case string(String)
        case bool(Bool)
        case integer(Int64)
        case decimal(String)

        public func sameType(as other: Value) -> Bool {
            switch (self, other) {
            case (.string, .string), (.bool, .bool), (.integer, .integer), (.decimal, .decimal): true
            default: false
            }
        }
    }

    public enum Failure: Error, LocalizedError {
        case concurrentModification
        case parseError(String)

        public var errorDescription: String? {
            switch self {
            case .concurrentModification:
                String(localized: "別のプロセスが設定を変更したため保存できませんでした。再読み込みしてください。")
            case .parseError(let reason): reason
            }
        }
    }

    // MARK: - Read（全スカラー）

    /// ファイルを読んで表示できるスカラー値を順番どおりに返す。
    /// JSON は深さ 1 まで（key / parent.key）、配列・深いオブジェクトは省略する。
    /// TOML は文字列・bool・整数・小数。未対応構文があれば拒否する。
    public static func read(
        from url: URL, format: Format
    ) throws -> (entries: [(key: String, value: Value)], raw: Data) {
        let data = try Data(contentsOf: url)
        let entries: [(String, Value)]
        switch format {
        case .json: entries = try readAllJSON(data: data)
        case .toml:
            guard let text = String(data: data, encoding: .utf8) else { throw unsupportedTOML }
            entries = try readAllTOML(text: text)
        }
        return (entries.filter { $0.0 != "hooks" && !$0.0.hasPrefix("hooks.") }, data)
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
        case .json:
            try validateKey(key)
            patched = try deleteJSON(data: currentData, keyPath: key)
        case .toml:
            guard let text = String(data: currentData, encoding: .utf8) else { throw unsupportedTOML }
            patched = Data(try deleteTOML(text: text, key: key).utf8)
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
            guard isBareKey(key) else { continue }
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

    static func patch(data: Data, key: String, value: Value, format: Format) throws -> Data {
        switch format {
        case .json:
            try validateKey(key)
            guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Failure.parseError("top-level is not an object")
            }
            try setJSON(&obj, keyPath: key, value: value)
            var result = try JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            result.append(contentsOf: "\n".utf8)
            return result
        case .toml:
            guard let text = String(data: data, encoding: .utf8) else { throw unsupportedTOML }
            return Data(try editTOML(text: text,
                                  key: key, value: value).utf8)
        }
    }

    private static func setJSON(_ obj: inout [String: Any], keyPath: String, value: Value) throws {
        let parts = keyPath.split(separator: ".", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return }
        if parts.count == 1 {
            if let existing = obj[first], !(existing is String),
               (existing as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() }) != true {
                throw Failure.parseError(String(localized: "この値はフォームで編集できません。エディタで開いてください。"))
            }
            switch value {
            case .string(let s): obj[first] = s
            case .bool(let b):   obj[first] = NSNumber(value: b)
            case .integer, .decimal: throw unsupportedTOML
            }
            return
        }
        if obj[first] != nil && !(obj[first] is [String: Any]) {
            throw Failure.parseError(String(localized: "この値はフォームで編集できません。エディタで開いてください。"))
        }
        var nested = (obj[first] as? [String: Any]) ?? [:]
        try setJSON(&nested, keyPath: parts[1], value: value)
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

    // MARK: - TOML (validated subset, preserving source lines)

    private static var unsupportedTOML: Failure {
        .parseError(String(localized: "安全に解釈できない TOML 構文があります。エディタで開いて編集してください。"))
    }

    private static func isBareKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }
    }

    private static func validateKey(_ key: String) throws {
        let parts = key.components(separatedBy: ".")
        guard parts.count <= 2, parts.allSatisfy(isBareKey) else { throw unsupportedTOML }
    }

    /// Split only outside quotes. Quoted dots are literal characters, never path separators.
    private static func splitTOML(_ text: String, at delimiter: Character) throws -> [String] {
        var quote: Character?
        var escaped = false
        var nesting = 0
        var start = text.startIndex
        var parts: [String] = []
        for i in text.indices {
            let c = text[i]
            if escaped { escaped = false; continue }
            if quote == "\"", c == "\\" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if delimiter == ",", c == "[" || c == "{" {
                nesting += 1
            } else if delimiter == ",", c == "]" || c == "}" {
                nesting -= 1
                guard nesting >= 0 else { throw unsupportedTOML }
            } else if c == delimiter, nesting == 0 {
                parts.append(String(text[start..<i]))
                start = text.index(after: i)
                // Comments need no quote validation.
                if delimiter == "#" { return parts + [String(text[start...])] }
                if delimiter == "=" { return parts + [String(text[start...])] }
            }
        }
        guard quote == nil, !escaped, nesting == 0 else { throw unsupportedTOML }
        return parts + [String(text[start...])]
    }

    public static func isValidTOMLKey(_ key: String) -> Bool {
        (try? tomlPath(key)) != nil
    }

    private static func tomlPath(_ key: String) throws -> [String] {
        guard key.utf8.count <= 4096 else { throw unsupportedTOML }
        let parts = try splitTOML(key, at: ".")
        guard parts.count <= 64 else { throw unsupportedTOML }
        return try parts.map {
            let part = $0.trimmingCharacters(in: .whitespaces)
            if isBareKey(part) { return part }
            if case .string(let decoded) = try tomlScalar(part) { return decoded }
            throw unsupportedTOML
        }
    }

    private static func quotedTOML(_ value: String) throws -> String {
        // JSON string escapes are a TOML-compatible subset. Reject DEL explicitly.
        guard !value.unicodeScalars.contains(where: { $0.value == 127 }) else { throw unsupportedTOML }
        return String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            .replacingOccurrences(of: "\\/", with: "/")
    }

    private static func displayedPath(_ path: [String]) throws -> String {
        try path.map { isBareKey($0) ? $0 : try quotedTOML($0) }.joined(separator: ".")
    }

    /// Decimal numbers retain their spelling, so parsing never rounds user values.
    public static func numberValue(_ text: String) throws -> Value {
        if text.range(of: #"^[+-]?(0|[1-9](_?[0-9])*)$"#, options: .regularExpression) != nil,
           let value = Int64(text.replacingOccurrences(of: "_", with: "")) {
            return .integer(value)
        }
        if text.range(of: #"^[+-]?(0|[1-9](_?[0-9])*)(\.[0-9](_?[0-9])*)?([eE][+-]?[0-9](_?[0-9])*)?$"#,
                      options: .regularExpression) != nil,
           text.contains(".") || text.lowercased().contains("e"),
           let value = Double(text.replacingOccurrences(of: "_", with: "")), value.isFinite {
            return .decimal(text)
        }
        throw Failure.parseError(String(localized: "有効な整数または有限の小数を入力してください。"))
    }

    private static func tomlScalar(_ text: String) throws -> Value {
        if text == "true" { return .bool(true) }
        if text == "false" { return .bool(false) }
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2,
           !text.dropFirst().dropLast().contains("'") {
            return .string(String(text.dropFirst().dropLast()))
        }
        if text.hasPrefix("\""),
           // TOML does not permit JSON's escaped slash or surrogate escapes.
           !text.contains("\\/"), !text.contains("\\uD"), !text.contains("\\ud"),
           let value = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) {
            return .string(value)
        }
        if let number = try? numberValue(text) { return number }
        throw unsupportedTOML
    }

    private static func renderedTOML(_ value: Value) throws -> String {
        switch value {
        case .string(let s): return try quotedTOML(s)
        case .bool(let b): return b ? "true" : "false"
        case .integer(let n): return String(n)
        case .decimal(let n):
            guard case .decimal = try numberValue(n) else { throw unsupportedTOML }
            return n
        }
    }

    /// Validate containers without exposing them as scalar controls.
    private static func validateTOMLValue(_ text: String, depth: Int = 0) throws {
        guard depth < 32 else { throw unsupportedTOML }
        if (try? tomlScalar(text)) != nil { return }
        let array = text.hasPrefix("[") && text.hasSuffix("]")
        let table = text.hasPrefix("{") && text.hasSuffix("}")
        guard array || table else { throw unsupportedTOML }
        let body = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return }
        var values = try splitTOML(body, at: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if array, values.last == "" { values.removeLast() }
        var keys: [[String]] = []
        for value in values {
            if array {
                try validateTOMLValue(value, depth: depth + 1)
            } else {
                let pair = try splitTOML(value, at: "=")
                guard pair.count == 2 else { throw unsupportedTOML }
                let key = try tomlPath(pair[0])
                guard !keys.contains(where: { $0.starts(with: key) || key.starts(with: $0) }) else {
                    throw unsupportedTOML
                }
                keys.append(key)
                try validateTOMLValue(pair[1].trimmingCharacters(in: .whitespaces), depth: depth + 1)
            }
        }
    }

    private struct TOMLAddress: Hashable {
        let scope: Int
        let path: [String]
    }

    private struct TOMLItem {
        let address: TOMLAddress
        let line: Int
        let valueRange: Range<String.Index>
        let value: Value?
        let rawValue: String
    }

    private struct TOMLDocument {
        enum Node { case scalar, implicitTable, dottedTable, explicitTable, arrayTable }
        var lines: [String]
        var items: [TOMLItem] = []
        var tables: [(path: [String], line: Int)] = []
        var nodes: [TOMLAddress: Node] = [:]

        init(_ text: String) throws {
            guard !text.unicodeScalars.contains(where: {
                ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127
            }) else { throw unsupportedTOML }
            lines = text.components(separatedBy: "\n")
            var section: [String] = []
            var arrays: [(path: [String], scope: Int)] = []
            var scope = 0
            var nextScope = 0
            for (index, line) in lines.enumerated() {
                if line.contains("\r") {
                    guard line.hasSuffix("\r"), index < lines.count - 1,
                          !line.dropLast().contains("\r") else { throw unsupportedTOML }
                }
                let content = line.hasSuffix("\r") ? String(line.dropLast()) : line
                let body = try splitTOML(content, at: "#")[0]
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("[") {
                    let array = trimmed.hasPrefix("[[")
                    let count = array ? 2 : 1
                    guard trimmed.hasSuffix(array ? "]]" : "]") else { throw unsupportedTOML }
                    section = try tomlPath(String(trimmed.dropFirst(count).dropLast(count)))
                    scope = arrays.last(where: {
                        section.starts(with: $0.path) && (!array || section.count > $0.path.count)
                    })?.scope ?? 0
                    if array {
                        let root = TOMLAddress(scope: scope, path: section)
                        // Repeated array elements get independent namespaces; none is GUI-editable.
                        try declareParents(section, scope: scope, dotted: false)
                        if let node = nodes[root], node != .arrayTable { throw unsupportedTOML }
                        nodes[root] = .arrayTable
                        nextScope += 1
                        scope = nextScope
                        arrays.removeAll { $0.path.starts(with: section) }
                        arrays.append((section, scope))
                        nodes[TOMLAddress(scope: scope, path: section)] = .explicitTable
                    } else {
                        try declareParents(section, scope: scope, dotted: false)
                        let address = TOMLAddress(scope: scope, path: section)
                        if let node = nodes[address], node != .implicitTable { throw unsupportedTOML }
                        nodes[address] = .explicitTable
                        if scope == 0 { tables.append((section, index)) }
                    }
                    continue
                }
                let assignment = try splitTOML(body, at: "=")
                guard assignment.count == 2 else { throw unsupportedTOML }
                let relativePath = try tomlPath(assignment[0])
                let path = section + relativePath
                let address = TOMLAddress(scope: scope, path: path)
                try declareParents(path, scope: scope, dotted: true, sectionDepth: section.count)
                guard nodes[address] == nil else { throw unsupportedTOML }
                nodes[address] = .scalar
                let rawValue = assignment[1].trimmingCharacters(in: .whitespaces)
                // ponytail: multiline values and dates require an external editor; never guess their boundaries.
                try validateTOMLValue(rawValue)
                let value = try? tomlScalar(rawValue)
                let valueStart = line.index(line.startIndex, offsetBy: assignment[0].count + 1)
                guard let range = line.range(of: rawValue, range: valueStart..<line.endIndex) else {
                    throw unsupportedTOML
                }
                items.append(TOMLItem(address: address, line: index, valueRange: range, value: value, rawValue: rawValue))
            }
        }

        mutating func declareParents(_ path: [String], scope: Int, dotted: Bool, sectionDepth: Int = 0) throws {
            for count in 1..<path.count {
                let address = TOMLAddress(scope: scope, path: Array(path.prefix(count)))
                if let node = nodes[address] {
                    guard node != .scalar, node != .arrayTable else { throw unsupportedTOML }
                    if dotted, count > sectionDepth, node != .dottedTable { throw unsupportedTOML }
                } else {
                    nodes[address] = dotted ? .dottedTable : .implicitTable
                }
            }
        }

        func entries() throws -> [(String, Value)] {
            try items.filter { $0.address.scope == 0 }.compactMap {
                guard let value = $0.value else { return nil }
                return (try displayedPath($0.address.path), value)
            }
        }
    }

    private static func readAllTOML(text: String) throws -> [(String, Value)] {
        try TOMLDocument(text).entries()
    }

    /// Change one value span (or insert/delete one line), then reparse before touching disk.
    private static func editTOML(text: String, key: String, value: Value?) throws -> String {
        let before = try TOMLDocument(text)
        let path = try tomlPath(key)
        let address = TOMLAddress(scope: 0, path: path)
        let target = before.items.first { $0.address == address }
        var lines = before.lines
        if let target {
            guard let originalValue = target.value else { throw unsupportedTOML }
            if let value {
                guard originalValue.sameType(as: value) else { throw unsupportedTOML }
                lines[target.line].replaceSubrange(target.valueRange, with: try renderedTOML(value))
            } else {
                lines.remove(at: target.line)
            }
        } else if let value {
            // Prefer the deepest existing table; otherwise insert a dotted assignment at the root.
            let table = before.tables.filter { path.starts(with: $0.path) && path.count > $0.path.count }
                .max { $0.path.count < $1.path.count }
            let start = table.map { $0.line + 1 } ?? 0
            let relative = Array(path.dropFirst(table?.path.count ?? 0))
            let newline = text.contains("\r\n") ? "\r" : ""
            lines.insert(try displayedPath(relative) + " = " + renderedTOML(value) + newline, at: start)
        } else {
            return text
        }
        let result = lines.joined(separator: "\n")
        let after = try TOMLDocument(result)
        var expected = Dictionary(uniqueKeysWithValues: before.items.map { ($0.address, $0.rawValue) })
        expected[address] = try value.map(renderedTOML)
        let actual = Dictionary(uniqueKeysWithValues: after.items.map { ($0.address, $0.rawValue) })
        guard expected == actual else { throw unsupportedTOML }
        // The one-span/one-line mutation above preserves every other byte. Check the surrounding lines too.
        if let target {
            let beforeOthers = before.lines.enumerated().filter { $0.offset != target.line }.map(\.element)
            let afterOthers = value == nil ? lines : lines.enumerated().filter { $0.offset != target.line }.map(\.element)
            guard beforeOthers == afterOthers else { throw unsupportedTOML }
        } else {
            var unchanged = lines
            let table = before.tables.filter { path.starts(with: $0.path) && path.count > $0.path.count }
                .max { $0.path.count < $1.path.count }
            unchanged.remove(at: table.map { $0.line + 1 } ?? 0)
            guard unchanged == before.lines else { throw unsupportedTOML }
        }
        return result
    }

    static func deleteTOML(text: String, key: String) throws -> String {
        try editTOML(text: text, key: key, value: nil)
    }
}
