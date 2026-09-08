import SwiftUI
import ManageArmsCore

/// 追加フロー（DESIGN.md 6 章 / 8 章）。**入力欄は 1 つだけ**にして、
/// 貼られた文字列で分岐する。**自動では入れない** — 取得して中身を見せてから、
/// 利用者が確定する。
///
/// v2.7 の再設計:
/// - URL の壊れは inline のエラー文で返す（alert にしない・入力欄を赤枠にしない）
/// - 取得中の段はスピナー+段名で表示（バイト量が分かる時だけ ProgressView(value:)）
/// - MCP JSON を貼られたら「生成コマンド」欄を出す。**行き止まりにしない**
///   — 貼るしかない状態から、コピーして貼れる状態へ 1 段だけ進める
/// - シート下部は [キャンセル] [追加] の順に置く（Esc=キャンセル / Enter=追加）

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
    /// MCP 生成コマンドの名前上書き（利用者が編集した値）。**空なら抽出名に戻す**。
    var mcpNameOverride: String = ""
    private(set) var staged: Staging?
    private(set) var isBusy = false
    /// いま何をしているか。**画面には段の名前を出す**（DESIGN.md 8 章の「押した結果が見える」）。
    private(set) var stage: Stage = .idle
    private var generation = UUID()
    /// 入力の壊れは alert にせず inline で見せる（DESIGN.md 8 章 v2.7）。
    var validationError: String?
    /// 導入エラーはこちらへ。**alert のまま残す** — 完了直後の操作なので、
    /// 画面遷移で消えると気づけない。
    var error: String?

    /// 進行段（DESIGN.md 6 章）。UI にそのまま出す語彙。
    enum Stage: Equatable, Sendable {
        case idle
        case fetching        // GitHub の zip を取得中
        case validating      // 中身を検査中
        case previewing      // 候補を見せている（`staged != nil` と対応）

        var localizedText: String? {
            switch self {
            case .idle:       nil
            case .fetching:   String(localized: "取得中…")
            case .validating: String(localized: "検証中…")
            case .previewing: String(localized: "プレビュー")
            }
        }
    }

    var interpretation: PasteInput { PasteInput.classify(text) }
    var source: GitHubSource? {
        guard case .github(let s) = interpretation else { return nil }
        return GitHubSource(repo: repo.isEmpty ? s.repo : repo,
                            branch: branch.isEmpty ? s.branch : branch,
                            subdir: subdir.isEmpty ? nil : subdir, branchAmbiguous: s.branchAmbiguous)
    }
    var servers: [MCPServer] { (try? PasteInput.mcpServers(text, name: name)) ?? [] }

    /// MCP の生成コマンド。**AddSheet が持たない** — 純粋関数（DESIGN.md 10.4）に集約。
    var mcpAddJSONCommand: MCPCommand.AddJSONCommand? {
        guard case .mcpJSON = interpretation else { return nil }
        return MCPCommand.addJSONCommand(text, name: mcpNameOverride)
    }

    /// URL 入力欄のインラインエラー（DESIGN.md 8 章 v2.7）。
    /// 空 or GitHub URL or MCP JSON なら nil。**「まだ何も入っていない」を赤くしない**。
    var urlInlineError: String? {
        guard kind == .skill else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // MCP JSON / コマンドは Skill タブでは間違いなので、そう伝える。
        switch interpretation {
        case .github:       return nil
        case .mcpJSON:      return String(localized: "これは MCP の設定です。「MCP接続」タブに切り替えてください。")
        case .command:      return String(localized: "これは起動コマンドです。「MCP接続」タブに切り替えてください。")
        case .unrecognized: return String(localized: "GitHub の URL として解釈できませんでした。")
        }
    }

    /// 追加（primary）ボタンを押していい状態か。Enter キーで反応する。
    var isPrimaryActionEnabled: Bool {
        guard !isBusy else { return false }
        switch kind {
        case .skill:  return source != nil && urlInlineError == nil
        case .mcp, .plugin, .subagent:
            // MCP / Plugin は入力の中身を CLI 側で検査するので、ここでは空欄でなければ通す。
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

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
        } else if case .mcpJSON = interpretation {
            kind = .mcp
            // 貼られた JSON から名前を先取りしておく（利用者が編集するときの初期値）。
            mcpNameOverride = MCPCommand.addJSONCommand(text)?.name ?? ""
        } else if case .command = interpretation {
            kind = .mcp
        }
    }

    func fetch() {
        guard let source, !isBusy else { return }
        discard()
        let token = generation
        isBusy = true
        stage = .fetching
        Task {
            do {
                // SHA を固定できれば固定する。ただし**レート制限で導入まで止めない** —
                // 未認証は 60 req/時（DESIGN.md 7.3）で、枯れているのは日常的に起きる。
                // 解決できなければブランチの zip を取り、sha は不明のままにする。
                let revision = try? await UpdateChecker.resolve(source, env: .live)
                if token == generation { stage = .validating }
                let result = try await Fetcher.stage(source, resolvedSHA: revision)
                if token == generation {
                    staged = result
                    stage = .previewing
                } else {
                    result.discard()
                }
            } catch {
                if token == generation {
                    self.error = "\(error)"
                    stage = .idle
                }
            }
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
        stage = .idle
    }

    /// シートを開く度に呼ぶ。**scope は必ず「ユーザー全体」に戻す**（DESIGN.md 8 章 v2.7）。
    /// エージェント選択もリセットして、前回の Plugin タブが残らないようにする。
    func resetForOpen() {
        agent = .claude
        validationError = nil
    }
}

