import Foundation
import Synchronization
import Darwin

/// 取得した中身の解釈結果。**自動では入れない。**
/// README からのコマンド抽出は必ず外すため、確認画面を挟む（DESIGN.md 6 章）。
public struct Candidate: Equatable, Sendable {
    public let kind: Kind
    public let name: String
    public let description: String?
    /// 一時ディレクトリ内の実体。`Staging.discard()` か install で片付く。
    public let localURL: URL
}

/// 一時展開の所有権。install するか discard するまで生きている。
public final class Staging: @unchecked Sendable {
    public let root: URL
    public let source: GitHubSource
    public let candidates: [Candidate]
    public let resolvedSHA: String?

    private let lock = NSLock()
    private var applying = false
    private var discarded = false

    public init(root: URL, source: GitHubSource, candidates: [Candidate],
                resolvedSHA: String? = nil) {
        self.root = root
        self.source = source
        self.candidates = candidates
        self.resolvedSHA = resolvedSHA
    }

    func claimForApply() -> Bool {
        lock.withLock {
            guard !applying, !discarded else { return false }
            applying = true
            return true
        }
    }

    func releaseAfterFailure() { lock.withLock { applying = false } }

    func finishApply() {
        let shouldRemove = lock.withLock {
            applying = false
            guard !discarded else { return false }
            discarded = true
            return true
        }
        if shouldRemove { try? FileManager.default.removeItem(at: root) }
    }

    /// 一時ディレクトリは `temporaryDirectory` 配下なので OS も回収するが、
    /// アプリが自前の掃除機能を持たなくて済むよう明示的に消す（9 章）。
    public func discard() {
        let shouldRemove = lock.withLock {
            guard !applying, !discarded else { return false }
            discarded = true
            return true
        }
        if shouldRemove { try? FileManager.default.removeItem(at: root) }
    }
}

public enum Fetcher {

    /// monorepo の zipball は subdir が 20 KB でも数百 MB になり得る（3.3）。
    public static let sizeLimit = 50 * 1024 * 1024

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooLarge(repo: String, bytes: Int)
        case downloadFailed(String)
        case extractFailed(String)
        case subdirNotFound(String)
        case nothingRecognized

