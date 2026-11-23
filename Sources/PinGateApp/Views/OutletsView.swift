import AppKit
import PinGateCore
import SwiftUI

private enum SourceKindTab: String, CaseIterable, Identifiable {
    case localProfile = "本地 Clash 配置"
    case remoteSubscription = "远程订阅 URL"
    case manualYAML = "手动 YAML"
    case upstreamProxy = "上游代理"

    var id: String { rawValue }
}

struct OutletsView: View {
    @Bindable var appState: AppState
    @State private var selectedOutletID: UUID?
    @State private var draftOutlet: OutletConfig?
    @State private var sourceKind: SourceKindTab = .localProfile

    // Source-specific draft state
    @State private var localProfilePath: String = ""
    @State private var subscriptionURL: String = ""
    @State private var subscriptionInterval: Int = 60
    @State private var manualYAMLText: String = ""
    @State private var upstreamScheme: UpstreamScheme = .http
    @State private var upstreamHost: String = "127.0.0.1"
    @State private var upstreamPort: Int = 7890
    @State private var upstreamUsername: String = ""
    @State private var upstreamPassword: String = ""

    @State private var newFallbackNode: String = ""
    @State private var showAdvancedNetwork: Bool = false
    @State private var showRestartAlert: Bool = false
    @State private var showDeleteAlert: Bool = false

    private var savedOutlet: OutletConfig? {
        guard let id = selectedOutletID else { return appState.config.primaryOutlet() }
        return appState.config.outlet(id: id)
    }

