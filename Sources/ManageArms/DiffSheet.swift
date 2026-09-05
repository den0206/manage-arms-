import SwiftUI
import ManageArmsCore

struct PreviewBox: Identifiable {
    let value: UpdatePreview
    var id: String { value.name }
}

/// DESIGN.md 7.4 — Skills の中身はプロンプト。黙って差し替えない。
struct DiffSheet: View {
    let preview: UpdatePreview
    let model: AppModel
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(preview.name) を更新").font(.title3.weight(.semibold))
            Text(versions).font(.caption).foregroundStyle(.secondary)

            Divider()
            if preview.hasChanges {
                Text("SKILL.md").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(preview.diff.enumerated()), id: \.offset) { _, line in
                            // verbatim: 差分の中身は SKILL.md の本文。翻訳対象ではないし、
                            // "%@ %@" というキーを作らせない。
                            Text(verbatim: "\(line.kind == .added ? "+" : "-") \(line.text)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(line.kind == .added ? Color.green : Color.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(8)
                }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            } else {
                ContentUnavailableView("内容に差分はありません", systemImage: "equal.circle")
            }

            HStack {
                Button("このバージョンで固定") {
                    model.discardPreview()
                    dismiss()
                }
                .help("上流が方針転換した時に更新を止めます")
                Spacer()
                Button("閉じる") { model.discardPreview(); dismiss() }
                Button("更新する") { model.applyPreview(); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!preview.hasChanges)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
    }

    private var versions: String {
        let old = preview.oldSha?.prefix(7) ?? "?"
        let new = preview.newSha?.prefix(7) ?? "?"
        return "\(old) → \(new)"
    }
}
