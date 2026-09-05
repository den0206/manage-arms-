import SwiftUI
import ManageArmsCore

enum Screen: String, CaseIterable, Identifiable {
    case resources, permissions, agents
    var id: String { rawValue }
    /// `String` を返すので SwiftUI の自動ローカライズが効かない。明示的に引く。
    var title: String {
        switch self {
        case .resources: String(localized: "リソース")
        case .permissions: String(localized: "権限")
        case .agents: String(localized: "エージェント")
        }
    }
    var icon: String {
        switch self {
        case .resources: "shippingbox"
        case .permissions: "lock"
        case .agents: "gearshape"
        }
    }
}

struct ContentView: View {
    let model: AppModel
    @State private var screen: Screen = .resources

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch screen {
            case .resources:   ResourceMatrix(inventory: model.inventory, model: model)
            case .permissions: PermissionList(model: model)
            case .agents:      AgentList(agents: model.inventory.agents)
            }
        }
        .alert("操作できませんでした",
               isPresented: .init(get: { model.errorMessage != nil },
                                  set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("再読み込み")
                .disabled(model.isLoading)
            }
        }
    }
}

// MARK: - リソースのマトリクス（DESIGN.md 5.2 / 8）

struct ResourceMatrix: View {
    let inventory: Inventory
    let model: AppModel
    @State private var add = AddModel()
    @State private var showAdd = false
    @State private var filter: Kind?

