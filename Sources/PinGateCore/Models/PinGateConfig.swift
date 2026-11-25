import Foundation

public enum CaptureMode: String, Codable, Sendable, CaseIterable, Hashable {
    case userSpace
    case systemExtension

    public var displayName: String {
        switch self {
        case .userSpace:
            return "标准代理模式"
        case .systemExtension:
            return "系统扩展模式（透明代理）"
        }
    }
}

public enum UpstreamScheme: String, Codable, Sendable, CaseIterable, Hashable {
    case http
    case socks5
}

public enum OutletSource: Codable, Sendable, Equatable, Hashable {
    case localClashProfile(path: String)
    case remoteSubscription(url: String, refreshIntervalMinutes: Int)
    case manualYAML(yaml: String)
    case upstreamProxy(
        scheme: UpstreamScheme,
        host: String,
        port: Int,
        username: String?,
        password: String?
    )

    public var kindDisplayName: String {
        switch self {
        case .localClashProfile:
            return "本地 Clash / FlClash 配置"
        case .remoteSubscription:
            return "远程订阅 URL"
        case .manualYAML:
            return "手动 YAML 节点"
        case .upstreamProxy:
            return "上游 HTTP/SOCKS5 代理"
        }
    }
}

public struct OutletConfig: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var listenHost: String
    public var listenPort: Int
    public var controllerPort: Int
    public var controllerSecret: String
    public var source: OutletSource
    public var primaryNodeName: String
    public var fallbackNodeNames: [String]
    public var expectedCountryCode: String?
    public var expectedIPHint: String?
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        listenHost: String = "127.0.0.1",
        listenPort: Int = 17899,
        controllerPort: Int = 17890,
        controllerSecret: String = OutletConfig.generateSecret(),
        source: OutletSource,
        primaryNodeName: String,
        fallbackNodeNames: [String] = [],
        expectedCountryCode: String? = "US",
        expectedIPHint: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.controllerPort = controllerPort
        self.controllerSecret = controllerSecret
        self.source = source
        self.primaryNodeName = primaryNodeName
        self.fallbackNodeNames = fallbackNodeNames
        self.expectedCountryCode = expectedCountryCode
        self.expectedIPHint = expectedIPHint
        self.enabled = enabled
    }

    public var proxyURLString: String {
        "http://\(listenHost):\(listenPort)"
    }

    public var socksProxyURLString: String {
        "socks5://\(listenHost):\(listenPort)"
    }

    public var controllerAddress: String {
        "127.0.0.1:\(controllerPort)"
    }

    public var controllerBaseURL: URL {
        URL(string: "http://127.0.0.1:\(controllerPort)")!
    }

    public static func generateSecret() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

public enum TargetKind: String, Codable, Sendable, CaseIterable, Hashable {
    case guiApp
    case cliTool
    case t3Integration

    public var displayName: String {
        switch self {
        case .guiApp:
            return "桌面应用"
        case .cliTool:
            return "命令行工具"
        case .t3Integration:
            return "T3 Code 集成"
        }
    }
}

public struct ManagedTarget: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: TargetKind
    public var outletID: UUID
    public var enabled: Bool
    public var bundleID: String?
    public var appPath: String?
    public var processMatchNames: [String]
    public var chromiumProxyFlags: Bool
    public var extraEnv: [String: String]
    public var cliCommandName: String?
    public var cliTargetBinaryPath: String?
    public var t3SettingsPath: String?
    public var t3ProviderKey: String?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TargetKind,
        outletID: UUID,
        enabled: Bool = true,
        bundleID: String? = nil,
        appPath: String? = nil,
        processMatchNames: [String] = [],
        chromiumProxyFlags: Bool = false,
        extraEnv: [String: String] = [:],
        cliCommandName: String? = nil,
        cliTargetBinaryPath: String? = nil,
        t3SettingsPath: String? = nil,
        t3ProviderKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.outletID = outletID
        self.enabled = enabled
        self.bundleID = bundleID
        self.appPath = appPath
        self.processMatchNames = processMatchNames
        self.chromiumProxyFlags = chromiumProxyFlags
        self.extraEnv = extraEnv
        self.cliCommandName = cliCommandName
        self.cliTargetBinaryPath = cliTargetBinaryPath
        self.t3SettingsPath = t3SettingsPath
        self.t3ProviderKey = t3ProviderKey
    }
}

