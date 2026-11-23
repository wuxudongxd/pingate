import Darwin
import Foundation

/// IPv4 / IPv6 CIDR prefix matcher with support for IPv4-mapped IPv6 addresses (`::ffff:a.b.c.d`).
public struct CIDRNetwork: Sendable, Equatable, Hashable {
    public enum Family: Sendable, Equatable, Hashable {
        case ipv4(network: UInt32, prefixLength: Int)
        case ipv6(high: UInt64, low: UInt64, prefixLength: Int)
    }

    public let rawValue: String
    public let family: Family

    public init?(_ notation: String) {
        let trimmed = notation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let addressPart = Self.normalizeIPString(String(parts[0]))

        if let ipv4 = Self.parseIPv4(addressPart) {
            let prefix: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), parsed >= 0, parsed <= 32 else { return nil }
                prefix = parsed
            } else {
                prefix = 32
            }
            let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
            self.rawValue = trimmed
            self.family = .ipv4(network: ipv4 & mask, prefixLength: prefix)
            return
        }

        if let (high, low) = Self.parseIPv6(addressPart) {
            let prefix: Int
            if parts.count == 2 {
                guard let parsed = Int(parts[1]), parsed >= 0, parsed <= 128 else { return nil }
                prefix = parsed
            } else {
                prefix = 128
            }
            let (maskedHigh, maskedLow) = Self.maskIPv6(high: high, low: low, prefixLength: prefix)
            self.rawValue = trimmed
            self.family = .ipv6(high: maskedHigh, low: maskedLow, prefixLength: prefix)
            return
        }

        return nil
    }

    /// Returns `true` if `ipAddress` falls within this CIDR range.
    public func contains(ipAddress: String) -> Bool {
        let normalized = Self.normalizeIPString(ipAddress)
        switch family {
        case .ipv4(let network, let prefix):
            guard let ipv4 = Self.parseIPv4(normalized) else { return false }
            let mask: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
            return (ipv4 & mask) == network

        case .ipv6(let netHigh, let netLow, let prefix):
            guard let (high, low) = Self.parseIPv6(normalized) else { return false }
            let (maskedHigh, maskedLow) = Self.maskIPv6(high: high, low: low, prefixLength: prefix)
            return maskedHigh == netHigh && maskedLow == netLow
        }
    }

    /// Normalizes an IP string by trimming whitespace/brackets, stripping IPv6 zone IDs (`%en0`),
    /// and unwrapping IPv4-mapped IPv6 addresses (`::ffff:127.0.0.1` -> `127.0.0.1`).
    public static func normalizeIPString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        if let zoneIndex = value.firstIndex(of: "%") {
            value = String(value[..<zoneIndex])
        }
        let lower = value.lowercased()
        if lower.hasPrefix("::ffff:") {
            let candidate = String(value.dropFirst("::ffff:".count))
            if parseIPv4(candidate) != nil {
                return candidate
            }
        }
        return value
    }

    public static func isLoopback(_ ipAddress: String) -> Bool {
        let normalized = normalizeIPString(ipAddress)
        if normalized == "::1" || normalized.lowercased() == "localhost" {
            return true
        }
        if let ipv4 = parseIPv4(normalized) {
            // 127.0.0.0/8
            return (ipv4 & 0xFF00_0000) == 0x7F00_0000
        }
        return false
    }

    public static func isUnspecified(_ ipAddress: String) -> Bool {
        let normalized = normalizeIPString(ipAddress)
        return normalized.isEmpty || normalized == "0.0.0.0" || normalized == "::"
    }

    private static func parseIPv4(_ address: String) -> UInt32? {
        var addr = in_addr()
        guard inet_pton(AF_INET, address, &addr) == 1 else { return nil }
        return UInt32(bigEndian: addr.s_addr)
    }

    private static func parseIPv6(_ address: String) -> (UInt64, UInt64)? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, address, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr) { raw in
            var high: UInt64 = 0
            var low: UInt64 = 0
            for i in 0..<8 {
                high = (high << 8) | UInt64(raw[i])
            }
            for i in 8..<16 {
                low = (low << 8) | UInt64(raw[i])
            }
            return (high, low)
        }
    }

    private static func maskIPv6(high: UInt64, low: UInt64, prefixLength: Int) -> (UInt64, UInt64) {
        if prefixLength <= 0 {
            return (0, 0)
        }
        if prefixLength <= 64 {
            let mask = ~UInt64(0) << (64 - prefixLength)
            return (high & mask, 0)
        }
        let lowBits = prefixLength - 64
        let lowMask = ~UInt64(0) << (64 - lowBits)
        return (high, low & lowMask)
    }
}

