import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 3.1 / 10.4 — `claude mcp add-json` の生成コマンド。
/// **アプリからは書かない。** 貼られた JSON を組み立て直して見せて、
/// 実行は利用者の CLI に委ねる。組み立てが壊れると、コピーして貼っても動かない。
@Suite("MCP add-json 生成コマンド")
struct MCPAddJSONTests {

    @Test("mcpServers ラッパー付き：先頭の名前とサーバー定義を取り出す")
    func mcpServersWrapper() {
        let json = """
        {"mcpServers":{"chrome-devtools":{"command":"npx","args":["-y","chrome-devtools-mcp@latest"]}}}
        """
        let result = MCPCommand.addJSONCommand(json)
        #expect(result?.name == "chrome-devtools")
        // JSON はキー順で正規化されている。
        #expect(result?.command == #"claude mcp add-json chrome-devtools '{"args":["-y","chrome-devtools-mcp@latest"],"command":"npx"}'"#)
    }

    @Test("素のサーバー定義：override 名前が要る")
    func bareServer() {
        let json = #"{"command":"npx","args":["-y","supabase-mcp"]}"#
        // 名前が無ければ生成しない（行き止まりにしない代わりに UI で入力させる）。
        #expect(MCPCommand.addJSONCommand(json) == nil)
        let result = MCPCommand.addJSONCommand(json, name: "supabase")
        #expect(result?.name == "supabase")
        #expect(result?.command == #"claude mcp add-json supabase '{"args":["-y","supabase-mcp"],"command":"npx"}'"#)
    }

    @Test("override 名前は抽出名より優先する")
    func overrideBeatsExtracted() {
        let json = #"{"mcpServers":{"chrome-devtools":{"url":"https://example.com/mcp"}}}"#
        let result = MCPCommand.addJSONCommand(json, name: "custom-name")
        #expect(result?.name == "custom-name")
        #expect(result?.command == #"claude mcp add-json custom-name '{"url":"https://example.com/mcp"}'"#)
    }

    @Test("override 名前が空白のみなら抽出名に戻す")
    func blankOverrideFallsBack() {
        let json = #"{"mcpServers":{"foo":{"command":"foo-bin"}}}"#
        let result = MCPCommand.addJSONCommand(json, name: "   ")
        #expect(result?.name == "foo")
    }

    @Test("シングルクォートは '\\'' に置き換える")
    func singleQuoteEscape() {
        // 値の中の `'` を素のまま埋めると sh -c の 1 語がそこで閉じる。
        let json = #"{"mcpServers":{"weird":{"command":"echo","args":["it's"]}}}"#
        let result = MCPCommand.addJSONCommand(json)
        // JSON 側の `'` を、シングルクォートを一旦抜けて `\'` を挟み、また入り直す形
        // （`'\''` の 4 文字）に置換する。
        #expect(result?.command == #"claude mcp add-json weird '{"args":["it'\''s"],"command":"echo"}'"#)
    }

    @Test("名前に危険文字が入っていれば引用する")
    func nameNeedsQuoting() {
        // 実運用では起きないが、他ツールが書いた JSON を素で信じない。
        let json = #"{"mcpServers":{"has space":{"command":"foo"}}}"#
        let result = MCPCommand.addJSONCommand(json)
        #expect(result?.command.hasPrefix("claude mcp add-json 'has space' ") == true)
    }

    @Test("壊れた JSON は nil を返す")
    func brokenJSON() {
        #expect(MCPCommand.addJSONCommand("{not json") == nil)
        #expect(MCPCommand.addJSONCommand("") == nil)
        #expect(MCPCommand.addJSONCommand("null") == nil)
    }

    @Test("mcpServers が空のときは nil")
    func emptyServers() {
        #expect(MCPCommand.addJSONCommand(#"{"mcpServers":{}}"#) == nil)
    }

    @Test("HTTP transport も同じ経路で生成する")
    func httpTransport() {
        let json = #"{"mcpServers":{"remote":{"url":"https://api.example.com/mcp","headers":{"Authorization":"Bearer x"}}}}"#
        let result = MCPCommand.addJSONCommand(json)
        #expect(result?.name == "remote")
        // ヘッダも payload に含まれる。add-json は生 JSON を透過的に渡す。
        #expect(result?.command == #"claude mcp add-json remote '{"headers":{"Authorization":"Bearer x"},"url":"https://api.example.com/mcp"}'"#)
    }
}
