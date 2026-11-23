import Foundation

public enum ExitProbeError: Error, LocalizedError, Sendable {
    case allProbesFailed([String])
    case invalidProxyConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .allProbesFailed(let errors):
            return "出口 IP 检测失败：\(errors.joined(separator: "；"))"
        case .invalidProxyConfiguration(let detail):
            return "代理配置无效：\(detail)"
        }
    }
}

/// Multi-provider exit IP prober routed strictly through an outlet's local HTTP proxy.
/// Avoids single-point-of-failure by cascading through independent HTTPS endpoints.
public struct ExitIPProber: Sendable {
    public enum ProbeProvider: String, CaseIterable, Sendable {
        case ipinfo = "ipinfo.io"
        case cloudflare = "cloudflare"
        case ipify = "api.ipify.org"
        case ifconfigCo = "ifconfig.co"

        public var endpointURL: URL {
            switch self {
            case .ipinfo:
                return URL(string: "https://ipinfo.io/json")!
            case .cloudflare:
                return URL(string: "https://cloudflare.com/cdn-cgi/trace")!
            case .ipify:
                return URL(string: "https://api.ipify.org?format=json")!
            case .ifconfigCo:
                return URL(string: "https://ifconfig.co/json")!
            }
        }
    }

    public let providers: [ProbeProvider]
    public let timeoutSeconds: TimeInterval

    public init(
        providers: [ProbeProvider] = ProbeProvider.allCases,
        timeoutSeconds: TimeInterval = 6.0
    ) {
        self.providers = providers
        self.timeoutSeconds = timeoutSeconds
    }

    /// Probes the egress IP through the given outlet's local HTTP proxy.
    /// Returns the first successful probe result, automatically falling back across providers.
    public func probe(outlet: OutletConfig) async throws -> ExitProbeResult {
        try await probe(proxyHost: outlet.listenHost, proxyPort: outlet.listenPort)
    }

    /// Probes the egress IP through an explicit local HTTP proxy host & port.
    public func probe(proxyHost: String, proxyPort: Int) async throws -> ExitProbeResult {
        guard !proxyHost.isEmpty, proxyPort > 0, proxyPort <= Int(UInt16.max) else {
            throw ExitProbeError.invalidProxyConfiguration("\(proxyHost):\(proxyPort)")
        }

        let session = makeProxiedSession(host: proxyHost, port: proxyPort)
        defer { session.invalidateAndCancel() }

        var failureReasons: [String] = []

        for provider in providers {
            do {
                let result = try await query(provider: provider, session: session)
                return result
            } catch {
                failureReasons.append("\(provider.rawValue): \(error.localizedDescription)")
            }
        }

        throw ExitProbeError.allProbesFailed(failureReasons)
    }

    /// Queries all configured providers and returns every successful result (for diagnostics).
    public func probeAll(proxyHost: String, proxyPort: Int) async -> [ExitProbeResult] {
        guard !proxyHost.isEmpty, proxyPort > 0, proxyPort <= Int(UInt16.max) else {
            return []
        }

        let session = makeProxiedSession(host: proxyHost, port: proxyPort)
        defer { session.invalidateAndCancel() }

        var results: [ExitProbeResult] = []
        for provider in providers {
            if let result = try? await query(provider: provider, session: session) {
                results.append(result)
            }
        }
        return results
    }

    /// Pure parser for each provider's response payload so parsing logic can be verified offline.
    public static func parseResponse(
        provider: ProbeProvider,
        data: Data,
        latencyMs: Int,
        probedAt: Date = Date()
    ) -> ExitProbeResult? {
        switch provider {
        case .ipinfo:
            return parseIPInfo(data: data, latencyMs: latencyMs, probedAt: probedAt)
        case .cloudflare:
            return parseCloudflareTrace(data: data, latencyMs: latencyMs, probedAt: probedAt)
        case .ipify:
            return parseIPify(data: data, latencyMs: latencyMs, probedAt: probedAt)
        case .ifconfigCo:
            return parseIfconfigCo(data: data, latencyMs: latencyMs, probedAt: probedAt)
        }
    }

