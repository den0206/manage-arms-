import Foundation

/// GUI アプリの `PATH` はターミナルと違う。DESIGN.md 3.7 —
/// launchd 起動時は `/usr/bin:/bin:/usr/sbin:/sbin` のみで、
/// `/opt/homebrew/bin` にある claude / codex / gemini は **1 つも見つからない**（実測）。
public enum ShellPath {

    /// 1 が失敗した場合の保険。よくあるインストール先。
    static let knownDirs = [
        "/opt/homebrew/bin", "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.bun/bin",
        NSHomeDirectory() + "/.volta/bin",
    ]

    /// プロセスが生きている間だけ保持する。永続化しない（ズレの原因になる）。
    public static let resolved: String = resolve()

    static func resolve() -> String {
        var dirs = loginShell().map { $0.split(separator: ":").map(String.init) } ?? []
        if dirs.isEmpty {
            dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").map(String.init)
        }
        // 保険は常に足す。ログインシェルが拾えても mise 等で漏れることがある。
        for dir in knownDirs where !dirs.contains(dir) {
            dirs.append(dir)
        }
        return dirs.joined(separator: ":")
    }

    /// `$SHELL -l -c 'echo $PATH'`。mise / asdf / nvm の shim もこれで拾える。
    static func loginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let out = try? Exec.run([shell, "-l", "-c", "echo $PATH"], path: nil) else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// `Process` の薄いラッパ。出力はパイプを読み切って即破棄する（DESIGN.md 3.5）。
public enum Exec {
    public struct Failure: Error, CustomStringConvertible {
        public let command: [String]
        public let code: Int32
        public let stderr: String
        public var description: String {
            "`\(command.joined(separator: " "))` が終了コード \(code) で失敗: \(stderr)"
        }
    }

    public static func run(_ command: [String], path: String?) throws -> String {
        guard let first = command.first else { return "" }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        if let path {
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            process.environment = env
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // 読み切ってから wait する。逆順だとパイプが埋まってデッドロックする。
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(command: command, code: process.terminationStatus,
                          stderr: String(decoding: errData, as: UTF8.self))
        }
        _ = first
        return String(decoding: outData, as: UTF8.self)
    }
}
