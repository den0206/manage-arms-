import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case added, removed }
    public let kind: Kind
    public let text: String
}

public struct TreeEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case file, directory }
    public let path: String
    public let kind: Kind
    public let size: Int
    public let fingerprint: UInt64
}

public struct UpdatePreview: Sendable {
    public let name: String
    public let oldSha: String?
    public let newSha: String?
    public let staging: Staging
    public let candidate: Candidate
    public let diff: [DiffLine]
    public let manifest: [TreeEntry]

    public init(name: String, oldSha: String?, newSha: String?, staging: Staging,
                candidate: Candidate, diff: [DiffLine], manifest: [TreeEntry]? = nil) {
        self.name = name
        self.oldSha = oldSha
        self.newSha = newSha
        self.staging = staging
        self.candidate = candidate
        self.diff = diff
        self.manifest = manifest ?? ((try? Updater.manifest(of: candidate.localURL)) ?? [])
    }

    public var hasChanges: Bool { !diff.isEmpty }
    public func discard() { staging.discard() }
}

public enum Updater {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notManaged(String)
        case pinned(String)
        case candidateMissing(String)
        case stagingUnavailable
        case candidateChanged
        case rollbackFailed(String)

        public var description: String {
            switch self {
            case .notManaged(let name):
                String(localized: "\(name) は取得元が分からないため更新できません")
            case .pinned(let name):
                String(localized: "\(name) は固定中です")
            case .candidateMissing(let name):
                String(localized: "取得したアーカイブに \(name) が見つかりません")
            case .stagingUnavailable:
                String(localized: "更新用の一時データは既に使用または破棄されています")
            case .candidateChanged:
                String(localized: "確認後に更新内容が変化したため適用を中止しました")
            case .rollbackFailed(let message):
                String(localized: "更新に失敗し、元の状態も完全には復元できませんでした: \(message)")
            }
        }
    }

    public static func preview(
        _ entry: Registry.Entry, env: Environment, registry: Registry
    ) async throws -> UpdatePreview {
        guard let repo = entry.repo else { throw Failure.notManaged(entry.name) }
        guard !entry.pinned else { throw Failure.pinned(entry.name) }
        let source = GitHubSource(repo: repo, branch: entry.branch, subdir: entry.subdir)
        let checkedSHA = registry.repos[UpdateChecker.repoKey(entry) ?? ""]?.latestSha
        let resolvedSHA: String
        if let checkedSHA { resolvedSHA = checkedSHA }
        else { resolvedSHA = try await UpdateChecker.resolve(source, env: env) }
        let staging = try await Fetcher.stage(source, resolvedSHA: resolvedSHA)
        guard let candidate = staging.candidates.first(where: {
            $0.name == entry.name && $0.kind.rawValue == entry.kind
        }) else {
            staging.discard()
            throw Failure.candidateMissing(entry.name)
        }
        let current = destination(for: entry, env: env)
        let oldManifest = (try? manifest(of: current)) ?? []
        let newManifest = try manifest(of: candidate.localURL)
        return UpdatePreview(name: entry.name, oldSha: entry.sha, newSha: resolvedSHA,
                             staging: staging, candidate: candidate,
                             diff: reviewDiff(oldRoot: current,
                                              newRoot: candidate.localURL,
                                              old: oldManifest, new: newManifest),
                             manifest: newManifest)
    }

    public static func apply(
        _ preview: UpdatePreview, env: Environment, registry: inout Registry
    ) throws {
        guard preview.staging.claimForApply() else { throw Failure.stagingUnavailable }
        var succeeded = false
        defer { if !succeeded { preview.staging.releaseAfterFailure() } }

        let fileManager = FileManager.default
        let originalRegistry = registry
        guard var entry = registry.entry(named: preview.name, kind: preview.candidate.kind) else {
            throw Failure.notManaged(preview.name)
        }
        let destination = destination(for: entry, env: env)
        guard !entry.pinned else { throw Failure.pinned(entry.name) }
        try WriteGuard.assertMutable(destination, env: env, registry: registry)
        try WriteGuard.assertSafeCreation(destination,
                                          inside: destination.deletingLastPathComponent(),
                                          anchor: env.home)
        guard try manifest(of: preview.candidate.localURL) == preview.manifest else {
            throw Failure.candidateChanged
        }
        try Fetcher.validate(preview.candidate, in: preview.staging)

        let transaction = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-update-\(UUID().uuidString)")
        let backup = transaction.appending(path: "previous")
        try fileManager.createDirectory(at: transaction, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: transaction) }
        let hadExisting = fileManager.fileExists(atPath: destination.path(percentEncoded: false))

        do {
            if hadExisting { try fileManager.moveItem(at: destination, to: backup) }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try fileManager.copyItem(at: preview.candidate.localURL, to: destination)
            entry.sha = preview.staging.resolvedSHA ?? preview.newSha
            registry = try Registry.update(env: env) { latest in
                guard var current = latest.entry(named: entry.name,
                                                 kind: preview.candidate.kind) else {
                    throw Failure.notManaged(entry.name)
                }
                guard !current.pinned else { throw Failure.pinned(entry.name) }
                current.sha = entry.sha
                latest.upsert(current)
            }
        } catch {
            registry = originalRegistry
            do {
                if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
                    try fileManager.removeItem(at: destination)
                }
                if hadExisting { try fileManager.moveItem(at: backup, to: destination) }
            } catch let rollbackError {
                throw Failure.rollbackFailed("\(error); \(rollbackError)")
            }
            throw error
        }
        succeeded = true
        preview.staging.finishApply()
    }

    private static func destination(for entry: Registry.Entry, env: Environment) -> URL {
        entry.kind == Kind.subagent.rawValue
            ? (entry.disabled ? env.disabledAgentStore : env.agentStore)
                .appending(path: "\(entry.name).md")
            : (entry.disabled ? env.disabledStore : env.skillStore).appending(path: entry.name)
    }

    static let diffTextLimit = 256 * 1024

    static func manifest(of root: URL) throws -> [TreeEntry] {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path(percentEncoded: false),
                                     isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue {
            return [try treeEntry(root, relativeTo: root.deletingLastPathComponent())]
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: keys,
                                                  options: [], errorHandler: { _, _ in false })
        else { return [] }
        return try walker.compactMap { value in
            guard let url = value as? URL else { return nil }
            return try treeEntry(url, relativeTo: root)
        }.sorted { $0.path < $1.path }
    }

    private static func treeEntry(_ url: URL, relativeTo root: URL) throws -> TreeEntry {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey,
                                                       .isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true,
              values.isRegularFile == true || values.isDirectory == true else {
            throw Fetcher.Failure.extractFailed(
                String(localized: "アーカイブに対応していない種類のファイルが含まれています"))
        }
        let base = root.standardized.path(percentEncoded: false)
        let path = url.standardized.path(percentEncoded: false)
        let relative = String(path.dropFirst(min(path.count, base.count)))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let kind: TreeEntry.Kind = values.isDirectory == true ? .directory : .file
        return TreeEntry(path: relative.isEmpty ? url.lastPathComponent : relative,
                         kind: kind, size: values.fileSize ?? 0,
                         fingerprint: kind == .file ? try fingerprint(url) : 0)
    }

    private static func fingerprint(_ url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash: UInt64 = 14_695_981_039_346_656_037
        while let data = try handle.read(upToCount: 64 * 1024), !data.isEmpty {
            for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        }
        return hash
    }

    static func treeDiff(old: [TreeEntry], new: [TreeEntry]) -> [DiffLine] {
        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: new.map { ($0.path, $0) })
        let paths = Set(oldByPath.keys).union(newByPath.keys).sorted()
        var result: [DiffLine] = []
        for path in paths {
            switch (oldByPath[path], newByPath[path]) {
            case (.none, let entry?):
                result.append(.init(kind: .added, text: "\(path) (\(entry.size) bytes)"))
            case (let entry?, .none):
                result.append(.init(kind: .removed, text: "\(path) (\(entry.size) bytes)"))
            case (let old?, let new?) where old != new:
                result.append(.init(kind: .removed, text: "\(path) (\(old.size) bytes)"))
                result.append(.init(kind: .added, text: "\(path) (\(new.size) bytes)"))
            default: break
            }
        }
        return result
    }

    static func reviewDiff(oldRoot: URL, newRoot: URL,
                           old: [TreeEntry], new: [TreeEntry]) -> [DiffLine] {
        let summary = treeDiff(old: old, new: new)
        let oldByPath = Dictionary(uniqueKeysWithValues: old.map { ($0.path, $0) })
        let newByPath = Dictionary(uniqueKeysWithValues: new.map { ($0.path, $0) })
        var details: [DiffLine] = []
        for path in Set(oldByPath.keys).intersection(newByPath.keys).sorted() {
            guard let before = oldByPath[path], let after = newByPath[path],
                  before != after, before.kind == .file, after.kind == .file,
                  before.size <= diffTextLimit, after.size <= diffTextLimit else { continue }
            let oldURL = fileURL(root: oldRoot, entry: before)
            let newURL = fileURL(root: newRoot, entry: after)
            guard let oldData = try? Data(contentsOf: oldURL),
                  let newData = try? Data(contentsOf: newURL),
                  String(data: oldData, encoding: .utf8) != nil,
                  String(data: newData, encoding: .utf8) != nil else { continue }
            details += diff(old: text(of: oldURL), new: text(of: newURL)).map {
                DiffLine(kind: $0.kind, text: "\(path): \($0.text)")
            }
        }
        return summary + details
    }

    private static func fileURL(root: URL, entry: TreeEntry) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return root.appending(path: entry.path)
        }
        return root
    }

    static func text(of url: URL) -> [String] {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) <= diffTextLimit,
              let data = try? Data(contentsOf: url) else { return [] }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func diff(old: [String], new: [String]) -> [DiffLine] {
        new.difference(from: old)
            .sorted { $0.offsetValue < $1.offsetValue }
            .map { change in
                switch change {
                case .insert(_, let text, _): DiffLine(kind: .added, text: text)
                case .remove(_, let text, _): DiffLine(kind: .removed, text: text)
                }
            }
    }
}

private extension CollectionDifference<String>.Change {
    var offsetValue: Int {
        switch self {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }
}
