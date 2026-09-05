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
}

struct ContentView: View {
    let model: AppModel
    @State private var screen: Screen = .home
    @State private var add = AddModel()
    @State private var showAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $screen) {
                Label("ホーム", systemImage: "house").tag(Screen.home)
                Section("エージェント") {
                    ForEach(Agent.allCases) { agent in
                        AgentSidebarRow(
                            agent: agent,
                            detection: model.inventory.agents[agent] ?? .undetected,
                            count: model.inventory.rows(for: agent).filter { $0.origin != .bundled }.count
                        )
                        .tag(Screen.agent(agent))
                    }
                }
                Section("そのほか") {
                    Label("権限", systemImage: "lock").tag(Screen.permissions)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            switch screen {
            case .home:
                HomeView(model: model, add: add, showAdd: $showAdd)
            case .agent(let agent):
                AgentPage(agent: agent, model: model, showAdd: $showAdd)
            case .permissions:
                PermissionList(model: model)
            }
        }
        .alert("操作できませんでした",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(add: add) {
                add.discard()
                showAdd = false
                model.reload()
            }
        }
        .sheet(isPresented: .init(get: { model.cleanup != nil },
                                  set: { if !$0 { model.cleanup = nil } })) {
            CleanupSheet(items: model.cleanup ?? [], model: model)
        }
        .sheet(item: Binding(get: { model.preview.map { PreviewBox(value: $0) } },
                             set: { if $0 == nil { model.discardPreview() } })) { box in
            DiffSheet(preview: box.value, model: model)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAdd = true } label: { Label("追加", systemImage: "plus") }
                    .help("GitHub の URL からスキルを追加します")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.analyzeUsage()
                } label: {
                    Label(model.isAnalyzing ? "分析中…" : "使用状況を分析",
                          systemImage: "clock.arrow.circlepath")
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
                }
                .disabled(model.isChecking)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .help("再読み込み")
                    .disabled(model.isLoading)
            }
        }
    }
}

/// エージェントの目印。**実物のアプリが入っていればそのアイコンを使う。**
/// ロゴ画像は同梱しない（他社の商標を配布物に入れない・9 章のディスク規律にも反する）。
/// Codex / Gemini CLI は CLI しか無くアイコンを持たないので SF Symbol に落ちる。
struct AgentIcon: View {
    let agent: Agent
    var size: CGFloat = 16

    var body: some View {
        if let icon = Self.icons[agent] {
            Image(nsImage: icon).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: agent.symbol).foregroundStyle(agent.tint)
        }
    }

    /// 1 度だけ引く。NSWorkspace のアイコンは OS が持っているので自前で持たない（9 章）。
    static let icons: [Agent: NSImage] = Dictionary(
        uniqueKeysWithValues: Agent.allCases.compactMap { agent in
            agent.appBundleID
                .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
                .map { (agent, NSWorkspace.shared.icon(forFile: $0.path(percentEncoded: false))) }
        })
}

extension Agent {
    /// デスクトップアプリの bundle id。**無いのが普通** — Claude Code / Codex /
    /// Gemini CLI はコマンドラインツールで、アイコンを持たない。
    var appBundleID: String? {
        switch self {
        case .claude: "com.anthropic.claudefordesktop"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .codex, .gemini: nil
        }
    }

    /// アプリが無いときの代替。**エージェントごとに変える** —
    /// 同じアイコンが 4 つ並ぶと、選択中がどれか分からない。
    var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .cursor: "cursorarrow"
        case .codex:  "chevron.left.forwardslash.chevron.right"
        case .gemini: "sparkle"
        }
    }
    var tint: Color {
        switch self {
        case .claude: .orange
        case .cursor: .blue
        case .codex:  .teal
        case .gemini: .purple
        }
    }
}

struct AgentSidebarRow: View {
    let agent: Agent
    let detection: Detection
    let count: Int

    var body: some View {
        HStack {
            Label {
                Text(agent.displayName)
            } icon: {
                AgentIcon(agent: agent)
            }
            Spacer()
            if detection == .undetected {
                Text("未検出").font(.caption).foregroundStyle(.tertiary)
            } else if count > 0 {
                Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
            }
        }
        .opacity(detection == .undetected ? 0.5 : 1)
    }
}

