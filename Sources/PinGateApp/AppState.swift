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

    // MARK: - Published Observable State
    var config: PinGateConfig
    var auditSnapshot: AuditSnapshot?
    var outletRunning: Bool = false
    var mihomoVersion: String?
    var exitProbe: ExitProbeResult?
    var isProbingExitIP: Bool = false
    var isSyncing: Bool = false
    var lastSyncResult: NodeSyncResult?
    var lastSyncError: String?
    var statusBannerMessage: String?

    var availableProfileNodes: [String] = []
    var activeMihomoNode: String?
    var mihomoGroupNodes: [String] = []
    var nodeLatenciesMs: [String: Int] = [:]
    var testingLatencyNodes: Set<String> = []
    var activeConnections: [MihomoActiveConnection] = []

    var cliShimStatuses: [UUID: Bool] = [:]
    var t3SyncStatuses: [UUID: Bool] = [:]
    var discoveredFlClashProfiles: [URL] = []
    var launchAtLogin: Bool = false
    var captureModeStatusMessage: String = "用户态托管模式运行中（NSWorkspace 启动注入 + CLI Shim + T3 Code 同步 + libproc 防漏审计）。"

    // MARK: - Internal Lifecycle
    private var hasBootstrapped = false
    private var pollTask: Task<Void, Never>?
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

    // MARK: - Chinese Date & Time Formatters

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

    // MARK: - Outlet Lifecycle & Sync

    func startOutlet(_ outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else {
            lastSyncError = "尚未配置任何出口通道。"
            return
        }
        lastSyncError = nil
        statusBannerMessage = "正在启动 \(targetOutlet.name)…"
        do {
            try await mihomoManager.start(outlet: targetOutlet, bypassRules: config.bypassRules)
            await refreshOutletRuntimeStatus(for: targetOutlet)
            statusBannerMessage = "\(targetOutlet.name) 已监听 :\(String(targetOutlet.listenPort))"
            await probeExitIP(outlet: targetOutlet)
            await refreshAudit()
            await refreshActiveConnections()
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = "启动失败"
        }
    }

    func stopOutlet(_ outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        statusBannerMessage = "正在停止 \(targetOutlet.name)…"
        await mihomoManager.stop(outletID: targetOutlet.id)
        await refreshOutletRuntimeStatus(for: targetOutlet)
        activeConnections = []
        statusBannerMessage = "\(targetOutlet.name) 已停止"
        await refreshAudit()
    }

    func restartOutlet(_ outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        lastSyncError = nil
        statusBannerMessage = "正在重启 \(targetOutlet.name)…"
        do {
            try await mihomoManager.restart(outlet: targetOutlet, bypassRules: config.bypassRules)
            await refreshOutletRuntimeStatus(for: targetOutlet)
            statusBannerMessage = "\(targetOutlet.name) 已重启"
            await probeExitIP(outlet: targetOutlet)
            await refreshAudit()
            await refreshActiveConnections()
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = "重启失败"
        }
    }

    func syncNow(outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        guard !isSyncing else { return }
        isSyncing = true
        lastSyncError = nil
        statusBannerMessage = "正在同步 \(targetOutlet.name)…"
        defer { isSyncing = false }

        do {
            let result = try await mihomoManager.syncAndRender(
                outlet: targetOutlet,
                bypassRules: config.bypassRules,
                hotReloadIfRunning: true
            )
            lastSyncResult = result
            statusBannerMessage = result.reloadedLive
                ? "已同步并热重载（\(result.extractedProxyNames.count) 个节点）"
                : "已生成 0600 权限配置（\(result.extractedProxyNames.count) 个节点）"
            await refreshOutletRuntimeStatus(for: targetOutlet)
            if outletRunning {
                await probeExitIP(outlet: targetOutlet)
            }
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = "同步失败"
        }
    }

    func selectActiveNode(_ nodeName: String, outlet: OutletConfig? = nil) async {
        guard let targetOutlet = outlet ?? config.primaryOutlet() else { return }
        let client = mihomoManager.apiClient(for: targetOutlet)
        do {
            try await client.selectProxy(nodeName: nodeName)
            activeMihomoNode = nodeName
            statusBannerMessage = "已切换出口节点至 \(nodeName)"
            await probeExitIP(outlet: targetOutlet)
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func testLatency(nodeName: String, outlet: OutletConfig) async {
        guard !nodeName.isEmpty else { return }
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
            statusBannerMessage = "出口 IP 探测失败：\(error.localizedDescription)"
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
            statusBannerMessage = "配置已保存（0600 权限）"

            let snapshotURL = configStore.runtimeDirectory.appendingPathComponent("extension-policy.json")
            let extSnapshot = interceptor.exportExtensionSnapshot(config: newConfig)
            try? extSnapshot.write(to: snapshotURL)

            if triggerSync {
                await syncNow()
            }
        } catch {
            lastSyncError = error.localizedDescription
            statusBannerMessage = "保存配置失败"
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
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
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
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        statusBannerMessage = "正在通过出口 :\(String(outlet.listenPort)) 重启 \(target.name)…"
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
            statusBannerMessage = "已启动 \(name)，固定至出口 :\(String(port))"
        case .activatedExisting(_, let name):
            statusBannerMessage = "已激活受保护的 \(name)"
        case .runningWithoutProxy(_, let name, let port):
            statusBannerMessage = "\(name) 未走出口 :\(String(port)) — 请点击「用代理重启」"
        case .restartedWithProxy(_, _, let name, let port):
            statusBannerMessage = "已通过出口 :\(String(port)) 重启 \(name)"
        case .blockedPortClosed(let host, let port, let name):
            lastSyncError = "Fail-Closed 拦截：本地出口 \(host):\(String(port)) 未监听，已阻止启动 \(name)。"
        }
    }

    func installCLIShim(for target: ManagedTarget) async {
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        do {
            let url = try interceptor.shimManager.installShim(
                target: target,
                outlet: outlet,
                bypassRules: config.bypassRules
            )
            statusBannerMessage = "已安装 CLI Shim：\(url.path)"
            refreshTargetStatuses()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func removeCLIShim(for target: ManagedTarget) async {
        guard let cmd = target.cliCommandName else { return }
        do {
            _ = try interceptor.shimManager.removeShim(commandName: cmd)
            statusBannerMessage = "已移除 CLI Shim：\(cmd)"
            refreshTargetStatuses()
        } catch {
            lastSyncError = error.localizedDescription
        }
    }

    func syncT3Code(for target: ManagedTarget) async {
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { return }
        do {
            let result = try interceptor.t3Adapter.sync(
                target: target,
                outlet: outlet,
                bypassRules: config.bypassRules
            )
            statusBannerMessage = result.changed
                ? "已同步 T3 Code（\(result.providerKey)）并自动备份"
                : "T3 Code（\(result.providerKey)）已是最新状态"
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
            statusBannerMessage = "已应用模板「\(template.name)」（新增 \(addedCount) 项）"
        } else {
            statusBannerMessage = "模板「\(template.name)」中的所有目标已存在"
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
            statusBannerMessage = "开机自启需要从 PinGate.app 应用程序包运行"
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
        content.title = "PinGate 防漏告警"
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
