import Foundation
import Yams

public enum MihomoConfigRendererError: Error, LocalizedError, Sendable {
    case emptyProxyList
    case serializationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyProxyList:
            return "代理节点列表为空，无法生成 mihomo 配置。"
        case .serializationFailed(let detail):
            return "序列化 mihomo YAML 配置失败：\(detail)"
        }
    }
}

public struct MihomoConfigRenderer: Sendable {
    public static let defaultDomesticNameservers: [String] = [
        "223.5.5.5",
        "119.29.29.29"
    ]

    public static let defaultRemoteDoHNameservers: [String] = [
        "https://1.1.1.1/dns-query",
        "https://dns.google/dns-query"
    ]

    public static let outletGroupName = "OUTLET"

    /// Built-in generic telemetry & auto-updater reporting domain suffixes blocked when `blockTelemetry` is enabled.
    /// Carefully excludes authentication, model API, and static asset domains (`daily-cloudcode-pa.googleapis.com`,
    /// `aicode.googleapis.com`, `www.googleapis.com`, `oauth2.googleapis.com`, `gstatic.com`, `lh3.googleusercontent.com`).
    public static let builtInTelemetryDomainSuffixes: [String] = [
        "play.googleapis.com",
        "google-analytics.com",
        "analytics.google.com",
        "ssl-google-analytics.l.google.com",
        "googletagmanager.com",
        "www-googletagmanager.l.google.com",
        "app-measurement.com",
        "firebaselogging.googleapis.com",
        "firebaseinstallations.googleapis.com",
        "crashlyticsreports-pa.googleapis.com",
        "sentry.io",
        "optimizationguide-pa.googleapis.com",
        "update.googleapis.com"
    ]

    /// Built-in wildcard patterns for telemetry / background auto-updater endpoints blocked when `blockTelemetry` is enabled.
    public static let builtInTelemetryDomainWildcards: [String] = [
        "antigravity-hub-auto-updater-*.us-central1.run.app"
    ]

    /// Full list of built-in Mihomo `REJECT` rules emitted when `bypassRules.blockTelemetry` is enabled.
    public static var builtInTelemetryRules: [String] {
        builtInTelemetryDomainSuffixes.map { "DOMAIN-SUFFIX,\($0),REJECT" }
            + builtInTelemetryDomainWildcards.map { "DOMAIN-WILDCARD,\($0),REJECT" }
    }

    public let domesticNameservers: [String]
    public let remoteDoHNameservers: [String]

    public init(
        domesticNameservers: [String] = MihomoConfigRenderer.defaultDomesticNameservers,
        remoteDoHNameservers: [String] = MihomoConfigRenderer.defaultRemoteDoHNameservers
    ) {
        self.domesticNameservers = domesticNameservers
        self.remoteDoHNameservers = remoteDoHNameservers
    }

    /// Renders a secure Mihomo Meta YAML configuration:
    /// - Domestic `default-nameserver` and `proxy-server-nameserver` for resolving upstream relay hosts
    /// - Remote DoH `nameserver` for proxied domains
    /// - Intentionally omits `dns.listen` (no unused local DNS port)
    /// - Loopback-only `external-controller` protected with `secret`
    /// - Private CIDR `DIRECT` rules and custom `DOMAIN-SUFFIX` `DIRECT` rules placed BEFORE `MATCH,OUTLET`
    public func renderYAML(
        outlet: OutletConfig,
        chain: ExtractedProxyChain,
        bypassRules: BypassRules
    ) throws -> String {
        guard !chain.proxies.isEmpty else {
            throw MihomoConfigRendererError.emptyProxyList
        }

        let proxyDicts: [[String: Any]] = chain.proxies.map { $0.toAnyDictionary() }
        let groupMembers: [String] = chain.outletGroupMembers.isEmpty
            ? [chain.primaryNodeName]
            : chain.outletGroupMembers

        var rules: [String] = []

        // 1. Private / local CIDR bypass rules BEFORE MATCH,OUTLET
        var seenCIDRs = Set<String>()
        let effectiveCIDRs = bypassRules.cidrs.isEmpty ? BypassRules.defaultPrivateCIDRs : bypassRules.cidrs
        for rawCIDR in effectiveCIDRs {
            let cidr = rawCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cidr.isEmpty, !seenCIDRs.contains(cidr) else { continue }
            seenCIDRs.insert(cidr)
            let ruleType = cidr.contains(":") ? "IP-CIDR6" : "IP-CIDR"
            rules.append("\(ruleType),\(cidr),DIRECT,no-resolve")
        }

        // 2. Configured bypass domain suffixes BEFORE telemetry REJECT and MATCH,OUTLET
        for suffix in bypassRules.mihomoDomainSuffixes() {
            rules.append("DOMAIN-SUFFIX,\(suffix),DIRECT")
        }

        // 3. Built-in telemetry & auto-updater REJECT rules (after DIRECT, before MATCH,OUTLET)
        if bypassRules.blockTelemetry {
            rules.append(contentsOf: Self.builtInTelemetryRules)
        }

        // 4. Catch-all routed through the pinned OUTLET group
        rules.append("MATCH,\(Self.outletGroupName)")

        let dnsConfig: [String: Any] = [
            "enable": true,
            "ipv6": false,
            "enhanced-mode": "normal",
            "default-nameserver": domesticNameservers,
            "proxy-server-nameserver": domesticNameservers,
            "nameserver": remoteDoHNameservers
        ]

        let root: [String: Any] = [
            "mixed-port": outlet.listenPort,
            "bind-address": outlet.listenHost,
            "allow-lan": false,
            "mode": "rule",
            "log-level": "info",
            "ipv6": false,
            "unified-delay": true,
            "tcp-concurrent": true,
            "external-controller": outlet.controllerAddress,
            "secret": outlet.controllerSecret,
            "dns": dnsConfig,
            "proxies": proxyDicts,
            "proxy-groups": [
                [
                    "name": Self.outletGroupName,
                    "type": "select",
                    "proxies": groupMembers
                ]
            ],
            "rules": rules
        ]

        do {
            let dumped = try Yams.dump(object: root, allowUnicode: true, sortKeys: true)
            return "# Generated by PinGate — do not edit manually\n" + dumped
        } catch {
            throw MihomoConfigRendererError.serializationFailed(error.localizedDescription)
        }
    }

    /// Renders and atomically writes the Mihomo configuration with `0600` permissions.
    public func writeConfig(
        outlet: OutletConfig,
        chain: ExtractedProxyChain,
        bypassRules: BypassRules,
        to destinationURL: URL
    ) throws {
        let yaml = try renderYAML(outlet: outlet, chain: chain, bypassRules: bypassRules)
        guard let data = yaml.data(using: .utf8) else {
            throw MihomoConfigRendererError.serializationFailed("无法将 YAML 编码为 UTF-8 文本。")
        }
        try ConfigStore.atomicWrite(data: data, to: destinationURL, posixPermissions: 0o600)
    }
}
