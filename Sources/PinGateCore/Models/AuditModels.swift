import Foundation

public enum HealthState: String, Codable, Sendable, Equatable, Hashable {
    case protected
    case warning
    case leaking
    case stopped

    public var displayName: String {
        switch self {
        case .protected:
            return "保护中"
        case .warning:
            return "需注意"
        case .leaking:
            return "发现漏网"
        case .stopped:
            return "已关闭"
        }
    }
}

public enum SocketClassification: String, Codable, Sendable, Equatable, Hashable {
    case proxied
    case loopback
    case bypass
    case leak

    public var displayName: String {
        switch self {
        case .proxied:
            return "已代理"
        case .loopback:
            return "本机连接"
        case .bypass:
            return "直连"
        case .leak:
            return "未走代理"
        }
    }
}

public struct SocketRecord: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var pid: Int32
    public var processName: String
    public var localAddress: String
    public var localPort: UInt16
    public var remoteAddress: String
    public var remotePort: UInt16
    public var tcpState: String
    public var ipVersion: Int
    public var classification: SocketClassification
    public var reason: String?

    public init(
        id: String? = nil,
        pid: Int32,
        processName: String,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        tcpState: String,
        ipVersion: Int = 4,
        classification: SocketClassification = .loopback,
        reason: String? = nil
    ) {
        self.id = id ?? "\(pid)-\(localAddress):\(localPort)->\(remoteAddress):\(remotePort)-\(tcpState)"
        self.pid = pid
        self.processName = processName
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
        self.tcpState = tcpState
        self.ipVersion = ipVersion
        self.classification = classification
        self.reason = reason
    }

    public var remoteEndpoint: String {
        ipVersion == 6 ? "[\(remoteAddress)]:\(remotePort)" : "\(remoteAddress):\(remotePort)"
    }
}

public enum ProxyEnvStatus: String, Codable, Sendable, Equatable, Hashable {
    case valid
    case missing
    case wrongPort
    case unreadable

    public var displayName: String {
        switch self {
        case .valid:
            return "代理环境正常"
        case .missing:
            return "缺少代理配置"
        case .wrongPort:
            return "代理端口不匹配"
        case .unreadable:
            return "无法读取进程环境"
        }
    }
}

public struct ProcessAudit: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var targetID: UUID?
    public var targetName: String
    public var processName: String
    public var executablePath: String
    public var proxyEnvStatus: ProxyEnvStatus
    public var observedHTTPSProxy: String?
    public var observedAllProxy: String?
    public var observedNoProxy: String?
    public var expectedOutletPort: Int
    public var sockets: [SocketRecord]

    public init(
        pid: Int32,
        targetID: UUID?,
        targetName: String,
        processName: String,
        executablePath: String,
        proxyEnvStatus: ProxyEnvStatus,
        observedHTTPSProxy: String? = nil,
        observedAllProxy: String? = nil,
        observedNoProxy: String? = nil,
        expectedOutletPort: Int,
        sockets: [SocketRecord] = []
    ) {
        self.pid = pid
        self.targetID = targetID
        self.targetName = targetName
        self.processName = processName
        self.executablePath = executablePath
        self.proxyEnvStatus = proxyEnvStatus
        self.observedHTTPSProxy = observedHTTPSProxy
        self.observedAllProxy = observedAllProxy
        self.observedNoProxy = observedNoProxy
        self.expectedOutletPort = expectedOutletPort
        self.sockets = sockets
    }

    public var proxiedSocketCount: Int {
        sockets.filter { $0.classification == .proxied }.count
    }

    public var bypassSocketCount: Int {
        sockets.filter { $0.classification == .bypass }.count
    }

    public var leakSockets: [SocketRecord] {
        sockets.filter { $0.classification == .leak }
    }

    public var isLeaking: Bool {
        !leakSockets.isEmpty || proxyEnvStatus == .missing || proxyEnvStatus == .wrongPort
    }
}

