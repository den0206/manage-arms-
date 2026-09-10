import Foundation

/// SKILL.md の frontmatter。一覧に必要なのは name と description だけ（）。
public struct Frontmatter: Equatable, Sendable {
    public var name: String?
    public var description: String?
    /// Subagent の判定に使う。SKILL.md には無く、agent の .md にはある（）。
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
    /// 先頭からこのバイト数だけ読む。「frontmatter だけ読む」。
    public static let headBytes = 4096

    /// ファイルの先頭 4 KB だけを読む。本文はメモリに載せない。
    public static func read(_ url: URL) -> FrontmatterResult {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missing }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: headBytes)) ?? Data()
        return parse(String(decoding: droppingPartialScalar(data), as: UTF8.self))
    }

    /// 末尾で切れた UTF-8 の断片を落とす。**日本語の description は 3 バイト**なので、
    /// 4 KB 境界が字の途中に落ちると `String(decoding:)` が U+FFFD を置き、
    /// 説明文の最後の 1 字が「�」になる。読めない断片は最初から渡さない。
    static func droppingPartialScalar(_ data: Data) -> Data {
        // 先頭バイトから続きの長さが決まる。継続バイトは 0b10xx_xxxx。
        var trailing = 0
        for byte in data.reversed() {
            if byte & 0b1100_0000 != 0b1000_0000 {
                let expected: Int
                switch byte {
                case 0x00...0x7F: expected = 1
                case 0xC0...0xDF: expected = 2
                case 0xE0...0xEF: expected = 3
                case 0xF0...0xF7: expected = 4
                default:          return data      // 不正なバイト列。触らず渡す
                }
                // 揃っていればそのまま、足りなければ末尾の断片を落とす。
                return trailing + 1 >= expected ? data : data.dropLast(trailing + 1)
            }
            trailing += 1
            if trailing > 3 { return data }        // 継続バイトが続きすぎ。触らない
        }
        return data
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
