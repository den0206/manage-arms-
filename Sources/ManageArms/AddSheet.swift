import SwiftUI
import ManageArmsCore

@MainActor
@Observable
final class AddModel {
    var text = ""
    var repo = ""
    var branch = ""
    var subdir = ""
    var kind: Kind = .skill
    var agent: Agent = .claude
    var name = ""
    var marketplace = ""
    var filter = ""
    private(set) var staged: Staging?
    private(set) var isBusy = false
    private var generation = UUID()
    var error: String?
    var interpretation: PasteInput { PasteInput.classify(text) }
    var source: GitHubSource? {
        guard case .github(let s) = interpretation else { return nil }
        return GitHubSource(repo: repo.isEmpty ? s.repo : repo,
                            branch: branch.isEmpty ? s.branch : branch,
                            subdir: subdir.isEmpty ? nil : subdir, branchAmbiguous: s.branchAmbiguous)
    }
    var servers: [MCPServer] { (try? PasteInput.mcpServers(text, name: name)) ?? [] }

    /// 一致が無ければ全件返す。絞り込みで行き止まりにしない。
    func visible(_ candidates: [Candidate]) -> [Candidate] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return candidates }
        let hit = candidates.filter { $0.name.lowercased().contains(query) }
        return hit.isEmpty ? candidates : hit
    }

    func syncFields() {
        discard()
        if case .github(let s) = interpretation {
            repo = s.repo; branch = s.branch ?? ""; subdir = s.subdir ?? ""
            // カタログ URL のスキル名は subdir にできないので、候補一覧の初期絞り込みに使う。
            filter = GitHubURL.skillHint(text) ?? ""
        } else if case .mcpJSON = interpretation { kind = .mcp }
        else if case .command = interpretation { kind = .mcp }
    }

    func fetch() {
        guard let source, !isBusy else { return }
        discard()
        let token = generation
        isBusy = true
        Task {
            do {
                // SHA を固定できれば固定する。ただし**レート制限で導入まで止めない** —
                // 未認証は 60 req/時（DESIGN.md 7.3）で、枯れているのは日常的に起きる。
                // 解決できなければブランチの zip を取り、sha は不明のままにする。
                let revision = try? await UpdateChecker.resolve(source, env: .live)
                let result = try await Fetcher.stage(source, resolvedSHA: revision)
                if token == generation { staged = result } else { result.discard() }
            } catch { if token == generation { self.error = "\(error)" } }
            isBusy = false
        }
    }

    func install(_ candidate: Candidate, onDone: @escaping () -> Void) {
        guard let staged, !isBusy else { return }
        isBusy = true
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    var registry = try Registry.read(env: .live)
                    try Installer.install(candidate, from: staged, env: .live,
                                          registry: &registry)
                    return nil
                } catch { return "\(error)" }
            }.value
            isBusy = false
            if let failure { error = failure } else { onDone() }
        }
    }

    func installConnection(onDone: @escaping () -> Void) {
        guard !isBusy else { return }
        let kind = kind, agent = agent, text = text, name = name, marketplace = marketplace
        isBusy = true
        Task {
            let failure = await Task.detached { () -> String? in
                do {
                    if kind == .mcp {
                        let servers = try PasteInput.mcpServers(text, name: name)
                        guard !servers.isEmpty else { throw MCPScanner.ReadFailure("MCPサーバーが見つかりません") }
                        let existing = try MCPScanner.read(agent, env: .live)
                        // Validate the whole input before starting; report partial success if a later CLI operation fails.
                        for server in servers {
                            try MCPManager.validate(server, for: agent)
                            if existing.contains(where: { $0.name == server.name }) { throw MCPManager.Failure.alreadyExists(server.name) }
                            if let command = server.command { _ = try Environment.live.run(["which", command]) }
                        }
                        var completed: [String] = []
                        for server in servers {
                            do { try MCPManager.add(server, to: agent, env: .live); completed.append(server.name) }
                            catch { throw MCPScanner.ReadFailure("追加済み：\(completed.joined(separator: "、"))。失敗：\(server.name)（\(String(describing: error))）") }
                        }
                        let installed = try MCPScanner.read(agent, env: .live)
                        guard servers.allSatisfy({ server in installed.contains { $0.name == server.name } }) else {
                            throw MCPScanner.ReadFailure("登録を確認できませんでした。一覧を更新してから再試行してください。")
                        }
                    } else {
                        try PluginManager.add(name, source: marketplace, to: agent, env: .live)
                    }
                    return nil
                } catch { return "\(error)" }
            }.value
            isBusy = false
            if let failure { error = failure } else { onDone() }
        }
    }

    func discard() {
        generation = UUID()
        staged?.discard(); staged = nil
    }
}

