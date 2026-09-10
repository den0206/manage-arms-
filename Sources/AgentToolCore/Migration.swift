import Foundation

public enum Migration {
    public enum Failure: Error, Equatable { case sourceMissing, conflict }

    public static func migrate(from source: URL, env: Environment) throws -> Int {
        let expected = env.home.appending(path: "Library/Application Support/ManageArms").standardizedFileURL
        guard source.standardizedFileURL == expected,
              FileManager.default.fileExists(atPath: source.appending(path: "registry.json").path) else {
            throw Failure.sourceMissing
        }
        let fm = FileManager.default
        let targets = [env.registryFile, env.agentStore, env.disabledStore, env.disabledAgentStore]
        guard !targets.contains(where: { fm.fileExists(atPath: $0.path) }) else { throw Failure.conflict }
        let legacy = Environment(home: env.home, appSupport: source, run: env.run, now: env.now, httpGet: env.httpGet)
        let registry = try Registry.read(env: legacy)
        let stage = URL(filePath: NSTemporaryDirectory()).appending(path: "agent-tool-migration-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        var moved: [URL] = []
        var succeeded = false
        defer {
            if !succeeded {
                for target in moved where fm.fileExists(atPath: target.path) { try? fm.removeItem(at: target) }
            }
        }
        let copies = [("agents", env.agentStore), ("disabled-skills", env.disabledStore), ("disabled-agents", env.disabledAgentStore)]
        for (name, target) in copies where fm.fileExists(atPath: source.appending(path: name).path) {
            try fm.copyItem(at: source.appending(path: name), to: stage.appending(path: name))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: stage.appending(path: name), to: target)
            moved.append(target)
        }
        try registry.save(env: env)
        succeeded = true
        return registry.resources.count
    }
}
