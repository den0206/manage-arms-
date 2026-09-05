import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 10.2 — 設計の生命線。
/// ここが破られると 3.4 / 3.5 / 9 の対策がすべて無意味になる。
/// 新しい `Source` を足した誰かが、このテストで止まる。
@Suite("走査範囲")
struct SourceTests {

    /// 踏むと数百 MB の I/O が走る、または触ってはいけない領域。
    static let forbidden = [
        "projects",           // ~/.claude/projects  129 MB / 145 セッション
        "sessions",           // ~/.codex/sessions    20 MB
        "logs_",              // ~/.codex/logs_2.sqlite 44 MB
        "file-history",       // ~/.claude/file-history 17 MB
        "cache",              // 再生成物。読む意味が無い
        "archived_sessions",
        "auth.json",          // 認証トークン（9 章の二重チェック）
        "oauth_creds.json",
    ]

    @Test("列挙が空でない")
    func notVacuous() {
        // 空だと以下のテストが素通りしてしまう
        #expect(Source.all.count >= 20)
    }

    @Test("禁止パスを 1 つも含まない")
    func noForbiddenPaths() {
        for source in Source.all {
            guard let path = source.relativePath else { continue }
            let lower = path.lowercased()
            for word in Self.forbidden {
                #expect(!lower.contains(word), "Source \(path) が禁止語 '\(word)' を含む")
            }
        }
    }

    @Test("解決後の絶対パスも禁止語を含まない")
    func resolvedPathsAreClean() {
        let env = Environment.test(home: URL(filePath: "/tmp/fake-home"))
        for source in Source.all {
            guard let url = source.url(in: env) else { continue }
            let lower = url.path(percentEncoded: false).lowercased()
            for word in Self.forbidden {
                #expect(!lower.contains(word), "\(url.path(percentEncoded: false)) が禁止語 '\(word)' を含む")
            }
        }
    }

    @Test("全 Source がホーム内かアプリ保存領域内に収まる")
    func staysInsideRoots() {
        let env = Environment.test(home: URL(filePath: "/tmp/fake-home"))
        for source in Source.all {
            guard let url = source.url(in: env) else { continue }
            let resolved = url.standardized.path(percentEncoded: false)
            let inHome = resolved.hasPrefix(env.home.standardized.path(percentEncoded: false))
            let inApp = resolved.hasPrefix(env.appSupport.standardized.path(percentEncoded: false))
            #expect(inHome || inApp, "\(resolved) がどちらのルートにも属さない")
        }
    }
}
