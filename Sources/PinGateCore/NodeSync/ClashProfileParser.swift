import Foundation
import Yams

public enum YAMLValue: Sendable, Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([YAMLValue])
    case dictionary([String: YAMLValue])
    case null

    public static func from(any value: Any?) -> YAMLValue {
        guard let value else { return .null }
        if value is NSNull {
            return .null
        }
        if let boolValue = value as? Bool {
            return .bool(boolValue)
        }
        if let intValue = value as? Int {
            return .int(intValue)
        }
        if let doubleValue = value as? Double {
            return .double(doubleValue)
        }
        if let stringValue = value as? String {
            return .string(stringValue)
        }
        if let dateValue = value as? Date {
            let formatter = ISO8601DateFormatter()
            return .string(formatter.string(from: dateValue))
        }
        if let arrayValue = value as? [Any] {
            return .array(arrayValue.map { YAMLValue.from(any: $0) })
        }
        if let dictValue = value as? [String: Any] {
            var mapped: [String: YAMLValue] = [:]
            mapped.reserveCapacity(dictValue.count)
            for (k, v) in dictValue {
                mapped[k] = YAMLValue.from(any: v)
            }
            return .dictionary(mapped)
        }
        if let anyDict = value as? [AnyHashable: Any] {
            var mapped: [String: YAMLValue] = [:]
            mapped.reserveCapacity(anyDict.count)
            for (k, v) in anyDict {
                mapped[String(describing: k)] = YAMLValue.from(any: v)
            }
            return .dictionary(mapped)
        }
        return .string(String(describing: value))
    }

    public func toAny() -> Any {
        switch self {
        case .string(let s):
            return s
        case .int(let i):
            return i
        case .double(let d):
            return d
        case .bool(let b):
            return b
        case .array(let arr):
            return arr.map { $0.toAny() }
        case .dictionary(let dict):
            var result: [String: Any] = [:]
            result.reserveCapacity(dict.count)
            for (k, v) in dict {
                result[k] = v.toAny()
            }
            return result
        case .null:
            return NSNull()
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }
}

public struct RawProxyNode: Sendable, Equatable {
    public let name: String
    public let fields: [String: YAMLValue]

    public init(name: String, fields: [String: YAMLValue]) {
        self.name = name
        self.fields = fields
    }

    public var dialerProxy: String? {
        guard let raw = fields["dialer-proxy"]?.stringValue else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public var proxyType: String? {
        fields["type"]?.stringValue
    }

    public func toAnyDictionary() -> [String: Any] {
        var result: [String: Any] = [:]
        result.reserveCapacity(fields.count)
        for (k, v) in fields {
            result[k] = v.toAny()
        }
        result["name"] = name
        return result
    }
}

public struct ExtractedProxyChain: Sendable, Equatable {
    public let primaryNodeName: String
    public let orderedProxyNames: [String]
    public let outletGroupMembers: [String]
    public let availableFallbackNames: [String]
    public let missingFallbackNames: [String]
    public let proxies: [RawProxyNode]

    public init(
        primaryNodeName: String,
        orderedProxyNames: [String],
        outletGroupMembers: [String],
        availableFallbackNames: [String],
        missingFallbackNames: [String],
        proxies: [RawProxyNode]
    ) {
        self.primaryNodeName = primaryNodeName
        self.orderedProxyNames = orderedProxyNames
        self.outletGroupMembers = outletGroupMembers
        self.availableFallbackNames = availableFallbackNames
        self.missingFallbackNames = missingFallbackNames
        self.proxies = proxies
    }
}

public enum ClashProfileParserError: Error, LocalizedError, Sendable, Equatable {
    case invalidYAML(String)
    case missingProxiesSection
    case emptyPrimaryNodeName
    case nodeNotFound(name: String, availableCount: Int)
    case missingDialerProxy(node: String, dialerProxy: String)
    case dialerProxyCycle(chain: [String])
    case fileReadFailed(String)
    case remoteFetchFailed(String)
    case invalidSourceConfiguration(String)

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let detail):
            return "Invalid Clash profile YAML: \(detail)"
        case .missingProxiesSection:
            return "No proxies found in Clash profile YAML."
        case .emptyPrimaryNodeName:
            return "Primary node name is empty. Configure primaryNodeName before syncing."
        case .nodeNotFound(let name, let availableCount):
            return "Node '\(name)' was not found among \(availableCount) proxies in profile."
        case .missingDialerProxy(let node, let dialerProxy):
            return "Node '\(node)' references dialer-proxy '\(dialerProxy)', which does not exist in profile."
        case .dialerProxyCycle(let chain):
            return "Circular dialer-proxy dependency detected: \(chain.joined(separator: " -> "))"
        case .fileReadFailed(let message):
            return "Failed to read profile file: \(message)"
        case .remoteFetchFailed(let message):
            return "Failed to fetch remote subscription: \(message)"
        case .invalidSourceConfiguration(let message):
            return "Invalid outlet source configuration: \(message)"
        }
    }
}

