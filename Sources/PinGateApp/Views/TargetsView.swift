import AppKit
import PinGateCore
import SwiftUI

struct TargetsView: View {
    @Bindable var appState: AppState
    @State private var editingTarget: ManagedTarget?
    @State private var isCreatingNew = false
    @State private var targetPendingDelete: ManagedTarget?
    @State private var targetPendingRemoveShim: ManagedTarget?
    @State private var targetPendingRestart: ManagedTarget?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
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
        .alert(
            "确定要删除「\(targetPendingDelete?.name ?? "")」吗？",
            isPresented: Binding(
                get: { targetPendingDelete != nil },
                set: { if !$0 { targetPendingDelete = nil } }
            )
        ) {
            Button("删除", role: .destructive) {
                if let target = targetPendingDelete {
                    targetPendingDelete = nil
                    var cfg = appState.config
                    cfg.targets.removeAll { $0.id == target.id }
                    Task { await appState.saveConfig(cfg, triggerSync: false) }
                }
            }
            Button("取消", role: .cancel) { targetPendingDelete = nil }
        } message: {
            Text("删除后将不再监控或代理该应用。")
        }
        .alert(
            "确定要移除「\(targetPendingRemoveShim?.cliCommandName ?? "")」命令吗？",
            isPresented: Binding(
                get: { targetPendingRemoveShim != nil },
                set: { if !$0 { targetPendingRemoveShim = nil } }
            )
        ) {
            Button("移除命令", role: .destructive) {
                if let target = targetPendingRemoveShim {
                    targetPendingRemoveShim = nil
                    Task { await appState.removeCLIShim(for: target) }
                }
            }
            Button("取消", role: .cancel) { targetPendingRemoveShim = nil }
        } message: {
            Text("移除后在终端直接运行该命令将不再自动走代理。")
        }
        .alert(
            "重启「\(targetPendingRestart?.name ?? "")」并走代理？",
            isPresented: Binding(
                get: { targetPendingRestart != nil },
                set: { if !$0 { targetPendingRestart = nil } }
            )
        ) {
            Button("重启并走代理", role: .destructive) {
                if let target = targetPendingRestart {
                    targetPendingRestart = nil
                    Task { await appState.restartTargetWithProxy(target: target) }
                }
            }
            Button("取消", role: .cancel) { targetPendingRestart = nil }
        } message: {
            Text("将关闭当前未走代理的实例，并通过代理重新启动。")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("代理应用")
                    .font(.title2.bold())
                Text("管理需要固定走代理的桌面应用、命令行工具与集成配置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Section("从常用模板添加") {
                    ForEach(PinGateTemplates.all.filter { $0.id != PinGateTemplates.custom.id }) { template in
                        Button {
                            Task { await appState.applyTemplate(template) }
                        } label: {
                            Label(template.name, systemImage: template.iconSystemName)
                        }
                    }
                }
                Divider()
                Button {
                    openCreateCustomSheet()
                } label: {
                    Label("自定义应用或命令…", systemImage: "plus.app")
                }
            } label: {
                Label("添加应用", systemImage: "plus")
            }
            .menuStyle(.borderedButton)
            .fixedSize()
            .disabled(appState.config.outlets.isEmpty)
        }
    }

    @ViewBuilder
    private var targetsListSection: some View {
        if appState.config.targets.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("尚未添加任何代理应用")
                    .font(.headline)
                Text("你可以从下方常用模板一键添加，或点击右上角「添加应用」手动配置。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(PinGateTemplates.all.filter { $0.id != PinGateTemplates.custom.id }) { template in
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
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            Button("一键添加") {
                                Task { await appState.applyTemplate(template) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(12)
                        .frame(minHeight: 105)
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
                }
            }
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            )
        } else {
            VStack(spacing: 10) {
                ForEach(appState.config.targets) { target in
                    targetRow(target)
                }
            }
        }
    }

    private func targetRow(_ target: ManagedTarget) -> some View {
        let processes = appState.processesForTarget(target)
        let isLeaking = appState.isTargetLeaking(target)
        let proxiedCount = appState.proxiedConnectionCount(for: target)
        let isBusy = appState.busyTargetIDs.contains(target.id)
        let showOutletTag = appState.config.outlets.count > 1
        let outletName = appState.config.outlet(id: target.outletID).map { AppState.displayOutletName($0.name) } ?? "主出口"

        return HStack(spacing: 12) {
            Toggle(
                "监控 \(target.name)",
                isOn: Binding(
                    get: { target.enabled },
                    set: { enabled in
                        var cfg = appState.config
                        if let idx = cfg.targets.firstIndex(where: { $0.id == target.id }) {
                            cfg.targets[idx].enabled = enabled
                            Task {
                                await appState.saveConfig(cfg, triggerSync: false)
                                if !enabled {
                                    appState.showStatusBanner("已暂停「\(target.name)」的代理监控")
                                }
                            }
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(target.enabled ? "暂停该应用的代理监控" : "开启该应用的代理监控")

            TargetIconView(
                target: target,
                size: 28,
                tintColor: isLeaking ? .red : (target.enabled ? .accentColor : .secondary)
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.headline)

                    if showOutletTag {
                        Text(outletName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                            .foregroundStyle(.secondary)
                    }

                    targetStatusSummary(
                        target: target,
                        processes: processes,
                        isLeaking: isLeaking,
                        proxiedCount: proxiedCount
                    )
                }

                Text(targetDetailPath(target))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    primaryActionButton(target: target, processes: processes, isLeaking: isLeaking)
                }

                Menu {
                    Button("编辑…") {
                        isCreatingNew = false
                        editingTarget = target
                    }

                    switch target.kind {
                    case .guiApp:
                        Button("重启并走代理…") {
                            targetPendingRestart = target
                        }
                    case .cliTool:
                        let installed = appState.cliShimStatuses[target.id] ?? false
                        Button(installed ? "重新安装命令" : "安装命令") {
                            Task { await appState.installCLIShim(for: target) }
                        }
                        if installed {
                            Button("移除命令…", role: .destructive) {
                                targetPendingRemoveShim = target
                            }
                        }
                    case .t3Integration:
                        Button("立即同步") {
                            Task { await appState.syncT3Code(for: target) }
                        }
                    }

                    Divider()

                    Button("删除…", role: .destructive) {
                        targetPendingDelete = target
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("更多操作")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .opacity(target.enabled ? 1.0 : 0.58)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isLeaking ? Color.red.opacity(0.07) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLeaking ? Color.red.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    @ViewBuilder
    private func targetStatusSummary(
        target: ManagedTarget,
        processes: [ProcessAudit],
        isLeaking: Bool,
        proxiedCount: Int
    ) -> some View {
        if !target.enabled {
            StatusDotLabel(text: "已暂停", color: .secondary.opacity(0.5))
        } else if isLeaking {
            Text("未走代理")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.18)))
                .foregroundStyle(.red)
        } else {
            switch target.kind {
            case .guiApp:
                if !processes.isEmpty {
                    StatusDotLabel(
                        text: proxiedCount > 0 ? "运行中 · \(String(proxiedCount)) 条连接" : "运行中 · 保护中",
                        color: .green
                    )
                } else {
                    StatusDotLabel(text: "未运行", color: .secondary.opacity(0.5))
                }
            case .cliTool:
                let installed = appState.cliShimStatuses[target.id] ?? false
                StatusDotLabel(
                    text: installed ? "命令已就绪" : "未安装命令",
                    color: installed ? .green : .orange
                )
            case .t3Integration:
                let synced = appState.t3SyncStatuses[target.id] ?? false
                StatusDotLabel(
                    text: synced ? "配置已同步" : "待同步",
                    color: synced ? .green : .orange
                )
            }
        }
    }

    private func targetDetailPath(_ target: ManagedTarget) -> String {
        switch target.kind {
        case .guiApp:
            return target.appPath ?? "未指定应用路径"
        case .cliTool:
            let cmd = target.cliCommandName ?? target.name
            return "~/.local/bin/\(cmd)"
        case .t3Integration:
            return target.t3SettingsPath ?? "~/.t3/userdata/settings.json"
        }
    }

    @ViewBuilder
    private func primaryActionButton(target: ManagedTarget, processes: [ProcessAudit], isLeaking: Bool) -> some View {
        switch target.kind {
        case .guiApp:
            if isLeaking {
                Button("重启并走代理") {
                    targetPendingRestart = target
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                Button(processes.isEmpty ? "启动" : "打开") {
                    Task { await appState.launchOrActivate(target: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .cliTool:
            let installed = appState.cliShimStatuses[target.id] ?? false
            if installed {
                Button("更新命令") {
                    Task { await appState.installCLIShim(for: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("安装命令") {
                    Task { await appState.installCLIShim(for: target) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .t3Integration:
            let synced = appState.t3SyncStatuses[target.id] ?? false
            if synced {
                Button("重新同步") {
                    Task { await appState.syncT3Code(for: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else {
                Button("同步") {
                    Task { await appState.syncT3Code(for: target) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private func openCreateCustomSheet() {
        guard let outletID = appState.config.primaryOutlet()?.id else { return }
        isCreatingNew = true
        editingTarget = ManagedTarget(
            name: "",
            kind: .guiApp,
            outletID: outletID,
            appPath: "/Applications/",
            chromiumProxyFlags: true,
            extraEnv: ["NODE_USE_ENV_PROXY": "1"]
        )
    }
}

private struct TargetEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ManagedTarget
    @State private var processNamesCSV: String
    @State private var validationError: String?
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
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "添加自定义应用" : "编辑 \(draft.name)")
                .font(.title3.bold())

            Form {
                TextField("名称", text: $draft.name, prompt: Text("如 Cursor、Claude Code"))
                Picker("类型", selection: $draft.kind) {
                    ForEach(TargetKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                if outlets.count > 1 {
                    Picker("使用出口", selection: $draft.outletID) {
                        ForEach(outlets) { outlet in
                            Text("\(AppState.displayOutletName(outlet.name)) (:\(String(outlet.listenPort)))")
                                .tag(outlet.id)
                        }
                    }
                }
                TextField("进程匹配名（逗号分隔）", text: $processNamesCSV)

                switch draft.kind {
                case .guiApp:
                    TextField("Bundle ID（可选）", text: Binding(
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
                                if draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    draft.name = url.deletingPathExtension().lastPathComponent
                                }
                            }
                        }
                    }
                    Toggle("注入 Chromium 代理与禁用 QUIC 参数", isOn: $draft.chromiumProxyFlags)

                case .cliTool:
                    TextField("命令名（安装到 ~/.local/bin）", text: Binding(
                        get: { draft.cliCommandName ?? "" },
                        set: { draft.cliCommandName = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("原程序路径", text: Binding(
                        get: { draft.cliTargetBinaryPath ?? "" },
                        set: { draft.cliTargetBinaryPath = $0.isEmpty ? nil : $0 }
                    ))

                case .t3Integration:
                    TextField("配置文件路径", text: Binding(
                        get: { draft.t3SettingsPath ?? "~/.t3/userdata/settings.json" },
                        set: { draft.t3SettingsPath = $0.isEmpty ? nil : $0 }
                    ))
                    TextField("服务键名（Provider Key）", text: Binding(
                        get: { draft.t3ProviderKey ?? "antigravity" },
                        set: { draft.t3ProviderKey = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .formStyle(.grouped)

            if let validationError {
                Text(validationError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    validateAndSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 380)
    }

    private func validateAndSave() {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            validationError = "请输入名称。"
            return
        }
        switch draft.kind {
        case .guiApp:
            let path = (draft.appPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, path != "/Applications/" else {
                validationError = "请选择或填写有效的应用程序路径（.app）。"
                return
            }
        case .cliTool:
            let cmd = (draft.cliCommandName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let bin = (draft.cliTargetBinaryPath ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cmd.isEmpty, !bin.isEmpty else {
                validationError = "请填写命令名和原程序路径。"
                return
            }
        case .t3Integration:
            break
        }

        validationError = nil
        draft.name = trimmedName
        draft.processMatchNames = processNamesCSV
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onSave(draft)
        dismiss()
    }
}