    private func query(provider: ProbeProvider, session: URLSession) async throws -> ExitProbeResult {
        var request = URLRequest(url: provider.endpointURL)
        request.timeoutInterval = timeoutSeconds
        request.setValue("PinGate/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let latencyMs = max(1, Int(Date().timeIntervalSince(start) * 1000))

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "PinGate.ExitIPProber",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP 状态码 \(statusCode)"]
            )
        }

        guard let parsed = Self.parseResponse(provider: provider, data: data, latencyMs: latencyMs) else {
            throw NSError(
                domain: "PinGate.ExitIPProber",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "无法解析检测结果"]
            )
        }
        return parsed
    }

    private func makeProxiedSession(host: String, port: Int) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        config.timeoutIntervalForResource = timeoutSeconds * 1.5
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.connectionProxyDictionary = [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
            "ExcludeSimpleHostnames": 0
        ]
        return URLSession(configuration: config)
    }

    // MARK: - Provider Parsers

    private struct IPInfoPayload: Decodable {
        let ip: String?
        let country: String?
        let region: String?
        let city: String?
        let org: String?
    }

    private static func parseIPInfo(data: Data, latencyMs: Int, probedAt: Date) -> ExitProbeResult? {
        guard let decoded = try? JSONDecoder().decode(IPInfoPayload.self, from: data),
              let ip = decoded.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty
        else {
            return nil
        }
        return ExitProbeResult(
            ip: ip,
            country: decoded.country,
            region: decoded.region,
            city: decoded.city,
            org: decoded.org,
            provider: ProbeProvider.ipinfo.rawValue,
            latencyMs: latencyMs,
            probedAt: probedAt
        )
    }

    private static func parseCloudflareTrace(data: Data, latencyMs: Int, probedAt: Date) -> ExitProbeResult? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        guard let ip = fields["ip"], !ip.isEmpty else { return nil }
        return ExitProbeResult(
            ip: ip,
            country: fields["loc"],
            region: nil,
            city: nil,
            org: fields["colo"].map { "Cloudflare 节点 \($0)" },
            provider: ProbeProvider.cloudflare.rawValue,
            latencyMs: latencyMs,
            probedAt: probedAt
        )
    }

    private struct IPifyPayload: Decodable {
        let ip: String?
    }

    private static func parseIPify(data: Data, latencyMs: Int, probedAt: Date) -> ExitProbeResult? {
        if let decoded = try? JSONDecoder().decode(IPifyPayload.self, from: data),
           let ip = decoded.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ip.isEmpty {
            return ExitProbeResult(
                ip: ip,
                provider: ProbeProvider.ipify.rawValue,
                latencyMs: latencyMs,
                probedAt: probedAt
            )
        }
        // Fallback if plain text IP was returned
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           !text.contains(" "),
           !text.contains("<") {
            return ExitProbeResult(
                ip: text,
                provider: ProbeProvider.ipify.rawValue,
                latencyMs: latencyMs,
                probedAt: probedAt
            )
        }
        return nil
    }

    private struct IfconfigCoPayload: Decodable {
        let ip: String?
        let country_iso: String?
        let region_name: String?
        let city: String?
        let asn_org: String?
    }

    private static func parseIfconfigCo(data: Data, latencyMs: Int, probedAt: Date) -> ExitProbeResult? {
        guard let decoded = try? JSONDecoder().decode(IfconfigCoPayload.self, from: data),
              let ip = decoded.ip?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty
        else {
            return nil
        }
        return ExitProbeResult(
            ip: ip,
            country: decoded.country_iso,
            region: decoded.region_name,
            city: decoded.city,
            org: decoded.asn_org,
            provider: ProbeProvider.ifconfigCo.rawValue,
            latencyMs: latencyMs,
            probedAt: probedAt
        )
    }
}
