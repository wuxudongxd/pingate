import AppKit
import PinGateCore
import SwiftUI

private enum SourceKindTab: String, CaseIterable, Identifiable {
    case localProfile = "Local Profile"
    case remoteSubscription = "Subscription URL"
    case manualYAML = "Manual YAML"
    case upstreamProxy = "Upstream Proxy"

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
                        "No Outlets Configured",
                        systemImage: "network.slash",
                        description: Text("Add an outlet to pin applications to a fixed proxy node.")
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
                Text("Outlets")
                    .font(.title2.bold())
                Text("Configure fixed proxy outlets, subscription sync sources, and node fallbacks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if appState.config.outlets.count > 1 {
                Picker("Outlet", selection: Binding(
                    get: { selectedOutletID ?? appState.config.outlets.first?.id ?? UUID() },
                    set: { id in
                        selectedOutletID = id
                        if let found = appState.config.outlet(id: id) {
                            populateDraft(from: found)
                        }
                    }
                )) {
                    ForEach(appState.config.outlets) { item in
                        Text("\(item.name) (:\(item.listenPort))").tag(item.id)
                    }
                }
                .frame(width: 220)
            }

            Button {
                addNewOutlet()
            } label: {
                Label("Add Outlet", systemImage: "plus")
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
                        Text(appState.outletRunning ? "Managed Mihomo Running" : "Outlet Stopped")
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
                        Label("Controller :\(String(outlet.controllerPort))", systemImage: "slider.horizontal.3")
                            .font(.caption.monospaced())
                        if let sync = appState.lastSyncResult {
                            Label(
                                "Extracted \(sync.extractedProxyNames.count) proxy(ies) • \(sync.syncedAt, style: .relative) ago",
                                systemImage: "checkmark.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }

                    if let chain = appState.lastSyncResult?.extractedProxyNames, !chain.isEmpty {
                        HStack(spacing: 6) {
                            Text("Chain:")
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
                        Button(appState.outletRunning ? "Restart" : "Start") {
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
                            Button("Stop") {
                                Task { await appState.stopOutlet(outlet) }
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Sync Now") {
                            Task { await appState.syncNow(outlet: outlet) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(appState.isSyncing)

                        Button("Test Latency") {
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
        GroupBox("General & Listener") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Outlet Name")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    TextField("Primary Outlet", text: binding(\.name))
                        .textFieldStyle(.roundedBorder)
                    Toggle("Enabled", isOn: binding(\.enabled))
                }

                GridRow {
                    Text("Listen Address")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("127.0.0.1", text: binding(\.listenHost))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                        Text(":")
                        TextField("17899", value: binding(\.listenPort), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 85)
                        Text("Controller Port")
                            .foregroundStyle(.secondary)
                            .padding(.leading, 8)
                        TextField("17890", value: binding(\.controllerPort), format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 85)
                    }
                    EmptyView()
                }

                GridRow {
                    Text("Expected Region / IP")
                        .foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .trailing)
                    HStack(spacing: 8) {
                        TextField("Country (e.g. US)", text: Binding(
                            get: { draftOutlet?.expectedCountryCode ?? "" },
                            set: { val in
                                draftOutlet?.expectedCountryCode = val.isEmpty ? nil : val.uppercased()
                                dirty = true
                            }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)

                        TextField("Optional IP hint", text: Binding(
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
        GroupBox("Proxy Source") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source Type", selection: $sourceKind) {
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

                            Button("Browse…") {
                                browseForProfileYAML()
                            }
                        }

                        if !appState.discoveredFlClashProfiles.isEmpty {
                            HStack(spacing: 8) {
                                Text("Detected FlClash Profiles:")
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

                        Text("PinGate watches this YAML file via DispatchSource and hot-reloads Mihomo automatically whenever your subscription refreshes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                case .remoteSubscription:
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("https://provider.example.com/subscribe?...", text: $subscriptionURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: subscriptionURL) { _, _ in dirty = true }
                        Stepper("Refresh every \(subscriptionInterval) minutes", value: $subscriptionInterval, in: 5...1440, step: 15)
                            .onChange(of: subscriptionInterval) { _, _ in dirty = true }
                    }

                case .manualYAML:
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Paste a Clash `proxies:` YAML block (stored with 0600 permissions):")
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
                            Text("Scheme").foregroundStyle(.secondary)
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
                            Text("Host & Port").foregroundStyle(.secondary)
                            HStack {
                                TextField("127.0.0.1", text: $upstreamHost)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: upstreamHost) { _, _ in dirty = true }
                                TextField("7890", value: $upstreamPort, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 85)
                                    .onChange(of: upstreamPort) { _, _ in dirty = true }
                            }
                        }
                        GridRow {
                            Text("Auth (Optional)").foregroundStyle(.secondary)
                            HStack {
                                TextField("Username", text: $upstreamUsername)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: upstreamUsername) { _, _ in dirty = true }
                                SecureField("Password", text: $upstreamPassword)
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
        GroupBox("Primary & Fallback Nodes (with Automatic dialer-proxy Resolution)") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Text("Primary Node")
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    TextField("Exact Clash proxy name", text: binding(\.primaryNodeName))
                        .textFieldStyle(.roundedBorder)

                    if !appState.availableProfileNodes.isEmpty {
                        Menu("Pick from Profile") {
                            ForEach(appState.availableProfileNodes, id: \.self) { node in
                                Button(node) {
                                    draftOutlet?.primaryNodeName = node
                                    dirty = true
                                }
                            }
                        }
                        .frame(width: 150)
                    }

                    if let ms = appState.nodeLatenciesMs[outlet.primaryNodeName] {
                        latencyBadge(ms)
                    }

                    Button("Ping") {
                        Task { await appState.testLatency(nodeName: outlet.primaryNodeName, outlet: outlet) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning || outlet.primaryNodeName.isEmpty)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Fallback Nodes")
                        .font(.subheadline.weight(.medium))

                    if outlet.fallbackNodeNames.isEmpty {
                        Text("No fallback nodes configured.")
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
                                Button("Ping") {
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
                        TextField("Add fallback node name…", text: $newFallbackNode)
                            .textFieldStyle(.roundedBorder)
                        if !appState.availableProfileNodes.isEmpty {
                            Menu("Pick") {
                                ForEach(appState.availableProfileNodes, id: \.self) { node in
                                    Button(node) {
                                        appendFallback(node)
                                    }
                                }
                            }
                        }
                        Button("Add") {
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
                Button("Delete Outlet", role: .destructive) {
                    deleteOutlet(id: id)
                }
            }

            Spacer()

            if dirty {
                Text("Unsaved changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("Save & Apply") {
                saveDraft()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftOutlet == nil)
        }
    }

    private func latencyBadge(_ ms: Int) -> some View {
        let color: Color = ms < 180 ? .green : (ms < 400 ? .orange : .red)
        return Text("\(ms) ms")
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
            name: "Outlet \(appState.config.outlets.count + 1)",
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
        panel.title = "Select Clash / FlClash Profile YAML"
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