/// Real-time leak auditor inspecting managed target processes for proxy env integrity and non-proxied TCP connections.
public struct LeakAuditor: Sendable {
    private static let activeAuditStates: Set<String> = ["ESTABLISHED", "SYN_SENT"]
    private static let ignoredSelfProcessNames: Set<String> = [
        "pingate",
        "pingateapp",
        "pingate-cli",
        "mihomo"
    ]

    public let inspector: any ProcessInspecting

    public init(inspector: any ProcessInspecting = DarwinProcessInspector()) {
        self.inspector = inspector
    }

    /// Performs a live audit against running processes matching targets in `config`.
    public func audit(
        config: PinGateConfig,
        outletRunningOverride: Bool? = nil
    ) -> AuditSnapshot {
        let auditableTargets = config.targets.filter { $0.enabled && $0.kind != .t3Integration }
        let matchedProcesses = inspector.inspectAllProcesses(
            matching: { name, path in
                Self.matchTarget(name: name, executablePath: path, in: auditableTargets) != nil
            },
            includeSockets: true,
            includeEnvironment: true
        )

        let outletRunning: Bool
        if let override = outletRunningOverride {
            outletRunning = override
        } else if let primary = config.primaryOutlet() {
            outletRunning = inspector.isLocalPortListening(
                host: primary.listenHost,
                port: primary.listenPort,
                timeout: 0.4
            )
        } else {
            outletRunning = false
        }

        return audit(config: config, processes: matchedProcesses, outletRunning: outletRunning)
    }

    /// Pure deterministic audit against a supplied process snapshot (ideal for unit testing and replay).
    public func audit(
        config: PinGateConfig,
        processes: [InspectedProcess],
        outletRunning: Bool
    ) -> AuditSnapshot {
        let auditableTargets = config.targets.filter { $0.enabled && $0.kind != .t3Integration }
        let bypassCIDRs = config.bypassRules.cidrs.compactMap(CIDRNetwork.init)
        let suspiciousIPs = Set(
            config.auditPolicy.suspiciousDirectIPs.map { CIDRNetwork.normalizeIPString($0) }
        )

        var seenPIDs = Set<Int32>()
        var audits: [ProcessAudit] = []

        for process in processes {
            guard !seenPIDs.contains(process.pid) else { continue }
            guard let target = Self.matchTarget(
                name: process.name,
                executablePath: process.executablePath,
                in: auditableTargets
            ) else {
                continue
            }
            seenPIDs.insert(process.pid)

            let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet()
            let expectedHost = outlet?.listenHost ?? "127.0.0.1"
            let expectedPort = outlet?.listenPort ?? PinGateConfig.defaultOutletPort

            let envEval = Self.evaluateProxyEnvironment(
                process.environment,
                expectedPort: expectedPort,
                expectedHost: expectedHost,
                arguments: process.arguments
            )

            var records: [SocketRecord] = []
            for rawSocket in process.sockets {
                guard Self.activeAuditStates.contains(rawSocket.tcpState) else { continue }
                guard !CIDRNetwork.isUnspecified(rawSocket.remoteAddress), rawSocket.remotePort > 0 else { continue }

                let (classification, reason) = Self.classifySocket(
                    rawSocket,
                    outletHost: expectedHost,
                    outletPort: expectedPort,
                    bypassCIDRs: bypassCIDRs,
                    suspiciousDirectIPs: suspiciousIPs
                )
                records.append(
                    SocketRecord(
                        pid: process.pid,
                        processName: process.name,
                        localAddress: rawSocket.localAddress,
                        localPort: rawSocket.localPort,
                        remoteAddress: rawSocket.remoteAddress,
                        remotePort: rawSocket.remotePort,
                        tcpState: rawSocket.tcpState,
                        ipVersion: rawSocket.ipVersion,
                        classification: classification,
                        reason: reason
                    )
                )
            }

            audits.append(
                ProcessAudit(
                    pid: process.pid,
                    targetID: target.id,
                    targetName: target.name,
                    processName: process.name,
                    executablePath: process.executablePath,
                    proxyEnvStatus: envEval.status,
                    observedHTTPSProxy: envEval.httpsProxy,
                    observedAllProxy: envEval.allProxy,
                    observedNoProxy: envEval.noProxy,
                    expectedOutletPort: expectedPort,
                    sockets: records
                )
            )
        }

        audits.sort { lhs, rhs in
            if lhs.isLeaking != rhs.isLeaking {
                return lhs.isLeaking && !rhs.isLeaking
            }
            return lhs.pid < rhs.pid
        }

        let totalProxied = audits.reduce(0) { $0 + $1.proxiedSocketCount }
        let totalBypass = audits.reduce(0) { $0 + $1.bypassSocketCount }
        let totalLeaks = audits.reduce(0) { $0 + $1.leakSockets.count }
        let missingOrWrongEnvCount = audits.filter {
            $0.proxyEnvStatus == .missing || $0.proxyEnvStatus == .wrongPort
        }.count
        let unreadableCount = audits.filter { $0.proxyEnvStatus == .unreadable }.count

        let overallState: HealthState
        let summary: String

        if totalLeaks > 0 || missingOrWrongEnvCount > 0 {
            overallState = .leaking
            var parts: [String] = []
            if totalLeaks > 0 {
                parts.append("\(totalLeaks) 条直连漏网连接")
            }
            if missingOrWrongEnvCount > 0 {
                parts.append("\(missingOrWrongEnvCount) 个进程缺失代理环境变量或端口不匹配")
            }
            if !outletRunning {
                parts.append("出口代理已停止")
            }
            summary = "检测到漏网风险：" + parts.joined(separator: "，")
        } else if !outletRunning {
            overallState = .stopped
            summary = "出口代理未监听（已扫描 \(audits.count) 个目标进程）"
        } else if unreadableCount > 0 {
            overallState = .warning
            summary = "\(unreadableCount) 个进程环境变量不可读；\(totalProxied) 条代理连接，0 漏网"
        } else if audits.isEmpty {
            overallState = .protected
            summary = "出口运行中；当前无活跃受保护目标进程"
        } else {
            overallState = .protected
            summary = "\(audits.count) 个进程受保护（\(totalProxied) 条代理连接，\(totalBypass) 条内网直连，0 漏网）"
        }

        return AuditSnapshot(
            overallState: overallState,
            outletRunning: outletRunning,
            processes: audits,
            totalProxiedSockets: totalProxied,
            totalBypassSockets: totalBypass,
            totalLeakSockets: totalLeaks,
            summary: summary
        )
    }

