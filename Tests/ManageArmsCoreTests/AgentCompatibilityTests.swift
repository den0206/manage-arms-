import Foundation
import Testing
@testable import ManageArmsCore

/// Opt-in live contract checks. Every subprocess gets an isolated home and working directory,
/// with no inherited credentials. This never uses Environment.live.
@Suite("AgentCompatibility", .disabled(if: ProcessInfo.processInfo.environment["COMPAT_AGENT"] == nil))
struct AgentCompatibilityTests {
    @Test("Installed CLI supports MCP round trip and plugin command contracts")
    func liveContract() throws {
        let agent = try #require(Agent(rawValue: ProcessInfo.processInfo.environment["COMPAT_AGENT"] ?? ""))
        let cli = try #require(agent.cliName)
        let home = FileManager.default.temporaryDirectory.appending(path: "agent-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let subprocessEnvironment = ["HOME": home.path, "PATH": path, "TMPDIR": home.path, "CI": "true", "NO_COLOR": "1"]
        let env = Environment.test(home: home, run: { argv in
            try Exec.run(argv, path: path, environment: subprocessEnvironment, directory: home)
        })
        let version = try env.run([cli, "--version"])
        print("Compatibility: \(agent.displayName) \(version.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(Detector.parseVersion(version) != nil)
        let probe = MCPServer(name: "manage-arms-compat-probe", transport: .stdio(
            command: "/usr/bin/true", args: ["--probe", "quoted value"], env: ["MANAGE_ARMS_PROBE": "isolated"]))
        try MCPManager.add(probe, to: agent, env: env)
        let registered = try #require(MCPScanner.read(agent, env: env).first { $0.name == probe.name })
        #expect(registered.command == probe.command)
        #expect(registered.args == probe.args)
        #expect(registered.env == probe.env)
        try MCPManager.remove(probe.name, from: agent, env: env)
        #expect(try !MCPScanner.read(agent, env: env).contains { $0.name == probe.name })
        let remote = MCPServer(name: "manage-arms-http-probe", transport: .http(
            url: "https://example.invalid/mcp", headers: agent == .codex ? [:] : ["X-Manage-Arms": "isolated"]))
        try MCPManager.add(remote, to: agent, env: env)
        #expect(try MCPScanner.read(agent, env: env).first { $0.name == remote.name }?.transport == remote.transport)
        try MCPManager.remove(remote.name, from: agent, env: env)
        if agent == .claude || agent == .codex {
            _ = try env.run([cli, "plugin", agent == .claude ? "install" : "add", "--help"])
            _ = try env.run([cli, "plugin", "remove", "--help"])
            _ = try PluginScanner.read(agent, env: env)
        }
    }
}
