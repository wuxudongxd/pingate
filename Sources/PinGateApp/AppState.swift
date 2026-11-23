import AppKit
import Foundation
import Observation
import PinGateCore
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class AppState {
    // MARK: - Core Services
    private let configStore: ConfigStore
    private let mihomoManager: MihomoProcessManager
    private let parser: ClashProfileParser
    private let leakAuditor: LeakAuditor
    private let exitProber: ExitIPProber
    private let interceptor: UserSpaceInterceptor
    private let inspector: DarwinProcessInspector
    private let updater: AppUpdater

    // MARK: - Published Observable State
    var config: PinGateConfig
    var auditSnapshot: AuditSnapshot?
    var outletRunning: Bool = false
    var isTogglingOutlet: Bool = false
    var isTogglingTelemetry: Bool = false
    var mihomoVersion: String?
    var exitProbe: ExitProbeResult?
    var isProbingExitIP: Bool = false
    var isSyncing: Bool = false
    var isTestingAllLatencies: Bool = false
    var lastSyncResult: NodeSyncResult?
    var lastSyncError: String?
    var statusBannerMessage: String?

    var availableProfileNodes: [String] = []
    var activeMihomoNode: String?
    var mihomoGroupNodes: [String] = []
    var nodeLatenciesMs: [String: Int] = [:]
    var testingLatencyNodes: Set<String> = []
    var busyTargetIDs: Set<UUID> = []
    var activeConnections: [MihomoActiveConnection] = []

    var cliShimStatuses: [UUID: Bool] = [:]
    var t3SyncStatuses: [UUID: Bool] = [:]
    var discoveredFlClashProfiles: [URL] = []
    var launchAtLogin: Bool = false
    var captureModeStatusMessage: String = "标准代理模式运行中（桌面应用注入 + 命令行工具 + T3 Code 同步 + 实时连接监控）。"

    // MARK: - Auto-Update State
    let currentAppVersion: SemanticVersion
    var availableUpdate: ReleaseInfo?
    var isCheckingUpdate: Bool = false
    var isDownloadingUpdate: Bool = false
    var updateProgress: UpdateProgress?
    var preparedUpdate: PreparedUpdate?
    var updateErrorMessage: String?
    var lastUpdateCheckAt: Date?
    var showUpdateSheet: Bool = false

    /// Requested dashboard tab navigation (e.g. from MenuBar leak alert "查看详情").
    var requestedDashboardSection: DashboardSection?

    // MARK: - Internal Lifecycle
    private var hasBootstrapped = false
    private var pollTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private var profileWatchers: [UUID: ProfileWatcher] = [:]
    private var previousHealthState: HealthState = .stopped
    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    init(configStore: ConfigStore? = nil) {
        let resolvedStore = configStore ?? Self.resolveConfigStoreFromEnvironment()
        self.configStore = resolvedStore
        self.mihomoManager = MihomoProcessManager(configStore: resolvedStore)
        self.parser = ClashProfileParser()
        self.inspector = DarwinProcessInspector()
        self.leakAuditor = LeakAuditor(inspector: inspector)
        self.exitProber = ExitIPProber()
        self.updater = AppUpdater(configStore: resolvedStore)
        self.currentAppVersion = AppUpdater.currentAppVersion()
        self.interceptor = UserSpaceInterceptor(
            appLauncher: AppLauncher(inspector: inspector),
            shimManager: CLIShimManager(),
            t3Adapter: T3CodeSyncAdapter(),
            snapshotURL: resolvedStore.runtimeDirectory.appendingPathComponent("extension-policy.json")
        )
        let loaded = (try? resolvedStore.loadOrBootstrap()) ?? PinGateConfig.defaultBootstrapConfig()
        self.config = loaded
        self.discoveredFlClashProfiles = ConfigStore.discoverFlClashProfiles()
        self.launchAtLogin = Self.readLaunchAtLoginState()
    }

    private static func resolveConfigStoreFromEnvironment() -> ConfigStore {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--config-dir"), args.indices.contains(idx + 1) {
            let expanded = NSString(string: args[idx + 1]).expandingTildeInPath
            return ConfigStore(baseDirectory: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        if let envDir = ProcessInfo.processInfo.environment["PINGATE_CONFIG_DIR"], !envDir.isEmpty {
            let expanded = NSString(string: envDir).expandingTildeInPath
            return ConfigStore(baseDirectory: URL(fileURLWithPath: expanded, isDirectory: true))
        }
        return ConfigStore()
    }

    // MARK: - Chinese Display & Time Formatters

    static func displayOutletName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "Primary Outlet" {
            return "主出口"
        }
        return trimmed
    }

    static func shortenedPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    static func relativeTimeString(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 {
            return "刚刚"
        } else if seconds < 60 {
            return "\(seconds) 秒前"
        } else if seconds < 3600 {
            return "\(seconds / 60) 分钟前"
        } else if seconds < 86400 {
            return "\(seconds / 3600) 小时前"
        } else {
            return "\(seconds / 86400) 天前"
        }
    }

    static func clockTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    // MARK: - Banner & Error Feedback

    func showStatusBanner(_ message: String, autoDismiss: Bool = true) {
        bannerDismissTask?.cancel()
        statusBannerMessage = message
        guard autoDismiss else { return }
        bannerDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            if self.statusBannerMessage == message {
                self.statusBannerMessage = nil
            }
        }
    }

    func dismissError() {
        lastSyncError = nil
    }

    // MARK: - Computed Status Helpers

    var overallHealthState: HealthState {
        if let snapshot = auditSnapshot {
            return snapshot.overallState
        }
        return outletRunning ? .protected : .stopped
    }

    var menuBarSymbolName: String {
        switch overallHealthState {
        case .protected:
            return "checkmark.shield.fill"
        case .warning:
            return "exclamationmark.shield.fill"
        case .leaking:
            return "xmark.shield.fill"
        case .stopped:
            return "shield.slash"
        }
    }

    var healthColor: Color {
        switch overallHealthState {
        case .protected:
            return .green
        case .warning:
            return .orange
        case .leaking:
            return .red
        case .stopped:
            return .secondary
        }
    }

    var activeProtectedProcessCount: Int {
        auditSnapshot?.processes.count ?? 0
    }

    var hasActiveProtectedTraffic: Bool {
        activeProtectedProcessCount > 0 || (auditSnapshot?.totalProxiedSockets ?? 0) > 0
    }

    var enabledTargets: [ManagedTarget] {
        config.targets.filter(\.enabled)
    }

    var quickSelectableNodes: [String] {
        var result: [String] = []
        var seen = Set<String>()
        let candidates = mihomoGroupNodes
            + (config.primaryOutlet().map { [$0.primaryNodeName] + $0.fallbackNodeNames } ?? [])
        for name in candidates {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    // MARK: - Bootstrap & Polling

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        let isSnapshotRun = CommandLine.arguments.contains("--snapshot")
            || CommandLine.arguments.contains("--snapshot-menubar")

        if !isSnapshotRun {
            requestNotificationPermissionIfBundled()
        }
        discoveredFlClashProfiles = ConfigStore.discoverFlClashProfiles()
        refreshTargetStatuses()

        let interceptorStatus = await interceptor.status()
        captureModeStatusMessage = interceptorStatus.detail

        if !isSnapshotRun {
            configureProfileWatchers()
        }

        if let primary = config.primaryOutlet() {
            await refreshAvailableNodes(for: primary)
            await refreshOutletRuntimeStatus(for: primary)

            let disableAutostart = CommandLine.arguments.contains("--no-autostart") || isSnapshotRun
            if !disableAutostart && primary.enabled && !outletRunning && !primary.primaryNodeName.isEmpty {
                await startOutlet(primary)
            } else if outletRunning {
                await probeExitIP(outlet: primary)
            }
        }

        await refreshAudit()
        await refreshActiveConnections()
        if !isSnapshotRun {
            startPollingLoop()
            startAutoUpdateLoop()
        }
    }

    private func startPollingLoop() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                let interval = max(1.0, self.config.auditPolicy.pollIntervalSeconds)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }

                await self.refreshAudit()
                tick += 1
                if tick % 2 == 0 {
                    await self.refreshActiveConnections()
                    self.refreshTargetStatuses()
                }
            }
        }
    }

    private func startAutoUpdateLoop() {
        updateCheckTask?.cancel()
        updateCheckTask = Task { [weak self] in
            // Initial delayed background check (5 seconds after startup)
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                guard let self else { return }
                if self.config.autoCheckUpdates {
                    await self.checkForUpdates(userInitiated: false)
                }
                // Check again every 6 hours
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }

    // MARK: - Auto-Update Operations

    func checkForUpdates(userInitiated: Bool) async {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        updateErrorMessage = nil
        if userInitiated {
            showStatusBanner("正在检查更新…", autoDismiss: false)
        }
        defer { isCheckingUpdate = false }

        let proxyOutlet = outletRunning ? config.primaryOutlet() : nil
        do {
            let result = try await updater.checkForUpdates(
                currentVersion: currentAppVersion,
                proxyOutlet: proxyOutlet
            )
            lastUpdateCheckAt = Date()
            switch result {
            case .updateAvailable(_, let release):
                availableUpdate = release
                preparedUpdate = nil
                updateProgress = nil
                showStatusBanner("发现新版本 \(release.tagName)")
                if userInitiated {
                    showUpdateSheet = true
                }
            case .upToDate(_, _):
                availableUpdate = nil
                preparedUpdate = nil
                if userInitiated {
                    showStatusBanner("已是最新版本（\(currentAppVersion.tagString)）")
                }
            }
        } catch {
            if userInitiated {
                updateErrorMessage = error.localizedDescription
                lastSyncError = "检查更新失败：\(error.localizedDescription)"
                statusBannerMessage = nil
            }
        }
    }

    func downloadAndVerifyUpdate() async {
        guard let release = availableUpdate, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        updateErrorMessage = nil
        updateProgress = .checking
        defer { isDownloadingUpdate = false }

        let proxyOutlet = outletRunning ? config.primaryOutlet() : nil
        do {
            let prepared = try await updater.downloadAndVerify(
                release: release,
                proxyOutlet: proxyOutlet,
                verifyCodeSign: true
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.updateProgress = progress
                }
            }
            preparedUpdate = prepared
            updateProgress = .readyToInstall(stagedAppURL: prepared.stagedAppURL)
        } catch {
            updateErrorMessage = error.localizedDescription
            updateProgress = nil
        }
    }

    func applyPreparedUpdateAndRestart() {
        guard let prepared = preparedUpdate else { return }
        updateErrorMessage = nil
        do {
            let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
            _ = try updater.scheduleSelfUpdate(
                prepared: prepared,
                waitForPID: currentPID,
                relaunchApp: true
            )
            quitApp()
        } catch {
            updateErrorMessage = error.localizedDescription
        }
    }

    func setAutoCheckUpdates(_ enabled: Bool) async {
        var cfg = config
        cfg.autoCheckUpdates = enabled
        await saveConfig(cfg, triggerSync: false)
    }

    // MARK: - Telemetry Blocking (Instant Save + Hot Reload)

    func setBlockTelemetry(_ enabled: Bool) async {
        guard !isTogglingTelemetry else { return }
        isTogglingTelemetry = true
        defer { isTogglingTelemetry = false }
        lastSyncError = nil

        var cfg = config
        cfg.blockTelemetry = enabled
        do {
            try configStore.save(cfg)
            config = cfg
            let snapshotURL = configStore.runtimeDirectory.appendingPathComponent("extension-policy.json")
            try? interceptor.exportExtensionSnapshot(config: cfg).write(to: snapshotURL)

            if let primary = cfg.primaryOutlet(), !primary.primaryNodeName.isEmpty {
                _ = try await mihomoManager.syncAndRender(
                    outlet: primary,
                    bypassRules: cfg.bypassRules,
                    hotReloadIfRunning: true
                )
            }
            showStatusBanner(enabled ? "已开启遥测拦截并生效" : "已关闭遥测拦截并生效")
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    // MARK: - Outlet Lifecycle & Sync

    func startOutlet(_ outlet: OutletConfig? = nil) async {
        guard !isTogglingOutlet else { return }
        guard let targetOutlet = outlet ?? config.primaryOutlet() else {
            lastSyncError = "尚未配置任何代理出口。"
            return
        }
        isTogglingOutlet = true
        defer { isTogglingOutlet = false }
        lastSyncError = nil
        showStatusBanner("正在开启代理保护…", autoDismiss: false)
        do {
            try await mihomoManager.start(outlet: targetOutlet, bypassRules: config.bypassRules)
            await refreshOutletRuntimeStatus(for: targetOutlet)
            showStatusBanner("代理保护已开启（:\(String(targetOutlet.listenPort))）")
            await probeExitIP(outlet: targetOutlet)
            await refreshAudit()
            await refreshActiveConnections()
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = nil
        }
    }

    func stopOutlet(_ outlet: OutletConfig? = nil) async {
        guard !isTogglingOutlet else { return }
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        isTogglingOutlet = true
        defer { isTogglingOutlet = false }
        showStatusBanner("正在关闭代理保护…", autoDismiss: false)
        await mihomoManager.stop(outletID: targetOutlet.id)
        await refreshOutletRuntimeStatus(for: targetOutlet)
        activeConnections = []
        showStatusBanner("代理保护已关闭")
        await refreshAudit()
    }

    func restartOutlet(_ outlet: OutletConfig? = nil) async {
        guard !isTogglingOutlet else { return }
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        isTogglingOutlet = true
        defer { isTogglingOutlet = false }
        lastSyncError = nil
        showStatusBanner("正在重启代理出口…", autoDismiss: false)
        do {
            try await mihomoManager.restart(outlet: targetOutlet, bypassRules: config.bypassRules)
            await refreshOutletRuntimeStatus(for: targetOutlet)
            showStatusBanner("代理出口已重启")
            await probeExitIP(outlet: targetOutlet)
            await refreshAudit()
            await refreshActiveConnections()
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = nil
        }
    }

    func syncNow(outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        showStatusBanner("正在同步订阅节点…", autoDismiss: false)
        defer { isSyncing = false }

        do {
            let result = try await mihomoManager.syncAndRender(
                outlet: targetOutlet,
                bypassRules: config.bypassRules,
                hotReloadIfRunning: true
            )
            lastSyncResult = result
            showStatusBanner(
                result.reloadedLive
                    ? "已同步节点并生效（\(result.extractedProxyNames.count) 个节点）"
                    : "已同步节点（\(result.extractedProxyNames.count) 个节点）"
            )
            await refreshOutletRuntimeStatus(for: targetOutlet)
            if outletRunning {
                await probeExitIP(outlet: targetOutlet)
            }
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = nil
        }
    }

    func selectActiveNode(_ nodeName: String, outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        let client = mihomoManager.apiClient(for: targetOutlet)
        do {
            try await client.selectProxy(nodeName: nodeName)
            activeMihomoNode = nodeName
            showStatusBanner("已切换出口节点至 \(nodeName)")
            await probeExitIP(outlet: targetOutlet)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func testLatency(nodeName: String, outlet: OutletConfig) async {
        guard !nodeName.isEmpty, !testingLatencyNodes.contains(nodeName) else { return }
        testingLatencyNodes.insert(nodeName)
        defer { testingLatencyNodes.remove(nodeName) }
        let client = mihomoManager.apiClient(for: outlet)
        do {
            let ms = try await client.proxyDelay(name: nodeName)
            nodeLatenciesMs[nodeName] = ms
        } catch {
            lastSyncError = "节点 \(nodeName) 测速失败：\(error.localizedDescription)"
        }
    }

    func testAllLatencies(outlet: OutletConfig) async {
        guard !isTestingAllLatencies else { return }
        isTestingAllLatencies = true
        defer { isTestingAllLatencies = false }
        let nodes = [outlet.primaryNodeName] + outlet.fallbackNodeNames
        for node in nodes where !node.isEmpty {
            await testLatency(nodeName: node, outlet: outlet)
        }
        await probeExitIP(outlet: outlet)
    }

    func probeExitIP(outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        guard !isProbingExitIP else { return }
        isProbingExitIP = true
        defer { isProbingExitIP = false }

        do {
            let result = try await exitProber.probe(outlet: targetOutlet)
            exitProbe = result
        } catch {
            showStatusBanner("出口 IP 检测失败：\(error.localizedDescription)")
        }
    }

    func refreshAvailableNodes(for outlet: OutletConfig) async {
        let parserCopy = parser
        let nodes: [String] = await Task.detached(priority: .utility) {
            switch outlet.source {
            case .localClashProfile(let path):
                let expanded = NSString(string: path).expandingTildeInPath
                guard !expanded.isEmpty else { return [] }
                return (try? parserCopy.listProxyNames(fromFileAt: URL(fileURLWithPath: expanded))) ?? []
            case .manualYAML(let yaml):
                return (try? parserCopy.listProxyNames(fromYAML: yaml)) ?? []
            case .remoteSubscription, .upstreamProxy:
                return []
            }
        }.value
        availableProfileNodes = nodes
    }

    private func refreshOutletRuntimeStatus(for outlet: OutletConfig) async {
        let managedRunning = await mihomoManager.isRunning(outletID: outlet.id)
        let host = outlet.listenHost
        let port = outlet.listenPort
        let inspectorCopy = inspector
        let portListening = await Task.detached(priority: .utility) {
            inspectorCopy.isLocalPortListening(host: host, port: port, timeout: 0.35)
        }.value

        outletRunning = managedRunning || portListening

        let client = mihomoManager.apiClient(for: outlet)
        if let ver = try? await client.version(timeout: 1.5) {
            mihomoVersion = ver.version
        } else if !outletRunning {
            mihomoVersion = nil
        }

        if let proxies = try? await client.proxies(timeout: 1.5),
           let group = proxies[MihomoConfigRenderer.outletGroupName]
        {
            activeMihomoNode = group.now
            mihomoGroupNodes = group.all ?? []
        }
    }

    // MARK: - Audit & Connections

    func refreshAudit() async {
        let currentConfig = config
        let auditorCopy = leakAuditor
        let snapshot: AuditSnapshot = await Task.detached(priority: .utility) {
            auditorCopy.audit(config: currentConfig)
        }.value

        let prevState = previousHealthState
        auditSnapshot = snapshot
        outletRunning = snapshot.outletRunning
        previousHealthState = snapshot.overallState

        if currentConfig.auditPolicy.notifyOnLeak,
           snapshot.overallState == .leaking,
           prevState != .leaking
        {
            sendLeakNotification(summary: snapshot.summary)
        }
    }

    func refreshActiveConnections() async {
        guard let outlet = config.primaryOutlet() else {
            activeConnections = []
            return
        }
        let client = mihomoManager.apiClient(for: outlet)
        if let conns = try? await client.activeConnections(timeout: 2.0) {
            activeConnections = conns
            if !outletRunning {
                outletRunning = true
            }
        } else if !outletRunning {
            activeConnections = []
        }
    }

    // MARK: - Config Persistence & Profile Watching

    func saveConfig(_ newConfig: PinGateConfig, triggerSync: Bool = true) async {
        do {
            try configStore.save(newConfig)
            config = newConfig
            discoveredFlClashProfiles = ConfigStore.discoverFlClashProfiles()
            configureProfileWatchers()
            refreshTargetStatuses()
            showStatusBanner("配置已保存")

            let snapshotURL = configStore.runtimeDirectory.appendingPathComponent("extension-policy.json")
            let extSnapshot = interceptor.exportExtensionSnapshot(config: newConfig)
            try? extSnapshot.write(to: snapshotURL)

            if triggerSync {
                await syncNow()
            }
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func configureProfileWatchers() {
        for watcher in profileWatchers.values {
            watcher.stop()
        }
        profileWatchers.removeAll()

        for outlet in config.outlets where outlet.enabled {
            guard case .localClashProfile(let rawPath) = outlet.source else { continue }
            let expanded = NSString(string: rawPath).expandingTildeInPath
            guard !expanded.isEmpty, FileManager.default.fileExists(atPath: expanded) else { continue }

            let outletID = outlet.id
            let watcher = ProfileWatcher(
                fileURL: URL(fileURLWithPath: expanded),
                debounceInterval: 1.0
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, let currentOutlet = self.config.outlet(id: outletID) else { return }
                    await self.syncNow(outlet: currentOutlet)
                }
            }
            if (try? watcher.start()) != nil {
                profileWatchers[outlet.id] = watcher
            }
        }
    }

    // MARK: - Target Operations

    func launchOrActivate(target: ManagedTarget) async {
        guard !busyTargetIDs.contains(target.id) else { return }
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        busyTargetIDs.insert(target.id)
        defer { busyTargetIDs.remove(target.id) }
        do {
            let outcome = try await interceptor.launchTarget(
                target,
                outlet: outlet,
                bypassRules: config.bypassRules,
                policy: config.auditPolicy,
                forceRestart: false
            )
            handleLaunchOutcome(outcome)
            await refreshAudit()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func restartTargetWithProxy(target: ManagedTarget) async {
        guard !busyTargetIDs.contains(target.id) else { return }
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        busyTargetIDs.insert(target.id)
        defer { busyTargetIDs.remove(target.id) }
        showStatusBanner("正在重启「\(target.name)」并走代理…", autoDismiss: false)
        do {
            let outcome = try await interceptor.launchTarget(
                target,
                outlet: outlet,
                bypassRules: config.bypassRules,
                policy: config.auditPolicy,
                forceRestart: true
            )
            handleLaunchOutcome(outcome)
            await refreshAudit()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    private func handleLaunchOutcome(_ outcome: AppLaunchOutcome) {
        switch outcome {
        case .launched(_, let name, let port):
            showStatusBanner("已启动 \(name) 并走代理（:\(String(port))）")
        case .activatedExisting(_, let name):
            showStatusBanner("已切换到 \(name)")
        case .runningWithoutProxy(_, let name, _):
            showStatusBanner("\(name) 当前未走代理，请点击「重启并走代理」")
        case .restartedWithProxy(_, _, let name, let port):
            showStatusBanner("已重启 \(name) 并走代理（:\(String(port))）")
        case .blockedPortClosed(let host, let port, let name):
            lastSyncError = "本地代理 \(host):\(String(port)) 未运行，已阻止启动 \(name) 以避免直连。"
        }
    }

    func installCLIShim(for target: ManagedTarget) async {
        guard !busyTargetIDs.contains(target.id) else { return }
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        busyTargetIDs.insert(target.id)
        defer { busyTargetIDs.remove(target.id) }
        do {
            let url = try interceptor.shimManager.installShim(
                target: target,
                outlet: outlet,
                bypassRules: config.bypassRules
            )
            showStatusBanner("已安装命令：\(Self.shortenedPath(url.path))")
            refreshTargetStatuses()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func removeCLIShim(for target: ManagedTarget) async {
        guard !busyTargetIDs.contains(target.id) else { return }
        guard let cmd = target.cliCommandName else { return }
        busyTargetIDs.insert(target.id)
        defer { busyTargetIDs.remove(target.id) }
        do {
            _ = try interceptor.shimManager.removeShim(commandName: cmd)
            showStatusBanner("已移除命令：\(cmd)")
            refreshTargetStatuses()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func syncT3Code(for target: ManagedTarget) async {
        guard !busyTargetIDs.contains(target.id) else { return }
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        busyTargetIDs.insert(target.id)
        defer { busyTargetIDs.remove(target.id) }
        do {
            let result = try interceptor.t3Adapter.sync(
                target: target,
                outlet: outlet,
                bypassRules: config.bypassRules
            )
            showStatusBanner(
                result.changed
                    ? "已同步 T3 Code（\(result.providerKey)）并自动备份"
                    : "T3 Code（\(result.providerKey)）已是最新状态"
            )
            refreshTargetStatuses()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func applyTemplate(_ template: TargetTemplate) async {
        guard let outletID = config.primaryOutlet()?.id else { return }
        let additions = template.makeTargets(outletID: outletID)
        var cfg = config
        var addedCount = 0
        for item in additions {
            let duplicate = cfg.targets.contains { existing in
                existing.name.lowercased() == item.name.lowercased() && existing.kind == item.kind
            }
            if !duplicate {
                cfg.targets.append(item)
                addedCount += 1
            }
        }
        if addedCount > 0 {
            await saveConfig(cfg, triggerSync: false)
            showStatusBanner("已添加「\(template.name)」（新增 \(addedCount) 项）")
        } else {
            showStatusBanner("「\(template.name)」中的所有项目都已添加")
        }
    }

    func refreshTargetStatuses() {
        var shims: [UUID: Bool] = [:]
        var t3: [UUID: Bool] = [:]
        for target in config.targets {
            guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { continue }
            switch target.kind {
            case .cliTool:
                let st = interceptor.shimManager.status(for: target)
                shims[target.id] = st.isInstalled && st.isManagedByPinGate
            case .t3Integration:
                t3[target.id] = interceptor.t3Adapter.isInSync(
                    target: target,
                    outlet: outlet,
                    bypassRules: config.bypassRules
                )
            case .guiApp:
                break
            }
        }
        cliShimStatuses = shims
        t3SyncStatuses = t3
    }

    // MARK: - Per-Target Audit Queries

    func processesForTarget(_ target: ManagedTarget) -> [ProcessAudit] {
        (auditSnapshot?.processes ?? []).filter { $0.targetID == target.id }
    }

    func isTargetLeaking(_ target: ManagedTarget) -> Bool {
        processesForTarget(target).contains { $0.isLeaking }
    }

    func proxiedConnectionCount(for target: ManagedTarget) -> Int {
        processesForTarget(target).reduce(0) { $0 + $1.proxiedSocketCount }
    }

    // MARK: - Launch at Login & Notifications

    private static func readLaunchAtLoginState() -> Bool {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard isBundledApp else {
            launchAtLogin = false
            showStatusBanner("开机自启需要从 PinGate.app 应用程序包运行")
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLogin = Self.readLaunchAtLoginState()
            lastSyncError = "更新开机自启设置失败：\(error.localizedDescription)"
        }
    }

    private func requestNotificationPermissionIfBundled() {
        guard isBundledApp else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendLeakNotification(summary: String) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "PinGate 直连提醒"
        content.body = summary
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "com.pingate.leak.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Shutdown

    func quitApp() {
        pollTask?.cancel()
        pollTask = nil
        updateCheckTask?.cancel()
        updateCheckTask = nil
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        for watcher in profileWatchers.values {
            watcher.stop()
        }
        profileWatchers.removeAll()
        Task {
            await mihomoManager.stopAll()
            NSApp.terminate(nil)
        }
    }
}

// MARK: - Shared UI Components

/// Full-row clickable collapsible card replacing macOS `DisclosureGroup` (which only reacts to its 8px chevron).
struct CollapsibleCard<Content: View>: View {
    let title: String
    @Binding var isExpanded: Bool
    var compact: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHoveringHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 12)
                    Text(title)
                        .font(compact ? .caption.weight(.medium) : .subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Spacer()
                }
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 8 : 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: compact ? 7 : 10, style: .continuous)
                        .fill(isHoveringHeader ? Color.primary.opacity(0.05) : Color.clear)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                isHoveringHeader = hovering
            }

            if isExpanded {
                Divider()
                    .padding(.horizontal, compact ? 10 : 14)
                content()
                    .padding(.horizontal, compact ? 10 : 14)
                    .padding(.top, compact ? 8 : 12)
                    .padding(.bottom, compact ? 10 : 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(compact ? Color.primary.opacity(0.03) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
}

/// Displays a real macOS application bundle icon when available, falling back to an SF Symbol.
struct TargetIconView: View {
    let target: ManagedTarget
    var size: CGFloat = 24
    var tintColor: Color = .secondary

    var body: some View {
        if target.kind == .guiApp, let appIcon = resolvedAppIcon() {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(tintColor.opacity(0.14))
                    .frame(width: size, height: size)
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(tintColor)
            }
        }
    }

    private var fallbackSymbol: String {
        switch target.kind {
        case .guiApp: return "app.fill"
        case .cliTool: return "terminal.fill"
        case .t3Integration: return "link"
        }
    }

    private func resolvedAppIcon() -> NSImage? {
        guard let rawPath = target.appPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty
        else { return nil }
        let expanded = NSString(string: rawPath).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }
        return NSWorkspace.shared.icon(forFile: expanded)
    }
}

/// Restrained macOS-native status indicator: solid 6pt dot + high-contrast label.
struct StatusDotLabel: View {
    let text: String
    let color: Color
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption)
                .fontWeight(emphasized ? .semibold : .regular)
                .foregroundStyle(emphasized ? color : .secondary)
        }
    }
}

/// Unified protection master switch.
/// Uses native `.alert` in standard windows, or calls `onRequestConfirmPause` inside MenuBarExtra popovers
/// where system confirmation dialogs can dismiss the popover.
struct ProtectionMasterSwitch: View {
    @Bindable var appState: AppState
    var onRequestConfirmPause: (() -> Void)? = nil
    @State private var showPauseAlert = false

    var body: some View {
        HStack(spacing: 6) {
            if appState.isTogglingOutlet {
                ProgressView()
                    .controlSize(.small)
            }
            Toggle(
                "代理保护总开关",
                isOn: Binding(
                    get: { appState.outletRunning },
                    set: { wantOn in
                        if wantOn {
                            Task { await appState.startOutlet() }
                        } else if appState.hasActiveProtectedTraffic {
                            if let onRequestConfirmPause {
                                onRequestConfirmPause()
                            } else {
                                showPauseAlert = true
                            }
                        } else {
                            Task { await appState.stopOutlet() }
                        }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(.green)
            .controlSize(.small)
            .disabled(appState.isTogglingOutlet)
            .help(appState.outletRunning ? "关闭代理保护" : "开启代理保护")
        }
        .alert("确定要关闭代理保护吗？", isPresented: $showPauseAlert) {
            Button("仍要关闭", role: .destructive) {
                Task { await appState.stopOutlet() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            let procs = appState.activeProtectedProcessCount
            let socks = appState.auditSnapshot?.totalProxiedSockets ?? 0
            Text("当前有 \(String(procs)) 个应用进程（\(String(socks)) 条代理连接）正在使用代理，关闭后会立即中断它们的网络连接。")
        }
    }
}
