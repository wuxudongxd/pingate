import Foundation

/// Serializable rule snapshot shared between the main PinGate app and a future Phase 3
/// `NETransparentProxyProvider` System Extension via an App Group container.
public struct ExtensionRuleSnapshot: Codable, Sendable, Equatable {
    public struct OutletRule: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let listenHost: String
        public let listenPort: Int

        public init(id: UUID, name: String, listenHost: String, listenPort: Int) {
            self.id = id
            self.name = name
            self.listenHost = listenHost
            self.listenPort = listenPort
        }
    }

    public struct TargetRule: Codable, Sendable, Equatable, Identifiable {
        public let id: UUID
        public let name: String
        public let kind: TargetKind
        public let outletID: UUID
        public let bundleID: String?
        public let appPath: String?
        public let processMatchNames: [String]

        public init(
            id: UUID,
            name: String,
            kind: TargetKind,
            outletID: UUID,
            bundleID: String?,
            appPath: String?,
            processMatchNames: [String]
        ) {
            self.id = id
            self.name = name
            self.kind = kind
            self.outletID = outletID
            self.bundleID = bundleID
            self.appPath = appPath
            self.processMatchNames = processMatchNames
        }
    }

    public let schemaVersion: Int
    public let generatedAt: Date
    public let captureMode: CaptureMode
    public let outlets: [OutletRule]
    public let targets: [TargetRule]
    public let bypassDomains: [String]
    public let bypassCIDRs: [String]

    public init(
        schemaVersion: Int = PinGateConfig.currentSchemaVersion,
        generatedAt: Date = Date(),
        captureMode: CaptureMode,
        outlets: [OutletRule],
        targets: [TargetRule],
        bypassDomains: [String],
        bypassCIDRs: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.captureMode = captureMode
        self.outlets = outlets
        self.targets = targets
        self.bypassDomains = bypassDomains
        self.bypassCIDRs = bypassCIDRs
    }

    /// Builds an AppGroup-ready rule snapshot from a `PinGateConfig`.
    public static func build(from config: PinGateConfig, generatedAt: Date = Date()) -> ExtensionRuleSnapshot {
        let outletRules = config.outlets
            .filter(\.enabled)
            .map {
                OutletRule(
                    id: $0.id,
                    name: $0.name,
                    listenHost: $0.listenHost,
                    listenPort: $0.listenPort
                )
            }

        let targetRules = config.targets
            .filter(\.enabled)
            .map {
                TargetRule(
                    id: $0.id,
                    name: $0.name,
                    kind: $0.kind,
                    outletID: $0.outletID,
                    bundleID: $0.bundleID,
                    appPath: $0.appPath,
                    processMatchNames: $0.processMatchNames
                )
            }

        return ExtensionRuleSnapshot(
            schemaVersion: config.schemaVersion,
            generatedAt: generatedAt,
            captureMode: config.captureMode,
            outlets: outletRules,
            targets: targetRules,
            bypassDomains: config.bypassRules.mihomoDomainSuffixes(),
            bypassCIDRs: config.bypassRules.cidrs
        )
    }

    /// Atomically writes the snapshot JSON to disk with `0600` permissions.
    public func write(to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func read(from url: URL) throws -> ExtensionRuleSnapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExtensionRuleSnapshot.self, from: data)
    }
}

/// Summary returned after applying traffic capture rules across managed targets.
public struct InterceptorApplyReport: Codable, Sendable, Equatable {
    public let mode: CaptureMode
    public let appliedAt: Date
    public let syncedCLIShims: [String]
    public let syncedT3Targets: [String]
    public let snapshotPath: String?
    public let warnings: [String]

    public init(
        mode: CaptureMode,
        appliedAt: Date = Date(),
        syncedCLIShims: [String] = [],
        syncedT3Targets: [String] = [],
        snapshotPath: String? = nil,
        warnings: [String] = []
    ) {
        self.mode = mode
        self.appliedAt = appliedAt
        self.syncedCLIShims = syncedCLIShims
        self.syncedT3Targets = syncedT3Targets
        self.snapshotPath = snapshotPath
        self.warnings = warnings
    }
}

/// Runtime status of the active `TrafficInterceptor` backend.
public struct InterceptorStatus: Codable, Sendable, Equatable {
    public let mode: CaptureMode
    public let isActive: Bool
    public let detail: String
    public let extensionAvailable: Bool

    public init(
        mode: CaptureMode,
        isActive: Bool,
        detail: String,
        extensionAvailable: Bool
    ) {
        self.mode = mode
        self.isActive = isActive
        self.detail = detail
        self.extensionAvailable = extensionAvailable
    }
}

