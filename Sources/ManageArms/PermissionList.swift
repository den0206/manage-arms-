import SwiftUI
import ManageArmsCore

/// 権限画面。DESIGN.md 8 章 — `permissions.allow` の横断掃除。
struct PermissionList: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var filter: Filter = .disposable

    enum Filter: String, CaseIterable, Identifiable {
        case disposable, duplicated, all
        var id: String { rawValue }
        var title: String {
            switch self {
            case .disposable: String(localized: "使い捨て")
            case .duplicated: String(localized: "重複")
            case .all: String(localized: "すべて")
            }
        }
    }

    private var entries: [PermissionEntry] {
        let all = model.permissions
        switch filter {
        case .all: return all
        case .disposable: return all.filter(\.isMachineSpecific)
        case .duplicated:
            let dupes = Set(PermissionScanner.duplicates(all).keys)
            return all.filter { dupes.contains($0.value) }
        }
    }

    private var chosen: [PermissionEntry] { entries.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                ContentUnavailableView(
                    model.permissions.isEmpty ? "権限の設定が見つかりません" : "該当なし",
                    systemImage: "lock.open",
                    description: Text(filter == .disposable
                        ? "マシン固有のパスを含むエントリはありません"
                        : "条件に合うエントリはありません"))
            } else {
                List(entries, selection: $selection) { entry in
                    row(entry)
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).fixedSize()

            Button("表示中をすべて選択") { selection = Set(entries.map(\.id)) }
                .disabled(entries.isEmpty)
            Button("選択解除") { selection.removeAll() }
                .disabled(selection.isEmpty)
            Spacer()
            Button(role: .destructive) {
                model.removePermissions(chosen)
                selection.removeAll()
            } label: {
                Label("選択した \(chosen.count) 件を削除", systemImage: "trash")
            }
            .disabled(chosen.isEmpty || model.isEditingPermissions)
        }
        .padding(12)
    }

    private func row(_ entry: PermissionEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.bucket.rawValue)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(.quaternary, in: Capsule())
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.value).font(.system(.caption, design: .monospaced)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.scopeName).font(.caption2).foregroundStyle(.secondary)
                    if entry.isMachineSpecific {
                        Label("マシン固有", systemImage: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    if let count = model.duplicateCounts[entry.value] {
                        Text("\(count) プロジェクトに重複")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .tag(entry.id)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("\(model.permissions.count) 件中 \(entries.count) 件を表示")
            if model.isEditingPermissions { Text("削除中…") }
            Spacer()
            // 他人の設定ファイルを書き換える唯一の場所。戻せることを明示する（9 章）。
            Text("削除前の内容は Application Support にバックアップされます")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
