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
                Text("纳管目标")
                    .font(.title2.bold())
                Text("为桌面应用注入固定出口，管理 CLI Shim 并同步 T3 Code 环境配置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                guard let outletID = appState.config.primaryOutlet()?.id else { return }
                isCreatingNew = true
                editingTarget = ManagedTarget(
                    name: "新建应用",
                    kind: .guiApp,
                    outletID: outletID,
                    appPath: "/Applications/",
                    chromiumProxyFlags: true,
                    extraEnv: ["NODE_USE_ENV_PROXY": "1"]
                )
            } label: {
                Label("新增目标", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(appState.config.outlets.isEmpty)
        }
    }

    private var templatesSection: some View {
        GroupBox("内置模板") {
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
                        Button("应用模板") {
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
        GroupBox("已纳管目标（\(String(appState.config.targets.count))）") {
            if appState.config.targets.isEmpty {
                Text("暂未配置纳管目标。请应用上方模板或手动新增目标。")
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
        let outletName = appState.config.outlet(id: target.outletID)?.name ?? "未知出口"

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
                        badge("漏网 / 未走代理", color: .red)
                    } else if !processes.isEmpty {
                        badge("\(String(proxiedCount)) 条代理", color: .green)
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
                            Text("Chromium 代理参数")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    case .cliTool:
                        let cmd = target.cliCommandName ?? target.name
                        let installed = appState.cliShimStatuses[target.id] ?? false
                        Label("~/.local/bin/\(cmd)", systemImage: "terminal")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        badge(installed ? "Shim 已安装" : "Shim 未安装", color: installed ? .green : .orange)
                    case .t3Integration:
                        let synced = appState.t3SyncStatuses[target.id] ?? false
                        Label(target.t3SettingsPath ?? "~/.t3/userdata/settings.json", systemImage: "doc.text")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        badge(synced ? "已同步" : "待同步", color: synced ? .green : .orange)
                    }
                }
            }

            Spacer()

            HStack(spacing: 8) {
                switch target.kind {
                case .guiApp:
                    if isLeaking {
                        Button("用代理重启") {
                            Task { await appState.restartTargetWithProxy(target: target) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    } else {
                        Button(processes.isEmpty ? "启动" : "激活窗口") {
                            Task { await appState.launchOrActivate(target: target) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .cliTool:
                    let installed = appState.cliShimStatuses[target.id] ?? false
                    Button(installed ? "重装 Shim" : "安装 Shim") {
                        Task { await appState.installCLIShim(for: target) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    if installed {
                        Button("移除") {
                            Task { await appState.removeCLIShim(for: target) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                case .t3Integration:
                    Button("同步 T3 Code") {
                        Task { await appState.syncT3Code(for: target) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("编辑") {
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
            Text(isNew ? "新增纳管目标" : "编辑 \(draft.name)")
                .font(.title3.bold())

            Form {
                TextField("名称", text: $draft.name)
                Picker("类型", selection: $draft.kind) {
                    ForEach(TargetKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                Picker("绑定出口", selection: $draft.outletID) {
                    ForEach(outlets) { outlet in
                        Text("\(outlet.name) (:\(String(outlet.listenPort)))").tag(outlet.id)
                    }
                }
                TextField("进程匹配名（逗号分隔）", text: $processNamesCSV)

                switch draft.kind {
                case .guiApp:
                    TextField("Bundle ID", text: Binding(
                        get: { draft.bundleID ?? "" },
                        set: { draft.bundleID = $0.isEmpty ? nil : $0 }
                    ))
                    HStack {
                        TextField("应用路径", text: Binding(
                            get: { draft.appPath ?? "" },
                            set: { draft.appPath = $0.isEmpty ? nil : $0 }
                        ))
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.directoryURL = URL(fileURLWithPath: "/Applications")
                            panel.title = "选择应用程序"
                            if panel.runModal() == .OK, let url = panel.url {
                                draft.appPath = url.path
                            }
                        }
                    }
                    Toggle("注入 Chromium 代理与禁用 QUIC 参数", isOn: $draft.chromiumProxyFlags)

                case .cliTool:
                    TextField("CLI 命令名（位于 ~/.local/bin）", text: Binding(
                        get: { draft.cliCommandName ?? "" },
                        set: { draft.cliCommandName = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("原始二进制路径", text: Binding(
                        get: { draft.cliTargetBinaryPath ?? "" },
                        set: { draft.cliTargetBinaryPath = $0.isEmpty ? nil : $0 }
                    ))

                case .t3Integration:
                    TextField("T3 配置文件路径", text: Binding(
                        get: { draft.t3SettingsPath ?? "~/.t3/userdata/settings.json" },
                        set: { draft.t3SettingsPath = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("Provider 键名", text: Binding(
                        get: { draft.t3ProviderKey ?? "antigravity" },
                        set: { draft.t3ProviderKey = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
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
