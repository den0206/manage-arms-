import Foundation
import Testing
@testable import AgentToolCore

@Suite("ManageArms移行")
struct MigrationTests {
    @Test("旧registryと無効化中実体を新しい保存領域へ移す")
    func migrates() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: "agent-tool-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment.test(home: home)
        let source = home.appending(path: "Library/Application Support/ManageArms")
        try FileManager.default.createDirectory(at: source.appending(path: "disabled-agents"), withIntermediateDirectories: true)
        try "{\"resources\":[{\"name\":\"demo\",\"kind\":\"skill\"}],\"browserDetection\":true}"
            .write(to: source.appending(path: "registry.json"), atomically: true, encoding: .utf8)
        try "body".write(to: source.appending(path: "disabled-agents/demo.md"), atomically: true, encoding: .utf8)

        #expect(try Migration.migrate(from: source, env: env) == 1)
        #expect(Registry.load(env: env).entry(named: "demo", kind: .skill) != nil)
        #expect(FileManager.default.fileExists(atPath: env.disabledAgentStore.appending(path: "demo.md").path))
        #expect(FileManager.default.fileExists(atPath: source.appending(path: "registry.json").path))
    }

    @Test("移行先にregistryがある場合は上書きしない")
    func refusesConflict() throws {
        let home = URL(filePath: NSTemporaryDirectory()).appending(path: "agent-tool-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let env = Environment.test(home: home)
        let source = home.appending(path: "Library/Application Support/ManageArms")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "{}".write(to: source.appending(path: "registry.json"), atomically: true, encoding: .utf8)
        try Registry().save(env: env)
        #expect(throws: Migration.Failure.conflict) { try Migration.migrate(from: source, env: env) }
    }
}
