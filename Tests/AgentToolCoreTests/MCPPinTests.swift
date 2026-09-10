import Foundation
import Testing
@testable import AgentToolCore

///  — MCP に必要なのは更新機能ではなくピン留め管理。
@Suite("MCP のピン留め")
struct MCPPinTests {

    static func npx(_ name: String, _ args: [String]) -> MCPServer {
        MCPServer(name: name, transport: .stdio(command: "npx", args: args, env: [:]))
    }

    // MARK: - 置き換え（10.1 純粋関数）

    @Test("@latest を版に置き換える")
    func pinsLatest() throws {
        let server = Self.npx("chrome-devtools", ["-y", "chrome-devtools-mcp@latest"])
        let pinned = try #require(MCPPin.pinned(server, to: "1.8.0"))
        #expect(pinned.args == ["-y", "chrome-devtools-mcp@1.8.0"])
        #expect(pinned.name == "chrome-devtools")
        #expect(pinned.command == "npx")
        // 固定後は floating でなくなる = ボタンが消える
        #expect(pinned.floatingPackage == nil)
    }

    @Test("env は保たれる")
    func keepsEnv() throws {
        let server = MCPServer(name: "x", transport: .stdio(
            command: "npx", args: ["foo-mcp@latest"], env: ["TOKEN": "abc"]))
        #expect(try #require(MCPPin.pinned(server, to: "2.0.0")).env == ["TOKEN": "abc"])
    }

    @Test("コマンド側の @latest も置き換える")
    func pinsCommand() throws {
        let server = MCPServer(name: "x", transport: .stdio(
            command: "foo-mcp@latest", args: [], env: [:]))
        #expect(try #require(MCPPin.pinned(server, to: "3.1.0")).command == "foo-mcp@3.1.0")
    }

    @Test("固定済み・HTTP は対象外")
    func rejectsNonFloating() {
        #expect(MCPPin.pinned(Self.npx("x", ["-y", "foo-mcp@1.0.0"]), to: "2.0.0") == nil)
        #expect(MCPPin.pinned(Self.npx("x", ["-y", "foo-mcp"]), to: "2.0.0") == nil)
        #expect(MCPPin.pinned(
            MCPServer(name: "x", transport: .http(url: "https://e.com", headers: [:])),
            to: "2.0.0") == nil)
    }

    /// スコープ付きパッケージの先頭 `@` を壊さないこと。
    @Test("スコープ付きパッケージ")
    func scopedPackage() throws {
        let server = Self.npx("x", ["-y", "@acme/foo-mcp@latest"])
        #expect(try #require(MCPPin.pinned(server, to: "1.2.3")).args
                == ["-y", "@acme/foo-mcp@1.2.3"])
    }

    // MARK: - npm レジストリ（フェイクで実行。10.6 でネットワークは叩かない）

    static func env(status: Int, body: String) -> Environment {
        Environment.test(home: URL(filePath: "/tmp/fake-home"),
                         httpGet: { _, _ in
                             .init(body: Data(body.utf8), status: status, headers: [:])
                         })
    }

    @Test("最新版を読む")
    func readsVersion() async throws {
        let version = try await MCPPin.latestVersion(
            ofPackage: "chrome-devtools-mcp",
            env: Self.env(status: 200, body: #"{"name":"chrome-devtools-mcp","version":"1.8.0"}"#))
        #expect(version == "1.8.0")
    }

    @Test("404 / 壊れた JSON / version 欠落はエラーにする", arguments: [
        (404, #"{"error":"Not found"}"#),
        (200, "{"),
        (200, #"{"name":"x"}"#),
        (500, ""),
    ])
    func lookupFailures(_ testCase: (Int, String)) async {
        await #expect(throws: MCPPin.Failure.self) {
            try await MCPPin.latestVersion(ofPackage: "x",
                                           env: Self.env(status: testCase.0, body: testCase.1))
        }
    }

    /// スコープ付きは `/` を含む。URL でエスケープされること。
    @Test("スコープ付きパッケージ名で URL を組める")
    func scopedLookup() async throws {
        let version = try await MCPPin.latestVersion(
            ofPackage: "@acme/foo-mcp", env: Self.env(status: 200, body: #"{"version":"9.9.9"}"#))
        #expect(version == "9.9.9")
    }

    // MARK: - 登録し直し（10.4 CLI はフェイク）

    /// **失敗しても消えたままにしない。** remove は通り add が落ちる状況で、
    /// 元の定義が復活すること。ここを落とすと MCP が消える。
    @Test("登録に失敗したら元の定義に戻す")
    func rollsBackOnFailure() async throws {
        let calls = Recorder()
        let env = Environment.test(
            home: URL(filePath: "/tmp/fake-home"),
            run: { argv in
                calls.record(argv)
                // add のうち、固定版を入れようとした時だけ失敗させる
                if argv.contains("add"), argv.contains(where: { $0.contains("@1.8.0") }) {
                    throw Exec.Failure(command: argv, code: 1, stderr: "boom")
                }
                return ""
            },
            httpGet: { _, _ in .init(body: Data(#"{"version":"1.8.0"}"#.utf8),
                                     status: 200, headers: [:]) })

        let server = Self.npx("chrome-devtools", ["-y", "chrome-devtools-mcp@latest"])
        await #expect(throws: (any Error).self) {
            try await MCPPin.pin(server, in: [.claude], env: env)
        }
        // 最後に元の @latest を入れ直していること
        let last = try #require(calls.all.last)
        #expect(last.contains("add"))
        #expect(last.contains { $0.contains("@latest") })
    }

    @Test("成功時は固定版で登録し直す")
    func pinsThroughCLI() async throws {
        let calls = Recorder()
        let env = Environment.test(
            home: URL(filePath: "/tmp/fake-home"),
            run: { calls.record($0); return "" },
            httpGet: { _, _ in .init(body: Data(#"{"version":"1.8.0"}"#.utf8),
                                     status: 200, headers: [:]) })

        try await MCPPin.pin(Self.npx("chrome-devtools", ["-y", "chrome-devtools-mcp@latest"]),
                             in: [.claude], env: env)
        #expect(calls.all.count == 2)                     // remove → add
        #expect(calls.all[0].contains("remove"))
        #expect(calls.all[1].contains { $0 == "chrome-devtools-mcp@1.8.0" })
    }

    @Test("固定済みのサーバーは弾く")
    func rejectsAlreadyPinned() async {
        let env = Environment.test(home: URL(filePath: "/tmp/fake-home"))
        await #expect(throws: MCPPin.Failure.notFloating("x")) {
            try await MCPPin.pin(Self.npx("x", ["-y", "foo-mcp@1.0.0"]), in: [.claude], env: env)
        }
    }
}

/// `Environment.run` は `@Sendable` なのでクロージャ内から可変状態を触れない。
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func record(_ argv: [String]) { lock.withLock { calls.append(argv) } }
    var all: [[String]] { lock.withLock { calls } }
}