public struct BypassRules: Codable, Sendable, Equatable, Hashable {
    public static let defaultBypassDomains: [String] = []

    public static let defaultPrivateCIDRs: [String] = [
        "127.0.0.0/8",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "100.64.0.0/10"
    ]

    public static let defaultNoProxyEntries: [String] = [
        "localhost",
        "127.0.0.1",
        "::1",
        "*.local"
    ]

    public var domains: [String]
    public var cidrs: [String]
    public var extraNoProxyEntries: [String]
    public var blockTelemetry: Bool

    public init(
        domains: [String] = BypassRules.defaultBypassDomains,
        cidrs: [String] = BypassRules.defaultPrivateCIDRs,
        extraNoProxyEntries: [String] = BypassRules.defaultNoProxyEntries,
        blockTelemetry: Bool = true
    ) {
        self.domains = domains
        self.cidrs = cidrs
        self.extraNoProxyEntries = extraNoProxyEntries
        self.blockTelemetry = blockTelemetry
    }

    private enum CodingKeys: String, CodingKey {
        case domains
        case cidrs
        case extraNoProxyEntries
        case blockTelemetry
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? Self.defaultBypassDomains
        self.cidrs = try container.decodeIfPresent([String].self, forKey: .cidrs) ?? Self.defaultPrivateCIDRs
        self.extraNoProxyEntries = try container.decodeIfPresent([String].self, forKey: .extraNoProxyEntries) ?? Self.defaultNoProxyEntries
        self.blockTelemetry = try container.decodeIfPresent(Bool.self, forKey: .blockTelemetry) ?? true
    }

    /// Generates a deduplicated comma-separated NO_PROXY value combining loopback/local hosts and private CIDRs.
    /// Bypass domains are intentionally omitted here so traffic routes through local Mihomo (`nameserver-policy: system` + `DIRECT`),
    /// avoiding direct public-IP sockets that would trigger false-positive leak alerts.
    public func noProxyCSV() -> String {
        var result: [String] = []
        var seen = Set<String>()
        for raw in extraNoProxyEntries + cidrs {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result.joined(separator: ",")
    }

    /// Generates a semicolon-separated Chromium `--proxy-bypass-list` value containing only local/loopback entries and private CIDRs.
    /// Bypass domains are handled by local Mihomo (`nameserver-policy: system` + `DOMAIN-SUFFIX,...,DIRECT`).
    public func chromiumBypassList() -> String {
        var result: [String] = []
        var seen = Set<String>()

        func appendUnique(_ value: String) {
            guard !value.isEmpty, !seen.contains(value) else { return }
            seen.insert(value)
            result.append(value)
        }

        for entry in extraNoProxyEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "::1" {
                appendUnique("[::1]")
            } else {
                appendUnique(trimmed)
            }
        }
        for cidr in cidrs {
            let trimmed = cidr.trimmingCharacters(in: .whitespacesAndNewlines)
            appendUnique(trimmed)
        }
        return result.joined(separator: ";")
    }

    /// Normalized domain suffixes for Mihomo `DOMAIN-SUFFIX,<domain>,DIRECT` rules (no leading `.` or `*.`).
    public func mihomoDomainSuffixes() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for domain in domains {
            var normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while normalized.hasPrefix("*.") {
                normalized = String(normalized.dropFirst(2))
            }
            while normalized.hasPrefix(".") {
                normalized = String(normalized.dropFirst(1))
            }
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }
}

public struct AuditPolicy: Codable, Sendable, Equatable, Hashable {
    public var pollIntervalSeconds: Double
    public var failClosedOnPortDown: Bool
    public var warnOnExitIPChange: Bool
    public var notifyOnLeak: Bool
    public var suspiciousDirectIPs: [String]
    public var probeTimeoutSeconds: Double

