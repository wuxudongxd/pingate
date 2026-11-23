import Darwin
import Foundation

public enum MihomoProcessState: String, Sendable, Equatable {
    case stopped
    case starting
    case running
    case restarting
    case failed

    public var displayName: String {
        switch self {
        case .stopped:
            return "已停止"
        case .starting:
            return "启动中"
        case .running:
            return "运行中"
        case .restarting:
            return "重启中"
        case .failed:
            return "启动失败"
        }
    }
}

public enum MihomoProcessError: Error, LocalizedError, Sendable {
    case startupFailed(String)
    case processExitedEarly(Int32)

    public var errorDescription: String? {
        switch self {
        case .startupFailed(let message):
            return "启动 mihomo 失败：\(message)"
        case .processExitedEarly(let code):
            return "mihomo 在启动阶段意外退出（退出码 \(code)）。"
        }
    }
}

public actor MihomoProcessManager {
    private struct ManagedInstance {
        var outlet: OutletConfig
        var bypassRules: BypassRules
        var process: Process
        var logHandle: FileHandle?
        var intentionalStop: Bool = false
        var restartAttempts: Int = 0
        var restartTask: Task<Void, Never>?
        var state: MihomoProcessState
    }

    public let configStore: ConfigStore
    public let binaryManager: MihomoBinaryManager
    public let parser: ClashProfileParser
    public let renderer: MihomoConfigRenderer

    private var instances: [UUID: ManagedInstance] = [:]
    private let maxLogSizeBytes: UInt64 = 5 * 1024 * 1024
    private let maxRestartAttempts = 5

    public init(
        configStore: ConfigStore = ConfigStore(),
        binaryManager: MihomoBinaryManager? = nil,
        parser: ClashProfileParser = ClashProfileParser(),
        renderer: MihomoConfigRenderer = MihomoConfigRenderer()
    ) {
        self.configStore = configStore
        self.binaryManager = binaryManager ?? MihomoBinaryManager(binDirectory: configStore.binDirectory)
        self.parser = parser
        self.renderer = renderer
    }

    public func state(for outletID: UUID) -> MihomoProcessState {
        instances[outletID]?.state ?? .stopped
    }

    public func isRunning(outletID: UUID) -> Bool {
        guard let instance = instances[outletID] else { return false }
        return instance.process.isRunning
    }

    public func pid(for outletID: UUID) -> Int32? {
        guard let instance = instances[outletID], instance.process.isRunning else { return nil }
        return instance.process.processIdentifier
    }

    public nonisolated func apiClient(for outlet: OutletConfig) -> MihomoAPIClient {
        MihomoAPIClient(outlet: outlet)
    }

    /// Resolves proxies from `outlet.source`, renders the `0600` Mihomo YAML config,
    /// and optionally hot-reloads a live Mihomo instance via `PUT /configs?force=true`.
    public func syncAndRender(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        hotReloadIfRunning: Bool = true
    ) async throws -> NodeSyncResult {
        try configStore.ensureDirectories()
        let chain = try await parser.resolveProxies(for: outlet)
        let configURL = configStore.renderedMihomoConfigURL(for: outlet)
        try renderer.writeConfig(outlet: outlet, chain: chain, bypassRules: bypassRules, to: configURL)

        var reloaded = false
        if hotReloadIfRunning {
            let client = apiClient(for: outlet)
            let reachable = await client.isReachable(timeout: 1.5)
            if reachable {
                try await client.reloadConfig(path: configURL.path, force: true)
                reloaded = true
            }
        }

        if var instance = instances[outlet.id] {
            instance.outlet = outlet
            instance.bypassRules = bypassRules
            instances[outlet.id] = instance
        }

        return NodeSyncResult(
            outletID: outlet.id,
            outletName: outlet.name,
            syncedAt: Date(),
            primaryNode: chain.primaryNodeName,
            extractedProxyNames: chain.orderedProxyNames,
            missingFallbackNodes: chain.missingFallbackNames,
            renderedConfigPath: configURL.path,
            reloadedLive: reloaded
        )
    }

    public func start(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        seedBinaryPaths: [URL] = MihomoBinaryManager.defaultSeedCandidateURLs()
    ) async throws {
        if let existing = instances[outlet.id], existing.process.isRunning {
            _ = try await syncAndRender(outlet: outlet, bypassRules: bypassRules, hotReloadIfRunning: true)
            return
        }

        let binaryURL = try binaryManager.ensureBinary(seedPaths: seedBinaryPaths)
        let syncResult = try await syncAndRender(outlet: outlet, bypassRules: bypassRules, hotReloadIfRunning: false)
        let configURL = URL(fileURLWithPath: syncResult.renderedConfigPath)

        try await spawnProcess(
            outlet: outlet,
            bypassRules: bypassRules,
            binaryURL: binaryURL,
            configURL: configURL,
            restartAttempts: 0
        )
    }

    public func stop(outletID: UUID) async {
        guard var instance = instances[outletID] else { return }
        instance.intentionalStop = true
        instance.restartTask?.cancel()
        instance.restartTask = nil
        instance.state = .stopped
        instances[outletID] = instance

        let process = instance.process
        if process.isRunning {
            process.terminate() // SIGTERM
            let deadline = Date().addingTimeInterval(2.0)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        try? instance.logHandle?.close()
        instances.removeValue(forKey: outletID)
    }

    public func stopAll() async {
        let ids = Array(instances.keys)
        for id in ids {
            await stop(outletID: id)
        }
    }

    public func restart(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        seedBinaryPaths: [URL] = MihomoBinaryManager.defaultSeedCandidateURLs()
    ) async throws {
        await stop(outletID: outlet.id)
        try await start(outlet: outlet, bypassRules: bypassRules, seedBinaryPaths: seedBinaryPaths)
    }

    // MARK: - Internal Supervision

    private func spawnProcess(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        binaryURL: URL,
        configURL: URL,
        restartAttempts: Int
    ) async throws {
        let logURL = configStore.logFileURL(for: outlet)
        let logHandle = try prepareLogFileHandle(at: logURL)

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-d", configStore.runtimeDirectory.path, "-f", configURL.path]
        process.standardOutput = logHandle
        process.standardError = logHandle

        let outletID = outlet.id
        process.terminationHandler = { [weak self] terminated in
            let status = terminated.terminationStatus
            Task { [weak self] in
                await self?.handleUnexpectedTermination(outletID: outletID, exitCode: status)
            }
        }

        do {
            try process.run()
        } catch {
            try? logHandle.close()
            throw MihomoProcessError.startupFailed(error.localizedDescription)
        }

        instances[outletID] = ManagedInstance(
            outlet: outlet,
            bypassRules: bypassRules,
            process: process,
            logHandle: logHandle,
            intentionalStop: false,
            restartAttempts: restartAttempts,
            restartTask: nil,
            state: .starting
        )

        // Wait for Controller API readiness (up to 5s)
        let client = apiClient(for: outlet)
        let deadline = Date().addingTimeInterval(5.0)
        var ready = false
        while Date() < deadline {
            if !process.isRunning {
                let code = process.terminationStatus
                if var inst = instances[outletID] {
                    inst.state = .failed
                    instances[outletID] = inst
                }
                throw MihomoProcessError.processExitedEarly(code)
            }
            if await client.isReachable(timeout: 0.5) {
                ready = true
                break
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        guard ready else {
            await stop(outletID: outletID)
            throw MihomoProcessError.startupFailed("控制器 \(outlet.controllerAddress) 在超时时间内未能就绪。")
        }

        if var inst = instances[outletID] {
            inst.state = .running
            inst.restartAttempts = 0
            instances[outletID] = inst
        }
    }

    private func handleUnexpectedTermination(outletID: UUID, exitCode: Int32) async {
        guard var instance = instances[outletID] else { return }
        try? instance.logHandle?.close()
        instance.logHandle = nil

        if instance.intentionalStop {
            instance.state = .stopped
            instances.removeValue(forKey: outletID)
            return
        }

        let nextAttempt = instance.restartAttempts + 1
        guard nextAttempt <= maxRestartAttempts else {
            instance.state = .failed
            instances[outletID] = instance
            return
        }

        instance.restartAttempts = nextAttempt
        instance.state = .restarting
        let outlet = instance.outlet
        let bypassRules = instance.bypassRules
        let backoffSeconds = min(pow(2.0, Double(nextAttempt - 1)), 16.0)

        instance.restartTask?.cancel()
        instance.restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoffSeconds))
            guard !Task.isCancelled, let self else { return }
            await self.performBackoffRestart(
                outlet: outlet,
                bypassRules: bypassRules,
                attempt: nextAttempt
            )
        }
        instances[outletID] = instance
    }

    private func performBackoffRestart(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        attempt: Int
    ) async {
        guard let current = instances[outlet.id], !current.intentionalStop else { return }
        let configURL = configStore.renderedMihomoConfigURL(for: outlet)
        do {
            let binaryURL = try binaryManager.ensureBinary()
            try await spawnProcess(
                outlet: outlet,
                bypassRules: bypassRules,
                binaryURL: binaryURL,
                configURL: configURL,
                restartAttempts: attempt
            )
        } catch {
            if var inst = instances[outlet.id] {
                inst.state = .failed
                instances[outlet.id] = inst
            }
        }
    }

    private func prepareLogFileHandle(at logURL: URL) throws -> FileHandle {
        let fm = FileManager.default
        if fm.fileExists(atPath: logURL.path) {
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? UInt64,
               size >= maxLogSizeBytes {
                let rotatedURL = logURL.appendingPathExtension("1")
                try? fm.removeItem(at: rotatedURL)
                try? fm.moveItem(at: logURL, to: rotatedURL)
            }
        }

        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
        } else {
            try? ConfigStore.setPosixPermissions(0o600, at: logURL)
        }

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        return handle
    }
}