public struct AuditSnapshot: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var overallState: HealthState
    public var outletRunning: Bool
    public var processes: [ProcessAudit]
    public var totalProxiedSockets: Int
    public var totalBypassSockets: Int
    public var totalLeakSockets: Int
    public var summary: String

    public init(
        timestamp: Date = Date(),
        overallState: HealthState,
        outletRunning: Bool,
        processes: [ProcessAudit],
        totalProxiedSockets: Int? = nil,
        totalBypassSockets: Int? = nil,
        totalLeakSockets: Int? = nil,
        summary: String
    ) {
        self.timestamp = timestamp
        self.overallState = overallState
        self.outletRunning = outletRunning
        self.processes = processes
        self.totalProxiedSockets = totalProxiedSockets ?? processes.reduce(0) { $0 + $1.proxiedSocketCount }
        self.totalBypassSockets = totalBypassSockets ?? processes.reduce(0) { $0 + $1.bypassSocketCount }
        self.totalLeakSockets = totalLeakSockets ?? processes.reduce(0) { $0 + $1.leakSockets.count }
        self.summary = summary
    }
}

public struct ExitProbeResult: Codable, Sendable, Equatable {
    public var ip: String
    public var country: String?
    public var region: String?
    public var city: String?
    public var org: String?
    public var provider: String
    public var latencyMs: Int
    public var probedAt: Date

    public init(
        ip: String,
        country: String? = nil,
        region: String? = nil,
        city: String? = nil,
        org: String? = nil,
        provider: String,
        latencyMs: Int,
        probedAt: Date = Date()
    ) {
        self.ip = ip
        self.country = country
        self.region = region
        self.city = city
        self.org = org
        self.provider = provider
        self.latencyMs = latencyMs
        self.probedAt = probedAt
    }
}

public struct NodeSyncResult: Codable, Sendable, Equatable {
    public var outletID: UUID
    public var outletName: String
    public var syncedAt: Date
    public var primaryNode: String
    public var extractedProxyNames: [String]
    public var missingFallbackNodes: [String]
    public var renderedConfigPath: String
    public var reloadedLive: Bool

    public init(
        outletID: UUID,
        outletName: String,
        syncedAt: Date = Date(),
        primaryNode: String,
        extractedProxyNames: [String],
        missingFallbackNodes: [String] = [],
        renderedConfigPath: String,
        reloadedLive: Bool = false
    ) {
        self.outletID = outletID
        self.outletName = outletName
        self.syncedAt = syncedAt
        self.primaryNode = primaryNode
        self.extractedProxyNames = extractedProxyNames
        self.missingFallbackNodes = missingFallbackNodes
        self.renderedConfigPath = renderedConfigPath
        self.reloadedLive = reloadedLive
    }
}

public struct MihomoVersionInfo: Codable, Sendable, Equatable {
    public var version: String
    public var meta: Bool?

    public init(version: String, meta: Bool? = nil) {
        self.version = version
        self.meta = meta
    }
}

public struct MihomoProxyNode: Identifiable, Codable, Sendable, Equatable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var now: String?
    public var all: [String]?
    public var alive: Bool?
    public var delayMs: Int?

    public init(
        name: String,
        type: String,
        now: String? = nil,
        all: [String]? = nil,
        alive: Bool? = nil,
        delayMs: Int? = nil
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.alive = alive
        self.delayMs = delayMs
    }
}

public struct MihomoActiveConnection: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var host: String
    public var destinationIP: String
    public var destinationPort: String
    public var sourceIP: String
    public var sourcePort: String
    public var network: String
    public var chains: [String]
    public var rule: String
    public var rulePayload: String
    public var upload: Int64
    public var download: Int64
    public var start: String

    public init(
        id: String,
        host: String,
        destinationIP: String,
        destinationPort: String,
        sourceIP: String,
        sourcePort: String,
        network: String,
        chains: [String],
        rule: String,
        rulePayload: String,
        upload: Int64,
        download: Int64,
        start: String
    ) {
        self.id = id
        self.host = host
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.sourceIP = sourceIP
        self.sourcePort = sourcePort
        self.network = network
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
        self.upload = upload
        self.download = download
        self.start = start
    }

    public var displayDestination: String {
        let target = host.isEmpty ? destinationIP : host
        return destinationPort.isEmpty ? target : "\(target):\(destinationPort)"
    }
}
