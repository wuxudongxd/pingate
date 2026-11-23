import AppKit
import PinGateCore
import SwiftUI

final class PinGateAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--open-dashboard") || CommandLine.arguments.contains("--snapshot") {
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct PinGateApp: App {
    @NSApplicationDelegateAdaptor(PinGateAppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        self._appState = State(initialValue: state)
        Task { @MainActor in
            await state.bootstrapIfNeeded()
            await Self.captureSnapshotIfRequested(appState: state)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Label {
                Text("PinGate")
            } icon: {
                Image(systemName: appState.menuBarSymbolName)
            }
        }
        .menuBarExtraStyle(.window)

        Window("PinGate Dashboard", id: "dashboard") {
            DashboardView(appState: appState)
                .frame(minWidth: 920, minHeight: 620)
                .task {
                    await appState.bootstrapIfNeeded()
                }
        }
        .defaultSize(width: 1020, height: 680)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(
            CommandLine.arguments.contains("--open-dashboard") ? .presented : .suppressed
        )
    }

    @MainActor
    private static func captureSnapshotIfRequested(appState: AppState) async {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--snapshot"), args.indices.contains(idx + 1) else {
            return
        }
        let outputPath = args[idx + 1]
        await appState.refreshAudit()
        await appState.refreshActiveConnections()

        let hosting = NSHostingController(rootView: DashboardView(appState: appState))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PinGate Dashboard"
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 1060, height: 700))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        try? await Task.sleep(for: .milliseconds(600))

        let targetView = window.contentView?.superview ?? window.contentView ?? hosting.view
        targetView.layoutSubtreeIfNeeded()
        let bounds = targetView.bounds
        if let rep = targetView.bitmapImageRepForCachingDisplay(in: bounds) {
            targetView.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            }
        }
        window.close()
        exit(0)
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case outlets = "Outlets"
    case targets = "Targets"
    case bypass = "Bypass Rules"
    case audit = "Audit & Monitor"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .outlets:
            return "network"
        case .targets:
            return "app.badge.checkmark"
        case .bypass:
            return "arrow.triangle.branch"
        case .audit:
            return "shield.lefthalf.filled"
        }
    }

    var subtitle: String {
        switch self {
        case .outlets:
            return "Proxy sources, nodes & latency"
        case .targets:
            return "Apps, CLI shims & T3 Code"
        case .bypass:
            return "Corporate domains & private CIDRs"
        case .audit:
            return "Live socket audit & connections"
        }
    }
}

struct DashboardView: View {
    @Bindable var appState: AppState
    @State private var selection: DashboardSection = .audit

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let banner = appState.statusBannerMessage {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                }

                Button {
                    Task { await appState.syncNow() }
                } label: {
                    Label(appState.isSyncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(appState.isSyncing)

                Button {
                    Task {
                        await appState.refreshAudit()
                        await appState.refreshActiveConnections()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            if let requestedTab = CommandLine.arguments.firstIndex(of: "--tab"),
               CommandLine.arguments.indices.contains(requestedTab + 1)
            {
                switch CommandLine.arguments[requestedTab + 1].lowercased() {
                case "outlets": selection = .outlets
                case "targets": selection = .targets
                case "bypass": selection = .bypass
                case "audit": selection = .audit
                default: break
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(appState.healthColor.opacity(0.16))
                            .frame(width: 38, height: 38)
                        Image(systemName: appState.menuBarSymbolName)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(appState.healthColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PinGate")
                            .font(.headline)
                        Text(appState.overallHealthState.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(appState.healthColor)
                    }
                    Spacer()
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(appState.outletRunning ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                    if let outlet = appState.config.primaryOutlet() {
                        Text("\(outlet.listenHost):\(String(outlet.listenPort))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No Outlet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    let leaks = appState.auditSnapshot?.totalLeakSockets ?? 0
                    Text(leaks == 0 ? "0 leaks" : "\(leaks) leaks")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill((leaks == 0 ? Color.green : Color.red).opacity(0.16))
                        )
                        .foregroundStyle(leaks == 0 ? Color.green : Color.red)
                }
            }
            .padding(14)

            Divider()

            List(DashboardSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .frame(width: 20)
                            .foregroundStyle(selection == section ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.rawValue)
                                .font(.body.weight(.medium))
                            Text(section.subtitle)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if section == .audit, let leaks = appState.auditSnapshot?.totalLeakSockets, leaks > 0 {
                            Text("\(leaks)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.sidebar)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let probe = appState.exitProbe {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(probe.country.map { "\($0) • \(probe.ip)" } ?? probe.ip)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text("\(String(probe.latencyMs))ms")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(appState.isProbingExitIP ? "Probing exit IP…" : "Exit IP not probed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                HStack(spacing: 8) {
                    Button(appState.outletRunning ? "Stop Outlet" : "Start Outlet") {
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

                    Button("Probe IP") {
                        Task { await appState.probeExitIP() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning || appState.isProbingExitIP)
                }
            }
            .padding(12)
        }
        .navigationSplitViewColumnWidth(min: 225, ideal: 245, max: 280)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .outlets:
            OutletsView(appState: appState)
        case .targets:
            TargetsView(appState: appState)
        case .bypass:
            BypassRulesView(appState: appState)
        case .audit:
            AuditMonitorView(appState: appState)
        }
    }
}