    /// Classifies a single active TCP socket against the outlet proxy endpoint, loopback, suspicious IPs, and bypass CIDRs.
    public static func classifySocket(
        _ socket: RawSocketInfo,
        outletHost: String,
        outletPort: Int,
        bypassCIDRs: [CIDRNetwork],
        suspiciousDirectIPs: Set<String> = []
    ) -> (SocketClassification, String?) {
        let normalizedRemote = CIDRNetwork.normalizeIPString(socket.remoteAddress)
        let normalizedOutletHost = CIDRNetwork.normalizeIPString(outletHost)

        let isOutletHost = normalizedRemote == normalizedOutletHost ||
            (CIDRNetwork.isLoopback(normalizedOutletHost) && CIDRNetwork.isLoopback(normalizedRemote))

        if isOutletHost && Int(socket.remotePort) == outletPort {
            return (.proxied, "已通过 PinGate 出口代理 \(normalizedRemote):\(outletPort)")
        }

        if CIDRNetwork.isLoopback(normalizedRemote) {
            return (.loopback, "本地回环通信（\(normalizedRemote):\(socket.remotePort)）")
        }

        // Check explicitly flagged suspicious IPs BEFORE bypass CIDRs so hijacked private-range IPs are caught.
        if suspiciousDirectIPs.contains(normalizedRemote) {
            return (.leak, "直连至可疑/黑洞 IP \(normalizedRemote):\(socket.remotePort)")
        }

        for cidr in bypassCIDRs where cidr.contains(ipAddress: normalizedRemote) {
            return (.bypass, "命中内网直连白名单 \(cidr.rawValue)")
        }

        return (.leak, "未走代理的直连流量 \(normalizedRemote):\(socket.remotePort)")
    }

