import Foundation
import AgentToolCore

private let protocolVersion = "1"

struct Request: Decodable {
    var storagePath: String?
    var projectPath: String?
    var selector: Selector?
    var agent: String?
    var name: String?
    var scope: String?
    var server: MCPInput?
    var url: String?
    var kind: String?
    var undo: Undo?
    var sourcePath: String?
}

struct Selector: Decodable {
    let name: String
    let kind: String
    let scope: String
    let agent: String
    let sourcePath: String?
}

struct MCPInput: Decodable {
    let name: String
    let command: String?
    let args: [String]?
    let env: [String: String]?
    let url: String?
    let headers: [String: String]?

    func server() -> MCPServer? {
        if let url { return MCPServer(name: name, transport: .http(url: url, headers: headers ?? [:])) }
        guard let command else { return nil }
        return MCPServer(name: name, transport: .stdio(command: command, args: args ?? [], env: env ?? [:]))
    }
}

struct Undo: Decodable {
    let originalPath: String
    let trashedPath: String
    let registryEntry: Registry.Entry
}

func response(_ value: [String: Any]) {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value),
          let text = String(data: data, encoding: .utf8) else { return }
    print(text)
}

func environment(for request: Request) -> Environment {
    let support = request.storagePath.map { URL(filePath: $0) }
        ?? Environment.live.appSupport
    return Environment(
        home: URL(filePath: NSHomeDirectory()), appSupport: support,
        run: { try Exec.run($0, path: ShellPath.resolved) }, now: { Date() },
        httpGet: Environment.live.httpGet
    )
}

func selectorMatches(_ row: ResourceRow, _ selector: Selector) -> Bool {
    guard row.name == selector.name, row.kind.rawValue == selector.kind,
          (row.reach.isUserWide ? "user" : "project") == selector.scope else { return false }
    if let owner = row.ownerAgent { return owner.rawValue == selector.agent }
    if let agent = Agent(rawValue: selector.agent), case .explicit? = row.state[agent] { return true }
    return false
}

let command = CommandLine.arguments.dropFirst().first ?? "version"
let input = FileHandle.standardInput.readDataToEndOfFile()
let request = (try? JSONDecoder().decode(Request.self, from: input)) ?? Request()

switch command {
case "version":
    response(["ok": true, "protocolVersion": protocolVersion,
              "data": ["cliVersion": "0.1.0-alpha.1", "protocolVersion": protocolVersion]])
case "scan-path":
    let env = environment(for: request)
    let registry = Registry.load(env: env)
    let detections = Detector.detectAll(env: env, overrides: registry.cliOverrides)
    let agents = Agent.allCases.map { agent -> [String: Any] in
        let detection = detections[agent] ?? .undetected
        let found: Bool
        let path: String?
        let version: String?
        switch detection {
        case .detected(let v, let p): found = true; path = p; version = v
        default: found = false; path = nil; version = nil
        }
        return ["id": agent.rawValue, "displayName": agent.displayName,
                "found": found, "path": path as Any, "version": version as Any]
    }
    response(["ok": true, "protocolVersion": protocolVersion,
              "data": ["resolvedPath": ShellPath.resolved, "agents": agents]])
case "inventory":
    let env = environment(for: request)
    let inventory = Inventory.load(env: env)
    let items = inventory.rows.map { row -> [String: Any] in
        let agents = row.ownerAgent.map { [$0] } ?? Agent.allCases.filter { agent in
            if case .explicit? = row.state[agent] { return true }
            return false
        }
        let agent = agents.first
        let entry = inventory.registry.resources.first { $0.name == row.name && $0.kind == row.kind.rawValue }
        let hasUpdate: Bool
        if case .available = row.update { hasUpdate = true } else { hasUpdate = false }
        let origin: String
        switch row.origin {
        case .managed: origin = "managed"
        case .user: origin = "user"
        case .bundled: origin = "bundled"
        }
        return ["id": row.id, "name": row.name, "kind": row.kind.rawValue,
                "scope": row.reach.isUserWide ? "user" : "project",
                "agent": agent?.rawValue as Any, "agents": agents.map(\.rawValue), "enabled": !row.isDisabled,
                "summary": row.summary as Any, "detail": row.detail as Any,
                "sourcePath": row.roots.first as Any,
                "repoUrl": entry?.repo as Any, "sha": entry?.sha as Any,
                "origin": origin, "hasUpdate": hasUpdate, "lastUsed": row.lastUsed?.ISO8601Format() as Any]
    }
    response(["ok": true, "protocolVersion": protocolVersion,
              "data": ["items": items]])
case "toggle":
    guard let selector = request.selector else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "selector is required"]])
        exit(1)
    }
    let env = environment(for: request)
    let inventory = Inventory.load(env: env)
    let matches = inventory.rows.filter { selectorMatches($0, selector) }
    guard matches.count == 1, let row = matches.first else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "tool not found"]])
        exit(1)
    }
    guard row.isManaged else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_IN_REGISTRY", "message": "tool is not managed"]])
        exit(1)
    }
    do {
        try Inventory.toggle(row, env: env)
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["enabled": row.isDisabled]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "OPERATION_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "mcp-status":
    let inventory = Inventory.load(env: environment(for: request))
    let processes = ProcessScanner.snapshot(env: environment(for: request))
    let servers = inventory.mcpServers.flatMap { agent, configured in
        let running = ProcessScanner.running(configured, in: processes)
        return configured.map { server in
            let process = running[server.name]
            return ["name": server.name, "agent": agent.rawValue,
                    "running": process != nil, "pid": process?.pid as Any]
        }
    }
    response(["ok": true, "protocolVersion": protocolVersion,
              "data": ["servers": servers]])
case "mcp-add":
    guard let rawAgent = request.agent, let agent = Agent(rawValue: rawAgent),
          let server = request.server?.server() else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "agent and server are required"]])
        exit(1)
    }
    do {
        try MCPManager.add(server, to: agent, env: environment(for: request))
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["name": server.name, "agent": agent.rawValue]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        let code = error.localizedDescription.contains("exists") ? "ALREADY_EXISTS" : "OPERATION_FAILED"
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": code, "message": error.localizedDescription]])
        exit(1)
    }