    public init(
        pollIntervalSeconds: Double = 3.0,
        failClosedOnPortDown: Bool = true,
        warnOnExitIPChange: Bool = true,
        notifyOnLeak: Bool = true,
        suspiciousDirectIPs: [String] = [],
        probeTimeoutSeconds: Double = 6.0
    ) {
        self.pollIntervalSeconds = pollIntervalSeconds
        self.failClosedOnPortDown = failClosedOnPortDown
        self.warnOnExitIPChange = warnOnExitIPChange
        self.notifyOnLeak = notifyOnLeak
        self.suspiciousDirectIPs = suspiciousDirectIPs
        self.probeTimeoutSeconds = probeTimeoutSeconds
    }
}

public struct PinGateConfig: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public static let defaultOutletPort = 17899
    public static let defaultControllerPort = 17890

    public var schemaVersion: Int
    public var outlets: [OutletConfig]
    public var targets: [ManagedTarget]
    public var bypassRules: BypassRules
    public var auditPolicy: AuditPolicy
    public var captureMode: CaptureMode
    public var autoCheckUpdates: Bool

    public init(
        schemaVersion: Int = PinGateConfig.currentSchemaVersion,
        outlets: [OutletConfig],
        targets: [ManagedTarget],
        bypassRules: BypassRules = BypassRules(),
        auditPolicy: AuditPolicy = AuditPolicy(),
        captureMode: CaptureMode = .userSpace,
        autoCheckUpdates: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.outlets = outlets
        self.targets = targets
        self.bypassRules = bypassRules
        self.auditPolicy = auditPolicy
        self.captureMode = captureMode
        self.autoCheckUpdates = autoCheckUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case outlets
        case targets
        case bypassRules
        case auditPolicy
        case captureMode
        case autoCheckUpdates
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.outlets = try container.decode([OutletConfig].self, forKey: .outlets)
        self.targets = try container.decode([ManagedTarget].self, forKey: .targets)
        self.bypassRules = try container.decodeIfPresent(BypassRules.self, forKey: .bypassRules) ?? BypassRules()
        self.auditPolicy = try container.decodeIfPresent(AuditPolicy.self, forKey: .auditPolicy) ?? AuditPolicy()
        self.captureMode = try container.decodeIfPresent(CaptureMode.self, forKey: .captureMode) ?? .userSpace
        self.autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
    }

    public var blockTelemetry: Bool {
        get { bypassRules.blockTelemetry }
        set { bypassRules.blockTelemetry = newValue }
    }

    public func outlet(id: UUID) -> OutletConfig? {
        outlets.first { $0.id == id }
    }

    public func primaryOutlet() -> OutletConfig? {
        outlets.first(where: { $0.enabled }) ?? outlets.first
    }

    public func targets(for outletID: UUID) -> [ManagedTarget] {
        targets.filter { $0.outletID == outletID }
    }

    /// Dynamically discovers Clash/FlClash YAML profiles under `~/Library/Application Support/com.follow.clash/profiles/`.
    public static func discoverFlClashProfiles(in directory: URL? = nil) -> [URL] {
        let baseDir = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.follow.clash/profiles", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: baseDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries
            .filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "yaml" || ext == "yml"
            }
            .sorted { lhs, rhs in
                let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lDate > rDate
            }
    }

    public static func defaultBootstrapConfig(
        discoveredProfilePath: String? = nil,
        primaryNodeName: String = ""
    ) -> PinGateConfig {
        let profilePath = discoveredProfilePath ?? discoverFlClashProfiles().first?.path ?? ""
        let outlet = OutletConfig(
            name: "主出口",
            listenHost: "127.0.0.1",
            listenPort: defaultOutletPort,
            controllerPort: defaultControllerPort,
            source: .localClashProfile(path: profilePath),
            primaryNodeName: primaryNodeName,
            fallbackNodeNames: [],
            expectedCountryCode: nil,
            expectedIPHint: nil,
            enabled: true
        )
        let targets = PinGateTemplates.antigravitySuite.makeTargets(outletID: outlet.id)
        return PinGateConfig(
            schemaVersion: currentSchemaVersion,
            outlets: [outlet],
            targets: targets,
            bypassRules: BypassRules(),
            auditPolicy: AuditPolicy(),
            captureMode: .userSpace
        )
    }
}