// MARK: - ホーム（追加の入口・DESIGN.md 6 章 / 8 章）

struct HomeView: View {
    let model: AppModel
    @Bindable var add: AddModel
    @Binding var showAdd: Bool

    /// 自分で入れたもの全部（このアプリ経由に限らない）。同梱は数えない。
    private var mine: [ResourceRow] { model.inventory.rows.filter { $0.origin != .bundled } }
    private var managed: [ResourceRow] { model.inventory.rows.filter(\.isManaged) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ManageArms").font(.title2.weight(.semibold))
                    Text("AI エージェントが持っているスキルを、ここでまとめて追加・削除できます。")
                        .foregroundStyle(.secondary)
                }
                addCard
                findCard
                managedCard
                agentCard
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .navigationTitle("ホーム")
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
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("中身を確認するまで何も入りません。追加したものは Claude Code / Cursor / Codex の全部から使えます。",
                      systemImage: "info.circle")
                // MCP とプラグインの追加は各 CLI に委譲している（DESIGN.md 3.1）。
                // 「未対応」ではなく「どこでやるか」を書く。
                Label("MCP サーバーとプラグインの追加は各 CLI が行います（claude mcp add / claude plugin install）。このアプリでは一覧と整理ができます。",
                      systemImage: "terminal")
            }
            .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func openAdd() {
        add.syncFields()
        showAdd = true
    }

    private var findCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("どこで見つける？").font(.headline)
            Link(destination: URL(string: "https://github.com/anthropics/skills")!) {
                Label("anthropics/skills — Anthropic 公式のスキル集", systemImage: "link")
            }
            Link(destination: URL(string: "https://github.com/topics/claude-skills")!) {
                Label("GitHub の claude-skills トピック", systemImage: "link")
            }
            Text("開いたページのフォルダの URL をコピーして、上のボックスに貼り付けます。")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var managedCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("あなたが入れたもの").font(.headline)
            if mine.isEmpty {
                Text("まだありません。上のボックスから追加できます。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("\(mine.count) 件。うち \(managed.count) 件はこのアプリから切り替え・削除できます（左のエージェントを選ぶ）")
                    .font(.callout).foregroundStyle(.secondary)
                Text(verbatim: mine.map(\.name).joined(separator: "  ·  "))
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    /// 旧「エージェント」画面の中身（DESIGN.md 8 章）。専用画面を持つほどの情報量が無い。
    private var agentCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("エージェントの検出状況").font(.headline)
            ForEach(Agent.allCases) { agent in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(agent.displayName).frame(width: 110, alignment: .leading)
                    detail(for: model.inventory.agents[agent] ?? .undetected, agent: agent)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(for detection: Detection, agent: Agent) -> some View {
        switch detection {
        case .detected(let version, let path):
            // Cursor は CLI が無いのが正常。空欄にせず理由を書く（DESIGN.md 8 章）。
            if version == nil, path == nil {
                Text("~/\(agent.configDir)（CLI なし・設定を直接読む）")
            } else {
                Text(verbatim: [version, path].compactMap { $0 }.joined(separator: "  "))
                    .textSelection(.enabled)
            }
        case .configOnly:
            Text("~/\(agent.configDir) はあるが CLI が見つからない")
        case .undetected:
            Text("未検出").foregroundStyle(.tertiary)
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
            if detection == .undetected {
                ContentUnavailableView {
                    Label("\(agent.displayName) が見つかりません", systemImage: "questionmark.folder")
                } description: {
                    Text("インストールすると、ここに持っているスキルが並びます。")
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
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AgentIcon(agent: agent, size: 18)
            }
        }
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
            .padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            table(rows(for: current, in: scoped), tab: current)
        }
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
                        Text(title(kind))
                        Text(items.count.formatted())
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
        // 1 件が数行にわたるので、区切りと縞が無いと塊の境目が読めない。
        .listRowSeparator(.visible)
        .alternatingRowBackgrounds()
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

    private func title(_ kind: Kind) -> String {
        switch kind {
        case .mcp:      String(localized: "MCP サーバー")
        case .skill:    String(localized: "スキル")
        case .subagent: String(localized: "サブエージェント")
        case .plugin:   String(localized: "プラグイン")
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

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    let chosen = item.tab == selection
                    Button { selection = item.tab } label: {
                        HStack(spacing: 5) {
                            Image(systemName: item.icon)
                            Text(item.title)
                            Text(item.count.formatted())
                                .font(.caption2.weight(.semibold))
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                                    in: Capsule())
                        .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
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

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 行の頭に固定幅の目印を置く。**どこで 1 件が始まるのか**が分からないと、
            // 説明文まで含めた塊が 1 枚の壁に見える。
            KindIcon(kind: row.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.weight(.semibold))
                    if row.isDisabled { Badge(text: String(localized: "無効")) }
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
        }
        .padding(.vertical, 6)
        .opacity(row.isDisabled ? 0.6 : 1)
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

    @ViewBuilder
    private var controls: some View {
        if row.isManaged {
            Toggle("", isOn: .init(get: { !row.isDisabled }, set: { _ in model.toggle(row) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(row.isDisabled ? "有効にする（全エージェント）" : "無効にする（全エージェント）")
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("削除する")
            .contextMenuAndConfirm(row: row, model: model, confirmDelete: $confirmDelete)
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                // 実体が置き場にあるものは、ファイルを動かさずに管理下へ入れられる（8 章）。
                if row.adoption == .possible {
                    Button("このアプリで管理") { model.adopt(row) }
                        .buttonStyle(.link).font(.caption)
                        .help("registry に登録して、切り替えと削除ができるようにします。ファイルは動かしません")
                }
                if row.kind == .mcp && row.canPin {
                    // MCP は消せないが `@latest` の固定はできる（7.2）。
                    Button("ピン留め") { model.pin(row) }
                        .buttonStyle(.link).font(.caption)
                        .disabled(model.isPinning)
                        .help("いま npm にある最新版に固定し、起動ごとに変わらないようにします")
                }
                RemovalHelp(row: row, agent: agent, model: model, project: project)
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
            VStack(alignment: .leading, spacing: 1) {
                Label("\(paths.count) プロジェクトにも個別に入っています",
                      systemImage: "exclamationmark.2")
                Text(verbatim: paths.map { ($0 as NSString).lastPathComponent }
                                    .joined(separator: "  ·  "))
                    .help(paths.joined(separator: "\n"))
            }
            .font(.caption2).foregroundStyle(.orange)
        case (.project, .both):
            Label("ユーザー全体にもあります。こちら側は消せます", systemImage: "exclamationmark.2")
                .font(.caption2).foregroundStyle(.orange)
        default:
            EmptyView()
        }
    }
}

/// 「消せない」で終わらせず、**どこで消すのかを出す**（DESIGN.md 3.1 — 書き込みは
/// 各 CLI に委譲しているので、削除もそちらが正しい経路）。
struct RemovalHelp: View {
    let row: ResourceRow
    let agent: Agent
    let model: AppModel
    var project: String?
    @State private var shown = false

    var body: some View {
        Button("削除するには…") { shown = true }
            .buttonStyle(.link).font(.caption)
            .popover(isPresented: $shown, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("「\(row.name)」の消し方").font(.headline)
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                    if let command {
                        HStack(spacing: 8) {
                            Text(verbatim: command)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(6)
                                .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(command, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .help("コピー")
                        }
                    }
                    // どのスコープを消すのかは、コマンド自体に焼き込んである。
                    // 取り違えるとユーザー全体の分が消えるので、言葉でも念を押す。
                    if project != nil {
                        Text("このプロジェクトの分だけを消します。")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else if !row.reach.projectPaths.isEmpty {
                        Text("ユーザー全体の分だけを消します。プロジェクト側は各プロジェクトのタブから消してください。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if case .needsMove(let root) = row.adoption {
                        Divider()
                        Text("実体を ~/\(root) から ~/.agents/skills へ移すと、このアプリで切り替え・削除できるようになります（移動は手で行ってください）。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .frame(width: 400)
            }
    }

    private var reason: String {
        if row.origin == .bundled {
            return String(localized: "エージェントに同梱されているものです。消してもエージェントの更新で戻ります。")
        }
        switch row.kind {
        case .plugin:
            return String(localized: "プラグインは各 CLI が入れています。**入れたのと同じ CLI**で消してください。")
        case .mcp where agent == .cursor:
            // Cursor に CLI は無い。設定ファイルを直接編集するのが唯一の経路（3.1）。
            return String(localized: "Cursor には CLI が無いので、設定ファイルの mcpServers から該当のエントリを消してください。")
        case .mcp:
            return String(localized: "MCP は各エージェントの設定ファイルにあります。動いている Claude と競合するため、書き換えは CLI に任せます。")
        case .skill, .subagent:
            return String(localized: "このアプリが入れたものではないため、実体を直接消してください。")
        }
    }

    /// **コマンドをでっち上げない。** 実在を確認したのは `claude plugin remove` /
    /// `codex plugin remove` / `<cli> mcp remove` だけ（`--help` で確認）。
    /// スコープの決定は Core の純粋関数に任せる（テストがある）。
    private var command: String? {
        row.removalCommand(
            agent: agent,
            project: project,
            mcpScope: project.flatMap { model.inventory.projectScan.mcpScope(row.name, in: $0) })
    }
}

/// 種別の目印。色と記号で「どこから次の 1 件か」を作る。
struct KindIcon: View {
    let kind: Kind

    var body: some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 6))
            .padding(.top, 1)
            .help(kind.rawValue.uppercased())
    }

    private var symbol: String {
        switch kind {
        case .mcp:      "server.rack"
        case .skill:    "wand.and.stars"
        case .subagent: "person.2"
        case .plugin:   "puzzlepiece.extension"
        }
    }

    private var tint: Color {
        switch kind {
        case .mcp:      .teal
        case .skill:    .blue
        case .subagent: .purple
        case .plugin:   .pink
        }
    }
}

struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
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
                Text("● 実行中").foregroundStyle(.green)
            } else if row.kind == .mcp {
                Text("停止中").foregroundStyle(.secondary)
            } else if scannedAt == nil {
                Text("使用状況は未集計").foregroundStyle(.quaternary)
            } else if !row.usageObservable {
                Text("使用状況は不明").foregroundStyle(.tertiary)
            } else if let last = row.lastUsed {
                Text("最終使用 \(last.formatted(.relative(presentation: .numeric)))")
                    .foregroundStyle(.secondary)
            } else {
                Text("一度も使っていません").foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .help(helpText)
    }

    private var helpText: String {
        if let running = row.running {
            let owner = running.owner?.displayName ?? String(localized: "所属不明のプロセス")
            return String(localized:
                "\(owner) が使用中 · 稼働 \(running.elapsed) · pid \(Int(running.pid))")
        }
        if row.kind == .mcp {
            return String(localized: "登録されていますが、いま起動しているプロセスはありません")
        }
        if scannedAt == nil {
            return String(localized: "未集計 —「使用状況を分析」を押すと集計します")
        }
        if !row.usageObservable {
            return String(localized:
                "Claude のセッションログしか読めないため不明です。使われていないという意味ではありません")
        }
        if let last = row.lastUsed {
            return String(localized:
                "最終使用: \(last.formatted(date: .abbreviated, time: .shortened))")
        }
        return String(localized: "集計した範囲では一度も使われていません")
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
            Text("プロジェクトから削除").font(.title3.weight(.semibold))

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
        .frame(width: 620, height: 420)
    }

    private func commands(_ list: [CleanupItem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(list) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            KindIcon(kind: item.kind)
                            Text(item.name).font(.callout.weight(.medium))
                            Text(verbatim: item.projectName)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(verbatim: item.command)
                            .font(.system(.caption2, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 150)
    }
}