case "mcp-remove":
    guard let rawAgent = request.agent, let agent = Agent(rawValue: rawAgent),
          let name = request.name else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "agent and name are required"]])
        exit(1)
    }
    do {
        let env = environment(for: request)
        if request.scope == "project", let project = request.projectPath {
            try MCPManager.removeProject(name, from: agent, project: project, env: env)
        } else {
            try MCPManager.remove(name, from: agent, env: env)
        }
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["removed": name]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "OPERATION_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "add":
    let kind = request.kind.flatMap(Kind.init(rawValue:)) ?? .skill
    guard let url = request.url, let source = GitHubURL.parse(url),
          kind == .skill || kind == .subagent,
          request.scope == nil || request.scope == "user" else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "a public GitHub Skill URL and user scope are required"]])
        exit(1)
    }
    do {
        let env = environment(for: request)
        let staging = try await Fetcher.stage(source)
        defer { staging.discard() }
        guard let candidate = staging.candidates.first(where: { $0.kind == kind }) else {
            response(["ok": false, "protocolVersion": protocolVersion,
                      "error": ["code": "NOT_FOUND", "message": "requested tool kind was not found"]])
            exit(1)
        }
        var registry = try Registry.read(env: env)
        try Installer.install(candidate, from: staging, env: env, registry: &registry)
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["name": candidate.name, "kind": candidate.kind.rawValue,
                            "installedPath": (candidate.kind == .subagent
                                ? env.agentStore.appending(path: candidate.name + ".md")
                                : env.skillStore.appending(path: candidate.name)).path,
                            "sha": staging.resolvedSHA as Any]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "FETCH_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "preview":
    guard let url = request.url, let source = GitHubURL.parse(url) else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "a public GitHub URL is required"]])
        exit(1)
    }
    do {
        let staging = try await Fetcher.stage(source)
        defer { staging.discard() }
        let hint = GitHubURL.skillHint(url)
        let candidates = staging.candidates.filter { hint == nil || $0.name == hint }.map { candidate in
            ["name": candidate.name, "kind": candidate.kind.rawValue,
             "installSelector": candidate.installSelector as Any,
             "description": candidate.description as Any]
        }
        response(["ok": true, "protocolVersion": protocolVersion, "data": ["candidates": candidates]])
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "FETCH_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "plugin-add":
    guard let name = request.name, let agentName = request.agent,
          let agent = Agent(rawValue: agentName) else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "plugin name and agent are required"]])
        exit(1)
    }
    do {
        try PluginManager.add(name, source: request.url ?? "", to: agent, env: environment(for: request))
        response(["ok": true, "protocolVersion": protocolVersion, "data": ["name": name]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "OPERATION_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "remove":
    guard let selector = request.selector else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_FOUND", "message": "selector is required"]])
        exit(1)
    }
    let env = environment(for: request)
    let inventory = Inventory.load(env: env)
    let matched = inventory.rows.filter { selectorMatches($0, selector) }
    guard matched.count == 1, let row = matched.first, row.isManaged,
          let entry = inventory.registry.entry(named: row.name, kind: row.kind) else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_IN_REGISTRY", "message": "managed tool not found"]])
        exit(1)
    }
    let original: URL
    switch row.kind {
    case .skill: original = (row.isDisabled ? env.disabledStore : env.skillStore).appending(path: row.name)
    case .subagent: original = (row.isDisabled ? env.disabledAgentStore : env.agentStore).appending(path: row.name + ".md")
    default:
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "NOT_IN_REGISTRY", "message": "tool kind cannot be removed"]])
        exit(1)
    }
    do {
        guard let trash = try Inventory.remove(row, env: env) else { throw SkillManager.Failure.notFound(row.name) }
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["undo": ["originalPath": original.path, "trashedPath": trash.path,
                                     "registryEntry": ["name": entry.name, "kind": entry.kind,
                                                       "repo": entry.repo as Any, "branch": entry.branch as Any,
                                                       "subdir": entry.subdir as Any, "sha": entry.sha as Any,
                                                       "pinned": entry.pinned, "disabled": entry.disabled]]]])
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "OPERATION_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
case "rollback":
    guard let undo = request.undo else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "ROLLBACK_FAILED", "message": "undo is required"]])
        exit(1)
    }
    do {
        let restored = try Inventory.restore(undo.registryEntry, from: URL(filePath: undo.trashedPath),
                                             originalPath: URL(filePath: undo.originalPath), env: environment(for: request))
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["restoredPath": restored.path]])
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "ROLLBACK_FAILED", "message": "rollback failed"]])
        exit(1)
    }
