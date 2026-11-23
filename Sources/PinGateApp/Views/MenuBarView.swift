import AppKit
import PinGateCore
import SwiftUI

struct MenuBarView: View {
    @Bindable var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusHeader

            if let error = appState.lastSyncError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            targetsSection

            Divider()

            nodeControlSection

            Divider()

            footerSection
        }
        .padding(14)
        .frame(width: 370)
        .task {
            await appState.bootstrapIfNeeded()
        }
    }

    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(appState.healthColor.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: appState.menuBarSymbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appState.healthColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("PinGate")
                            .font(.headline)
                        statusPill(
                            text: appState.overallHealthState.displayName,
                            color: appState.healthColor
                        )
                    }
                    if let outlet = appState.config.primaryOutlet() {
                        Text("\(outlet.name) • \(outlet.listenHost):\(String(outlet.listenPort))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No outlet configured")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                let leakCount = appState.auditSnapshot?.totalLeakSockets ?? 0
                statusPill(
                    text: leakCount == 0 ? "0 Leaks" : "\(leakCount) Leaks!",
                    color: leakCount == 0 ? .green : .red
                )
            }

            HStack(spacing: 8) {
                if let probe = appState.exitProbe {
                    Label {
                        Text("\(probe.country ?? "--") • \(probe.ip)")
                            .font(.caption.monospaced())
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .foregroundStyle(.primary)

                    Text("(\(String(probe.latencyMs))ms)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Label {
                        Text(appState.isProbingExitIP ? "Probing exit IP…" : "Exit IP pending")
                            .font(.caption)
                    } icon: {
                        Image(systemName: "globe")
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task { await appState.probeExitIP() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Re-probe outlet exit IP")
                .disabled(!appState.outletRunning || appState.isProbingExitIP)

                Button(appState.outletRunning ? "Stop" : "Start") {
                    Task {
                        if appState.outletRunning {
                            await appState.stopOutlet()
                        } else {
                            await appState.startOutlet()
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Protected Targets")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let snapshot = appState.auditSnapshot {
                    Text("\(snapshot.totalProxiedSockets) proxied")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            if appState.config.targets.isEmpty {
                Text("No managed targets configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(appState.config.targets) { target in
                    targetCard(target)
                }
            }
        }
    }

    private func targetCard(_ target: ManagedTarget) -> some View {
        let processes = appState.processesForTarget(target)
        let isLeaking = appState.isTargetLeaking(target)
        let proxiedCount = appState.proxiedConnectionCount(for: target)
        let isRunning = !processes.isEmpty

        return HStack(spacing: 10) {
            Image(systemName: targetIcon(target.kind))
                .font(.system(size: 14))
                .foregroundStyle(isLeaking ? Color.red : (isRunning ? Color.green : Color.secondary))
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(target.name)
                        .font(.subheadline.weight(.medium))
                    if isLeaking {
                        statusPill(text: "Unproxied", color: .red)
                    } else if isRunning {
                        statusPill(text: "\(proxiedCount) proxied", color: .green)
                    } else if target.kind == .cliTool {
                        let installed = appState.cliShimStatuses[target.id] ?? false
                        statusPill(
                            text: installed ? "Shim Ready" : "No Shim",
                            color: installed ? .blue : .secondary
                        )
                    } else if target.kind == .t3Integration {
                        let synced = appState.t3SyncStatuses[target.id] ?? false
                        statusPill(
                            text: synced ? "Synced" : "Unsynced",
                            color: synced ? .blue : .orange
                        )
                    } else {
                        Text("Idle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isLeaking {
                    Text("Process detected without outlet proxy")
                        .font(.caption2)
                        .foregroundStyle(.red)
                } else if isRunning {
                    Text("\(processes.count) active process(es)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let cmd = target.cliCommandName {
                    Text("~/.local/bin/\(cmd)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                } else if target.kind == .t3Integration {
                    Text(target.t3SettingsPath ?? "~/.t3/userdata/settings.json")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            targetActionButton(target: target, isRunning: isRunning, isLeaking: isLeaking)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLeaking ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isLeaking ? Color.red.opacity(0.35) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func targetActionButton(target: ManagedTarget, isRunning: Bool, isLeaking: Bool) -> some View {
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
                Button(isRunning ? "Activate" : "Launch") {
                    Task { await appState.launchOrActivate(target: target) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .cliTool:
            let installed = appState.cliShimStatuses[target.id] ?? false
            Button(installed ? "Update" : "Install") {
                Task { await appState.installCLIShim(for: target) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        case .t3Integration:
            Button("Sync") {
                Task { await appState.syncT3Code(for: target) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var nodeControlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Outlet Node")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let syncedAt = appState.lastSyncResult?.syncedAt {
                    Text("Synced \(syncedAt, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                let nodes = appState.quickSelectableNodes
                Picker(
                    "Active Node",
                    selection: Binding(
                        get: { appState.activeMihomoNode ?? appState.config.primaryOutlet()?.primaryNodeName ?? "" },
                        set: { newNode in
                            guard !newNode.isEmpty else { return }
                            Task { await appState.selectActiveNode(newNode) }
                        }
                    )
                ) {
                    if nodes.isEmpty {
                        Text("No nodes synced").tag("")
                    } else {
                        ForEach(nodes, id: \.self) { node in
                            Text(node).tag(node)
                        }
                    }
                }
                .labelsHidden()
                .disabled(nodes.isEmpty)

                Button {
                    Task { await appState.syncNow() }
                } label: {
                    if appState.isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(appState.isSyncing)
            }
        }
    }

    private var footerSection: some View {
        VStack(spacing: 8) {
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { appState.launchAtLogin },
                    set: { appState.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.caption)

            HStack {
                Button {
                    openWindow(id: "dashboard")
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Dashboard", systemImage: "macwindow")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Spacer()

                Button("Quit PinGate") {
                    appState.quitApp()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func targetIcon(_ kind: TargetKind) -> String {
        switch kind {
        case .guiApp: return "app.fill"
        case .cliTool: return "terminal.fill"
        case .t3Integration: return "link.circle.fill"
        }
    }

    private func statusPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}
