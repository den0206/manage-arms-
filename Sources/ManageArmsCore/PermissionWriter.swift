import Foundation

/// `permissions` の削除だけを行う。DESIGN.md 8 章 / 9 章。
///
/// **これは 9 章のホワイトリスト（symlink と registry 記載の実体）の唯一の例外。**
/// `WriteGuard` は削除・移動を守るもので、ここは「ファイルの中の 1 キーを書き換える」
/// という別の操作なので、専用のガードを置く。許すのは次の全部を満たす場合だけ:
///
///   1. ファイル名が `settings.json` / `settings.local.json` に完全一致する
///   2. 場所が `~/.claude/` か `<project>/.claude/` の直下である
///   3. 操作が `permissions.<bucket>` の配列からの削除である
///
/// **`permissions` 以外のキーには一切触らない。** 実測で `enabledPlugins` /
/// `hooks` / `extraKnownMarketplaces` が同居しており、消すと別の設定が壊れる。
public enum PermissionWriter {

    public enum Denial: Error, Equatable, CustomStringConvertible {
        case notASettingsFile(String)
        case notInClaudeDir(String)

        public var description: String {
            switch self {
            case .notASettingsFile(let p):
                String(localized: "\(p) は権限設定ファイルではありません")
            case .notInClaudeDir(let p):
                String(localized: "\(p) は .claude ディレクトリの中にありません")
            }
        }
    }

    /// 書き換えてよいファイルか（名前と `.claude` 直下であること）。
    /// **通らなければ throw**。
    public static func assertWritable(_ file: URL) throws {
        let path = file.standardized.path(percentEncoded: false)
        guard PermissionScanner.fileNames.contains(file.lastPathComponent) else {
            throw Denial.notASettingsFile(path)
        }
        guard file.standardized.deletingLastPathComponent().lastPathComponent == ".claude" else {
            throw Denial.notInClaudeDir(path)
        }
    }

    /// 実際の書き込み経路で使う版。**`.claude` という名前のディレクトリは
    /// どこにでも作れる**ので、その親がホームか既知プロジェクトであることまで見る。
    /// 上のコメントが宣言していた条件 2「`~/.claude/` か `<project>/.claude/` の直下」は
    /// これで初めて満たされる。
    static func assertWritable(_ file: URL, under roots: [URL]) throws {
        try assertWritable(file)
        let base = file.standardized.deletingLastPathComponent().deletingLastPathComponent()
        guard roots.contains(where: {
            $0.standardizedFileURL.path == base.standardizedFileURL.path
        }) else {
            throw Denial.notInClaudeDir(file.standardized.path(percentEncoded: false))
        }
    }

    /// 指定したエントリを消す。ファイル単位にまとめて 1 回ずつ書く。
    public static func remove(_ entries: [PermissionEntry], env: Environment) throws {
        // 読んだ場所以外は書かない。`PermissionScanner` が走査するのと同じ集合。
        let roots = [env.home] + ProjectScan.projectPaths(in: env).map { URL(filePath: $0) }
        for (file, group) in Dictionary(grouping: entries, by: \.file) {
            try assertWritable(file, under: roots)
            try edit(file, env: env) { permissions in
                for bucket in PermissionEntry.Bucket.allCases {
                    let doomed = Set(group.filter { $0.bucket == bucket }.map(\.value))
                    guard !doomed.isEmpty else { continue }
                    guard let current = permissions[bucket.rawValue] as? [String] else { continue }
                    permissions[bucket.rawValue] = current.filter { !doomed.contains($0) }
                }
            }
        }
    }

    /// 読む → `permissions` だけ差し替える → バックアップを取ってアトミックに書く。
    /// `MCPManager.editCursor` と同じ形（3.1 で `mcpServers` 以外を触らないのと同じ）。
    static func edit(_ file: URL, env: Environment,
                     _ mutate: (inout [String: Any]) -> Void) throws {
        let data = try Data(contentsOf: file)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Denial.notASettingsFile(file.path(percentEncoded: false))
        }
        var permissions = root["permissions"] as? [String: Any] ?? [:]
        mutate(&permissions)
        root["permissions"] = permissions

        // 編集前の中身を残す。他人の設定ファイルを書き換える唯一の場所なので、
        // 戻せる状態にしてから書く（9 章）。
        try backup(data, of: file, env: env)
        let encoded = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try encoded.write(to: file, options: .atomic)
    }

    static let backupDirectory = "permission-backups"

    /// 設定ファイル 1 つあたりに残す世代数。
    ///
    /// **際限なく増やさない**（DESIGN.md 9 章 / CLAUDE.md「ストレージの規律」）。
    /// リソース管理アプリが自分でディスクを汚したら本末転倒で、以前はここが
    /// 編集のたびに 1 ファイル増え続け、消す導線も無かった。
    /// 目的は「直前の編集に戻せること」なので、数世代あれば足りる。
    static let generations = 5

    /// 区切りは `__`。**slug には `-` が入る**（パスの `/` を潰したもの）ので、
    /// `-` で区切ると同じ設定ファイルの世代をまとめられない。
    static let stampSeparator = "__"

    /// バックアップはアプリの保存領域に置く。**他人のディレクトリを汚さない。**
    /// `<proj>/.claude/settings.local.json.bak` を作ると git status に出てしまう。
    static func backup(_ data: Data, of file: URL, env: Environment) throws {
        let dir = env.appSupport.appending(path: backupDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: env.now())
            .replacingOccurrences(of: ":", with: "-")
        let slug = Self.slug(of: file)
        try data.write(to: dir.appending(path: "\(stamp)\(stampSeparator)\(slug)"),
                       options: .atomic)
        try prune(slug: slug, in: dir, env: env)
    }

    static func slug(of file: URL) -> String {
        file.standardized.path(percentEncoded: false)
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 同じ設定ファイルの古い世代を落とす。**消すのは自分が作ったものだけ** —
    /// `WriteGuard.assertAppBackup` を通してから消す（9 章）。
    ///
    /// 区切りを持たない名前は 0.1.0 が書いた旧形式なので**触らない**。
    /// 帰属を判定できないものを消すのは、このアプリが一番やってはいけないこと。
    static func prune(slug: String, in dir: URL, env: Environment) throws {
        let fm = FileManager.default
        let suffix = stampSeparator + slug
        let mine = ((try? fm.contentsOfDirectory(atPath: dir.path(percentEncoded: false))) ?? [])
            .filter { $0.hasSuffix(suffix) }
            .sorted()                                  // 先頭が ISO8601 なので辞書順 = 古い順
        guard mine.count > generations else { return }
        for name in mine.dropLast(generations) {
            let url = dir.appending(path: name)
            try WriteGuard.assertAppBackup(url, env: env)
            try fm.removeItem(at: url)
        }
    }
}
