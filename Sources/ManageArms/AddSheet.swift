import SwiftUI
import ManageArmsCore

@MainActor
@Observable
final class AddModel {
    var text = ""
    var repo = ""
    var branch = ""
    var subdir = ""
    private(set) var staged: Staging?
    private(set) var isBusy = false
    var error: String?

    /// 入力欄は 1 つだけ。貼られた文字列を見て分岐する（DESIGN.md 6 章）。
    var interpretation: PasteInput { PasteInput.classify(text) }

    var source: GitHubSource? {
        guard case .github(let s) = interpretation else { return nil }
        return GitHubSource(repo: repo.isEmpty ? s.repo : repo,
                            branch: branch.isEmpty ? s.branch : branch,
                            subdir: subdir.isEmpty ? nil : subdir,
                            branchAmbiguous: s.branchAmbiguous)
    }

    /// 貼られた瞬間に編集可能なフォームへ流し込む。
    func syncFields() {
        guard case .github(let s) = interpretation else { return }
        repo = s.repo
        branch = s.branch ?? ""
        subdir = s.subdir ?? ""
    }

    /// **自動では入れない。** 取得して中身を見せるところまで（6 章）。
    func fetch() {
        guard let source, !isBusy else { return }
        discard()
        isBusy = true
        Task {
            do {
                staged = try await Fetcher.stage(source)
            } catch let failure {
                self.error = "\(failure)"
            }
            isBusy = false
        }
    }

    func install(_ candidate: Candidate, onDone: () -> Void) {
        guard let staged else { return }
        do {
            var registry = Registry.load(env: .live)
            try Installer.install(candidate, from: staged, env: .live, registry: &registry)
            onDone()
        } catch {
            self.error = "\(error)"
        }
    }

    func discard() {
        staged?.discard()
        staged = nil
    }
}

struct AddSheet: View {
    @Bindable var add: AddModel
    let onInstalled: () -> Void
    // ManageArmsCore.Environment と名前が衝突するので修飾する
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "スキル・サブエージェントを追加",
                        subtitle: String(localized: "確認するまで何も入りません"),
                        symbol: "plus.circle", tint: .accentColor)

            VStack(alignment: .leading, spacing: 6) {
                TextField("GitHub の URL / MCP の JSON / npx コマンドを貼り付け",
                          text: $add.text, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: add.text) { add.syncFields() }
                interpretation
            }

            if case .github = add.interpretation { form }

            Divider()
            result
            Spacer(minLength: 0)
        }
        .padding(20)
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .frame(width: 580, height: 480)
        .animation(Motion.pop, value: add.staged?.candidates.count ?? 0)
        .alert("失敗しました", isPresented: .init(get: { add.error != nil },
                                            set: { if !$0 { add.error = nil } })) {
            Button("OK") { add.error = nil }
        } message: { Text(add.error ?? "") }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if add.isBusy {
                    ProgressView().controlSize(.small)
                    Text("取得しています…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { add.discard(); dismiss() }
                Button(add.isBusy ? "取得中…" : "取得") { add.fetch() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(add.source == nil || add.isBusy)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var interpretation: some View {
        switch add.interpretation {
        case .github:
            Label("GitHub リポジトリとして解釈しました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .mcpJSON:
            Label("MCP の設定です。追加は claude mcp add で行います", systemImage: "terminal")
                .foregroundStyle(.orange).font(.caption)
        case .command:
            Label("MCP の起動コマンドです。追加は claude mcp add で行います", systemImage: "terminal")
                .foregroundStyle(.orange).font(.caption)
        case .unrecognized:
            Text(add.text.isEmpty ? " " : "解釈できませんでした")
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    /// 解釈結果は編集できる（6 章）。特にブランチ名に "/" を含む場合はここで直す。
    private var form: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("リポジトリ").font(.caption).foregroundStyle(.secondary)
                TextField("owner/name", text: $add.repo).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("ブランチ").font(.caption).foregroundStyle(.secondary)
                TextField("main", text: $add.branch).textFieldStyle(.roundedBorder)
            }
            GridRow {
                Text("サブディレクトリ").font(.caption).foregroundStyle(.secondary)
                TextField("（リポジトリ直下なら空）", text: $add.subdir)
                    .textFieldStyle(.roundedBorder)
            }
            if add.source?.branchAmbiguous == true {
                GridRow {
                    Text("")
                    Label("ブランチ名に「/」が含まれる場合、区切りが正しいか確認してください",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.radiusS))
    }

    @ViewBuilder
    private var result: some View {
        if add.isBusy {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("取得しています…") }
                .foregroundStyle(.secondary)
        } else if let staged = add.staged {
            Text("見つかった候補").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(staged.candidates, id: \.name) { candidate in
                        CandidateRow(candidate: candidate) {
                            add.install(candidate) { onInstalled() }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } else {
            Text("「取得」を押すと中身を確認できます。確認するまで何も入りません。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// 取得した候補 1 件。**押す前に、何がどこへ入るのかを 1 枚で見せる**（DESIGN.md 6 章）。
struct CandidateRow: View {
    let candidate: Candidate
    let install: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            KindIcon(kind: candidate.kind, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(.body.weight(.medium))
                Text(candidate.description ?? String(localized: "（説明なし）"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                // Skills は全エージェント一括（3.2）。導入先は選べない。
                Label(candidate.kind == .subagent ? "Claude Code / Cursor に導入されます"
                                                  : "Claude Code / Cursor / Codex に導入されます",
                      systemImage: "arrow.down.circle")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button("追加", action: install)
                .disabled(candidate.kind != .skill && candidate.kind != .subagent)
        }
        .padding(10)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.quinary),
                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusS)
                .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
        }
        .animation(Motion.gentle, value: hovering)
        .onHover { hovering = $0 }
    }
}