public struct ClashProfileParser: Sendable {
    private static let builtInDetours: Set<String> = ["DIRECT", "REJECT", "PASS"]

    public init() {}

    /// Parses all proxy entries from a Clash profile YAML, a bare list of proxies, or a single proxy mapping.
    public func parseAllProxies(fromYAML yaml: String) throws -> [RawProxyNode] {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: yaml)
        } catch {
            throw ClashProfileParserError.invalidYAML(error.localizedDescription)
        }

        let rawList: [[String: Any]]
        if let rootDict = loaded as? [String: Any] {
            if let proxiesAny = rootDict["proxies"] as? [Any] {
                rawList = proxiesAny.compactMap { $0 as? [String: Any] }
            } else if rootDict["name"] is String && rootDict["type"] is String {
                // Single manual proxy block
                rawList = [rootDict]
            } else {
                throw ClashProfileParserError.missingProxiesSection
            }
        } else if let listAny = loaded as? [Any] {
            rawList = listAny.compactMap { $0 as? [String: Any] }
        } else {
            throw ClashProfileParserError.missingProxiesSection
        }

        guard !rawList.isEmpty else {
            throw ClashProfileParserError.missingProxiesSection
        }

        var nodes: [RawProxyNode] = []
        nodes.reserveCapacity(rawList.count)
        for item in rawList {
            guard let name = item["name"] as? String, !name.isEmpty else {
                continue
            }
            var fields: [String: YAMLValue] = [:]
            fields.reserveCapacity(item.count)
            for (k, v) in item {
                fields[k] = YAMLValue.from(any: v)
            }
            nodes.append(RawProxyNode(name: name, fields: fields))
        }

        guard !nodes.isEmpty else {
            throw ClashProfileParserError.missingProxiesSection
        }
        return nodes
    }

    public func listProxyNames(fromYAML yaml: String) throws -> [String] {
        try parseAllProxies(fromYAML: yaml).map(\.name)
    }

    public func listProxyNames(fromFileAt url: URL) throws -> [String] {
        let yaml = try readYAMLFile(at: url)
        return try listProxyNames(fromYAML: yaml)
    }

    public func extractChain(
        fromFileAt url: URL,
        primaryNodeName: String,
        fallbackNodeNames: [String] = []
    ) throws -> ExtractedProxyChain {
        let yaml = try readYAMLFile(at: url)
        return try extractChain(
            fromYAML: yaml,
            primaryNodeName: primaryNodeName,
            fallbackNodeNames: fallbackNodeNames
        )
    }

    /// Recursively extracts the primary node, any `dialer-proxy` hop dependencies (at arbitrary depth),
    /// and any available fallback nodes (plus their `dialer-proxy` chains).
    public func extractChain(
        fromYAML yaml: String,
        primaryNodeName: String,
        fallbackNodeNames: [String] = []
    ) throws -> ExtractedProxyChain {
        let allNodes = try parseAllProxies(fromYAML: yaml)
        var byName: [String: RawProxyNode] = [:]
        byName.reserveCapacity(allNodes.count)
        for node in allNodes {
            if byName[node.name] == nil {
                byName[node.name] = node
            }
        }

        let trimmedPrimary = primaryNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrimary.isEmpty else {
            throw ClashProfileParserError.emptyPrimaryNodeName
        }
        guard byName[trimmedPrimary] != nil else {
            throw ClashProfileParserError.nodeNotFound(name: trimmedPrimary, availableCount: byName.count)
        }

        var collectedNodes: [RawProxyNode] = []
        var collectedSet = Set<String>()

        func resolveRecursive(
            nodeName: String,
            stack: [String],
            into outNodes: inout [RawProxyNode],
            seen: inout Set<String>
        ) throws {
            if stack.contains(nodeName) {
                throw ClashProfileParserError.dialerProxyCycle(chain: stack + [nodeName])
            }
            guard !seen.contains(nodeName) else { return }
            guard let node = byName[nodeName] else {
                if let parent = stack.last {
                    throw ClashProfileParserError.missingDialerProxy(node: parent, dialerProxy: nodeName)
                }
                throw ClashProfileParserError.nodeNotFound(name: nodeName, availableCount: byName.count)
            }

            if let dialer = node.dialerProxy, !Self.builtInDetours.contains(dialer.uppercased()) {
                try resolveRecursive(
                    nodeName: dialer,
                    stack: stack + [nodeName],
                    into: &outNodes,
                    seen: &seen
                )
            }

            if !seen.contains(node.name) {
                seen.insert(node.name)
                outNodes.append(node)
            }
        }

        // Resolve primary node (errors here are fatal)
        try resolveRecursive(
            nodeName: trimmedPrimary,
            stack: [],
            into: &collectedNodes,
            seen: &collectedSet
        )

        // Resolve fallbacks (missing or broken fallbacks are recorded as missing rather than failing primary)
        var availableFallbacks: [String] = []
        var missingFallbacks: [String] = []
        var seenFallbacks = Set<String>([trimmedPrimary])

        for rawFallback in fallbackNodeNames {
            let fallback = rawFallback.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fallback.isEmpty, !seenFallbacks.contains(fallback) else { continue }
            seenFallbacks.insert(fallback)

            var tempNodes = collectedNodes
            var tempSet = collectedSet
            do {
                try resolveRecursive(
                    nodeName: fallback,
                    stack: [],
                    into: &tempNodes,
                    seen: &tempSet
                )
                collectedNodes = tempNodes
                collectedSet = tempSet
                availableFallbacks.append(fallback)
            } catch {
                missingFallbacks.append(fallback)
            }
        }

        let outletMembers = [trimmedPrimary] + availableFallbacks
        return ExtractedProxyChain(
            primaryNodeName: trimmedPrimary,
            orderedProxyNames: collectedNodes.map(\.name),
            outletGroupMembers: outletMembers,
            availableFallbackNames: availableFallbacks,
            missingFallbackNames: missingFallbacks,
            proxies: collectedNodes
        )
    }

    public func fetchRemoteSubscription(
        url: URL,
        timeout: TimeInterval = 15,
        session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("clash.meta/1.19 PinGate/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClashProfileParserError.remoteFetchFailed(error.localizedDescription)
        }

        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw ClashProfileParserError.remoteFetchFailed("HTTP status \(httpResponse.statusCode)")
        }

        guard let rawText = String(data: data, encoding: .utf8), !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClashProfileParserError.remoteFetchFailed("Empty or non-UTF-8 response body")
        }

        // If the payload is base64-encoded Clash YAML, decode it transparently.
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("proxies:") && !trimmed.contains("server:"),
           let decodedData = Data(base64Encoded: trimmed, options: [.ignoreUnknownCharacters]),
           let decodedText = String(data: decodedData, encoding: .utf8),
           decodedText.contains("proxies:") || decodedText.contains("server:") {
            return decodedText
        }

        return rawText
    }

    public func resolveProxies(
        for outlet: OutletConfig,
        session: URLSession = .shared
    ) async throws -> ExtractedProxyChain {
        switch outlet.source {
        case .localClashProfile(let path):
            let expanded = NSString(string: path).expandingTildeInPath
            guard !expanded.isEmpty else {
                throw ClashProfileParserError.invalidSourceConfiguration("Local Clash profile path is empty.")
            }
            return try extractChain(
                fromFileAt: URL(fileURLWithPath: expanded),
                primaryNodeName: outlet.primaryNodeName,
                fallbackNodeNames: outlet.fallbackNodeNames
            )

        case .remoteSubscription(let urlString, _):
            guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw ClashProfileParserError.invalidSourceConfiguration("Invalid subscription URL: \(urlString)")
            }
            let yaml = try await fetchRemoteSubscription(url: url, session: session)
            return try extractChain(
                fromYAML: yaml,
                primaryNodeName: outlet.primaryNodeName,
                fallbackNodeNames: outlet.fallbackNodeNames
            )

        case .manualYAML(let yaml):
            let trimmedPrimary = outlet.primaryNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPrimary.isEmpty {
                let all = try parseAllProxies(fromYAML: yaml)
                return try extractChain(
                    fromYAML: yaml,
                    primaryNodeName: all[0].name,
                    fallbackNodeNames: outlet.fallbackNodeNames
                )
            }
            return try extractChain(
                fromYAML: yaml,
                primaryNodeName: trimmedPrimary,
                fallbackNodeNames: outlet.fallbackNodeNames
            )

        case .upstreamProxy(let scheme, let host, let port, let username, let password):
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty, (1...65535).contains(port) else {
                throw ClashProfileParserError.invalidSourceConfiguration("Upstream proxy host/port is invalid.")
            }
            let nodeName = outlet.primaryNodeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "UPSTREAM"
                : outlet.primaryNodeName.trimmingCharacters(in: .whitespacesAndNewlines)

            var fields: [String: YAMLValue] = [
                "name": .string(nodeName),
                "type": .string(scheme.rawValue),
                "server": .string(trimmedHost),
                "port": .int(port)
            ]
            if scheme == .socks5 {
                fields["udp"] = .bool(true)
            }
            if let username, !username.isEmpty {
                fields["username"] = .string(username)
            }
            if let password, !password.isEmpty {
                fields["password"] = .string(password)
            }
            let node = RawProxyNode(name: nodeName, fields: fields)
            return ExtractedProxyChain(
                primaryNodeName: nodeName,
                orderedProxyNames: [nodeName],
                outletGroupMembers: [nodeName],
                availableFallbackNames: [],
                missingFallbackNames: [],
                proxies: [node]
            )
        }
    }

    private func readYAMLFile(at url: URL) throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ClashProfileParserError.fileReadFailed("\(url.path): \(error.localizedDescription)")
        }
    }
}
