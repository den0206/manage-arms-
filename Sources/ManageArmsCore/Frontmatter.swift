import Foundation

/// SKILL.md の frontmatter。一覧に必要なのは name と description だけ（DESIGN.md 9 章）。
public struct Frontmatter: Equatable, Sendable {
    public var name: String?
    public var description: String?
    /// Subagent の判定に使う。SKILL.md には無く、agent の .md にはある（DESIGN.md 6 章）。
    public var tools: String?
}

public enum FrontmatterResult: Equatable, Sendable {
    case parsed(Frontmatter)
    /// 先頭が `---` で始まっていない。
    case missing
    /// 読み取った範囲内に閉じ `---` が無い。4 KB しか読まない設計の副作用なので
    /// 「description 無し」と混同せず、UI では明示する（10.1）。
    case truncated
}

public enum FrontmatterParser {
    /// 先頭からこのバイト数だけ読む。DESIGN.md 9 章「frontmatter だけ読む」。
    public static let headBytes = 4096

    /// ファイルの先頭 4 KB だけを読む。本文はメモリに載せない。
    public static func read(_ url: URL) -> FrontmatterResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headBytes)) ?? Data()
        return parse(String(decoding: data, as: UTF8.self))
    }

    public static func parse(_ text: String) -> FrontmatterResult {
        // CRLF と BOM を先に潰す
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return .missing }
        lines.removeFirst()

        // 閉じ `---` を探す。本文中の `---` に引っかからないよう、行全体が `---` のものだけ。
        guard let end = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return .truncated }

        return .parsed(parseBody(Array(lines[..<end])))
    }

    static func parseBody(_ lines: [String]) -> Frontmatter {
        var result = Frontmatter()
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }

            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)

            // YAML ブロックスカラー（`>` `>-` `|` `|-`）。実在するスキルの大半がこの形式。
            if value.first == ">" || value.first == "|" {
                let fold = value.first == ">"
                var block: [String] = []
                while index < lines.count {
                    let next = lines[index]
                    if !next.isEmpty, !next.hasPrefix(" "), !next.hasPrefix("\t") { break }
                    block.append(next.trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                value = block.joined(separator: fold ? " " : "\n")
            } else {
                value = unquote(value)
            }

            switch key {
            case "name":        result.name = value.isEmpty ? nil : value
            case "description": result.description = value.isEmpty ? nil : value
            case "tools":       result.tools = value.isEmpty ? nil : value
            default:            break
            }
        }
        return result
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, let last = s.last,
              first == last, first == "\"" || first == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }
}