struct AddSheet: View {
    @Bindable var add: AddModel
    let onInstalled: () -> Void
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Toolを追加", subtitle: String(localized: "種類と追加先を確認してから追加します"))
            Picker("種類", selection: $add.kind) {
                Text("スキル・サブエージェント").tag(Kind.skill)
                Text("MCP接続").tag(Kind.mcp)
                Text("Plugin").tag(Kind.plugin)
            }.pickerStyle(.segmented).disabled(add.isBusy)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if add.kind == .skill {
                        Text("エージェントに手順や専門知識を追加します。共有先にも反映されます。")
                            .font(.callout).foregroundStyle(.secondary)
                        input
                        if add.source != nil {
                            DisclosureGroup("取得元の詳細") {
                                TextField("リポジトリ", text: $add.repo)
                                TextField("ブランチ", text: $add.branch)
                                TextField("サブディレクトリ", text: $add.subdir)
                            }.textFieldStyle(.roundedBorder)
                        }
                        if let staged = add.staged {
                            if staged.candidates.count > 1 {
                                TextField("候補を絞り込む", text: $add.filter)
                                    .textFieldStyle(.roundedBorder)
                            }
                            ForEach(Array(add.visible(staged.candidates).enumerated()), id: \.offset) { _, candidate in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(candidate.name).font(.headline)
                                        Text(candidate.description ?? "").font(.caption).lineLimit(3)
                                        if candidate.kind != .plugin {
                                            Text(candidate.kind == .subagent ? "Claude Code / Cursor に導入されます" : "Claude Code / Cursor / Codex に導入されます")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    Button(candidate.kind == .plugin ? "Pluginとして追加…" : "追加") {
                                        if candidate.kind == .plugin {
                                            add.name = candidate.name
                                            add.marketplace = "https://github.com/" + staged.source.repo
                                            add.kind = .plugin
                                            add.discard()
                                        } else { add.install(candidate, onDone: onInstalled) }
                                    }
                                }.padding(10).background(.quinary, in: RoundedRectangle(cornerRadius: 8))
                            }
                        } else if !add.text.isEmpty && add.source == nil {
                            Text("このURLからは取得元を決められません。配布元のGitHubのURLを貼り付けてください。")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("GitHubのURLを貼り付けて「内容を確認」を押してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("追加先", selection: $add.agent) {
                            ForEach(Agent.allCases.filter { add.kind == .mcp || [.claude, .codex].contains($0) }) { agent in
                                Text(agent.displayName).tag(agent)
                            }
                        }
                        Label("適用範囲：選択したエージェントのユーザー全体", systemImage: "person.crop.circle")
                            .font(.caption).foregroundStyle(.secondary)
                        if add.kind == .mcp {
                            Text("外部サービスやローカルツールへの接続を追加します。")
                                .font(.callout).foregroundStyle(.secondary)
                            TextField("接続名（JSONに名前がある場合は省略可）", text: $add.name)
                            input
                            Text("認証情報や環境変数が必要な場合は、配布元のMCP設定JSONを貼り付けてください。")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(add.servers, id: \.name) { server in
                                Label(server.name.isEmpty ? String(localized: "接続名を入力してください") : server.name,
                                      systemImage: "network")
                            }
                        } else {
                            Text("Pluginは配布元と名前を指定して追加します。")
                                .font(.callout).foregroundStyle(.secondary)
                            TextField("plugin@marketplace", text: $add.name)
                            TextField("配布元のHTTPS URL（登録済みなら省略可）", text: $add.marketplace)
                            Text("URLを指定すると配布元も登録されます。Plugin追加に失敗した場合も配布元の登録は残ります。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.textFieldStyle(.roundedBorder).disabled(add.isBusy)
            }
            Divider()
            HStack {
                if add.isBusy { ProgressView().controlSize(.small); Text("処理中…") }
                Spacer()
                Button("閉じる") { add.discard(); dismiss() }.disabled(add.isBusy)
                Button(add.kind == .skill ? "内容を確認" : "追加") {
                    if add.kind == .skill { add.fetch() } else { add.installConnection(onDone: onInstalled) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(add.isBusy || (add.kind == .skill && add.source == nil))
            }
        }
        .padding(20).frame(width: 620, height: 560)
        .interactiveDismissDisabled(add.isBusy)
        .onDisappear { add.discard() }
        .onChange(of: add.kind) { _, kind in
            if kind == .plugin && ![Agent.claude, .codex].contains(add.agent) { add.agent = .claude }
        }
        .alert("操作できませんでした", isPresented: .init(get: { add.error != nil }, set: { if !$0 { add.error = nil } })) {
            Button("OK") { add.error = nil }
        } message: { Text(add.error ?? "") }
    }

    private var input: some View {
        TextField(add.kind == .mcp ? "MCP設定JSON / HTTPS接続先 / 起動コマンド" : "GitHubのURL",
                  text: $add.text, axis: .vertical)
            .lineLimit(3...6).font(.system(.body, design: .monospaced))
            .onChange(of: add.text) { add.syncFields() }
    }
}
