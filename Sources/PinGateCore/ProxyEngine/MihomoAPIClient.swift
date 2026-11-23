import Foundation

public enum MihomoAPIError: Error, LocalizedError, Sendable {
    case invalidURL(String)
    case transportError(String)
    case httpError(statusCode: Int, body: String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let path):
            return "Invalid Mihomo Controller URL path: \(path)"
        case .transportError(let detail):
            return "Mihomo Controller connection error: \(detail)"
        case .httpError(let statusCode, let body):
            return "Mihomo Controller returned HTTP \(statusCode): \(body)"
        case .decodingError(let detail):
            return "Failed to decode Mihomo Controller response: \(detail)"
        }
    }
}

public struct MihomoAPIClient: Sendable {
    public let baseURL: URL
    public let secret: String
    private let session: URLSession

    public init(baseURL: URL, secret: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.secret = secret
        self.session = session
    }

    public init(outlet: OutletConfig, session: URLSession = .shared) {
        self.baseURL = outlet.controllerBaseURL
        self.secret = outlet.controllerSecret
        self.session = session
    }

    public func isReachable(timeout: TimeInterval = 1.5) async -> Bool {
        do {
            _ = try await version(timeout: timeout)
            return true
        } catch {
            return false
        }
    }

    public func version(timeout: TimeInterval = 5.0) async throws -> MihomoVersionInfo {
        let data = try await performRequest(method: "GET", path: "/version", timeout: timeout)
        do {
            return try JSONDecoder().decode(MihomoVersionInfo.self, from: data)
        } catch {
            throw MihomoAPIError.decodingError(error.localizedDescription)
        }
    }

    public func proxies(timeout: TimeInterval = 5.0) async throws -> [String: MihomoProxyNode] {
        let data = try await performRequest(method: "GET", path: "/proxies", timeout: timeout)
        do {
            let envelope = try JSONDecoder().decode(ProxiesEnvelope.self, from: data)
            var result: [String: MihomoProxyNode] = [:]
            result.reserveCapacity(envelope.proxies.count)
            for (name, raw) in envelope.proxies {
                let latestDelay = raw.history?.last?.delay
                result[name] = MihomoProxyNode(
                    name: raw.name ?? name,
                    type: raw.type ?? "Unknown",
                    now: raw.now,
                    all: raw.all,
                    alive: raw.alive,
                    delayMs: (latestDelay ?? 0) > 0 ? latestDelay : nil
                )
            }
            return result
        } catch {
            throw MihomoAPIError.decodingError(error.localizedDescription)
        }
    }

    public func proxyDelay(
        name: String,
        testURL: String = "https://www.gstatic.com/generate_204",
        timeoutMs: Int = 5000
    ) async throws -> Int {
        let encodedName = Self.encodePathSegment(name)
        let queryItems = [
            URLQueryItem(name: "timeout", value: String(timeoutMs)),
            URLQueryItem(name: "url", value: testURL)
        ]
        let reqTimeout = TimeInterval(max(timeoutMs, 1000)) / 1000.0 + 3.0
        let data = try await performRequest(
            method: "GET",
            path: "/proxies/\(encodedName)/delay",
            queryItems: queryItems,
            timeout: reqTimeout
        )
        do {
            let decoded = try JSONDecoder().decode(DelayResponse.self, from: data)
            return decoded.delay
        } catch {
            throw MihomoAPIError.decodingError(error.localizedDescription)
        }
    }

    public func activeConnections(timeout: TimeInterval = 5.0) async throws -> [MihomoActiveConnection] {
        let data = try await performRequest(method: "GET", path: "/connections", timeout: timeout)
        do {
            let envelope = try JSONDecoder().decode(ConnectionsEnvelope.self, from: data)
            return (envelope.connections ?? []).map { item in
                MihomoActiveConnection(
                    id: item.id,
                    host: item.metadata?.host ?? "",
                    destinationIP: item.metadata?.destinationIP ?? "",
                    destinationPort: item.metadata?.destinationPort ?? "",
                    sourceIP: item.metadata?.sourceIP ?? "",
                    sourcePort: item.metadata?.sourcePort ?? "",
                    network: item.metadata?.network ?? "tcp",
                    chains: item.chains ?? [],
                    rule: item.rule ?? "",
                    rulePayload: item.rulePayload ?? "",
                    upload: item.upload ?? 0,
                    download: item.download ?? 0,
                    start: item.start ?? ""
                )
            }
        } catch {
            throw MihomoAPIError.decodingError(error.localizedDescription)
        }
    }

    public func selectProxy(
        group: String = MihomoConfigRenderer.outletGroupName,
        nodeName: String,
        timeout: TimeInterval = 5.0
    ) async throws {
        let encodedGroup = Self.encodePathSegment(group)
        let payload = try JSONEncoder().encode(["name": nodeName])
        _ = try await performRequest(
            method: "PUT",
            path: "/proxies/\(encodedGroup)",
            body: payload,
            timeout: timeout
        )
    }

    public func reloadConfig(path: String, force: Bool = true, timeout: TimeInterval = 10.0) async throws {
        let queryItems = [URLQueryItem(name: "force", value: force ? "true" : "false")]
        let payload = try JSONEncoder().encode(["path": path])
        _ = try await performRequest(
            method: "PUT",
            path: "/configs",
            queryItems: queryItems,
            body: payload,
            timeout: timeout
        )
    }

    // MARK: - Helpers

    private func performRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        timeout: TimeInterval
    ) async throws -> Data {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw MihomoAPIError.invalidURL(path)
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw MihomoAPIError.invalidURL(path)
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MihomoAPIError.transportError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MihomoAPIError.transportError("Non-HTTP response received")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw MihomoAPIError.httpError(statusCode: httpResponse.statusCode, body: bodyText)
        }
        return data
    }

    internal static func encodePathSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    // MARK: - Private Decodable DTOs

    private struct ProxiesEnvelope: Decodable {
        let proxies: [String: RawProxyItem]
    }

    private struct RawProxyItem: Decodable {
        let name: String?
        let type: String?
        let now: String?
        let all: [String]?
        let alive: Bool?
        let history: [DelayHistoryEntry]?
    }

    private struct DelayHistoryEntry: Decodable {
        let delay: Int
    }

    private struct DelayResponse: Decodable {
        let delay: Int
    }

    private struct ConnectionsEnvelope: Decodable {
        let connections: [RawConnectionItem]?
    }

    private struct RawConnectionItem: Decodable {
        let id: String
        let metadata: RawConnectionMetadata?
        let upload: Int64?
        let download: Int64?
        let start: String?
        let chains: [String]?
        let rule: String?
        let rulePayload: String?
    }

    private struct RawConnectionMetadata: Decodable {
        let network: String?
        let sourceIP: String?
        let destinationIP: String?
        let sourcePort: String?
        let destinationPort: String?
        let host: String?
    }
}
