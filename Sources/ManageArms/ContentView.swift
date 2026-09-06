import AppKit
import SwiftUI
import ManageArmsCore

/// サイドバーの選択（DESIGN.md 8 章）。
/// **エージェントごとに 1 画面**にする — 4 エージェント × 4 種別を 1 つの表に詰めると、
/// 初心者は「自分の Claude に何が入っているのか」を読み取れない。
enum Screen: Hashable {
    case home
    case agent(Agent)
    case permissions
    case settings
}

struct ContentView: View {
    let model: AppModel
    @State private var screen: Screen = .home
    @State private var add = AddModel()
    @State private var showAdd = false

    /// 何かしら走っている間は、トップの細い帯だけで知らせる（一覧は読めるまま）。
    private var busy: Bool {
        model.isLoading || model.isChecking || model.isAnalyzing || model.isCleaning
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                if let lead = model.watcher.pending {
                    BrowserLeadBanner(lead: lead,
                                      add: { model.watcher.accept(lead) },
                                      skip: { model.watcher.dismiss() })
                }
                if !model.inventory.issues.isEmpty {
                    DisclosureGroup("読み取りに失敗した項目があります") {
                        ForEach(model.inventory.issues, id: \.self) { Text($0).font(.caption).textSelection(.enabled) }
                    }.padding(12).background(.orange.opacity(0.1))
                }
                detail
            }
                .overlay(alignment: .top) { BusyBar(active: busy) }
        }
        .alert("操作できませんでした",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        // 検知の「追加する」から。URL を入れて取得まで済ませた状態で開く（6 章）。
        // **自動では入れない** — 候補一覧を見せてから利用者が選ぶ。
        // `onChange` ではなく `task(id:)` — メニューバーから開いた場合は
        // ウィンドウが出る前に値が入っており、変化として観測できない。
        // メニューバーや ⌘, から。設定を別ウィンドウにせず、この画面に切り替える。
        .task(id: model.pendingScreen) {
            guard let requested = model.pendingScreen else { return }
            screen = requested
            model.pendingScreen = nil
        }
        .task(id: model.incomingLead) {
            guard let lead = model.incomingLead else { return }
            add.text = lead.url
            add.syncFields()
            add.fetch()
            showAdd = true
            model.incomingLead = nil
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(add: add) {
                add.discard()
                showAdd = false
                model.reload()
            }
            .onAppear { if case .agent(let agent) = screen { add.agent = agent } }
        }
        .sheet(isPresented: .init(get: { model.cleanup != nil },
                                  set: { if !$0 { model.cleanup = nil } })) {
            CleanupSheet(items: model.cleanup ?? [], model: model)
        }
        .sheet(item: Binding(get: { model.preview.map { PreviewBox(value: $0) } },
                             set: { if $0 == nil { model.discardPreview() } })) { box in
            DiffSheet(preview: box.value, model: model)
        }
        .toolbar { toolbar }
        .disabled(model.isMutating)
        .task {
            model.reload()      // 常駐中に閉じている間は読まないので、開いたときに読む
            while !Task.isCancelled {
                if NSApp.windows.contains(where: { $0.isVisible && !$0.isMiniaturized }) { model.refreshActivity() }
                do { try await Task.sleep(for: .seconds(3)) } catch { break }
            }
        }
        // 常駐したまま閉じたときにメモリへ抱え続けない（DESIGN.md 3.5 / 9 章）。
        .onDisappear { model.releaseForBackground() }
    }

    private var sidebar: some View {
        List(selection: $screen) {
            Label("ホーム", systemImage: "house").tag(Screen.home)
            Section("エージェント") {
                // 管理対象から外したものは並べない。戻すのはホームの一覧から（3.7）。
                ForEach(Agent.allCases.filter { model.inventory.agents[$0] != .disabled }) { agent in
                    AgentSidebarRow(
                        agent: agent,
                        detection: model.inventory.agents[agent] ?? .undetected,
                        count: model.inventory.rows(for: agent).filter { $0.origin != .bundled }.count
                    )
                    .tag(Screen.agent(agent))
                }
            }
            Section("メンテナンス") {
                Label("権限", systemImage: "lock").tag(Screen.permissions)
                Label("設定", systemImage: "gearshape").tag(Screen.settings)
            }
        }
        .navigationSplitViewColumnWidth(min: 208, ideal: 228, max: 300)
        .safeAreaInset(edge: .bottom) { sidebarFooter }
    }

    /// 最後に何を読んだのか。**使用状況は明示的に集計する**（3.9）ので、
    /// 「まだ押していない」ことが分かる場所が要る。
    private var sidebarFooter: some View {
        usageFooter
            .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// ブラウザ検知の ON/OFF は設定画面（⌘,）に置く。ここには置かない — 同じ設定を
    /// 2 か所に出すと、片方だけ直したときに食い違う。
    private var usageFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
            if let at = model.inventory.usageScannedAt {
                Text("使用状況 \(at.formatted(.relative(presentation: .numeric)))")
            } else {
                Text("使用状況は未集計")
            }
            Spacer(minLength: 0)
        }
        .help("起動状態はウィンドウ表示中に3秒ごとに確認します。Tool呼び出し中を示すものではありません。")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    @ViewBuilder
    private var detail: some View {
        switch screen {
        case .home:
            HomeView(model: model, add: add, showAdd: $showAdd, screen: $screen)
        case .agent(let agent):
            AgentPage(agent: agent, model: model, showAdd: $showAdd)
        case .permissions:
            PermissionList(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showAdd = true } label: { Label("追加", systemImage: "plus") }
                .help("スキル・MCP・Pluginを追加します")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.analyzeUsage()
            } label: {
                Label(model.isAnalyzing ? "分析中…" : "使用状況を分析",
                      systemImage: "clock.arrow.circlepath")
                    .symbolEffect(.pulse, isActive: model.isAnalyzing && !Motion.reduced)
            }
            .disabled(model.isAnalyzing)
            .help(model.inventory.usageScannedAt.map {
                String(localized: "前回: \($0.formatted(date: .abbreviated, time: .shortened))")
            } ?? String(localized: "セッションログから最終使用日を集計します（初回は数秒かかります）"))
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                model.checkUpdates()
            } label: {
                Label(model.isChecking ? "確認中…" : "更新を確認",
                      systemImage: "arrow.triangle.2.circlepath")
                    .symbolEffect(.rotate, isActive: model.isChecking && !Motion.reduced)
            }
            .disabled(model.isChecking)
        }
        ToolbarItem(placement: .primaryAction) {
            // 明示的な再読み込みは CLI の間引き（DESIGN.md 3.5）も飛ばす。
            // 押したのに変わらないなら、このボタンは何のためにあるのか分からない。
            Button { model.reload(forceCLI: true) } label: {
                Image(systemName: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.isLoading && !Motion.reduced)
            }
            .help("再読み込み")
            .disabled(model.isLoading)
        }
    }
}

