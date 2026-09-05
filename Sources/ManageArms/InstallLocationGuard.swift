import AppKit
import ManageArmsCore

/// 起動時の設置場所ガード。DMG や外付けから直接起動していたら
/// `/Applications` への移動を促す（`InstallLocation.shouldPromptToMove`）。
///
/// OS を触る側なので、判定そのものは `ManageArmsCore.InstallLocationClassifier`
/// （純粋関数・テスト対象）に置き、ここはその前後だけを持つ。
enum InstallLocationGuard {

    enum Failure: Error {
        /// `/Applications` に同名バンドルが既にある。既存を壊さないため移動しない。
        case destinationExists
        case copyFailed
        case relaunchFailed
    }

    /// `applicationDidFinishLaunching` から 1 回だけ呼ぶ。
    @MainActor
    static func promptIfNeeded() {
        let bundle = Bundle.main.bundleURL
        guard location(of: bundle).shouldPromptToMove else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "アプリケーションフォルダに移動しますか？")
        alert.informativeText = String(localized:
            "いまの場所から起動したままだと、ディスクを取り出したときに ManageArms が使えなくなります。導入したスキルはそのまま残ります。")
        alert.addButton(withTitle: String(localized: "移動して再起動"))
        alert.addButton(withTitle: String(localized: "そのまま使う"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            let installed = try installIntoApplications(bundle)
            try relaunchAfterExit(at: installed)
            NSApp.terminate(nil)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = String(localized: "移動できませんでした")
            failure.informativeText = message(for: error)
            failure.addButton(withTitle: String(localized: "OK"))
            failure.runModal()
        }
    }

    // MARK: - 判定

    static func location(of bundleURL: URL) -> InstallLocation {
        let values = try? bundleURL.resourceValues(
            forKeys: [.volumeIsReadOnlyKey, .volumeIsRemovableKey]
        )
        return InstallLocationClassifier.classify(
            bundlePath: bundleURL.resolvingSymlinksInPath().path(percentEncoded: false),
            applicationsPaths: applicationsPaths(),
            volumeIsReadOnly: values?.volumeIsReadOnly ?? false,
            volumeIsRemovable: values?.volumeIsRemovable ?? false
        )
    }

    private static func applicationsPaths() -> [String] {
        ["/Applications"] + FileManager.default
            .urls(for: .applicationDirectory, in: .userDomainMask)
            .map { $0.resolvingSymlinksInPath().path(percentEncoded: false) }
    }

    // MARK: - 移動と再起動

    /// バンドルを `/Applications` へコピーし、コピー先を返す。**元は消さない** —
    /// DMG は読み取り専用で消せないし、外付けディスク上のユーザーのファイルを勝手に消さない。
    static func installIntoApplications(_ bundleURL: URL) throws -> URL {
        let destination = URL(filePath: "/Applications", directoryHint: .isDirectory)
            .appending(path: bundleURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
            throw Failure.destinationExists
        }
        // cp ではなく ditto。拡張属性とコード署名の完全性を保ったままバンドルを複製する。
        guard run("/usr/bin/ditto", [bundleURL.path(percentEncoded: false),
                                     destination.path(percentEncoded: false)]) == 0 else {
            // 中途半端なバンドルを /Applications に残さない。消すのは直前に自分が作ったものだけ。
            try? FileManager.default.removeItem(at: destination)
            throw Failure.copyFailed
        }
        // DMG 由来の quarantine を落とす。残すと移動後の初回起動でまた確認ダイアログが出る。
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine",
                                   destination.path(percentEncoded: false)])
        return destination
    }

    /// 自プロセスの終了を待ってからコピー先を起動し直すヘルパーを仕込む。
    /// 実際の終了は呼び出し側が行う（同一 bundle id が生きているうちに `open` しても、
    /// 既存インスタンスが前面に来るだけで新しい方は起動しない）。
    static func relaunchAfterExit(at installedURL: URL) throws {
        // パスはスクリプト本文に埋めず引数で渡す（$0 はスクリプト名の位置）。
        let script = """
        i=0
        while kill -0 "$1" 2>/dev/null; do
          sleep 0.2; i=$((i+1)); [ $i -gt 300 ] && break
        done
        /usr/bin/open "$2"
        """
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "relaunch",
                             String(ProcessInfo.processInfo.processIdentifier),
                             installedURL.path(percentEncoded: false)]
        do {
            // 親の終了後も launchd に引き取られて動き続ける（待たない）。
            try process.run()
        } catch {
            throw Failure.relaunchFailed
        }
    }

    private static func message(for error: Error) -> String {
        switch error {
        case Failure.destinationExists:
            String(localized: "アプリケーションフォルダに同じ名前のアプリが既にあります。そちらを起動してください。")
        default:
            String(localized: "アプリケーションフォルダへ手動でドラッグしてください。")
        }
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: launchPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
