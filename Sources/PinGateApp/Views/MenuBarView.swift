import AppKit
import PinGateCore
import SwiftUI

private enum MenuBarPendingConfirm: Equatable {
    case pauseProtection
    case quitApp
    case restartTarget(ManagedTarget)
}

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var pendingConfirm: MenuBarPendingConfirm?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            masterHeaderSection

            if let confirm = pendingConfirm {
                inlineConfirmationCard(for: confirm)
            }

            if let leakCount = appState.auditSnapshot?.totalLeakSockets, leakCount > 0 {
                leakAlertStrip(leakCount: leakCount)
            }

            if let error = appState.lastSyncError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        appState.dismissError()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
            }

            nodeSwitcherSection

            Divider()

            targetsSection

            Divider()

            footerSection
        }
        .padding(14)
        .frame(width: 340)
        .task {
            await appState.bootstrapIfNeeded()
        }
    }

    // MARK: - Top Master Control (Single Focus)

    private var masterHeaderSection: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                Circle()
                    .fill(appState.healthColor.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: appState.menuBarSymbolName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(appState.healthColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("PinGate")
                    .font(.headline)
                Text(headerSubtitleText)
                    .font(.caption)
                    .foregroundStyle(appState.overallHealthState == .leaking ? Color.red : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            ProtectionMasterSwitch(appState: appState) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    pendingConfirm = .pauseProtection
                }
            }
        }
    }

    private var headerSubtitleText: String {
        switch appState.overallHealthState {
        case .leaking:
            let leaks = appState.auditSnapshot?.totalLeakSockets ?? 0
            if leaks > 0 {
                return "发现 \(String(leaks)) 条未走代理的连接"
            }
            return "检测到应用未走代理"
        case .stopped:
            return "已关闭"
        case .warning:
            return "需注意"
        case .protected:
            if let probe = appState.exitProbe {
                if let country = probe.country, !country.isEmpty {
                    return "保护中 · \(country) \(probe.ip)"
                }
                return "保护中 · \(probe.ip)"
            }
            if let outlet = appState.config.primaryOutlet() {
                return "保护中 · :\(String(outlet.listenPort))"
            }
            return "保护中"
        }
    }

    // MARK: - Inline Popover Confirmation Banner (100% reliable inside MenuBarExtra)

    private func inlineConfirmationCard(for confirm: MenuBarPendingConfirm) -> some View {
        let title: String
        let detail: String
        let destructiveLabel: String

        switch confirm {
        case .pauseProtection:
            let procs = appState.activeProtectedProcessCount
            let socks = appState.auditSnapshot?.totalProxiedSockets ?? 0
            title = "确定要关闭代理保护吗？"
            detail = "当前有 \(String(procs)) 个应用进程（\(String(socks)) 条代理连接）正在使用代理，关闭后会立即中断它们的网络连接。"
            destructiveLabel = "仍要关闭"
        case .quitApp:
            let procs = appState.activeProtectedProcessCount
            title = "确定要退出 PinGate 吗？"
            detail = "当前有 \(String(procs)) 个应用进程正在使用代理，退出后会停止本地代理并中断连接。"
            destructiveLabel = "停止并退出"
        case .restartTarget(let target):
            title = "重启「\(target.name)」并走代理？"
            detail = "将关闭当前未走代理的实例，并通过代理重新启动。"
            destructiveLabel = "重启并走代理"
        }

        return VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Spacer()
                Button("取消") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        pendingConfirm = nil
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)

                Button(destructiveLabel, role: .destructive) {
                    let action = confirm
                    pendingConfirm = nil
                    switch action {
                    case .pauseProtection:
                        Task { await appState.stopOutlet() }
                    case .quitApp:
                        appState.quitApp()
                    case .restartTarget(let target):
                        Task { await appState.restartTargetWithProxy(target: target) }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.mini)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func leakAlertStrip(leakCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
            Text("发现 \(String(leakCount)) 条未走代理的连接")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
            Spacer()
            Button("查看详情") {
                openDashboard(to: .audit)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.mini)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.28), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Node Switcher (Compact Single Row)

    private var nodeSwitcherSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                let nodes = appState.quickSelectableNodes
                Picker(
                    "代理节点",
                    selection: Binding(
                        get: { appState.activeMihomoNode ?? appState.config.primaryOutlet()?.primaryNodeName ?? "" },
                        set: { newNode in
                            guard !newNode.isEmpty else { return }
                            Task { await appState.selectActiveNode(newNode) }
                        }
                    )
                ) {
                    if nodes.isEmpty {
                        Text("暂无可用节点").tag("")
                    } else {
                        ForEach(nodes, id: \.self) { node in
                            Text(node).tag(node)
                        }
                    }
                }
                .labelsHidden()
                .disabled(nodes.isEmpty || !appState.outletRunning)

                Button {
                    Task { await appState.syncNow() }
                } label: {
                    if appState.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 16, height: 16)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("从订阅源同步最新节点并生效")
                .disabled(appState.isSyncing)
            }

            HStack(spacing: 8) {
                if let probe = appState.exitProbe, appState.outletRunning {
                    Text("延迟 \(String(probe.latencyMs)) ms")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else if appState.isProbingExitIP {
                    Text("正在检测出口 IP…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let syncedAt = appState.lastSyncResult?.syncedAt {
                    Text("· 已同步 \(AppState.relativeTimeString(from: syncedAt))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if appState.outletRunning {
                    Button {
                        Task { await appState.probeExitIP() }
                    } label: {
                        Text(appState.isProbingExitIP ? "检测中…" : "测出口 IP")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(appState.isProbingExitIP)
                }
            }
        }
    }

    // MARK: - Protected Targets (Decluttered, Enabled Only)

    private var targetsSection: some View {
        let targets = appState.enabledTargets
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("代理应用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot = appState.auditSnapshot, snapshot.totalProxiedSockets > 0 {
                    Text("\(String(snapshot.totalProxiedSockets)) 条代理连接")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if targets.isEmpty {
                Text("暂未启用任何代理应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 6) {
                    ForEach(targets) { target in
                        targetRow(target)
                    }
                }
            }
        }
    }

    private func targetRow(_ target: ManagedTarget) -> some View {
        let processes = appState.processesForTarget(target)
        let isLeaking = appState.isTargetLeaking(target)
        let proxiedCount = appState.proxiedConnectionCount(for: target)
        let isRunning = !processes.isEmpty
        let isBusy = appState.busyTargetIDs.contains(target.id)

        return HStack(spacing: 10) {
            TargetIconView(
                target: target,
                size: 24,
                tintColor: isLeaking ? .red : (isRunning ? .accentColor : .secondary)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                targetStatusLine(
                    target: target,
                    isRunning: isRunning,
                    isLeaking: isLeaking,
                    proxiedCount: proxiedCount
                )
            }

            Spacer(minLength: 6)

            if isBusy {
                ProgressView()
                    .controlSize(.small)
            } else {
                targetQuickAction(target: target, isRunning: isRunning, isLeaking: isLeaking)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isLeaking ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isLeaking ? Color.red.opacity(0.32) : Color.primary.opacity(0.06), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .contextMenu {
            targetContextMenu(for: target)
        }
    }

    @ViewBuilder
    private func targetStatusLine(
        target: ManagedTarget,
        isRunning: Bool,
        isLeaking: Bool,
        proxiedCount: Int
    ) -> some View {
        if isLeaking {
            StatusDotLabel(text: "未走代理", color: .red, emphasized: true)
        } else {
            switch target.kind {
            case .guiApp:
                if isRunning {
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

    @ViewBuilder
    private func targetQuickAction(target: ManagedTarget, isRunning: Bool, isLeaking: Bool) -> some View {
        switch target.kind {
        case .guiApp:
            if isLeaking {
                Button("重启并走代理") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        pendingConfirm = .restartTarget(target)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
            } else {
                Button(isRunning ? "打开" : "启动") {
                    Task { await appState.launchOrActivate(target: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .cliTool:
            let installed = appState.cliShimStatuses[target.id] ?? false
            if !installed {
                Button("安装") {
                    Task { await appState.installCLIShim(for: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .t3Integration:
            let synced = appState.t3SyncStatuses[target.id] ?? false
            if !synced {
                Button("同步") {
                    Task { await appState.syncT3Code(for: target) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func targetContextMenu(for target: ManagedTarget) -> some View {
        switch target.kind {
        case .guiApp:
            Button("打开") {
                Task { await appState.launchOrActivate(target: target) }
            }
            Button("重启并走代理…") {
                withAnimation(.easeInOut(duration: 0.16)) {
                    pendingConfirm = .restartTarget(target)
                }
            }
        case .cliTool:
            Button("重新安装命令") {
                Task { await appState.installCLIShim(for: target) }
            }
        case .t3Integration:
            Button("重新同步 T3 Code") {
                Task { await appState.syncT3Code(for: target) }
            }
        }
    }

    // MARK: - Footer (Aligned Full-Width Toggle + Optional Update Row + Calm Actions)

    private var footerSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("开机自动启动")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(
                    "开机自动启动",
                    isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            if let release = appState.availableUpdate {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                    Text("发现新版本 \(release.tagName)")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button("立即更新") {
                        appState.showUpdateSheet = true
                        openDashboard(to: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }

            HStack {
                Button {
                    openDashboard(to: nil)
                } label: {
                    Label("打开控制台", systemImage: "macwindow")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("退出 PinGate") {
                    if appState.outletRunning && appState.hasActiveProtectedTraffic {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            pendingConfirm = .quitApp
                        }
                    } else {
                        appState.quitApp()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func openDashboard(to section: DashboardSection?) {
        if let section {
            appState.requestedDashboardSection = section
        }
        openWindow(id: "dashboard")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