struct AgentSidebarRow: View {
    let agent: Agent
    let detection: Detection
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.displayName).lineLimit(1)
            Spacer(minLength: 4)
            if !detection.isActive {
                StatusDot(detection: detection)
            } else if count > 0 {
                Text(count.formatted())
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(Motion.count, value: count)
                    .foregroundStyle(.secondary)
            } else {
                StatusDot(detection: detection)
            }
        }
        .opacity(detection.isActive ? 1 : 0.55)
        .animation(Motion.gentle, value: detection)
    }
}

// MARK: - ホーム（追加の入口・DESIGN.md 6 章 / 8 章）

struct HomeView: View {
    let model: AppModel
    @Bindable var add: AddModel
    @Binding var showAdd: Bool
    @Binding var screen: Screen

    /// 自分で入れたもの全部（このアプリ経由に限らない）。同梱は数えない。
    private var mine: [ResourceRow] { model.inventory.rows.filter { $0.origin != .bundled } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.block) {
                hero
                addCard
                summary
                agentList
            }
            .padding(28)
            .frame(maxWidth: Theme.readable, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("ホーム")
    }

    /// 表紙。**ロゴを大きく飾らない** — ここで要るのは「何ができるアプリか」の 1 行だけ。
    private var hero: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 26, height: 26)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "ManageArms").font(.title2.weight(.semibold))
                Text("AI エージェントが持っているスキルを、ここでまとめて追加・削除できます。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 貼って押すだけ。**取得して中身を見せるまで何も入らない**（6 章）。
    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("スキル・サブエージェントを追加する").font(.headline)
            Text("使いたいスキルの GitHub ページを開き、その URL をそのまま貼り付けてください。")
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("https://github.com/owner/repo/tree/main/skills/foo", text: $add.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { openAdd() }
                Button("追加") { openAdd() }
                    .buttonStyle(.borderedProminent)
                    .disabled(add.text.isEmpty)
            }
            // 貼った瞬間に「何として読んだか」を返す。シートを開く前に間違いに気づける（6 章）。
            if !add.text.isEmpty {
                interpretation
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // **貼る URL の入手先は、貼る場所と同じ箱に置く。**
            // 「どうやって入れるのか分からない」が最大の詰まり所（6 章）なので、
            // 探し先まで含めて 1 か所で完結させる。節に切り出すと追加導線から離れる。
            HStack(spacing: 6) {
                Text("探す:")
                Link(destination: URL(string: "https://github.com/anthropics/skills")!) {
                    Text(verbatim: "anthropics/skills")
                }
                Text(verbatim: "·")
                Link(destination: URL(string: "https://github.com/topics/claude-skills")!) {
                    Text(verbatim: "github.com/topics/claude-skills")
                }
            }
            .font(.caption)
            Text("中身を確認するまで何も入りません。追加したものは Claude Code / Cursor / Codex の全部から使えます。")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .card()
        .animation(Motion.pop, value: add.text.isEmpty)
    }

    @ViewBuilder
    private var interpretation: some View {
        switch add.interpretation {
        case .github:
            Label("GitHub リポジトリとして解釈しました", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        case .mcpJSON, .command:
            Label("MCP の設定です。追加は claude mcp add で行います", systemImage: "terminal")
                .foregroundStyle(.orange).font(.caption)
        case .unrecognized:
            Label("解釈できませんでした", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary).font(.caption)
        }
    }

    private func openAdd() {
        add.syncFields()
        showAdd = true
    }

    /// 持ち物の要約。**名前は並べない** — 18 個のチップを敷き詰めても押せないし、
    /// 同じ一覧は各エージェント画面にあって、そちらでは切り替えと削除ができる。
    /// ここに要るのは規模（何が何件か）と、異常があるという事実だけ。
    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            statRow
            // 正常なら何も出ない。読み込めないものは各画面に散るので気づけない（5.3）。
            if broken > 0 {
                Label("読み込めないものが \(broken) 件あります（左のエージェントを選ぶと確認できます）",
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var broken: Int { mine.count(where: \.isUnusable) }

    /// 種別ごとの件数。**同梱は数えない** — 自分で入れたものの規模が知りたい。
    /// 4 枚のカードに散らさず、1 本の帯を縦罫で仕切る（合計が 1 つの事実だと分かる）。
    private var statRow: some View {
        HStack(spacing: 0) {
            ForEach(Kind.allCases, id: \.self) { kind in
                if kind != Kind.allCases.first {
                    Divider().frame(height: 30)
                }
                StatTile(title: kind.title,
                         count: mine.filter { $0.kind == kind }.count,
                         symbol: kind.symbol)
                    .padding(.horizontal, 14)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.radiusM))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusM).strokeBorder(.separator, lineWidth: 1)
        }
    }

    /// 旧「エージェント」画面の中身（DESIGN.md 8 章）。専用画面を持つほどの情報量が無い。
    /// **押せばそのエージェントの画面へ行く** — 検出状況を見た次にやることはそれ。
    /// 囲みは 1 枚。4 枚のカードに分けると、4 行の表と同じ情報に 4 倍の縁が付く。
    ///
    /// 検出は自動（3.7）。ここに置く操作は、自動で決まらない 2 つだけ —
    /// 管理対象から外す / `PATH` に無い CLI のパスを教える。
    private var agentList: some View {
        VStack(alignment: .leading, spacing: Theme.gap) {
            Text("エージェント").font(.headline)
            VStack(spacing: 0) {
                ForEach(Agent.allCases) { agent in
                    if agent != Agent.allCases.first { Divider() }
                    AgentRow(agent: agent, model: model) {
                        withAnimation(Motion.gentle) { screen = .agent(agent) }
                    }
                }
                Divider()
                cliPathMenu
            }
            // 行の下敷きは四角なので、角丸で切り抜く。先頭と末尾の行にホバーすると
            // 囲みの角からはみ出す。
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusM))
            .card(padding: 0)
            Text("検出できたエージェントは自動で並びます。オフにしたものは一覧から外れるだけで、設定ファイルには触れません。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// CLI が `PATH` で見つからないときの逃げ道（3.7 の 4 番目）。
    /// 行ごとにボタンを置くと 4 行ぶんの飾りになるので、まとめて 1 か所に出す。
    private var cliPathMenu: some View {
        Menu {
            ForEach(Agent.allCases.filter { $0.cliName != nil }) { agent in
                Button(agent.displayName) { model.chooseCLIPath(for: agent) }
            }
            if !manuallyLocated.isEmpty {
                Divider()
                ForEach(manuallyLocated) { agent in
                    Button("\(agent.displayName) の指定を解除") { model.clearCLIPath(for: agent) }
                }
            }
        } label: {
            Label("CLI のパスを指定…", systemImage: "plus.circle")
                .font(.callout).foregroundStyle(Color.accentColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("PATH から CLI を見つけられないときに、実行ファイルを直接指定します")
    }

    private var manuallyLocated: [Agent] {
        Agent.allCases.filter { model.inventory.registry.setting($0).path != nil }
    }
}

/// ホームのエージェント 1 行。検出状況（3.7 の 4 状態）を色と文で両方出す。
/// **1 行に収める** — 名前・状態・バージョン・件数は、縦に積まなくても横に並ぶ。
/// 右端のスイッチだけは行のボタンの外に出す（ボタンの中に入れると、
/// 切り替えたつもりが画面遷移になる）。
struct AgentRow: View {
    let agent: Agent
    let model: AppModel
    let open: () -> Void
    @State private var hovering = false

    private var detection: Detection { model.inventory.agents[agent] ?? .undetected }
    private var count: Int {
        model.inventory.rows(for: agent).filter { $0.origin != .bundled }.count
    }
    private var enabled: Bool { detection.isActive }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: open) {
                HStack(spacing: 8) {
                    Text(agent.displayName).font(.callout.weight(.medium))
                    Spacer(minLength: 8)
                    detail
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if count > 0, enabled {
                        Text(count.formatted())
                            .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                    }
                    status
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .opacity(enabled ? 1 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.55)
            .disabled(!enabled)

            Toggle(agent.displayName, isOn: .init(get: { detection != .disabled },
                                                  set: { model.setAgent(agent, enabled: $0) }))
                .toggleStyle(.switch).controlSize(.small)
                .labelsHidden()
                .help("オフにすると、このエージェントを一覧から外します（設定ファイルは変更しません）")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(hovering && enabled ? AnyShapeStyle(.quaternary.opacity(0.4))
                                        : AnyShapeStyle(.clear))
        .animation(Motion.gentle, value: hovering)
        .onHover { hovering = $0 }
    }

    /// 状態は色だけでなく文字でも出す（3.7）。「未検出」と「管理対象外」は別物。
    /// **「有効」とは呼ばない** — 隣のスイッチと、スキルの有効/無効が既にその語を使っている。
    @ViewBuilder
    private var status: some View {
        switch detection {
        case .detected:
            Pill(text: String(localized: "検出済み"), tint: .green, icon: "checkmark.circle.fill")
        case .configOnly:
            Pill(text: String(localized: "設定のみ"), tint: .orange)
        case .undetected:
            Pill(text: String(localized: "未検出"))
        case .disabled:
            Pill(text: String(localized: "管理対象外"))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch detection {
        case .detected(let version, let path):
            // Cursor は CLI が無いのが正常。空欄にせず理由を書く（DESIGN.md 8 章）。
            if version == nil, path == nil {
                Text("~/\(agent.configDir)（CLI なし・設定を直接読む）")
            } else {
                HStack(spacing: 4) {
                    if model.inventory.registry.setting(agent).path != nil {
                        Pill(text: String(localized: "手動指定"))
                    }
                    Text(verbatim: [version, path].compactMap { $0 }.joined(separator: "  "))
                }
                .help(path ?? "")
            }
        case .configOnly:
            Text("~/\(agent.configDir) はあるが CLI が見つからない")
        case .undetected:
            Text("インストールするか、CLI のパスを指定してください").foregroundStyle(.tertiary)
        case .disabled:
            Text("オンにすると一覧に戻ります").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - エージェント 1 つ分の画面

struct AgentPage: View {
    let agent: Agent
    let model: AppModel
    @Binding var showAdd: Bool
    @State private var tab: ScopeTab = .user

    private var rows: [ResourceRow] { model.inventory.rows(for: agent) }
    private var detection: Detection { model.inventory.agents[agent] ?? .undetected }

    var body: some View {
        Group {
            if detection == .disabled {
                ContentUnavailableView {
                    Label("\(agent.displayName) は管理対象から外しています", systemImage: "eye.slash")
                } description: {
                    Text("ホームのエージェント一覧でオンに戻せます。")
                }
            } else if detection == .undetected {
                ContentUnavailableView {
                    Label("\(agent.displayName) が見つかりません", systemImage: "questionmark.folder")
                } description: {
                    Text("インストールするか、ホームで CLI のパスを指定すると、ここに持っているスキルが並びます。")
                }
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("まだ何も入っていません", systemImage: "shippingbox")
                } description: {
                    Text("GitHub の URL を貼り付けるだけで追加できます。")
                } actions: {
                    Button("追加") { showAdd = true }.buttonStyle(.borderedProminent)
                }
            } else {
                list
            }
        }
        .navigationTitle(agent.displayName)
    }

    /// スコープはタブで切り替える。**同時に見せるのは 1 つの表だけ。**
    private var list: some View {
        let scoped = model.inventory.scoped(for: agent)
        let items = tabs(scoped)
        let current = items.contains { $0.tab == tab } ? tab : .user
        return VStack(alignment: .leading, spacing: 0) {
            ScopeTabs(items: items, selection: $tab)
            HStack(spacing: 10) {
                Text(note(for: current)).foregroundStyle(.secondary)
                if case .project(let path) = current {
                    Button {
                        NSWorkspace.shared.open(URL(filePath: path))
                    } label: {
                        Label("Finder で開く", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.link)
                    .help(path)
                    let rows = rows(for: current, in: scoped)
                    if !rows.isEmpty {
                        Button("このプロジェクトの \(rows.count) 件を削除…") {
                            model.cleanup = model.inventory
                                .cleanupItems(rows, agent: agent, project: path)
                        }
                        .buttonStyle(.link)
                    }
                }
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            table(rows(for: current, in: scoped), tab: current)
                .id(current)
                .transition(.opacity)
        }
        .animation(Motion.gentle, value: current)
    }

    private func table(_ rows: [ResourceRow], tab: ScopeTab) -> some View {
        let kinds = Kind.allCases.filter { k in rows.contains { $0.kind == k } }
        return List {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("あなたが入れたものはまだありません。", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                    Button("追加") { showAdd = true }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 4)
            }
            ForEach(kinds, id: \.self) { kind in
                let items = rows.filter { $0.kind == kind }
                Section {
                    ForEach(items) { row in
                        ResourceRowView(row: row, agent: agent, model: model,
                                        scannedAt: model.inventory.usageScannedAt,
                                        context: context(of: tab),
                                        project: projectPath(of: tab))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(kind.title)
                        Text(items.count.formatted()).monospacedDigit().foregroundStyle(.tertiary)
                    }
                    .textCase(nil)
                }
            }
        }
        // 1 件が数行にわたるので、区切りが無いと塊の境目が読めない。
        // 縞（alternatingRowBackgrounds）は入れない — 中身の無い下部まで縞が伸びて、
        // 「まだ何かある」ように見える。行頭のアイコンとホバーで境目は足りている。
        .listRowSeparator(.visible)
        .listStyle(.inset)
    }

    private func tabs(_ scoped: Inventory.Scoped) -> [ScopeTabItem] {
        var items = [ScopeTabItem(tab: .user, title: String(localized: "ユーザー全体"),
                                  icon: "person", count: scoped.user.count, help: nil)]
        items += scoped.byProject.map {
            ScopeTabItem(tab: .project($0.path),
                         title: ($0.path as NSString).lastPathComponent,
                         icon: "folder", count: $0.rows.count, help: $0.path)
        }
        if !scoped.bundled.isEmpty {
            items.append(ScopeTabItem(tab: .bundled, title: String(localized: "同梱"),
                                      icon: "shippingbox", count: scoped.bundled.count,
                                      help: nil))
        }
        return items
    }

    private func rows(for tab: ScopeTab, in scoped: Inventory.Scoped) -> [ResourceRow] {
        switch tab {
        case .user:              scoped.user
        case .bundled:           scoped.bundled
        case .project(let path): scoped.byProject.first { $0.path == path }?.rows ?? []
        }
    }

    private func note(for tab: ScopeTab) -> String {
        switch tab {
        case .user:
            String(localized: "どのプロジェクトでも使えます。")
        case .project:
            String(localized: "このプロジェクトの中でだけ効きます。ユーザー全体にも同じものがあれば、こちら側は消せます。")
        case .bundled:
            String(localized: "エージェントに同梱されているため、manage-arms からは変更できません。")
        }
    }

    private func projectPath(of tab: ScopeTab) -> String? {
        if case .project(let path) = tab { path } else { nil }
    }

    private func context(of tab: ScopeTab) -> ScopeContext {
        switch tab {
        case .user:    .userWide
        case .project: .project
        case .bundled: .bundled
        }
    }
}

extension Kind {
    var title: LocalizedStringKey {
        switch self {
        case .mcp:      "MCP サーバー"
        case .skill:    "スキル"
        case .subagent: "サブエージェント"
        case .plugin:   "プラグイン"
        }
    }

    var symbol: String {
        switch self {
        case .mcp:      "server.rack"
        case .skill:    "wand.and.stars"
        case .subagent: "person.2"
        case .plugin:   "puzzlepiece.extension"
        }
    }
}

/// スコープの切り替えタブ（DESIGN.md 8 章）。**同時に見せるのは 1 つの表だけ。**
/// プロジェクトの数は環境しだいで増える（実測 19）ので、
/// 固定幅のセグメントではなく横スクロールにする。
enum ScopeTab: Hashable {
    case user
    case project(String)
    case bundled
}

struct ScopeTabItem: Identifiable {
    let tab: ScopeTab
    let title: String
    let icon: String
    let count: Int
    let help: String?
    var id: ScopeTab { tab }
}

struct ScopeTabs: View {
    let items: [ScopeTabItem]
    @Binding var selection: ScopeTab
    /// 選択中の下敷きだけが動く。チップ全体をフェードさせるより、
    /// **どこからどこへ移ったか**が分かる。
    @Namespace private var underlay

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let chosen = item.tab == selection
                    Button {
                        withAnimation(Motion.pop) { selection = item.tab }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.icon).font(.caption)
                            Text(verbatim: item.title).lineLimit(1)
                            Text(item.count.formatted())
                                .font(.caption2.weight(.semibold)).monospacedDigit()
                                .opacity(0.75)
                        }
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(chosen ? AnyShapeStyle(.white)
                                                : AnyShapeStyle(.secondary))
                        .background {
                            if chosen {
                                Capsule().fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "scope", in: underlay)
                            } else {
                                Capsule().fill(.quaternary.opacity(0.4))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(item.help ?? item.title)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
    }
}

/// リソース 1 件。**操作できるのは registry.json に載っているものだけ**（DESIGN.md 9 章）。
/// 操作できないものも同じ行の形で出し、代わりに「どこで管理されているか」を書く —
/// **消せないことと、消し方が分からないことを、同じ見た目にしない。**
struct ResourceRowView: View {
    let row: ResourceRow
    /// どのエージェントの画面か。**削除の案内は CLI ごとに違う**ので必要。
    let agent: Agent
    let model: AppModel
    let scannedAt: Date?
    /// どの表に置かれているか。重複の注記を出し分ける。
    var context: ScopeContext = .userWide
    /// プロジェクトのタブならそのパス。削除コマンドのスコープに効く。
    var project: String?
    @State private var confirmDelete = false
    @State private var confirmExisting = false
    @State private var removalFile: URL?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 行の頭に固定幅の目印を置く。**どこで 1 件が始まるのか**が分からないと、
            // 説明文まで含めた塊が 1 枚の壁に見える。
            KindIcon(kind: row.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.weight(.semibold))
                    if row.isDisabled { Pill(text: String(localized: "無効")) }
                    // 事故（リンク切れ等）は無効化と別物として見せる。
                    if row.isUnusable {
                        Label("読み込めません", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                if let summary = row.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                // 補足はできるだけ 1 行に畳む。1 件が 5 行になると、
                // 行の切れ目が説明文に埋もれる。
                HStack(spacing: 10) {
                    UsageLabel(row: row, scannedAt: scannedAt)
                    UpdateLabel(row: row, model: model)
                    // リンク切れは置き場を、CLI 管理のものは管理元を出す。
                    if let note = row.isUnusable ? row.detail : managedBy {
                        Text(note).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            .textSelection(.enabled)
                    }
                }
                HStack(spacing: 8) {
                    ScopeNote(reach: row.reach, context: context)
                    if context == .userWide, case .both(let paths) = row.reach {
                        Button("プロジェクト側 \(paths.count) 件を削除…") {
                            model.cleanup = paths.flatMap {
                                model.inventory.cleanupItems([row], agent: agent, project: $0)
                            }
                        }
                        .buttonStyle(.link).font(.caption2)
                    }
                }
            }
            Spacer(minLength: 8)
            controls
                .disabled(model.isMutating || model.isPinning || model.isChecking || model.isAnalyzing)
        }
        .confirmationDialog("「\(row.name)」を削除しますか？", isPresented: $confirmExisting) {
            Button("削除", role: .destructive) { model.removeExisting(row, agent: agent, project: project, file: removalFile) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            if let removalFile {
                if project != nil {
                    Text("ゴミ箱へ移動：\(removalFile.path)。これはプロジェクトで共有されるファイルです。他のメンバーや別のマシンにも影響します。")
                } else {
                    Text("ゴミ箱へ移動：\(removalFile.path)。この配置場所を共有するエージェントにも影響します。")
                }
            } else {
                Text("\(agent.displayName) / \(project ?? String(localized: "ユーザー全体")) の登録を削除します。必要な場合は再追加してください。")
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 6)
        .background(hovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                    in: RoundedRectangle(cornerRadius: Theme.radiusS))
        .animation(Motion.gentle, value: hovering)
        .onHover { hovering = $0 }
        .opacity(row.isDisabled ? 0.6 : 1)
        .animation(Motion.gentle, value: row.isDisabled)
    }

    /// **「他ツールが入れた」で片付けない。** ユーザーが入れたものは
    /// どこで消せるのかまで書く（DESIGN.md 3.1 — 書き込みは各 CLI に委譲している）。
    private var managedBy: String? {
        guard row.origin != .managed else { return nil }
        switch row.kind {
        case .plugin:
            // **その画面のエージェントの CLI を書く。** 「claude / codex」と併記すると、
            // Cursor の行にまで claude が出て、消えないコマンドを打たせることになる。
            guard let cli = agent.cliName else { return String(localized: "各 CLI が管理します") }
            return String(localized: "\(cli) plugin コマンドで管理します")
        case .mcp:
            guard let cli = agent.cliName else {
                return String(localized: "~/\(agent.configDir)/mcp.json で管理します")
            }
            return String(localized: "\(cli) mcp コマンドで管理します")
        case .skill, .subagent:
            if row.origin == .bundled { return String(localized: "エージェント同梱") }
            // プロジェクトにしか無いものは、表の見出しが既にプロジェクトを言っている。
            return row.roots.isEmpty ? nil : String(localized: "実体: \(row.detail)")
        }
    }

    private var removableFiles: [URL] {
        row.removableFiles(agent: agent, project: project, env: .live)
    }

    @ViewBuilder
    private var controls: some View {
        if row.origin == .bundled {
            Label("同梱・変更不可", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        } else if row.isManaged && project == nil {
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("共有先すべてで有効", isOn: .init(get: { !row.isDisabled }, set: { _ in model.toggle(row) }))
                    .toggleStyle(.switch).controlSize(.small).font(.caption)
                Button("削除…", role: .destructive) { confirmDelete = true }
                    .contextMenuAndConfirm(row: row, model: model, confirmDelete: $confirmDelete)
            }
        } else {
            VStack(alignment: .trailing, spacing: 6) {
                if row.kind == .mcp || row.kind == .plugin {
                    Button("削除…", role: .destructive) { removalFile = nil; confirmExisting = true }
                        .disabled(agent != .cursor && model.inventory.agents[agent]?.isUsable != true)
                    if row.kind == .mcp && row.canPin && project == nil {
                        Button("最新版に固定…") { model.pin(row, agent: agent) }.font(.caption)
                    }
                } else if !removableFiles.isEmpty {
                    Menu("削除…") {
                        ForEach(removableFiles, id: \.path) { file in
                            Button(file.path) { removalFile = file; confirmExisting = true }
                        }
                    }
                } else {
                    Label("保護対象・管理元で変更", systemImage: "lock.fill").font(.caption)
                }
            }
        }
    }

}

/// 表がスコープごとに分かれているので、行に出すのは**重複しているときだけ**
/// （DESIGN.md 5.1 / 8 章）。どこで効いているかは表の見出しが既に言っている。
enum ScopeContext: Equatable {
    case userWide
    case project
    case bundled
}

struct ScopeNote: View {
    let reach: ResourceRow.Reach
    let context: ScopeContext

    var body: some View {
        switch (context, reach) {
        case (.userWide, .both(let paths)):
            // 5.2 の「散らかり」。ユーザー全体にあるのに個別にも入っている。
            // 橙にするのは**指摘の 1 行だけ**。プロジェクト名まで橙にすると、
            // 行の半分が警告色になって、本当に危ないもの（読み込めない）と区別が付かない。
            VStack(alignment: .leading, spacing: 1) {
                Label("\(paths.count) プロジェクトにも個別に入っています",
                      systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text(verbatim: paths.map { ($0 as NSString).lastPathComponent }
                                    .joined(separator: "  ·  "))
                    .foregroundStyle(.secondary)
                    .help(paths.joined(separator: "\n"))
            }
            .font(.caption2)
        case (.project, .both):
            Label("ユーザー全体にもあります。内容の違いを確認してください", systemImage: "exclamationmark.circle")
                .font(.caption2).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

struct KindIcon: View {
    let kind: Kind
    var size: CGFloat = Theme.glyph

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: size * 0.62))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .padding(.top, 1)
            .help(kind.rawValue.uppercased())
    }
}

extension View {
    /// 右クリックメニューと削除確認。行本体ではなく操作側に付けて、
    /// 一覧のスクロール中に誤爆しないようにする。
    func contextMenuAndConfirm(row: ResourceRow, model: AppModel,
                               confirmDelete: Binding<Bool>) -> some View {
        contextMenu {
            Button(row.isDisabled ? "有効にする" : "無効にする") { model.toggle(row) }
            Button(isPinnedRow(row) ? "更新の固定を解除" : "このバージョンで固定") {
                model.togglePin(row)
            }
            Divider()
            Button("削除…", role: .destructive) { confirmDelete.wrappedValue = true }
        }
        .confirmationDialog("「\(row.name)」を削除しますか？", isPresented: confirmDelete) {
            Button("削除", role: .destructive) { model.remove(row) }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("ファイルはゴミ箱へ移動します。あとから Finder で戻せます。")
        }
    }
}

private func isPinnedRow(_ row: ResourceRow) -> Bool {
    if case .pinned = row.update { true } else { false }
}

/// 最終使用日（DESIGN.md 3.9 / 5.3）。
/// **「未集計」「観測範囲外」「未使用」を 1 つも混ぜない。**
/// どれも同じ空白に見せると、ユーザーは消してよいものを消せず、
/// 消してはいけないものを消す。
struct UsageLabel: View {
    let row: ResourceRow
    let scannedAt: Date?

    var body: some View {
        Group {
            // MCP だけは「今この瞬間の状態」を持つ（3.9）。最終使用日より優先する。
            if row.running != nil {
                HStack(spacing: 4) {
                    RunningDot()
                    Text("起動検出")
                }
                .foregroundStyle(.green)
            } else if row.kind == .mcp {
                Text("起動未確認").foregroundStyle(.secondary)
            } else if scannedAt == nil {
                Text("使用状況は未集計").foregroundStyle(.quaternary)
            } else if !row.usageObservable {
                Text("使用状況は不明").foregroundStyle(.tertiary)
            } else if let last = row.lastUsed {
                Text("最終使用 \(last.formatted(.relative(presentation: .numeric)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("使用記録なし").foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .help(helpText)
    }

    private var helpText: String {
        if let running = row.running {
            let owner = running.owner?.displayName ?? String(localized: "所属不明のプロセス")
            return String(localized:
                "\(owner) のプロセスを検出 · 稼働 \(running.elapsed) · pid \(Int(running.pid))")
        }
        if row.kind == .mcp {
            return String(localized: "ローカルプロセスを確認できません。HTTP接続や所属不明のプロセスは停止と断定できません。")
        }
        if scannedAt == nil {
            return String(localized: "未集計 —「使用状況を分析」を押すと集計します")
        }
        if !row.usageObservable {
            return String(localized:
                "対応 Agent のセッションログから観測できないため不明です。使われていないという意味ではありません")
        }
        if let last = row.lastUsed {
            return String(localized:
                "最終使用: \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "集計した範囲では一度も使われていません")
    }
}

/// 稼働中の点。**動くのはここだけ** — 一覧の中で本当に「今」を表しているのは
/// 実行中の MCP だけなので、点滅する要素をこれ以外に増やさない。
struct RunningDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.green)
            .frame(width: 6, height: 6)
            .overlay {
                Circle().stroke(.green.opacity(0.5), lineWidth: 1)
                    .scaleEffect(pulsing ? 2.2 : 1)
                    .opacity(pulsing ? 0 : 1)
            }
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                    pulsing = true
                }
            }
    }
}

/// 更新状態（DESIGN.md 7.6）。
struct UpdateLabel: View {
    let row: ResourceRow
    let model: AppModel

    var body: some View {
        switch row.update {
        case .available:
            Button("更新があります（差分を見る）") { model.showDiff(for: row) }
                .buttonStyle(.link).font(.caption2)
        case .pinned(let behind):
            Label(behind ? "固定中（更新あり）" : "固定中", systemImage: "pin.fill")
                .font(.caption2).foregroundStyle(behind ? .orange : .secondary)
                .help("解除は右クリックメニューから")
        case .upToDate:
            Text("最新").font(.caption2).foregroundStyle(.secondary)
        case .unknown, .unmanaged:
            EmptyView()
        }
    }
}

/// 一括削除の確認（DESIGN.md 5.2）。**実行するコマンドをそのまま見せる。**
/// 「何が消えるか分からないボタン」を作らない。
struct CleanupSheet: View {
    let items: [CleanupItem]
    let model: AppModel
    @SwiftUI.Environment(\.dismiss) private var dismiss

    private var runnable: [CleanupItem] { items.filter(\.executable) }
    private var manual: [CleanupItem] { items.filter { !$0.executable } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "プロジェクトから削除")

            if !runnable.isEmpty {
                Text("次のコマンドを実行します（\(runnable.count) 件）")
                    .font(.callout).foregroundStyle(.secondary)
                commands(runnable)
            }
            if !manual.isEmpty {
                Divider()
                Label("これはアプリから実行しません。リポジトリの中のファイルなので、消したことが git で共有されます。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                commands(manual)
                Button {
                    let text = manual.map(\.command).joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("コマンドをコピー", systemImage: "doc.on.doc")
                }
                .font(.caption)
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button(model.isCleaning ? "削除中…" : "削除する") { model.runCleanup(items) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runnable.isEmpty || model.isCleaning)
            }
        }
        .padding(20)
        .frame(width: 620, height: 440)
    }

    private func commands(_ list: [CleanupItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(list) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            KindIcon(kind: item.kind, size: 18)
                            Text(item.name).font(.callout.weight(.medium))
                            Pill(text: item.projectName, icon: "folder")
                        }
                        Text(verbatim: item.command)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quinary, in: RoundedRectangle(cornerRadius: Theme.radiusS))
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 160)
    }
}
