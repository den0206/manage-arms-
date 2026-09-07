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

    private var added: Int { preview.diff.count { $0.kind == .added } }
    private var removed: Int { preview.diff.count { $0.kind != .added } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "\(preview.name) を更新", subtitle: versions)

            if preview.hasChanges {
                HStack(spacing: 6) {
                    Text("更新対象の全ファイル").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Pill(text: "+\(added)", tint: .green)
                    Pill(text: "−\(removed)", tint: .red)
                }
                diff
                if preview.detailsOmitted {
                    Text("大きな変更の本文は省略しています。ファイル単位の変更一覧はすべて表示しています。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("内容に差分はありません", systemImage: "equal.circle")
            }
        }
        .padding(20)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(width: 660, height: 500)
        .interactiveDismissDisabled(model.isMutating)
    }

    /// 差分は**行の色ではなく、行そのものの地色**で分ける。
    /// 記号（+ / −）だけだと、等幅でも折り返しの多い散文では追えない。
    private var diff: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(preview.diff.enumerated()), id: \.offset) { _, line in
                    let plus = line.kind == .added
                    HStack(alignment: .top, spacing: 8) {
                        Text(verbatim: plus ? "+" : "−")
                            .foregroundStyle(plus ? Color.green : Color.red)
                            .frame(width: 10, alignment: .leading)
                        // verbatim: 差分の中身は SKILL.md の本文。翻訳対象ではないし、
                        // "%@ %@" というキーを作らせない。
                        Text(verbatim: line.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(plus ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                }
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button("このバージョンで固定") {
                    model.pinPreview()
                }
                .disabled(model.isMutating)
                .help("上流が方針転換した時に更新を止めます")
                Spacer()
                Button("閉じる") { model.discardPreview(); dismiss() }
                    .disabled(model.isMutating)
                Button("更新する") { model.applyPreview() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isMutating)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(.bar)
    }

    private var versions: String {
        let old = preview.oldSha?.prefix(7) ?? "?"
        let new = preview.newSha?.prefix(7) ?? "?"
        return "\(old) → \(new)"
    }
}