    /// 種別が増えると 26 件のスキルの下に埋もれるので絞り込む。
    private var rows: [ResourceRow] {
        filter.map { kind in inventory.rows.filter { $0.kind == kind } } ?? inventory.rows
    }
    private var kinds: [Kind] {
        Kind.allCases.filter { kind in inventory.rows.contains { $0.kind == kind } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            scopeBar
            Divider()
            if rows.isEmpty {
                ContentUnavailableView("リソースがありません", systemImage: "shippingbox")
            } else {
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        header
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(rows) { row in
                            RowView(row: row, model: model, scannedAt: inventory.usageScannedAt)
                            Divider().gridCellUnsizedAxes(.horizontal)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            Divider()
            legend
        }
        .sheet(item: Binding(get: { model.preview.map { PreviewBox(value: $0) } },
                             set: { if $0 == nil { model.discardPreview() } })) { box in
            DiffSheet(preview: box.value, model: model)
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(add: add) {
                add.discard()
                showAdd = false
                model.reload()
            }
        }
    }

    private var scopeBar: some View {
        HStack {
            // v1 は読み取り表示のみ（DESIGN.md 5.2）。プロジェクトスコープはまだ選べない。
            Picker("スコープ", selection: .constant(0)) {
                Text("ユーザー全体").tag(0)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .disabled(true)
            Button {
                showAdd = true
            } label: {
                Label("追加", systemImage: "plus")
            }
            Button {
                model.checkUpdates()
            } label: {
                Label(model.isChecking ? "確認中…" : "更新を確認",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isChecking)
            Button {
                model.analyzeUsage()
            } label: {
                Label(model.isAnalyzing ? "分析中…" : "使用状況を分析",
                      systemImage: "clock.arrow.circlepath")
            }
            .disabled(model.isAnalyzing)
            .help(inventory.usageScannedAt.map {
                String(localized: "前回: \($0.formatted(date: .abbreviated, time: .shortened))")
            } ?? String(localized: "セッションログから最終使用日を集計します（初回は数秒かかります）"))
            Spacer()
            Picker("", selection: $filter) {
                Text("すべて").tag(Kind?.none)
                ForEach(kinds, id: \.self) { kind in
                    Text(label(kind)).tag(Kind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
            Text("\(rows.count) 件")
                .foregroundStyle(.secondary)
                .font(.callout)
        }
        .padding(12)
    }

    private func label(_ kind: Kind) -> String {
        switch kind {
        case .mcp: "MCP"
        case .skill: "Skills"
        case .subagent: "Subagents"
        case .plugin: "Plugins"
        }
    }

    private var header: some View {
        GridRow {
            Text("リソース")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
                .frame(minWidth: 240, alignment: .leading)
            Text("最終使用").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).frame(width: 96)
            ForEach(Agent.allCases, id: \.self) { agent in
                AgentHeader(agent: agent, detection: inventory.agents[agent] ?? .undetected)
            }
            Text("更新").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).frame(width: 132)
            Text("").frame(width: 84)
        }
    }

    private var legend: some View {
        // 記号は ResourceRow.State.symbol と対。文字列リテラルのまま置くことで
        // SwiftUI が Localizable.strings から引く（"%@ %@" をキーにしない）。
        HStack(spacing: 16) {
            Text("● 有効")
            Text("○ 未導入")
            Text("— 非対応")
            Text("· 未検出")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct AgentHeader: View {
    let agent: Agent
    let detection: Detection

    var body: some View {
        VStack(spacing: 1) {
            Text(agent.displayName)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 108)
        .padding(.vertical, 8)
        .opacity(detection == .undetected ? 0.45 : 1)
        .help(helpText)
    }

    private var subtitle: String {
        switch detection {
        case .detected(let version, _): version ?? "─"   // Cursor は CLI が無いのが正常
        case .configOnly:               String(localized: "CLI なし")
        case .undetected:               String(localized: "未検出")
        }
    }

    private var helpText: String {
        switch detection {
        case .detected(_, let path):
            path ?? String(localized: "\(agent.displayName) は CLI を持ちません（設定を直接読みます）")
        case .configOnly:
            String(localized: "設定は見つかりましたが \(agent.cliName ?? "") CLI が見つかりません。表示のみです")
        case .undetected:
            String(localized: "\(agent.displayName) が見つかりません")
        }
    }
}

/// 最終使用日のセル（DESIGN.md 3.9 / 5.3）。
/// **「未集計」「観測範囲外」「未使用」を 1 つも混ぜない。**
/// どれも同じ空白に見せると、ユーザーは消してよいものを消せず、
/// 消してはいけないものを消す。
struct UsageCell: View {
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
                Text("—").foregroundStyle(.quaternary)
            } else if !row.usageObservable {
                Text("─").foregroundStyle(.tertiary)
            } else if let last = row.lastUsed {
                Text(last.formatted(.relative(presentation: .numeric)))
                    .foregroundStyle(.secondary)
            } else {
                Text("未使用").foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .frame(width: 96)
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

struct RowView: View {
    let row: ResourceRow
    let model: AppModel
    var scannedAt: Date?

    var body: some View {
        GridRow {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.name).font(.body.weight(.medium))
                    Text(row.kind.rawValue.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if let summary = row.summary {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(row.detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .padding(.vertical, 8)
            // 固定幅列（エージェント 4 + 更新 + 操作）の合計が窓幅に迫ると
            // ここが 0 まで潰れて縦組みになる。下限を切っておく。
            .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)

            UsageCell(row: row, scannedAt: scannedAt)

            ForEach(Agent.allCases, id: \.self) { agent in
                let state = row.state[agent] ?? .absent
                Text(state.symbol)
                    .font(.body)
                    .foregroundStyle(color(for: state))
                    .frame(width: 108)
                    .help(description(for: state, agent: agent))
            }

            updateCell.frame(width: 132)
            control.frame(width: 84)
        }
        .opacity(row.isDisabled ? 0.55 : 1)
    }

    /// 更新状態と操作（DESIGN.md 7.6）。
    private var isPinned: Bool {
        if case .pinned = row.update { true } else { false }
    }

    @ViewBuilder
    private var updateCell: some View {
        switch row.update {
        case .unmanaged where row.kind == .plugin:
            // Plugin の更新は各 CLI が持つ。アプリは二重管理しない（DESIGN.md 7.5）。
            Text("CLI が管理").font(.caption2).foregroundStyle(.tertiary)
                .help("プラグインの更新は claude / codex plugin update が行います")
        case .unmanaged:
            Text("—").foregroundStyle(.quaternary)
        case .unknown where row.kind == .plugin:
            Text("CLI が管理").font(.caption2).foregroundStyle(.tertiary)
        case .unknown:
            Text("未確認").font(.caption).foregroundStyle(.tertiary)
        case .upToDate:
            Text("最新").font(.caption).foregroundStyle(.secondary)
        case .available:
            Button("差分を見る") { model.showDiff(for: row) }
                .buttonStyle(.link).font(.caption)
        case .pinned(let behind):
            Label(behind ? "固定中（更新あり）" : "固定中", systemImage: "pin.fill")
                .font(.caption2).foregroundStyle(behind ? .orange : .secondary)
                .help("固定を解除するには行を右クリック")
        }
    }

    /// 操作できるのは registry.json に載っているものだけ（DESIGN.md 9 章）。
    /// 他ツールが入れたスキルは表示するが変更させない。
    @ViewBuilder
    private var control: some View {
        if row.kind == .mcp {
            // MCP に「更新」は無い。必要なのはピン留め（DESIGN.md 7.2）。
            if row.canPin {
                Button("ピン留め") { model.pin(row) }
                    .buttonStyle(.link).font(.caption)
                    .disabled(model.isPinning)
                    .help("いま npm にある最新版に固定し、起動ごとに変わらないようにします")
            } else {
                Text("固定済み").font(.caption2).foregroundStyle(.tertiary)
                    .help("バージョンが指定済みです。起動ごとに変わることはありません")
            }
        } else if row.isManaged {
            Toggle("", isOn: .init(get: { !row.isDisabled },
                                   set: { _ in model.toggle(row) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(row.isDisabled ? "有効にする（全エージェント）" : "無効にする（全エージェント）")
                .contextMenu {
                    Button(isPinned ? "固定を解除" : "このバージョンで固定") {
                        model.togglePin(row)
                    }
                }
        } else {
            Text("外部管理")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .help("他のツールが入れたスキルです。manage-arms からは変更できません")
        }
    }

    private func color(for state: ResourceRow.State) -> some ShapeStyle {
        switch state {
        case .explicit:                     AnyShapeStyle(.tint)
        case .inherited:                    AnyShapeStyle(.tint.opacity(0.5))
        case .external:                     AnyShapeStyle(.orange)
        case .absent:                       AnyShapeStyle(.secondary)
        case .unsupported, .undetected:     AnyShapeStyle(.quaternary)
        }
    }

    /// 「非対応」と「未検出」を同じ文言にしない（DESIGN.md 8）。
    private func description(for state: ResourceRow.State, agent: Agent) -> String {
        switch state {
        case .explicit:    String(localized: "\(agent.displayName) で有効")
        case .inherited:   String(localized: "ユーザー全体から継承")
        case .external:    String(localized: "他ツールが管理しています")
        case .absent:      String(localized: "\(agent.displayName) には未導入")
        case .unsupported: String(localized: "\(agent.displayName) に \(row.kind.rawValue) はありません")
        case .undetected:  String(localized: "\(agent.displayName) が見つかりません")
        }
    }
}

// MARK: - エージェント画面（DESIGN.md 8）

struct AgentList: View {
    let agents: [Agent: Detection]

    var body: some View {
        Table(Agent.allCases) {
            TableColumn("エージェント") { Text($0.displayName) }
            TableColumn("バージョン") { agent in
                switch agents[agent] ?? .undetected {
                case .detected(let v, _): Text(v ?? "─").foregroundStyle(v == nil ? .secondary : .primary)
                case .configOnly:         Text("─").foregroundStyle(.secondary)
                case .undetected:         Text("未検出").foregroundStyle(.tertiary)
                }
            }
            TableColumn("パス") { agent in
                switch agents[agent] ?? .undetected {
                case .detected(_, let path):
                    Text(path ?? String(localized: "~/\(agent.configDir)（CLI なし・設定を直接読む）"))
                        .foregroundStyle(path == nil ? .secondary : .primary)
                case .configOnly:
                    Text("~/\(agent.configDir) はあるが CLI が見つからない")
                        .foregroundStyle(.secondary)
                case .undetected:
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        }
    }
}
