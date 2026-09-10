import Foundation
import Synchronization
import Darwin

/// GUI アプリの `PATH` はターミナルと違う。 —
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

/// `Process` の薄いラッパ。出力はパイプを読み切って即破棄する（）。
public enum Exec {
    public static let outputLimit = 2 * 1024 * 1024
    public static let timeout: TimeInterval = 180
    /// プロセス終了後、パイプを読み切るのを待つ上限。
    /// **無期限には待たない** — 孫プロセスがパイプを握ったまま生き残ると EOF が来ない。
    static let drainTimeout: TimeInterval = 5
    public struct Failure: Error, CustomStringConvertible {
        public let command: [String]
        public let code: Int32
        public let stderr: String
        public var description: String {
            // 補間の中に文字列リテラルを置かない（検査スクリプトが文言を抽出できなくなる）。
            let safe = command.first.map { [$0] + MCPServer.redacted(Array(command.dropFirst())) } ?? []
            let head = safe.prefix(3).joined(separator: " ")
            return String(localized: "`\(head)` が終了コード \(Int(code)) で失敗: \(stderr)")
        }
    }

    public static func run(_ command: [String], path: String?, environment: [String: String]? = nil, directory: URL? = nil) throws -> String {
        guard let first = command.first else { return "" }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = command
        process.currentDirectoryURL = directory
        process.environment = environment ?? ProcessInfo.processInfo.environment
        if let path {
            var env = process.environment ?? [:]
            env["PATH"] = path
            process.environment = env
        }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let output = Mutex(Data()), errors = Mutex(Data())
        // **EOF を見たことを待てるようにする。** `readabilityHandler` は別キューで
        // 非同期に配送されるので、`waitUntilExit()` の直後にハンドラを外すと、
        // まだ配送されていない分がそのまま消える。`readDataToEndOfFile()` から
        // 差し替えたときに落ちた保証がこれで、実害は
        // `claude plugin list --json` の JSON が途中で切れて読めなくなること。
        // 空の chunk が EOF。そこでハンドラを外すので `leave` は 1 回しか走らない。
        let drained = DispatchGroup()
        drained.enter()
        drained.enter()
        out.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            output.withLock { data in
                if data.count < outputLimit {
                    data.append(chunk.prefix(outputLimit - data.count))
                }
            }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                drained.leave()
                return
            }
            errors.withLock { data in
                if data.count < outputLimit {
                    data.append(chunk.prefix(outputLimit - data.count))
                }
            }
        }
        // 子プロセスグループごと止める。`Process` は posix_spawn で子を独立した
        // プロセスグループに置くので、pid をそのままグループ ID として使える
        // （親から `setpgid` を呼んでも exec 済みで EACCES になり、意味が無い）。
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            Darwin.kill(-process.processIdentifier, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { Darwin.kill(-process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        process.waitUntilExit()
        // 終了を待っただけでは、パイプに残った分がまだ配送されていない。
        // 読み切り（EOF）まで待ってからハンドラを外す。上限を過ぎたら
        // 取れた分だけで進む — 出力を諦めることはあっても、ここで固まらない。
        _ = drained.wait(timeout: .now() + drainTimeout)
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        try? out.fileHandleForReading.close()
        try? err.fileHandleForReading.close()
        var stderr = String(decoding: errors.withLock { $0 }, as: UTF8.self)
        for secret in secrets(in: command) where !secret.isEmpty {
            stderr = stderr.replacingOccurrences(of: secret, with: "[redacted]")
        }
        stderr = stderr.replacing(#/(?i)Bearer\s+[^\s"']+/#, with: "Bearer [redacted]")
        guard process.terminationStatus == 0 else {
            throw Failure(command: command, code: process.terminationStatus,
                          stderr: stderr)
        }
        _ = first
        return String(decoding: output.withLock { $0 }, as: UTF8.self)
    }

    static func secrets(in command: [String]) -> Set<String> {
        let flags = Set(["-e", "--env", "-H", "--header", "--token", "--api-key",
                         "--apikey", "--secret", "--password", "--authorization"])
        var result: Set<String> = []
        for index in command.indices.dropFirst() where flags.contains(command[index - 1].lowercased()) {
            let value = command[index]
            result.insert(value)
            if let separator = value.firstIndex(where: { $0 == "=" || $0 == ":" }) {
                result.insert(String(value[value.index(after: separator)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        for argument in command {
            let lower = argument.lowercased()
            for flag in flags where lower.hasPrefix(flag + "=") {
                result.insert(String(argument.dropFirst(flag.count + 1)))
            }
        }
        return result
    }
}