case "migrate":
    guard let sourcePath = request.sourcePath else {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "MIGRATION_CONFLICT", "message": "sourcePath is required"]])
        exit(1)
    }
    do {
        let env = environment(for: request)
        let count = try Migration.migrate(from: URL(filePath: sourcePath), env: env)
        response(["ok": true, "protocolVersion": protocolVersion,
                  "data": ["migratedEntries": count, "skipped": 0, "targetPath": env.registryFile.path]])
    } catch Migration.Failure.conflict {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "MIGRATION_CONFLICT", "message": "migration target already exists"]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion,
                  "error": ["code": "MIGRATION_CONFLICT", "message": "migration failed"]])
        exit(1)
    }
case "update-preview", "update-apply":
    guard let selector = request.selector, let kind = Kind(rawValue: selector.kind) else {
        response(["ok": false, "protocolVersion": protocolVersion, "error": ["code": "NOT_FOUND", "message": "selector is required"]])
        exit(1)
    }
    do {
        let env = environment(for: request)
        let registry = try Registry.read(env: env)
        guard let entry = registry.entry(named: selector.name, kind: kind) else { throw Updater.Failure.notManaged(selector.name) }
        let preview = try await Updater.preview(entry, env: env, registry: registry)
        defer { preview.discard() }
        if command == "update-preview" {
            let lines = preview.diff.map { line -> [String: String] in
                let kind: String
                switch line.kind { case .added: kind = "added"; case .removed: kind = "removed" }
                return ["kind": kind, "text": line.text]
            }
            response(["ok": true, "protocolVersion": protocolVersion, "data": ["currentSha": preview.oldSha as Any, "latestSha": preview.newSha as Any, "lines": lines]])
        } else {
            var latest = registry
            try Updater.apply(preview, env: env, registry: &latest)
            response(["ok": true, "protocolVersion": protocolVersion, "data": ["appliedSha": preview.newSha as Any]])
        }
    } catch let denial as WriteGuard.Denial {
        response(["ok": false, "protocolVersion": protocolVersion, "error": ["code": "WRITE_GUARD_DENIED", "message": denial.localizedDescription]])
        exit(1)
    } catch {
        response(["ok": false, "protocolVersion": protocolVersion, "error": ["code": "FETCH_FAILED", "message": error.localizedDescription]])
        exit(1)
    }
default:
    response(["ok": false, "protocolVersion": protocolVersion,
              "error": ["code": "NOT_FOUND", "message": "unknown command"]])
    exit(1)
}
