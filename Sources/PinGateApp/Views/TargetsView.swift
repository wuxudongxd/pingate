import AppKit
import PinGateCore
import SwiftUI

struct TargetsView: View {
    @Bindable var appState: AppState
    @State private var editingTarget: ManagedTarget?
    @State private var isCreatingNew = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                templatesSection
                targetsListSection
            }
            .padding(22)
        }
        .sheet(item: $editingTarget) { target in
            TargetEditorSheet(
                target: target,
                outlets: appState.config.outlets,
                isNew: isCreatingNew
            ) { saved in
                var cfg = appState.config
                if let idx = cfg.targets.firstIndex(where: { $0.id == saved.id }) {
                    cfg.targets[idx] = saved
                } else {
                    cfg.targets.append(saved)
                }
                Task { await appState.saveConfig(cfg, triggerSync: false) }
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Managed Targets")
                    .font(.title2.bold())
                Text("Pin GUI apps, install CLI shims, and keep T3 Code provider environments synchronized.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let outletID = appState.config.primaryOutlet()?.id else { return }
                isCreatingNew = true
                editingTarget = ManagedTarget(
                    name: "New App",
                    kind: .guiApp,
                    outletID: outletID,
                    appPath: "/Applications/",
                    chromiumProxyFlags: true,
                    extraEnv: ["NODE_USE_ENV_PROXY": "1"]
                )
            } label: {
                Label("Add Target", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.config.outlets.isEmpty)
        }
    }

    private var templatesSection: some View {
        GroupBox("Built-in Templates") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 12)], spacing: 12) {
                ForEach(PinGateTemplates.all) { template in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: template.iconSystemName)
                                .foregroundStyle(Color.accentColor)
                            Text(template.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        Text(template.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 0)
                        Button("Apply Template") {
                            Task { await appState.applyTemplate(template) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .frame(minHeight: 112)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                }
            }
            .padding(6)
        }
    }

    private var targetsListSection: some View {
        GroupBox("Active Targets (\(appState.config.targets.count))") {
            if appState.config.targets.isEmpty {
                Text("No managed targets yet. Apply a template above or add a custom target.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 10) {
                    ForEach(appState.config.targets) { target in
                        targetRow(target)
                    }
                }
                .padding(6)
            }
        }
    }

    private func targetRow(_ target: ManagedTarget) -> some View {
        let processes = appState.processesForTarget(target)
        let isLeaking = appState.isTargetLeaking(target)
        let proxiedCount = appState.proxiedConnectionCount(for: target)
        let outletName = appState.config.outlet(id: target.outletID)?.name ?? "Unknown Outlet"

        return HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { target.enabled },
                    set: { enabled in
                        var cfg = appState.config
                        if let idx = cfg.targets.firstIndex(where: { $0.id == target.id }) {
                            cfg.targets[idx].enabled = enabled
                            Task { await appState.saveConfig(cfg, triggerSync: false) }
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.headline)
                    badge(target.kind.displayName, color: .secondary)
                    badge(outletName, color: .accentColor)

                    if isLeaking {
                        badge("LEAK / UNPROXIED", color: .red)
                    } else if !processes.isEmpty {
                        badge("\(proxiedCount) proxied", color: .green)
                    }
                }

                HStack(spacing: 12) {
                    switch target.kind {
                    case .guiApp:
                        if let appPath = target.appPath {
                            Label(appPath, systemImage: "folder")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if target.chromiumProxyFlags {
                            Text("Chromium flags")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    case .cliTool:
                        let cmd = target.cliCommandName ?? target.name
                        let installed = appState.cliShimStatuses[target.id] ?? false
                        Label("~/.local/bin/\(cmd)", systemImage: "terminal")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        badge(installed ? "Shim Installed" : "Shim Not Installed", color: installed ? .green : .orange)
                    case .t3Integration:
                        let synced = appState.t3SyncStatuses[target.id] ?? false
                        Label(target.t3SettingsPath ?? "~/.t3/userdata/settings.json", systemImage: "doc.text")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        badge(synced ? "Synced" : "Needs Sync", color: synced ? .green : .orange)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                switch target.kind {
                case .guiApp:
                    if isLeaking {
                        Button("Restart with Proxy") {
                            Task { await appState.restartTargetWithProxy(target: target) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    } else {
                        Button(processes.isEmpty ? "Launch" : "Activate") {
                            Task { await appState.launchOrActivate(target: target) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .cliTool:
                    let installed = appState.cliShimStatuses[target.id] ?? false
                    Button(installed ? "Reinstall Shim" : "Install Shim") {
                        Task { await appState.installCLIShim(for: target) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if installed {
                        Button("Remove") {
                            Task { await appState.removeCLIShim(for: target) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .t3Integration:
                    Button("Sync T3 Code") {
                        Task { await appState.syncT3Code(for: target) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("Edit") {
                    isCreatingNew = false
                    editingTarget = target
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(role: .destructive) {
                    var cfg = appState.config
                    cfg.targets.removeAll { $0.id == target.id }
                    Task { await appState.saveConfig(cfg, triggerSync: false) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isLeaking ? Color.red.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLeaking ? Color.red.opacity(0.35) : Color.secondary.opacity(0.14), lineWidth: 1)
        )
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

private struct TargetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManagedTarget
    @State private var processNamesCSV: String
    let outlets: [OutletConfig]
    let isNew: Bool
    let onSave: (ManagedTarget) -> Void

    init(target: ManagedTarget, outlets: [OutletConfig], isNew: Bool, onSave: @escaping (ManagedTarget) -> Void) {
        self._draft = State(initialValue: target)
        self._processNamesCSV = State(initialValue: target.processMatchNames.joined(separator: ", "))
        self.outlets = outlets
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isNew ? "Add Managed Target" : "Edit \(draft.name)")
                .font(.title3.bold())

            Form {
                TextField("Name", text: $draft.name)
                Picker("Kind", selection: $draft.kind) {
                    ForEach(TargetKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker("Outlet", selection: $draft.outletID) {
                    ForEach(outlets) { outlet in
                        Text("\(outlet.name) (:\(outlet.listenPort))").tag(outlet.id)
                    }
                }
                TextField("Process Match Names (comma-separated)", text: $processNamesCSV)

                switch draft.kind {
                case .guiApp:
                    TextField("Bundle ID", text: Binding(
                        get: { draft.bundleID ?? "" },
                        set: { draft.bundleID = $0.isEmpty ? nil : $0 }
                    ))
                    HStack {
                        TextField("App Path", text: Binding(
                            get: { draft.appPath ?? "" },
                            set: { draft.appPath = $0.isEmpty ? nil : $0 }
                        ))
                        Button("Browse…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            if panel.runModal() == .OK, let url = panel.url {
                                draft.appPath = url.path
                            }
                        }
                    }
                    Toggle("Inject Chromium Proxy & Disable-QUIC Flags", isOn: $draft.chromiumProxyFlags)

                case .cliTool:
                    TextField("CLI Command Name (in ~/.local/bin)", text: Binding(
                        get: { draft.cliCommandName ?? "" },
                        set: { draft.cliCommandName = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Real Target Binary Path", text: Binding(
                        get: { draft.cliTargetBinaryPath ?? "" },
                        set: { draft.cliTargetBinaryPath = $0.isEmpty ? nil : $0 }
                    ))

                case .t3Integration:
                    TextField("T3 Settings Path", text: Binding(
                        get: { draft.t3SettingsPath ?? "~/.t3/userdata/settings.json" },
                        set: { draft.t3SettingsPath = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Provider Key", text: Binding(
                        get: { draft.t3ProviderKey ?? "antigravity" },
                        set: { draft.t3ProviderKey = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    draft.processMatchNames = processNamesCSV
                        .split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
