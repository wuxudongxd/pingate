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
    case audit = "运行状态"
    case targets = "代理应用"
    case outlets = "代理出口"
    case bypass = "规则与隐私"

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
            return "hand.raised"
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
        .sheet(isPresented: $appState.showUpdateSheet) {
            UpdateSheetView(appState: appState)
        }
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
                        Text(appState.isSyncing ? "同步中…" : "同步节点")
                    }
                }
                .help("从订阅源同步最新节点并生效")
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
        } else if let release = appState.availableUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("发现新版本 \(release.tagName)")
                    .font(.caption.weight(.medium))
                Spacer()
                Button("立即更新") {
                    appState.showUpdateSheet = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Color.accentColor.opacity(0.10))
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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: appState.menuBarSymbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(appState.healthColor)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("PinGate")
                            .font(.headline)
                        StatusDotLabel(
                            text: appState.overallHealthState.displayName,
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
                        Text("未配置代理出口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if appState.outletRunning {
                        Button {
                            Task { await appState.probeExitIP() }
                        } label: {
                            Group {
                                if appState.isProbingExitIP {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "globe")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("重新检测出口 IP")
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

            Divider()

            // Minimal 1-line version & update check footer
            HStack(spacing: 6) {
                Text(appState.currentAppVersion.tagString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if let release = appState.availableUpdate {
                    Button {
                        appState.showUpdateSheet = true
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text("升级至 \(release.tagName)")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await appState.checkForUpdates(userInitiated: true) }
                    } label: {
                        HStack(spacing: 4) {
                            if appState.isCheckingUpdate {
                                ProgressView()
                                    .controlSize(.mini)
                            }
                            Text(appState.isCheckingUpdate ? "检查中…" : "检查更新")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(appState.isCheckingUpdate)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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

// MARK: - Auto-Update Release Notes & Install Sheet

private struct UpdateSheetView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var showRestartConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let release = appState.availableUpdate {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 40, height: 40)
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("发现新版本 \(release.tagName)")
                            .font(.headline)
                        Text("当前版本 \(appState.currentAppVersion.tagString) → \(release.tagName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("更新说明")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "本次更新包含稳定性改进与问题修复。"
                            : release.releaseNotes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .frame(height: 170)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
                }

                if let progress = appState.updateProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            if appState.isDownloadingUpdate {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(progress.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if case .downloading(let fraction, _, _) = progress {
                            ProgressView(value: fraction)
                        }
                    }
                }

                if let err = appState.updateErrorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("在 GitHub 查看") {
                        NSWorkspace.shared.open(release.htmlURL)
                    }
                    .buttonStyle(.link)
                    .font(.caption)

                    Spacer()

                    Button("稍后") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    if appState.preparedUpdate != nil {
                        Button("重启并更新") {
                            showRestartConfirm = true
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    } else {
                        Button(appState.isDownloadingUpdate ? "正在下载并校验更新…" : "下载并校验") {
                            Task { await appState.downloadAndVerifyUpdate() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.isDownloadingUpdate)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("已是最新版本")
                        .font(.headline)
                    Text("当前版本 \(appState.currentAppVersion.tagString) 已为最新。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HStack {
                        Spacer()
                        Button("关闭") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .alert("准备更新到 \(appState.availableUpdate?.tagName ?? "")", isPresented: $showRestartConfirm) {
            Button("重启并更新") {
                appState.applyPreparedUpdateAndRestart()
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("更新完成后会自动重启 PinGate 并恢复代理，配置不会丢失。")
        }
    }
}