        public var description: String {
            switch self {
            case .tooLarge(let repo, let bytes):
                String(localized: "\(repo) のアーカイブが大きすぎます（\(bytes / 1024 / 1024) MB、上限 50 MB）")
            case .downloadFailed(let m):
                String(localized: "ダウンロードに失敗しました: \(m)")
            case .extractFailed(let m):
                String(localized: "展開に失敗しました: \(m)")
            case .subdirNotFound(let p):
                String(localized: "\(p) がアーカイブ内に見つかりません")
            case .nothingRecognized:
                String(localized: "SKILL.md も plugin.json も見つかりません。対応していない形式です")
            }
        }
    }

    /// zip を落として展開し、中身から種別を判定する。`git clone` は使わない（3.3）。
    public static func stage(
        _ source: GitHubSource,
        defaultBranch: String = "main",
        resolvedSHA: String? = nil
    ) async throws -> Staging {
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "manage-arms-fetch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            let zip = root.appending(path: "archive.zip")
            try await download(source.archiveURL(defaultBranch: defaultBranch,
                                                 revision: resolvedSHA),
                               to: zip, repo: source.repo)
            let available = try? root.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            guard available == nil || available! >= Int64(extractedSizeLimit * 2) else {
                throw Failure.extractFailed(String(localized: "アーカイブを安全に展開する空き容量がありません"))
            }

            let unpacked = root.appending(path: "unpacked")
            try await extract(zip, to: unpacked)
            try? FileManager.default.removeItem(at: zip)   // zip 本体はもう要らない

            // zipball は `<repo>-<branch>/` を 1 段かぶせる
            let top = try singleTopLevel(of: unpacked)
            let base = source.subdir.map { top.appending(path: $0) } ?? top
            guard FileManager.default.fileExists(atPath: base.path(percentEncoded: false)) else {
                throw Failure.subdirNotFound(source.subdir ?? "/")
            }

            // ディレクトリ名由来の候補も含めて、最後にもう一度名前を検査する。
            // ここを通った名前だけが `Installer` でパスに使われる（9 章の作成方向）。
            let candidates = identify(base).filter { WriteGuard.isValidName($0.name) }
            guard !candidates.isEmpty else { throw Failure.nothingRecognized }
            return Staging(root: root, source: source, candidates: candidates,
                           resolvedSHA: resolvedSHA)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static let extractedSizeLimit = 200 * 1024 * 1024
    static let singleFileLimit = 20 * 1024 * 1024
    static let entryLimit = 10_000
    static let extractTimeLimit: TimeInterval = 30

    /// `strict` はこれから利用者のディレクトリへ入る木にだけ使う。アーカイブ全体の
    /// 走査では上限だけを見る — 取り出さない場所（リポジトリ直下の `AGENTS.md` が
    /// symlink 等）まで拒むと、subdir を指した取得まで巻き添えで失敗する。
    static func validateExtractedTree(_ root: URL, strict: Bool = true) throws {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in false }) else { return }
        var entries = 0
        var total = 0
        for case let url as URL in walker {
            entries += 1
            guard entries <= entryLimit else {
                throw Failure.extractFailed(String(localized: "展開したファイル数が上限を超えました"))
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            let unsupported = values.isSymbolicLink == true
                || !(values.isDirectory == true || values.isRegularFile == true)
            if unsupported {
                guard strict else { continue }   // 列挙は symlink を降りない
                throw Failure.extractFailed(values.isSymbolicLink == true
                    ? String(localized: "アーカイブにシンボリックリンクが含まれています")
                    : String(localized: "アーカイブに対応していない種類のファイルが含まれています"))
            }
            if values.isRegularFile == true {
                let size = values.fileSize ?? 0
                guard size <= singleFileLimit else {
                    throw Failure.extractFailed(String(localized: "展開したファイルが大きすぎます"))
                }
                total += size
                guard total <= extractedSizeLimit else {
                    throw Failure.extractFailed(String(localized: "展開後の合計サイズが上限を超えました"))
                }
            }
        }
    }

    static func validate(_ candidate: Candidate, in staging: Staging) throws {
        let stagedRoot = staging.root.resolvingSymlinksInPath().standardizedFileURL
        let local = candidate.localURL.resolvingSymlinksInPath().standardizedFileURL
        guard local.path == stagedRoot.path || WriteGuard.isInside(local, stagedRoot),
              !WriteGuard.isSymlink(candidate.localURL) else {
            throw Failure.extractFailed(String(localized: "取得物が一時領域の外を参照しています"))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.localURL.path,
                                             isDirectory: &isDirectory) else {
            throw Failure.extractFailed(String(localized: "取得物が見つかりません"))
        }
        if isDirectory.boolValue {
            try validateExtractedTree(candidate.localURL)
        } else {
            let values = try candidate.localURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  (values.fileSize ?? 0) <= singleFileLimit else {
                throw Failure.extractFailed(String(localized: "取得物のファイルが大きすぎるか、対応していない形式です"))
            }
        }
    }

    // MARK: - ダウンロード

    /// codeload は GET には `Content-Length` を返す（HEAD には返さないので
    /// `curl -I` では見えない）。実測では最初の進捗コールバックで全体サイズが判明し、
    /// **10 KB 書いた時点で中断**できる。返らない場合の保険として
    /// 書き込み量による中断も残してある（3.3）。
    ///
    /// ⚠️ completion handler 付きの `downloadTask` は
    /// デリゲートの進捗コールバックを無効化する。中断するには
    /// デリゲート駆動にして継続を自分で resume する必要がある。
    static func download(_ url: URL, to destination: URL, repo: String) async throws {
        let downloader = Downloader(limit: sizeLimit, destination: destination, repo: repo)
        // ephemeral: ディスクキャッシュを持たない（9 章「キャッシュディレクトリを持たない」）。
        let session = URLSession(configuration: .ephemeral, delegate: downloader,
                                 delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await downloader.run(session: session, url: url)
    }

    final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let limit: Int
        let destination: URL
        let repo: String

        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, any Error>?
        private var exceeded = false
        private var written = 0
        /// 判明していればアーカイブ全体のサイズ。エラー表示に使う。
        private var expectedTotal = 0
        private var stagingError: (any Error)?

        init(limit: Int, destination: URL, repo: String) {
            self.limit = limit; self.destination = destination; self.repo = repo
        }

        func run(session: URLSession, url: URL) async throws {
            let task = session.downloadTask(with: url)
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    lock.withLock { continuation = cont }
                    if Task.isCancelled { task.cancel() } else { task.resume() }
                }
            } onCancel: {
                task.cancel()
            }
        }

        private func finish(_ result: Result<Void, any Error>) {
            let cont = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                defer { continuation = nil }
                return continuation
            }
            cont?.resume(with: result)
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite expected: Int64) {
            let over = (expected > 0 && expected > Int64(limit)) || totalBytesWritten > Int64(limit)
            lock.withLock {
                written = Int(totalBytesWritten)
                if expected > 0 { expectedTotal = Int(expected) }
                if over { exceeded = true }
            }
            if over { downloadTask.cancel() }
        }

        /// 受け取った一時ファイルはこの関数を抜けると消えるので、ここで移す。
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    throw Failure.downloadFailed("HTTP \(http.statusCode)")
                }
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                lock.withLock { stagingError = error }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didCompleteWithError error: (any Error)?) {
            let (over, bytes, staged) = lock.withLock {
                (exceeded, max(expectedTotal, written), stagingError)
            }
            if over {
                finish(.failure(Failure.tooLarge(repo: repo, bytes: bytes)))
            } else if let staged {
                finish(.failure(staged))
            } else if let error {
                finish(.failure(Failure.downloadFailed(error.localizedDescription)))
            } else {
                finish(.success(()))
            }
        }
    }

    // MARK: - 展開

    /// Foundation に zip 展開 API は無い。ZIPFoundation 等の依存を足すより
    /// OS 同梱の `ditto` に任せる方がメモリにも載らず依存もゼロ（3.3）。
    /// Zip Slip 安全であることは spike #13 で実測済み。
    /// **`async` なのは待ち方のため。** 以前は `Thread.sleep` で回していたが、
    /// ここは nonisolated async の中（`stage` から呼ばれる）なので、
    /// グローバル executor のスレッドを最大 30 秒占有することになる。
    /// 協調スレッドプールはコア数程度しか無いので、塞ぐのではなく返す。
    static func extract(_ zip: URL, to destination: URL) async throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-xk", zip.path(percentEncoded: false),
                             destination.path(percentEncoded: false)]
        // **読まないパイプを渡さない。** バッファが埋まると子プロセスが書き込みで止まる。
        // かといって捨てると展開失敗の理由が出せなくなるので、`Exec.run` と同じく
        // 読み手を付けて上限まで溜める（`ditto -xk` は標準出力を使わない）。
        let err = Pipe()
        let message = Mutex(Data())
        // `Exec.run` と同じ理由で EOF を待てるようにする。終了を待っただけでは
        // 未配送分が残り、ハンドラを外した瞬間に消える（失敗理由が空になる）。
        let drained = DispatchGroup()
        drained.enter()
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            message.withLock { if $0.count < 4096 { $0.append(chunk.prefix(4096 - $0.count)) } }
        }
        defer {
            err.fileHandleForReading.readabilityHandler = nil
            try? err.fileHandleForReading.close()
        }
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(extractTimeLimit)
        var validationFailure: (any Error)?
        while process.isRunning {
            if Date() >= deadline {
                validationFailure = Failure.extractFailed(
                    String(localized: "アーカイブの展開が制限時間を超えました"))
                process.terminate()
                break
            }
            do { try validateExtractedTree(destination, strict: false) }
            catch { validationFailure = error; process.terminate(); break }
            // 1 秒間隔。この検査は展開ツリーを毎回歩くので、細かく回すと
            // 上限いっぱい（10,000 項目 × 30 秒）で数十万回の stat になる。
            // ディスクを埋めさせない役目は取得前の空き容量検査が担っている。
            do { try await Task.sleep(for: .seconds(1)) }
            catch {
                // **キャンセルは握り潰さない。** `try?` にすると待たずに回り続け、
                // 上限まで CPU を焼く。畳んで `ditto` を孤児にしない。
                validationFailure = error
                process.terminate()
                break
            }
        }
        if validationFailure != nil, process.isRunning {
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + Exec.drainTimeout)
        if let validationFailure { throw validationFailure }
        guard process.terminationStatus == 0 else {
            let reason = String(decoding: message.withLock { $0 }, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure.extractFailed(reason.isEmpty
                ? String(localized: "展開コマンドが失敗しました") : reason)
        }
        try validateExtractedTree(destination, strict: false)
    }

    /// zipball は `<repo>-<branch>/` を 1 段かぶせる。それを剥がす。
    static func singleTopLevel(of dir: URL) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(
            atPath: dir.path(percentEncoded: false)))?.filter { !$0.hasPrefix(".") } ?? []
        guard entries.count == 1 else { return dir }
        return dir.appending(path: entries[0])
    }

    // MARK: - 種別判定

    /// 取得した中身を見て決める。README のテキストからは推測しない（6 章）。
    ///
    /// **symlink は追わない。** `stage()` はアーカイブ全体を strict 検査しなくなった
    /// （取り出さない場所の symlink で導入ごと落とさないため）ので、frontmatter を
    /// 読む前にここで弾く。追うと取得先の細工 1 つで任意のローカルファイルの中身が
    /// 確認画面に出る。実体として入るものは `validate` が改めて strict 検査する。
    static func identify(_ base: URL) -> [Candidate] {
        guard !WriteGuard.isSymlink(base) else { return [] }
        let fm = FileManager.default
        func exists(_ path: String) -> Bool {
            let url = base.appending(path: path)
            return fm.fileExists(atPath: url.path(percentEncoded: false))
                && !WriteGuard.isSymlink(url)
        }

        // marketplace を兼ねたリポジトリは plugin.json と skills/ の両方を持つ。
        // どちらかで打ち切ると片方が選べなくなるので、併記して確認画面で選ばせる（6 章）。
        var found: [Candidate] = []
        if exists(".claude-plugin/plugin.json") {
            found.append(Candidate(kind: .plugin, name: base.lastPathComponent,
                                   description: nil, localURL: base))
        }
        if exists("SKILL.md") {
            let front = FrontmatterParser.read(base.appending(path: "SKILL.md"))
            guard case .parsed(let matter) = front else {
                return found + [Candidate(kind: .skill, name: base.lastPathComponent,
                                          description: nil, localURL: base)]
            }
            // **frontmatter の `name` は取得先が書いた文字列**で、こちらの管理下にない。
            // パス要素として使えない名前（`../` を含む等）はディレクトリ名に落とす。
            let declared = matter.name.flatMap { WriteGuard.isValidName($0) ? $0 : nil }
            return found + [Candidate(kind: .skill, name: declared ?? base.lastPathComponent,
                                      description: matter.description, localURL: base)]
        }

        // `.md` に frontmatter の `tools:` があれば Subagent（6 章）。
        let markdown = (try? fm.contentsOfDirectory(atPath: base.path(percentEncoded: false)))?
            .filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }.sorted() ?? []
        let subagents = markdown.compactMap { file -> Candidate? in
            let url = base.appending(path: file)
            guard !WriteGuard.isSymlink(url),
                  case .parsed(let matter) = FrontmatterParser.read(url), matter.tools != nil
            else { return nil }
            return Candidate(kind: .subagent, name: String(file.dropLast(3)),
                             description: matter.description, localURL: url)
        }
        if !subagents.isEmpty { return found + subagents }

        return found + skills(under: base, depth: 3)
    }

    /// リポジトリ直下を指された場合、スキルは何段か下に並んでいることがある。
    /// `skills/<name>`（vercel-labs/skills）だけでなく
    /// `skills/<category>/<name>`（mattpocock/skills）もあるので数段たどる。
    /// Subagent の判定は指されたディレクトリ直下だけで行う — 下層の `.md` まで
    /// frontmatter を読むと、ただの文書が候補に混ざる。
    static func skills(under base: URL, depth: Int) -> [Candidate] {
        guard depth > 0 else { return [] }
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: base.path(percentEncoded: false)))?
            .filter { !$0.hasPrefix(".") }.sorted() ?? []
        return children.flatMap { child -> [Candidate] in
            var isDir: ObjCBool = false
            let url = base.appending(path: child)
            // `fileExists(isDirectory:)` は symlink を追うので、単独では
            // リンクされた実ユーザーのディレクトリまで降りてしまう。
            guard fm.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir),
                  isDir.boolValue, !WriteGuard.isSymlink(url)
            else { return [] }
            if fm.fileExists(atPath: url.appending(path: "SKILL.md")
                                        .path(percentEncoded: false)) {
                return identify(url)
            }
            return skills(under: url, depth: depth - 1)
        }
    }
}