/// Unified traffic capture abstraction decoupling policy/UI from execution backend:
/// - Phase 1-2: `UserSpaceInterceptor` (NSWorkspace env/arg launcher + CLI shims + T3 provider sync + libproc auditing)
/// - Phase 3:   `NETransparentProxyProvider` System Extension reading `ExtensionRuleSnapshot` via App Group container
public protocol TrafficInterceptor: Sendable {
    var mode: CaptureMode { get }

    func applyRules(config: PinGateConfig) async throws -> InterceptorApplyReport
    func launchTarget(
        _ target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        policy: AuditPolicy,
        forceRestart: Bool
    ) async throws -> AppLaunchOutcome
    func status() async -> InterceptorStatus
    func exportExtensionSnapshot(config: PinGateConfig) -> ExtensionRuleSnapshot
}

/// Phase 1-2 User-Space traffic capture implementation.
/// Coordinates `AppLauncher`, `CLIShimManager`, and `T3CodeSyncAdapter`, while also writing an
/// AppGroup-compatible `ExtensionRuleSnapshot` to keep the Phase 3 System Extension seam exercised.
public struct UserSpaceInterceptor: TrafficInterceptor, Sendable {
    public let mode: CaptureMode = .userSpace
    public let appLauncher: AppLauncher
    public let shimManager: CLIShimManager
    public let t3Adapter: T3CodeSyncAdapter
    public let snapshotURL: URL?

    public init(
        appLauncher: AppLauncher = AppLauncher(),
        shimManager: CLIShimManager = CLIShimManager(),
        t3Adapter: T3CodeSyncAdapter = T3CodeSyncAdapter(),
        snapshotURL: URL? = nil
    ) {
        self.appLauncher = appLauncher
        self.shimManager = shimManager
        self.t3Adapter = t3Adapter
        self.snapshotURL = snapshotURL
    }

    public func applyRules(config: PinGateConfig) async throws -> InterceptorApplyReport {
        var syncedShims: [String] = []
        var syncedT3: [String] = []
        var warnings: [String] = []

        for target in config.targets where target.enabled {
            guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else {
                warnings.append("应用「\(target.name)」未绑定有效代理出口。")
                continue
            }

            switch target.kind {
            case .cliTool:
                do {
                    let url = try shimManager.installShim(
                        target: target,
                        outlet: outlet,
                        bypassRules: config.bypassRules
                    )
                    syncedShims.append(url.path)
                } catch {
                    warnings.append("命令行工具「\(target.name)」已跳过：\(error.localizedDescription)")
                }

            case .t3Integration:
                do {
                    let result = try t3Adapter.sync(
                        target: target,
                        outlet: outlet,
                        bypassRules: config.bypassRules
                    )
                    syncedT3.append("\(result.providerKey)（\(result.changed ? "已更新" : "已是最新")）")
                } catch T3SyncError.settingsFileNotFound(let path) {
                    warnings.append("未找到 T3 Code 配置文件 \(path)，已跳过同步。")
                } catch {
                    warnings.append("T3 Code 同步「\(target.name)」警告：\(error.localizedDescription)")
                }

            case .guiApp:
                // GUI apps receive injected environment & Chromium flags at launch time via AppLauncher.
                break
            }
        }

        var writtenSnapshotPath: String? = nil
        if let snapshotURL {
            let snapshot = exportExtensionSnapshot(config: config)
            do {
                try snapshot.write(to: snapshotURL)
                writtenSnapshotPath = snapshotURL.path
            } catch {
                warnings.append("写入系统扩展规则快照失败：\(error.localizedDescription)")
            }
        }

        return InterceptorApplyReport(
            mode: mode,
            syncedCLIShims: syncedShims,
            syncedT3Targets: syncedT3,
            snapshotPath: writtenSnapshotPath,
            warnings: warnings
        )
    }

    public func launchTarget(
        _ target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        policy: AuditPolicy = AuditPolicy(),
        forceRestart: Bool = false
    ) async throws -> AppLaunchOutcome {
        try await appLauncher.launch(
            target: target,
            outlet: outlet,
            bypassRules: bypassRules,
            policy: policy,
            forceRestart: forceRestart
        )
    }

    public func status() async -> InterceptorStatus {
        InterceptorStatus(
            mode: .userSpace,
            isActive: true,
            detail: "标准代理模式运行中（桌面应用注入 + 命令行工具 + T3 Code 同步 + 实时连接监控）。",
            extensionAvailable: false
        )
    }

    public func exportExtensionSnapshot(config: PinGateConfig) -> ExtensionRuleSnapshot {
        ExtensionRuleSnapshot.build(from: config)
    }
}