struct AddSheet: View {
    @Bindable var add: AddModel
    let onInstalled: () -> Void
    @SwiftUI.Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "Toolを追加",
                        subtitle: String(localized: "種類と追加先を確認してから追加します"))
            Picker("種類", selection: $add.kind) {
                Text("スキル・サブエージェント").tag(Kind.skill)
                Text("MCP接続").tag(Kind.mcp)
                Text("Plugin").tag(Kind.plugin)
            }
            .pickerStyle(.segmented)
            .disabled(add.isBusy)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch add.kind {
                    case .skill:    skillBody
                    case .mcp:      mcpBody
                    case .plugin:   pluginBody
                    case .subagent: skillBody     // 使わない分岐だが switch を網羅する
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(add.isBusy && add.stage == .fetching)
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .interactiveDismissDisabled(add.isBusy)
        .onAppear { add.resetForOpen() }
        .onDisappear { add.discard() }
        .onChange(of: add.kind) { _, kind in
            if kind == .plugin && ![Agent.claude, .codex].contains(add.agent) { add.agent = .claude }
        }
        .alert("操作できませんでした",
               isPresented: .init(get: { add.error != nil },
                                  set: { if !$0 { add.error = nil } })) {
            Button("OK") { add.error = nil }
        } message: { Text(add.error ?? "") }
    }

    // MARK: - スキル / サブエージェントの本体

    @ViewBuilder
    private var skillBody: some View {
        Text("エージェントに手順や専門知識を追加します。共有先にも反映されます。")
            .font(.callout).foregroundStyle(.secondary)
        // 入力欄。**フォーカスリングと重ねて赤枠を出さない** — 通常のフィールドのまま、
        // 下にエラー文を 1 行だけ添える（DESIGN.md 8 章 v2.7）。
        TextField("GitHubのURL", text: $add.text, axis: .vertical)
            .lineLimit(3...6)
            .font(.system(.body, design: .monospaced))
            .onChange(of: add.text) { add.syncFields() }
            .onSubmit { if add.isPrimaryActionEnabled { add.fetch() } }
        if let error = add.urlInlineError {
            Text(verbatim: error)
                .font(.caption)
                .foregroundStyle(.red)
        }
        if add.source != nil {
            DisclosureGroup("取得元の詳細") {
                TextField("リポジトリ", text: $add.repo)
                TextField("ブランチ", text: $add.branch)
                TextField("サブディレクトリ", text: $add.subdir)
            }
        }
        // 段の名前を必ず見せる（DESIGN.md 8 章：押した結果が分かる）。
        if let stageText = add.stage.localizedText, add.stage != .previewing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(verbatim: stageText).font(.callout).foregroundStyle(.secondary)
            }
        }
        if let staged = add.staged {
            if staged.candidates.count > 1 {
                TextField("候補を絞り込む", text: $add.filter)
            }
            ForEach(Array(add.visible(staged.candidates).enumerated()), id: \.offset) { _, candidate in
                candidateRow(candidate, staged: staged)
            }
        } else if !add.text.isEmpty && add.source == nil && add.urlInlineError == nil {
            Text("このURLからは取得元を決められません。配布元のGitHubのURLを貼り付けてください。")
                .font(.caption).foregroundStyle(.orange)
        } else if add.staged == nil, add.stage == .idle {
            Text("GitHubのURLを貼り付けて「追加」を押してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func candidateRow(_ candidate: Candidate, staged: Staging) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).font(.headline)
                Text(candidate.description ?? "").font(.caption).lineLimit(3)
                // 導入先の**scope も併記**する（DESIGN.md 8 章 v2.7）— 既定は User。
                HStack(spacing: 6) {
                    if candidate.kind != .plugin {
                        Text(candidate.kind == .subagent
                             ? "Claude Code / Cursor に導入されます"
                             : "Claude Code / Cursor / Codex に導入されます")
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Pill(text: String(localized: "ユーザー全体"), icon: "person")
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
        }
        .padding(10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.radiusS))
    }

    // MARK: - MCP の本体

    @ViewBuilder
    private var mcpBody: some View {
        Picker("追加先", selection: $add.agent) {
            ForEach(Agent.allCases.filter { $0.supports(.mcp) }) { agent in
                Text(agent.displayName).tag(agent)
            }
        }
        // 「User 固定」であることを Pill で見せる。scope 選択の必要はない（DESIGN.md 5.1）。
        HStack(spacing: 6) {
            Pill(text: String(localized: "ユーザー全体"), icon: "person")
            Text("選択したエージェントの全プロジェクトに効きます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text("外部サービスやローカルツールへの接続を追加します。")
            .font(.callout).foregroundStyle(.secondary)
        TextField("接続名（JSONに名前がある場合は省略可）", text: $add.name)
        TextField("MCP設定JSON / HTTPS接続先 / 起動コマンド",
                  text: $add.text, axis: .vertical)
            .lineLimit(3...6).font(.system(.body, design: .monospaced))
            .onChange(of: add.text) { add.syncFields() }
        Text("認証情報や環境変数が必要な場合は、配布元のMCP設定JSONを貼り付けてください。")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(add.servers, id: \.name) { server in
            Label(server.name.isEmpty ? String(localized: "接続名を入力してください") : server.name,
                  systemImage: "network")
        }
        // 貼られたのが MCP JSON なら、生成コマンド欄を出して**行き止まりにしない**。
        // アプリからは書かず（不変条件 1）、`claude mcp add-json` をコピーさせる導線。
        if add.mcpAddJSONCommand != nil {
            MCPCommandPanel(add: add)
        }
    }

    // MARK: - Plugin の本体（既存挙動）

    @ViewBuilder
    private var pluginBody: some View {
        Picker("追加先", selection: $add.agent) {
            ForEach(Agent.allCases.filter { [Agent.claude, .codex].contains($0) }) { agent in
                Text(agent.displayName).tag(agent)
            }
        }
        HStack(spacing: 6) {
            Pill(text: String(localized: "ユーザー全体"), icon: "person")
        }
        Text("Pluginは配布元と名前を指定して追加します。")
            .font(.callout).foregroundStyle(.secondary)
        TextField("plugin@marketplace", text: $add.name)
        TextField("配布元のHTTPS URL（登録済みなら省略可）", text: $add.marketplace)
        Text("URLを指定すると配布元も登録されます。Plugin追加に失敗した場合も配布元の登録は残ります。")
            .font(.caption).foregroundStyle(.secondary)
    }

    // MARK: - 下部

    /// 下部は [キャンセル] [追加] の順（DESIGN.md 8 章 v2.7）。
    /// - Esc = キャンセル（`.cancelAction`）
    /// - Enter = 追加（`.defaultAction`）だが `isPrimaryActionEnabled` の時だけ
    private var footer: some View {
        HStack {
            if add.isBusy, let stage = add.stage.localizedText {
                ProgressView().controlSize(.small)
                Text(verbatim: stage).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("キャンセル") { add.discard(); dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(add.isBusy && add.stage == .fetching)
            Button("追加") { primaryAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!add.isPrimaryActionEnabled)
        }
    }

    private func primaryAction() {
        switch add.kind {
        case .skill:  add.fetch()
        case .mcp:    add.installConnection(onDone: onInstalled)
        case .plugin: add.installConnection(onDone: onInstalled)
        case .subagent: add.fetch()
        }
    }
}

/// 「生成コマンド」パネル。**AddSheet の中に閉じ込める** — MCP 追加の「行き止まり」を
/// 解くためだけの UI で、`claude mcp add-json` をコピーさせる。書き込みは行わない
/// （不変条件 1 — 書き込みは Registry / MCPScanner の 2 か所だけ）。
struct MCPCommandPanel: View {
    @Bindable var add: AddModel
    @State private var copied = false

    private var extractedName: String {
        // 生成そのものは pure（`MCPCommand.addJSONCommand`）。ここは表示だけ。
        add.mcpAddJSONCommand?.name ?? ""
    }

    private var command: String {
        add.mcpAddJSONCommand?.command ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("生成コマンド").font(.subheadline.weight(.semibold))
            Text("`~/.claude.json` は Claude Code が使うので、アプリからは書きません。以下をコピーして実行してください。")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("接続名").font(.caption).foregroundStyle(.secondary)
                TextField("接続名", text: $add.mcpNameOverride,
                          prompt: Text(verbatim: extractedName))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            HStack(alignment: .top, spacing: 8) {
                ScrollView(.horizontal) {
                    Text(verbatim: command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusS)
                        .strokeBorder(.separator, lineWidth: 1)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(Motion.reduced ? 1.0 : 1.2))
                        copied = false
                    }
                } label: {
                    Label(copied ? String(localized: "✓ コピーしました")
                                 : String(localized: "コピー"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(command.isEmpty)
                .animation(Motion.gentle, value: copied)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusM)
                .strokeBorder(.separator, lineWidth: 1)
        }
    }
}
