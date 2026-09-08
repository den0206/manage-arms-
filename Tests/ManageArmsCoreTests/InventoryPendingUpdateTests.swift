import Foundation
import Testing
@testable import ManageArmsCore

/// DESIGN.md 7.6 — ホームとツールバーで共用する「更新がある行」の抽出。
@Suite("pendingUpdateRows")
struct InventoryPendingUpdateTests {

    private func row(_ name: String, update: UpdateStatus) -> ResourceRow {
        ResourceRow(name: name, kind: .skill, summary: nil, detail: "",
                    state: [:], origin: .managed, isDisabled: false, update: update)
    }

    @Test("available だけを拾い、pinned・unknown・upToDate は除く")
    func onlyAvailable() {
        let inv = Inventory(agents: [:], rows: [
            row("a", update: .available(sha: "abc")),
            row("b", update: .pinned(behind: true)),
            row("c", update: .upToDate),
            row("d", update: .unknown),
            row("e", update: .available(sha: "def")),
        ])
        let names = inv.pendingUpdateRows.map(\.name).sorted()
        #expect(names == ["a", "e"])
    }

    @Test("何も無ければ空")
    func empty() {
        let inv = Inventory(agents: [:], rows: [])
        #expect(inv.pendingUpdateRows.isEmpty)
    }
}
