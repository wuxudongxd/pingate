import AppKit
import PinGateCore
import SwiftUI

final class PinGateAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--open-dashboard")
            || CommandLine.arguments.contains("--snapshot")
            || CommandLine.arguments.contains("--snapshot-menubar")
        {
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
            await Self.captureSnapshotsIfRequested(appState: state)
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

        Window("PinGate 控制台", id: "dashboard") {
            DashboardView(appState: appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    await appState.bootstrapIfNeeded()
                }
        }
        .defaultSize(width: 980, height: 660)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(
            CommandLine.arguments.contains("--open-dashboard") ? .presented : .suppressed
        )
    }

    @MainActor
    private static func captureSnapshotsIfRequested(appState: AppState) async {
        let args = CommandLine.arguments
        let dashboardPath: String? = {
            guard let idx = args.firstIndex(of: "--snapshot"), args.indices.contains(idx + 1) else {
                return nil
            }
            return args[idx + 1]
        }()
        let menuBarPath: String? = {
            guard let idx = args.firstIndex(of: "--snapshot-menubar"), args.indices.contains(idx + 1) else {
                return nil
            }
            return args[idx + 1]
        }()

        guard dashboardPath != nil || menuBarPath != nil else {
            return
        }

        await appState.refreshAudit()
        await appState.refreshActiveConnections()

        if let outputPath = dashboardPath {
            let hosting = NSHostingController(rootView: DashboardView(appState: appState))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "PinGate 控制台"
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: 980, height: 660))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            try? await Task.sleep(for: .milliseconds(600))
            saveWindowSnapshot(window: window, fallbackView: hosting.view, to: outputPath)
            window.close()
        }

        if let outputPath = menuBarPath {
            let popoverRoot = MenuBarView(appState: appState)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingController(rootView: popoverRoot)
            let fitting = hosting.view.fittingSize
            let width = max(340, fitting.width)
            let height = max(360, fitting.height)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "PinGate 菜单栏"
            window.contentViewController = hosting
            window.setContentSize(NSSize(width: width, height: height))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            try? await Task.sleep(for: .milliseconds(500))
            saveWindowSnapshot(window: window, fallbackView: hosting.view, to: outputPath)
            window.close()
        }

        exit(0)
    }

    @MainActor
    private static func saveWindowSnapshot(window: NSWindow, fallbackView: NSView, to outputPath: String) {
        let targetView = window.contentView?.superview ?? window.contentView ?? fallbackView
        targetView.layoutSubtreeIfNeeded()
        let bounds = targetView.bounds
        if let rep = targetView.bitmapImageRepForCachingDisplay(in: bounds) {
            targetView.cacheDisplay(in: bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
            }
        }
    }
}

enum DashboardSection: String, CaseIterable, Identifiable {
    case audit = "防漏审计"
    case targets = "纳管目标"
    case outlets = "出口通道"
    case bypass = "直连白名单"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .audit:
            return "shield.lefthalf.filled"
        case .targets:
            return "app.badge.checkmark"
        case .outlets:
            return "network"
        case .bypass:
            return "arrow.triangle.branch"
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
            VStack(spacing: 0) {
                feedbackBanners
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await appState.syncNow() }
                } label: {
                    HStack(spacing: 5) {
                        if appState.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text(appState.isSyncing ? "同步中…" : "同步配置")
                    }
                }
                .help("从订阅源同步节点并热重载")
                .disabled(appState.isSyncing)

                Button {
                    Task { await refreshCurrentSection() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新当前状态 (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .background {
            // Keyboard shortcuts ⌘1–⌘4 for instant tab switching.
            Group {
                Button("") { selection = .audit }.keyboardShortcut("1", modifiers: .command)
                Button("") { selection = .targets }.keyboardShortcut("2", modifiers: .command)
                Button("") { selection = .outlets }.keyboardShortcut("3", modifiers: .command)
                Button("") { selection = .bypass }.keyboardShortcut("4", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
        .onAppear {
            applyRequestedTabFromLaunchArgs()
            if let requested = appState.requestedDashboardSection {
                selection = requested
                appState.requestedDashboardSection = nil
            }
        }
        .onChange(of: appState.requestedDashboardSection) { _, newSection in
            if let newSection {
                selection = newSection
                appState.requestedDashboardSection = nil
            }
        }
    }

    @ViewBuilder
    private var feedbackBanners: some View {
        if let error = appState.lastSyncError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer()
                Button("关闭") {
                    appState.dismissError()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.orange.opacity(0.14))
            Divider()
        } else if let banner = appState.statusBannerMessage {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                Text(banner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            Divider()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Unified compact master control card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: appState.menuBarSymbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appState.healthColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("PinGate")
                            .font(.headline)
                        StatusDotLabel(
                            text: appState.shortProtectionStateLabel,
                            color: appState.healthColor,
                            emphasized: appState.overallHealthState == .leaking
                        )
                    }

                    Spacer()

                    ProtectionMasterSwitch(appState: appState)
                }

                HStack(spacing: 6) {
                    if let probe = appState.exitProbe, appState.outletRunning {
                        Text(probe.country.map { "\($0) · \(probe.ip)" } ?? probe.ip)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let outlet = appState.config.primaryOutlet() {
                        Text("\(outlet.listenHost):\(String(outlet.listenPort))")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("尚未配置出口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.outletRunning {
                        Button {
                            Task { await appState.probeExitIP() }
                        } label: {
                            if appState.isProbingExitIP {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "globe")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("重新探测出口 IP")
                        .disabled(appState.isProbingExitIP)
                    }
                }
            }
            .padding(14)

            Divider()

            List(DashboardSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    HStack {
                        Label(section.rawValue, systemImage: section.systemImage)
                        Spacer()
                        if section == .audit, let leaks = appState.auditSnapshot?.totalLeakSockets, leaks > 0 {
                            Text(String(leaks))
                                .font(.caption2.bold())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.red))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .navigationSplitViewColumnWidth(min: 205, ideal: 220, max: 250)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .audit:
            AuditMonitorView(appState: appState)
        case .targets:
            TargetsView(appState: appState)
        case .outlets:
            OutletsView(appState: appState)
        case .bypass:
            BypassRulesView(appState: appState)
        }
    }

    private func refreshCurrentSection() async {
        switch selection {
        case .audit:
            await appState.refreshAudit()
            await appState.refreshActiveConnections()
        case .targets:
            await appState.refreshAudit()
            appState.refreshTargetStatuses()
        case .outlets:
            if let outlet = appState.config.primaryOutlet() {
                await appState.refreshAvailableNodes(for: outlet)
                await appState.probeExitIP(outlet: outlet)
            }
        case .bypass:
            await appState.refreshAudit()
        }
    }

    private func applyRequestedTabFromLaunchArgs() {
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
