import Foundation
import Testing
@testable import ManageArmsCore

@Suite("Config editor")
struct ConfigWriterTests {
    private func read(_ text: String, format: ConfigWriter.Format = .toml) throws -> [(key: String, value: ConfigWriter.Value)] {
        let url = FileManager.default.temporaryDirectory.appending(path: "config-test-\(UUID().uuidString)")
        try Data(text.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try ConfigWriter.read(from: url, format: format).entries
    }

    @Test func sectionsNeverLeakIntoTopLevel() throws {
        let entries = try read("""
        model = "example"
        [projects."/tmp/a"]
        trust_level = "trusted"
        [projects."/tmp/b"]
        trust_level = "trusted"
        [[skills.config]]
        trusted_hash = "sha256:abc"
        enabled = true
        [sandbox_workspace_write]
        network_access = true # allowed
        [[other]]
        network_access = false
        """)
        #expect(entries.map(\.key) == ["model", "projects.\"/tmp/a\".trust_level", "projects.\"/tmp/b\".trust_level", "sandbox_workspace_write.network_access"])
        #expect(entries.last?.value == .bool(true))
    }

    @Test func stringRoundTripAndComments() throws {
        let source = Data("model = 'old' # keep\n[features]\nflag = true\n".utf8)
        let value = "a\\b\"c\nnext\t# literal"
        let result = try ConfigWriter.patch(data: source, key: "model", value: .string(value), format: .toml)
        let text = String(decoding: result, as: UTF8.self)
        #expect(text.contains("# keep"))
        #expect(try read(text).first?.value == .string(value))
        #expect(text.contains("[features]\nflag = true"))
    }

    @Test func arrayTableIsAnEditingBoundary() throws {
        let source = "[features]\nflag = true\n[[skills.config]]\nflag = false\n"
        let result = try ConfigWriter.patch(data: Data(source.utf8), key: "features.added", value: .bool(true), format: .toml)
        #expect(String(decoding: result, as: UTF8.self) == "[features]\nadded = true\nflag = true\n[[skills.config]]\nflag = false\n")
        #expect(try ConfigWriter.deleteTOML(text: source, key: "features.flag") == "[features]\n[[skills.config]]\nflag = false\n")
        #expect(try ConfigWriter.deleteTOML(text: source, key: "features.missing") == source)
    }

    @Test func JSONPreservesComplexSettings() throws {
        #expect(try read(#"{"hooks":{"enabled":true},"hooksEnabled":true}"#, format: .json).map(\.key) == ["hooksEnabled"])
        let hookSource = "hooksEnabled = true\n[hooks]\nenabled = true\n[hooks.options]\ncommand = 'example'\n"
        #expect(try read(hookSource).map(\.key) == ["hooksEnabled"])
        let hookResult = try ConfigWriter.patch(data: Data(hookSource.utf8), key: "hooksEnabled", value: .bool(false), format: .toml)
        #expect(String(decoding: hookResult, as: UTF8.self) == hookSource.replacingOccurrences(of: "hooksEnabled = true", with: "hooksEnabled = false"))
        let source = Data(#"{"permissions":{"allow":["Read"],"defaultMode":"default"},"hooks":{"Stop":[]},"newSetting":true}"#.utf8)
        let result = try ConfigWriter.patch(data: source, key: "permissions.defaultMode", value: .string("plan"), format: .json)
        let object = try #require(JSONSerialization.jsonObject(with: result) as? [String: Any])
        let permissions = try #require(object["permissions"] as? [String: Any])
        #expect(permissions["allow"] as? [String] == ["Read"])
        #expect(permissions["defaultMode"] as? String == "plan")
        #expect(object["hooks"] != nil)
        #expect(try read(String(decoding: result, as: UTF8.self), format: .json).contains(where: { $0.key == "newSetting" }))
        #expect(throws: ConfigWriter.Failure.self) {
            try ConfigWriter.patch(data: source, key: "permissions.allow", value: .string("oops"), format: .json)
        }
    }

    @Test func unsupportedValuesAndInvalidKeysAreNotOverwritten() throws {
        for key in ["bad\nkey", "a..b", "a = true", ""] {
            #expect(throws: ConfigWriter.Failure.self) {
                try ConfigWriter.patch(data: Data(), key: key, value: .bool(true), format: .toml)
            }
        }
        for source in ["model = 123", "model = [\"a\"]", "model = \"\"\"multi\nline\"\"\""] {
            #expect(throws: ConfigWriter.Failure.self) {
                try ConfigWriter.patch(data: Data(source.utf8), key: "model", value: .string("new"), format: .toml)
            }
        }
        for source in ["features = { flag = true }", "[[features]]\nflag = true"] {
            #expect(throws: ConfigWriter.Failure.self) {
                try ConfigWriter.patch(data: Data(source.utf8), key: "features.flag", value: .bool(false), format: .toml)
            }
        }
    }

    @Test func dottedNumbersPreserveSourceAndType() throws {
        let source = "# comment\r\n[features]\r\n  multi_agent_v2.min_wait_timeout_ms = 120000  # keep\r\nmulti_agent_v2.default_wait_timeout_ms = 120000\r\nratio = 1.25e-2\r\n"
        let entries = try read(source)
        #expect(entries.first?.key == "features.multi_agent_v2.min_wait_timeout_ms")
        #expect(entries.first?.value == .integer(120000))
        #expect(entries.last?.value == .decimal("1.25e-2"))
        let result = try ConfigWriter.patch(data: Data(source.utf8), key: entries[0].key, value: .integer(240000), format: .toml)
        #expect(String(decoding: result, as: UTF8.self) == source.replacingOccurrences(of: "= 120000  # keep", with: "= 240000  # keep"))
        #expect(throws: ConfigWriter.Failure.self) {
            try ConfigWriter.patch(data: result, key: entries[0].key, value: .string("240000"), format: .toml)
        }
        #expect(try ConfigWriter.deleteTOML(text: source, key: entries[0].key) == source.replacingOccurrences(of: "  multi_agent_v2.min_wait_timeout_ms = 120000  # keep\r\n", with: ""))
    }

    @Test func equivalentPathsAndQuotedDots() throws {
        for source in ["features.worker.timeout = 120000", "[features]\nworker.timeout = 120000", "[features.worker]\ntimeout = 120000"] {
            #expect(try read(source).first?.key == "features.worker.timeout")
            let result = try ConfigWriter.patch(data: Data(source.utf8), key: "features.worker.timeout", value: .integer(5), format: .toml)
            #expect(String(decoding: result, as: UTF8.self) == source.replacingOccurrences(of: "120000", with: "5"))
        }
        let source = "[projects.\"/tmp/a.b\"]\ntrust_level = 'trusted'\n[features]\n\"worker.timeout\" = 1\nworker.timeout = 2\n"
        let entries = try read(source)
        #expect(entries.map(\.key) == ["projects.\"/tmp/a.b\".trust_level", "features.\"worker.timeout\"", "features.worker.timeout"])
        let result = try ConfigWriter.patch(data: Data(source.utf8), key: "features.\"worker.timeout\"", value: .integer(3), format: .toml)
        #expect(String(decoding: result, as: UTF8.self) == source.replacingOccurrences(of: " = 1", with: " = 3"))
    }

    @Test func numbersRejectInvalidInputWithoutRounding() throws {
        #expect(try ConfigWriter.numberValue("9_223_372_036_854_775_807") == .integer(Int64.max))
        #expect(try ConfigWriter.numberValue("0.1234567890123456789") == .decimal("0.1234567890123456789"))
        for text in ["01", "1__0", "1_", "9223372036854775808", "1.0 # injected", "nan", "inf", "1e999", "1\nother = true"] {
            #expect(throws: ConfigWriter.Failure.self) { try ConfigWriter.numberValue(text) }
        }
    }

    @Test func documentValidationAndOpaqueContainers() throws {
        let source = "model = 'old'\nargs = ['--flag', [1, 2], { name = 'a', enabled = true }]\n"
        let result = try ConfigWriter.patch(data: Data(source.utf8), key: "model", value: .string("new"), format: .toml)
        #expect(String(decoding: result, as: UTF8.self).contains("args = ['--flag', [1, 2], { name = 'a', enabled = true }]"))
        for tail in ["x = 1\nx = 2", "x = 1\nx.y = 2", "[x]\n[x]", "x.y = 1\n[x]", "[x.y]\n[x]\ny.z = 1", "[[x]]\n[x]", "[x.y]\n[[x]]", "x = [\n1, 2\n]", "x = \"\"\"text\nmodel = 'bad'\n\"\"\"", "x = 00", "x = {a = 1, a = 2}", "x = [1,,2]"] {
            #expect(throws: ConfigWriter.Failure.self) {
                try ConfigWriter.patch(data: Data(("model = 'old'\n" + tail).utf8), key: "model", value: .string("new"), format: .toml)
            }
        }
        #expect(throws: ConfigWriter.Failure.self) {
            try ConfigWriter.patch(data: Data(source.utf8), key: "args.extra", value: .bool(true), format: .toml)
        }
    }

    @Test func referenceHintsUseFullKeys() {
        let codex = Agent.codex.configFields
        #expect(codex.contains(where: { $0.key == "sandbox_workspace_write.network_access" && $0.isBool }))
        #expect(!codex.contains(where: { $0.key == "network_access" }))
        #expect(codex.first(where: { $0.key == "model_reasoning_effort" })?.options.contains("xhigh") == true)
        #expect(Agent.claude.configFields.first(where: { $0.key == "permissions.defaultMode" })?.options.contains("default") == true)
        #expect(Set(codex.map(\.key)).count == codex.count)
    }
}
