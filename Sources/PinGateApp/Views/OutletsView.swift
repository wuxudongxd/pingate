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
    @State private var dirty: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow

                if let outlet = draftOutlet {
                    runtimeCard(for: outlet)
                    basicSettingsCard(outlet: outlet)
                    sourceConfigCard
                    nodeSelectionCard(outlet: outlet)
                    actionBar
                } else {
                    ContentUnavailableView(
                        "尚未配置出口通道",
                        systemImage: "network.slash",
                        description: Text("添加一个出口通道，将目标应用固定到指定代理节点。")
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
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("出口通道")
                    .font(.title2.bold())
                Text("配置固定代理出口、订阅自动同步源及主备节点切换。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.config.outlets.count > 1 {
                Picker("出口通道", selection: Binding(
                    get: { selectedOutletID ?? appState.config.outlets.first?.id ?? UUID() },
                    set: { id in
                        selectedOutletID = id
                        if let found = appState.config.outlet(id: id) {
                            populateDraft(from: found)
                        }
                    }
                )) {
                    ForEach(appState.config.outlets) { item in
                        Text("\(item.name) (:\(String(item.listenPort)))").tag(item.id)
                    }
                }
                .frame(width: 220)
            }

            Button {
                addNewOutlet()
            } label: {
                Label("新增出口", systemImage: "plus")
            }
            .buttonStyle(.bordered)
        }
    }

    private func runtimeCard(for outlet: OutletConfig) -> some View {
        GroupBox {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(appState.outletRunning ? Color.green : Color.secondary)
                            .frame(width: 10, height: 10)
                        Text(appState.outletRunning ? "托管 mihomo 运行中" : "出口已停止")
                            .font(.headline)
                        if let version = appState.mihomoVersion {
                            Text(version)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                        }
                    }

                    HStack(spacing: 14) {
                        Label("\(outlet.listenHost):\(String(outlet.listenPort))", systemImage: "arrow.left.arrow.right")
                            .font(.caption.monospaced())
                        Label("控制端口 :\(String(outlet.controllerPort))", systemImage: "slider.horizontal.3")
                            .font(.caption.monospaced())
                        if let sync = appState.lastSyncResult {
                            Label(
                                "已提取 \(sync.extractedProxyNames.count) 个节点 • \(AppState.relativeTimeString(from: sync.syncedAt))",
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let chain = appState.lastSyncResult?.extractedProxyNames, !chain.isEmpty {
                        HStack(spacing: 6) {
                            Text("代理链：")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(chain, id: \.self) { name in
                                Text(name)
                                    .font(.caption2)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            }
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    HStack(spacing: 8) {
                        Button(appState.outletRunning ? "重启" : "启动") {
                            Task {
                                if appState.outletRunning {
                                    await appState.restartOutlet(outlet)
                                } else {
                                    await appState.startOutlet(outlet)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)

                        if appState.outletRunning {
                            Button("停止") {
                                Task { await appState.stopOutlet(outlet) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("立即同步") {
                            Task { await appState.syncNow(outlet: outlet) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.isSyncing)

                        Button("测试延迟") {
                            Task { await appState.testAllLatencies(outlet: outlet) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!appState.outletRunning)
                    }
                }
            }
            .padding(6)
        }
    }

    private func basicSettingsCard(outlet: OutletConfig) -> some View {
        GroupBox("常规与监听配置") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("出口名称")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    TextField("主出口通道", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                    Toggle("启用", isOn: binding(\.enabled))
                }

                GridRow {
                    Text("监听地址")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("127.0.0.1", text: binding(\.listenHost))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Text(":")
                        TextField("17899", value: binding(\.listenPort), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 85)
                        Text("控制端口")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                        TextField("17890", value: binding(\.controllerPort), format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 85)
                    }
                    EmptyView()
                }

                GridRow {
                    Text("预期地区 / IP")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("国家代码（如 US）", text: Binding(
                            get: { draftOutlet?.expectedCountryCode ?? "" },
                            set: { val in
                                draftOutlet?.expectedCountryCode = val.isEmpty ? nil : val.uppercased()
                                dirty = true
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)

                        TextField("可选出口 IP 提示", text: Binding(
                            get: { draftOutlet?.expectedIPHint ?? "" },
                            set: { val in
                                draftOutlet?.expectedIPHint = val.isEmpty ? nil : val
                                dirty = true
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                    }
                    EmptyView()
                }
            }
            .padding(8)
        }
    }

    private var sourceConfigCard: some View {
        GroupBox("代理来源") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("来源类型", selection: $sourceKind) {
                    ForEach(SourceKindTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: sourceKind) { _, _ in
                    dirty = true
                }

                switch sourceKind {
                case .localProfile:
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField(
                                "~/Library/Application Support/com.follow.clash/profiles/...",
                                text: $localProfilePath
                            )
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: localProfilePath) { _, _ in dirty = true }

                            Button("选择…") {
                                browseForProfileYAML()
                            }
                        }

                        if !appState.discoveredFlClashProfiles.isEmpty {
                            HStack(spacing: 8) {
                                Text("已发现的 FlClash 配置：")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                ForEach(appState.discoveredFlClashProfiles.prefix(3), id: \.path) { url in
                                    Button(url.lastPathComponent) {
                                        localProfilePath = url.path
                                        dirty = true
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

                        Text("PinGate 通过 DispatchSource 监听该 YAML 文件变更，订阅更新时自动提取节点并热重载 mihomo。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .remoteSubscription:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://provider.example.com/subscribe?...", text: $subscriptionURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: subscriptionURL) { _, _ in dirty = true }
                        Stepper("每 \(subscriptionInterval) 分钟自动刷新", value: $subscriptionInterval, in: 5...1440, step: 15)
                            .onChange(of: subscriptionInterval) { _, _ in dirty = true }
                    }

                case .manualYAML:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("粘贴 Clash proxies YAML 片段（将以 0600 权限安全存储）：")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $manualYAMLText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 110)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                            )
                            .onChange(of: manualYAMLText) { _, _ in dirty = true }
                    }

                case .upstreamProxy:
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                        GridRow {
                            Text("协议").foregroundStyle(.secondary)
                            Picker("", selection: $upstreamScheme) {
                                ForEach(UpstreamScheme.allCases, id: \.self) { scheme in
                                    Text(scheme.rawValue.uppercased()).tag(scheme)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            .onChange(of: upstreamScheme) { _, _ in dirty = true }
                        }
                        GridRow {
                            Text("主机与端口").foregroundStyle(.secondary)
                            HStack {
                                TextField("127.0.0.1", text: $upstreamHost)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: upstreamHost) { _, _ in dirty = true }
                                TextField("7890", value: $upstreamPort, format: .number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 85)
                                    .onChange(of: upstreamPort) { _, _ in dirty = true }
                            }
                        }
                        GridRow {
                            Text("认证（可选）").foregroundStyle(.secondary)
                            HStack {
                                TextField("用户名", text: $upstreamUsername)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: upstreamUsername) { _, _ in dirty = true }
                                SecureField("密码", text: $upstreamPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: upstreamPassword) { _, _ in dirty = true }
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private func nodeSelectionCard(outlet: OutletConfig) -> some View {
        GroupBox("主备节点（自动递归解析 dialer-proxy 链）") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("主节点")
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    TextField("Clash 节点精确名称", text: binding(\.primaryNodeName))
                        .textFieldStyle(.roundedBorder)

                    if !appState.availableProfileNodes.isEmpty {
                        Menu("从配置选择") {
                            ForEach(appState.availableProfileNodes, id: \.self) { node in
                                Button(node) {
                                    draftOutlet?.primaryNodeName = node
                                    dirty = true
                                }
                            }
                        }
                        .frame(width: 130)
                    }

                    if let ms = appState.nodeLatenciesMs[outlet.primaryNodeName] {
                        latencyBadge(ms)
                    }

                    Button("测速") {
                        Task { await appState.testLatency(nodeName: outlet.primaryNodeName, outlet: outlet) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning || outlet.primaryNodeName.isEmpty)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("备用节点")
                        .font(.subheadline.weight(.medium))

                    if outlet.fallbackNodeNames.isEmpty {
                        Text("暂未配置备用节点。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(outlet.fallbackNodeNames, id: \.self) { node in
                            HStack {
                                Text(node)
                                    .font(.body)
                                Spacer()
                                if let ms = appState.nodeLatenciesMs[node] {
                                    latencyBadge(ms)
                                }
                                Button("测速") {
                                    Task { await appState.testLatency(nodeName: node, outlet: outlet) }
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(!appState.outletRunning)

                                Button(role: .destructive) {
                                    draftOutlet?.fallbackNodeNames.removeAll { $0 == node }
                                    dirty = true
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    HStack {
                        TextField("输入备用节点名称…", text: $newFallbackNode)
                            .textFieldStyle(.roundedBorder)
                        if !appState.availableProfileNodes.isEmpty {
                            Menu("选择") {
                                ForEach(appState.availableProfileNodes, id: \.self) { node in
                                    Button(node) {
                                        appendFallback(node)
                                    }
                                }
                            }
                        }
                        Button("添加") {
                            appendFallback(newFallbackNode)
                            newFallbackNode = ""
                        }
                        .disabled(newFallbackNode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(8)
        }
    }

    private var actionBar: some View {
        HStack {
            if appState.config.outlets.count > 1, let id = draftOutlet?.id {
                Button("删除出口", role: .destructive) {
                    deleteOutlet(id: id)
                }
            }

            Spacer()

            if dirty {
                Text("有未保存的更改")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("保存并应用") {
                saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftOutlet == nil)
        }
    }

    private func latencyBadge(_ ms: Int) -> some View {
        let color: Color = ms < 180 ? .green : (ms < 400 ? .orange : .red)
        return Text("\(String(ms)) ms")
            .font(.caption2.monospaced().weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

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
        dirty = false
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
        dirty = false
        Task {
            await appState.saveConfig(cfg, triggerSync: true)
            await appState.refreshAvailableNodes(for: updated)
        }
    }

    private func addNewOutlet() {
        let nextPort = (appState.config.outlets.map(\.listenPort).max() ?? 17898) + 1
        let nextCtrl = (appState.config.outlets.map(\.controllerPort).max() ?? 17889) + 1
        let newOutlet = OutletConfig(
            name: "出口通道 \(appState.config.outlets.count + 1)",
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
            dirty = true
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
            dirty = true
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
                dirty = true
            }
        )
    }
}
