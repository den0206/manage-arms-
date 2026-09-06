import Foundation

/// `permissions.allow` の 1 エントリ。DESIGN.md 8 章。
public struct PermissionEntry: Identifiable, Equatable, Sendable {
    public enum Bucket: String, CaseIterable, Sendable { case allow, deny, ask }

    /// どのプロジェクトか。`nil` はユーザー全体（`~/.claude/settings.json`）。
    public let project: String?
    public let file: URL
    public let bucket: Bucket
    public let value: String
    /// マシン固有の絶対パスを含む = 他のマシンでも他のプロジェクトでも使えない。
    /// `Bash(git -C /Users/…/secondary-simulator log --oneline -15)` のような
    /// **二度と使わない使い捨て**がこれで拾える（実測 371 件中 22 件）。
    public let isMachineSpecific: Bool

    public var id: String { "\(file.path(percentEncoded: false))|\(bucket.rawValue)|\(value)" }
    /// **`String` を返すので SwiftUI は自動で引かない**（CLAUDE.md「ローカライズ」）。
    public var scopeName: String {
        project.map { ($0 as NSString).lastPathComponent } ?? String(localized: "ユーザー全体")
    }

    public init(project: String?, file: URL, bucket: Bucket, value: String,
                isMachineSpecific: Bool) {
        self.project = project; self.file = file; self.bucket = bucket
        self.value = value; self.isMachineSpecific = isMachineSpecific
    }
}

/// 各プロジェクトの `settings.local.json` に溜まった権限を横断で読む。
///
/// **`Source.all` には載せない。** プロジェクトのパスは動的で静的列挙にできないため、
/// `UsageScanner` と同じく専用の入り口にする（3.4 / 10.2）。
/// 読むのは `<proj>/.claude/settings.json` と `settings.local.json` の 2 つだけ。
public enum PermissionScanner {

    static let fileNames = ["settings.json", "settings.local.json"]

    public static func scan(env: Environment) -> [PermissionEntry] {
        scan(projects: ProjectScan.projectPaths(in: env), env: env)
    }

    public static func scan(projects: [String], env: Environment) -> [PermissionEntry] {
        var found = read(file: env.home.appending(path: ".claude/settings.json"),
                         project: nil, env: env)
        for path in projects {
            for name in fileNames {
                found += read(file: URL(filePath: path).appending(path: ".claude/\(name)"),
                              project: path, env: env)
            }
        }
        return found
    }

    static func read(file: URL, project: String?, env: Environment) -> [PermissionEntry] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let permissions = object["permissions"] as? [String: Any]
        else { return [] }                       // 無いのは正常（未設定）
        let home = env.home.standardized.path(percentEncoded: false)
        return PermissionEntry.Bucket.allCases.flatMap { bucket -> [PermissionEntry] in
            (permissions[bucket.rawValue] as? [String] ?? []).map {
                PermissionEntry(project: project, file: file, bucket: bucket, value: $0,
                                isMachineSpecific: $0.contains(home))
            }
        }
    }

    /// 複数プロジェクトに同じエントリがある = ユーザー全体に 1 つ置けば足りる。
    /// 5.2 の「散らかりの検出」と同じ問題の別の顔（実測: `WebSearch` が 7 プロジェクト）。
    public static func duplicates(_ entries: [PermissionEntry]) -> [String: [PermissionEntry]] {
        Dictionary(grouping: entries.filter { $0.project != nil }, by: \.value)
            .filter { $0.value.count > 1 }
    }
}