    private var hasUnsavedChanges: Bool {
        guard let built = buildDraftWithSource(), let saved = savedOutlet else { return false }
        return built != saved
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow

                if let outlet = draftOutlet {
                    currentOutletAndNodeCard(outlet: outlet)
                    sourceConfigCard
                    advancedNetworkSection(outlet: outlet)

                    if hasUnsavedChanges {
                        unsavedChangesBar
                    }
                } else {
                    ContentUnavailableView(
                        "尚未配置代理出口",
                        systemImage: "network.slash",
                        description: Text("添加一个代理出口，将指定应用固定到目标节点。")
                    )
                    .padding(.vertical, 40)
                }
            }
            .padding(22)
        }
        .onAppear {
            loadInitialSelection()
        }
        .onChange(of: appState.config.outlets) { _, _ in
            if selectedOutletID == nil || appState.config.outlet(id: selectedOutletID!) == nil {
                loadInitialSelection()
            }
        }
        .alert("确定要重启代理出口吗？", isPresented: $showRestartAlert) {
            Button("重启", role: .destructive) {
                if let outlet = buildDraftWithSource() ?? savedOutlet {
                    Task { await appState.restartOutlet(outlet) }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("重启过程中，正在使用该出口的应用会短暂重连（约 1–2 秒）。")
        }
        .alert("确定要删除此代理出口吗？", isPresented: $showDeleteAlert) {
            Button("删除", role: .destructive) {
                if let id = draftOutlet?.id {
                    deleteOutlet(id: id)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let boundCount = draftOutlet.map { appState.config.targets(for: $0.id).count } ?? 0
            if boundCount > 0 {
                Text("当前仍有 \(String(boundCount)) 个代理应用绑定到此出口，删除后需要重新指定。")
            } else {
                Text("删除后此出口配置将被移除。")
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("代理出口")
                    .font(.title2.bold())
                Text("选择固定出口节点、测速并管理订阅来源。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.config.outlets.count > 1 {
                Picker("代理出口", selection: Binding(
                    get: { selectedOutletID ?? appState.config.outlets.first?.id ?? UUID() },
                    set: { id in
                        selectedOutletID = id
                        if let found = appState.config.outlet(id: id) {
                            populateDraft(from: found)
                        }
                    }
                )) {
                    ForEach(appState.config.outlets) { item in
                        Text("\(AppState.displayOutletName(item.name)) (:\(String(item.listenPort)))")
                            .tag(item.id)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }

            Button {
                addNewOutlet()
            } label: {
                Label("新增出口", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Layer 1A: Current Outlet Status & Node Selection

    private func currentOutletAndNodeCard(outlet: OutletConfig) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusDotLabel(
                            text: appState.outletRunning
                                ? "运行中\(appState.mihomoVersion.map { " · mihomo \($0)" } ?? "")"
                                : "已关闭（点击左上角总开关即可开启）",
                            color: appState.outletRunning ? .green : .secondary
                        )
                        if let sync = appState.lastSyncResult {
                            Text("· 已同步 \(AppState.relativeTimeString(from: sync.syncedAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 10) {
                        if let probe = appState.exitProbe, appState.outletRunning {
                            Text("当前出口：\(probe.country.map { "\($0) · " } ?? "")\(probe.ip)（\(String(probe.latencyMs)) ms）")
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                        } else {
                            Text("监听端口：\(outlet.listenHost):\(String(outlet.listenPort))")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        Task { await appState.probeExitIP(outlet: outlet) }
                    } label: {
                        if appState.isProbingExitIP {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("检测中…")
                            }
                        } else {
                            Text("测出口 IP")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning || appState.isProbingExitIP)

                    Button {
                        Task { await appState.testAllLatencies(outlet: outlet) }
                    } label: {
                        if appState.isTestingAllLatencies {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("测速中…")
                            }
                        } else {
                            Text("全部测速")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning || appState.isTestingAllLatencies)

                    Menu {
                        Button("立即同步订阅") {
                            Task { await appState.syncNow(outlet: outlet) }
                        }
                        .disabled(appState.isSyncing)

                        if appState.outletRunning {
                            Divider()
                            Button("重启出口…") {
                                showRestartAlert = true
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("更多操作")
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("主节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)

                    HStack(spacing: 8) {
                        TextField("输入或选择节点名称", text: binding(\.primaryNodeName))
                            .textFieldStyle(.roundedBorder)

                        if !appState.availableProfileNodes.isEmpty {
                            Menu("选择节点") {
                                ForEach(appState.availableProfileNodes, id: \.self) { node in
                                    Button(node) {
                                        draftOutlet?.primaryNodeName = node
                                    }
                                }
                            }
                            .fixedSize()
                        }

                        if let ms = appState.nodeLatenciesMs[outlet.primaryNodeName] {
                            latencyBadge(ms)
                        }

                        Button {
                            Task { await appState.testLatency(nodeName: outlet.primaryNodeName, outlet: outlet) }
                        } label: {
                            if appState.testingLatencyNodes.contains(outlet.primaryNodeName) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Text("测速")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(
                            !appState.outletRunning
                                || outlet.primaryNodeName.isEmpty
                                || appState.testingLatencyNodes.contains(outlet.primaryNodeName)
                        )
                    }
                }

                GridRow(alignment: .top) {
                    Text("备用节点")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        if !outlet.fallbackNodeNames.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(outlet.fallbackNodeNames, id: \.self) { node in
                                    HStack(spacing: 8) {
                                        Text(node)
                                            .font(.subheadline)
                                        Spacer()
                                        if let ms = appState.nodeLatenciesMs[node] {
                                            latencyBadge(ms)
                                        }
                                        Button {
                                            Task { await appState.testLatency(nodeName: node, outlet: outlet) }
                                        } label: {
                                            if appState.testingLatencyNodes.contains(node) {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Text("测速")
                                            }
                                        }
                                        .buttonStyle(.borderless)
                                        .controlSize(.small)
                                        .disabled(!appState.outletRunning || appState.testingLatencyNodes.contains(node))

                                        Button(role: .destructive) {
                                            draftOutlet?.fallbackNodeNames.removeAll { $0 == node }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .frame(width: 22, height: 22)
                                                .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.borderless)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.primary.opacity(0.04))
                                    )
                                }
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("添加备用节点名称…", text: $newFallbackNode)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    appendFallback(newFallbackNode)
                                    newFallbackNode = ""
                                }

                            if !appState.availableProfileNodes.isEmpty {
                                Menu("选择") {
                                    ForEach(appState.availableProfileNodes, id: \.self) { node in
                                        Button(node) {
                                            appendFallback(node)
                                        }
                                    }
                                }
                                .fixedSize()
                            }

                            Button("添加") {
                                appendFallback(newFallbackNode)
                                newFallbackNode = ""
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(newFallbackNode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Layer 1B: Subscription / Proxy Source

    private var sourceConfigCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("订阅与代理来源")
                    .font(.headline)
                Spacer()
                Button {
                    if let outlet = buildDraftWithSource() ?? savedOutlet {
                        Task { await appState.syncNow(outlet: outlet) }
                    }
                } label: {
                    if appState.isSyncing {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("同步中…")
                        }
                    } else {
                        Label("同步节点", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isSyncing)
            }

            Picker("来源类型", selection: $sourceKind) {
                ForEach(SourceKindTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            switch sourceKind {
            case .localProfile:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        TextField(
                            "~/Library/Application Support/com.follow.clash/profiles/...",
                            text: $localProfilePath
                        )
                        .textFieldStyle(.roundedBorder)

                        Button("选择…") {
                            browseForProfileYAML()
                        }
                    }

                    if !appState.discoveredFlClashProfiles.isEmpty {
                        HStack(spacing: 8) {
                            Text("本机已发现 FlClash 配置：")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(appState.discoveredFlClashProfiles.prefix(3), id: \.path) { url in
                                Button(url.lastPathComponent) {
                                    localProfilePath = url.path
                                    Task {
                                        if var updated = buildDraftWithSource() {
                                            updated.source = .localClashProfile(path: url.path)
                                            await appState.refreshAvailableNodes(for: updated)
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                        }
                    }

                    Text("订阅更新后将自动同步节点，并自动解析前置代理链。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .remoteSubscription:
                VStack(alignment: .leading, spacing: 8) {
                    TextField("https://provider.example.com/subscribe?...", text: $subscriptionURL)
                        .textFieldStyle(.roundedBorder)
                    Stepper("每 \(subscriptionInterval) 分钟自动刷新", value: $subscriptionInterval, in: 5...1440, step: 15)
                        .font(.subheadline)
                }

            case .manualYAML:
                VStack(alignment: .leading, spacing: 6) {
                    Text("粘贴 Clash 节点 YAML 片段：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $manualYAMLText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 110)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                                .allowsHitTesting(false)
                        )
                }

            case .upstreamProxy:
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("协议")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        Picker("协议", selection: $upstreamScheme) {
                            ForEach(UpstreamScheme.allCases, id: \.self) { scheme in
                                Text(scheme.rawValue.uppercased()).tag(scheme)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    GridRow {
                        Text("主机与端口")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        HStack {
                            TextField("127.0.0.1", text: $upstreamHost)
                                .textFieldStyle(.roundedBorder)
                            TextField("7890", value: $upstreamPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 85)
                        }
                    }
                    GridRow {
                        Text("认证（可选）")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        HStack {
                            TextField("用户名", text: $upstreamUsername)
                                .textFieldStyle(.roundedBorder)
                            SecureField("密码", text: $upstreamPassword)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Layer 2: Full-Row Clickable Collapsible Advanced Network Settings

    private func advancedNetworkSection(outlet: OutletConfig) -> some View {
        CollapsibleCard(title: "高级网络设置", isExpanded: $showAdvancedNetwork) {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("出口名称")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        TextField("主出口", text: binding(\.name))
                            .textFieldStyle(.roundedBorder)
                    }

                    GridRow {
                        Text("监听地址")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        HStack(spacing: 8) {
                            TextField("127.0.0.1", text: binding(\.listenHost))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                            Text(":")
                            TextField("17899", value: binding(\.listenPort), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("控制端口")
                                .foregroundStyle(.secondary)
                                .padding(.leading, 8)
                            TextField("17890", value: binding(\.controllerPort), format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }

                    GridRow {
                        Text("预期地区")
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .trailing)
                        HStack(spacing: 8) {
                            TextField("国家代码（如 US）", text: Binding(
                                get: { draftOutlet?.expectedCountryCode ?? "" },
                                set: { val in
                                    draftOutlet?.expectedCountryCode = val.isEmpty ? nil : val.uppercased()
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 150)

                            TextField("预期出口 IP 提示（可选）", text: Binding(
                                get: { draftOutlet?.expectedIPHint ?? "" },
                                set: { val in
                                    draftOutlet?.expectedIPHint = val.isEmpty ? nil : val
                                }
                            ))
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if appState.config.outlets.count > 1 {
                    Divider()
                    HStack {
                        Spacer()
                        Button("删除此出口…", role: .destructive) {
                            showDeleteAlert = true
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: - Contextual Save Bar (Only Shown When Dirty)

    private var unsavedChangesBar: some View {
        HStack(spacing: 10) {
            StatusDotLabel(text: "有未保存的更改", color: .orange, emphasized: true)
            Spacer()
            Button("还原") {
                if let saved = savedOutlet {
                    populateDraft(from: saved)
                }
            }
            .buttonStyle(.bordered)
            Button("保存并应用") {
                saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func latencyBadge(_ ms: Int) -> some View {
        let color: Color = ms < 180 ? .green : (ms < 400 ? .orange : .red)
        return Text("\(String(ms)) ms")
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }

    // MARK: - Draft Management

    private func loadInitialSelection() {
        let target = appState.config.primaryOutlet() ?? appState.config.outlets.first
        selectedOutletID = target?.id
        if let target {
            populateDraft(from: target)
            Task { await appState.refreshAvailableNodes(for: target) }
        } else {
            draftOutlet = nil
        }
    }

    private func populateDraft(from outlet: OutletConfig) {
        draftOutlet = outlet
        switch outlet.source {
        case .localClashProfile(let path):
            sourceKind = .localProfile
            localProfilePath = path
        case .remoteSubscription(let url, let interval):
            sourceKind = .remoteSubscription
            subscriptionURL = url
            subscriptionInterval = interval
        case .manualYAML(let yaml):
            sourceKind = .manualYAML
            manualYAMLText = yaml
        case .upstreamProxy(let scheme, let host, let port, let user, let pass):
            sourceKind = .upstreamProxy
            upstreamScheme = scheme
            upstreamHost = host
            upstreamPort = port
            upstreamUsername = user ?? ""
            upstreamPassword = pass ?? ""
        }
    }

    private func buildDraftWithSource() -> OutletConfig? {
        guard var outlet = draftOutlet else { return nil }
        switch sourceKind {
        case .localProfile:
            outlet.source = .localClashProfile(path: localProfilePath.trimmingCharacters(in: .whitespacesAndNewlines))
        case .remoteSubscription:
            outlet.source = .remoteSubscription(
                url: subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines),
                refreshIntervalMinutes: subscriptionInterval
            )
        case .manualYAML:
            outlet.source = .manualYAML(yaml: manualYAMLText)
        case .upstreamProxy:
            outlet.source = .upstreamProxy(
                scheme: upstreamScheme,
                host: upstreamHost.trimmingCharacters(in: .whitespacesAndNewlines),
                port: upstreamPort,
                username: upstreamUsername.isEmpty ? nil : upstreamUsername,
                password: upstreamPassword.isEmpty ? nil : upstreamPassword
            )
        }
        return outlet
    }

    private func saveDraft() {
        guard let updated = buildDraftWithSource() else { return }
        var cfg = appState.config
        if let idx = cfg.outlets.firstIndex(where: { $0.id == updated.id }) {
            cfg.outlets[idx] = updated
        } else {
            cfg.outlets.append(updated)
        }
        draftOutlet = updated
        Task {
            await appState.saveConfig(cfg, triggerSync: true)
            await appState.refreshAvailableNodes(for: updated)
        }
    }

    private func addNewOutlet() {
        let nextPort = (appState.config.outlets.map(\.listenPort).max() ?? 17898) + 1
        let nextCtrl = (appState.config.outlets.map(\.controllerPort).max() ?? 17889) + 1
        let newOutlet = OutletConfig(
            name: "代理出口 \(appState.config.outlets.count + 1)",
            listenPort: nextPort,
            controllerPort: nextCtrl,
            source: .localClashProfile(path: appState.discoveredFlClashProfiles.first?.path ?? ""),
            primaryNodeName: ""
        )
        var cfg = appState.config
        cfg.outlets.append(newOutlet)
        selectedOutletID = newOutlet.id
        populateDraft(from: newOutlet)
        Task { await appState.saveConfig(cfg, triggerSync: false) }
    }

    private func deleteOutlet(id: UUID) {
        var cfg = appState.config
        cfg.outlets.removeAll { $0.id == id }
        Task {
            await appState.saveConfig(cfg, triggerSync: false)
            loadInitialSelection()
        }
    }

    private func appendFallback(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var outlet = draftOutlet else { return }
        if !outlet.fallbackNodeNames.contains(trimmed) {
            outlet.fallbackNodeNames.append(trimmed)
            draftOutlet = outlet
        }
    }

    private func browseForProfileYAML() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "选择 Clash / FlClash 配置文件 (YAML)"
        if panel.runModal() == .OK, let url = panel.url {
            localProfilePath = url.path
            if var updated = buildDraftWithSource() {
                updated.source = .localClashProfile(path: url.path)
                Task { await appState.refreshAvailableNodes(for: updated) }
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<OutletConfig, T>) -> Binding<T> {
        Binding(
            get: { draftOutlet![keyPath: keyPath] },
            set: { newValue in
                draftOutlet?[keyPath: keyPath] = newValue
            }
        )
    }
}