    /// Evaluates whether a process has valid proxy environment variables (or Chromium `--proxy-server` flag) targeting `expectedPort`.
    public static func evaluateProxyEnvironment(
        _ env: [String: String]?,
        expectedPort: Int,
        expectedHost: String = "127.0.0.1",
        arguments: [String] = []
    ) -> (status: ProxyEnvStatus, httpsProxy: String?, allProxy: String?, noProxy: String?) {
        let cliProxyArg = extractChromiumProxyFlag(from: arguments)

        guard let env else {
            if let cliProxyArg {
                let status = classifyProxyURL(cliProxyArg, expectedPort: expectedPort, expectedHost: expectedHost)
                return (status, cliProxyArg, nil, nil)
            }
            return (.unreadable, nil, nil, nil)
        }

        let httpsProxy = firstNonEmpty(env["HTTPS_PROXY"], env["https_proxy"])
        let httpProxy = firstNonEmpty(env["HTTP_PROXY"], env["http_proxy"])
        let allProxy = firstNonEmpty(env["ALL_PROXY"], env["all_proxy"])
        let noProxy = firstNonEmpty(env["NO_PROXY"], env["no_proxy"])

        let primaryObserved = httpsProxy ?? httpProxy ?? allProxy ?? cliProxyArg
        guard let observed = primaryObserved else {
            return (.missing, httpsProxy, allProxy, noProxy)
        }

        // Verify primary proxy value matches the expected local outlet port.
        let primaryStatus = classifyProxyURL(observed, expectedPort: expectedPort, expectedHost: expectedHost)
        if primaryStatus != .valid {
            return (primaryStatus, httpsProxy ?? httpProxy, allProxy, noProxy)
        }

        // If ALL_PROXY is also set, make sure it does not conflict by pointing to a different port.
        if let allProxy {
            let allStatus = classifyProxyURL(allProxy, expectedPort: expectedPort, expectedHost: expectedHost)
            if allStatus == .wrongPort {
                return (.wrongPort, httpsProxy ?? httpProxy, allProxy, noProxy)
            }
        }

        return (.valid, httpsProxy ?? httpProxy ?? cliProxyArg, allProxy, noProxy)
    }

    /// Matches a running process (name + executable path) to the most specific enabled target.
    public static func matchTarget(
        name: String,
        executablePath: String,
        in targets: [ManagedTarget]
    ) -> ManagedTarget? {
        let lowerName = name.lowercased()
        if ignoredSelfProcessNames.contains(lowerName) {
            return nil
        }

        // Pass 1: Prefer exact app bundle path prefix matches (most specific).
        for target in targets where target.enabled {
            if let rawAppPath = target.appPath?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawAppPath.isEmpty,
               rawAppPath != "/Applications/" {
                let expanded = NSString(string: rawAppPath).expandingTildeInPath
                let normalizedPrefix = expanded.hasSuffix("/") ? expanded : expanded + "/"
                if executablePath == expanded || executablePath.hasPrefix(normalizedPrefix) {
                    return target
                }
            }
        }

        // Pass 2: Match against processMatchNames on process basename only (not full path).
        let basename = executablePath.isEmpty
            ? lowerName
            : URL(fileURLWithPath: executablePath).lastPathComponent.lowercased()

        for target in targets where target.enabled {
            for pattern in target.processMatchNames {
                let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !trimmed.isEmpty else { continue }
                if basename == trimmed || lowerName == trimmed || basename.contains(trimmed) {
                    return target
                }
            }
        }

        return nil
    }

    private static func classifyProxyURL(
        _ rawValue: String,
        expectedPort: Int,
        expectedHost: String
    ) -> ProxyEnvStatus {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .missing }

        // Chromium `--proxy-server` may contain multiple scheme mappings separated by `;`
        // e.g. `http=127.0.0.1:17899;https=127.0.0.1:17899` or `http://127.0.0.1:17899`.
        let entries = trimmed.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        var foundPort = false

        for entry in entries where !entry.isEmpty {
            let candidate: String
            if let eq = entry.firstIndex(of: "="), !entry.contains("://") {
                candidate = "http://" + String(entry[entry.index(after: eq)...])
            } else if entry.contains("://") {
                candidate = entry
            } else {
                candidate = "http://" + entry
            }

            guard let components = URLComponents(string: candidate),
                  let port = components.port,
                  let host = components.host
            else {
                continue
            }

            foundPort = true
            let normalizedHost = CIDRNetwork.normalizeIPString(host)
            let normalizedExpected = CIDRNetwork.normalizeIPString(expectedHost)
            let hostMatches = normalizedHost.lowercased() == normalizedExpected.lowercased() ||
                (CIDRNetwork.isLoopback(normalizedExpected) && CIDRNetwork.isLoopback(normalizedHost))

            if hostMatches && port == expectedPort {
                return .valid
            }
        }

        return foundPort ? .wrongPort : .wrongPort
    }

    private static func extractChromiumProxyFlag(from arguments: [String]) -> String? {
        for (index, arg) in arguments.enumerated() {
            if arg.hasPrefix("--proxy-server=") {
                return String(arg.dropFirst("--proxy-server=".count))
            }
            if arg == "--proxy-server", index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}
