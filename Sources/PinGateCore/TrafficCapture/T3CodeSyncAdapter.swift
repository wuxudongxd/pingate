import Foundation

public enum T3SyncError: Error, LocalizedError, Sendable, Equatable {
    case settingsFileNotFound(String)
    case invalidJSONStructure(String)
    case providerNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .settingsFileNotFound(let path):
            return "T3 Code settings.json not found at \(path)."
        case .invalidJSONStructure(let detail):
            return "Invalid T3 Code settings.json structure: \(detail)."
        case .providerNotFound(let key):
            return "Provider instance '\(key)' not found in T3 Code settings.json."
        }
    }
}

public struct T3SyncResult: Codable, Sendable, Equatable {
    public let settingsPath: String
    public let providerKey: String
    public let backupPath: String?
    public let changed: Bool
    public let appliedKeys: [String]

    public init(
        settingsPath: String,
        providerKey: String,
        backupPath: String?,
        changed: Bool,
        appliedKeys: [String]
    ) {
        self.settingsPath = settingsPath
        self.providerKey = providerKey
        self.backupPath = backupPath
        self.changed = changed
        self.appliedKeys = appliedKeys
    }
}

/// Idempotently synchronizes `providerInstances.<providerKey>.environment` in `~/.t3/userdata/settings.json`
/// while preserving all unrelated keys, providers, and `valueRedacted` secrets verbatim.
public struct T3CodeSyncAdapter: Sendable {
    public static let defaultSettingsPath = "~/.t3/userdata/settings.json"
    public static let defaultProviderKey = "antigravity"

    private static let managedProxyKeysOrder: [String] = [
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "NODE_USE_ENV_PROXY"
    ]

    private static let lowercaseMirrorKeys: Set<String> = [
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "no_proxy"
    ]

    public init() {}

    public func resolveSettingsURL(for target: ManagedTarget) -> URL {
        let raw = target.t3SettingsPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = (raw?.isEmpty == false ? raw! : Self.defaultSettingsPath)
        let expanded = NSString(string: path).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    /// Synchronizes proxy environment entries for `target`'s T3 provider instance.
    /// Creates a `.bak` backup alongside `settings.json` before writing when changes occur.
    @discardableResult
    public func sync(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules
    ) throws -> T3SyncResult {
        let settingsURL = resolveSettingsURL(for: target)
        let providerKey = target.t3ProviderKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? target.t3ProviderKey!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultProviderKey

        return try sync(
            settingsURL: settingsURL,
            providerKey: providerKey,
            outlet: outlet,
            bypassRules: bypassRules,
            extraEnv: target.extraEnv
        )
    }

    /// Synchronizes proxy environment entries in an explicit `settingsURL` and `providerKey`.
    @discardableResult
    public func sync(
        settingsURL: URL,
        providerKey: String = defaultProviderKey,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        extraEnv: [String: String] = [:]
    ) throws -> T3SyncResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: settingsURL.path) else {
            throw T3SyncError.settingsFileNotFound(settingsURL.path)
        }

        let originalData = try Data(contentsOf: settingsURL)
        guard var root = try JSONSerialization.jsonObject(with: originalData) as? [String: Any] else {
            throw T3SyncError.invalidJSONStructure("Root JSON value must be an object")
        }

        guard var providerInstances = root["providerInstances"] as? [String: Any] else {
            throw T3SyncError.invalidJSONStructure("Missing 'providerInstances' object")
        }

        guard var provider = providerInstances[providerKey] as? [String: Any] else {
            throw T3SyncError.providerNotFound(providerKey)
        }

        let existingEnv = (provider["environment"] as? [[String: Any]]) ?? []
        let desiredMap = buildDesiredValues(outlet: outlet, bypassRules: bypassRules, extraEnv: extraEnv)
        let updatedEnv = mergeEnvironment(existing: existingEnv, desired: desiredMap)

        let changed = !environmentsEqual(existingEnv, updatedEnv)
        let appliedKeys = desiredMap.keys.sorted()

        guard changed else {
            return T3SyncResult(
                settingsPath: settingsURL.path,
                providerKey: providerKey,
                backupPath: nil,
                changed: false,
                appliedKeys: appliedKeys
            )
        }

        // Write .bak backup preserving original bytes before modifying.
        let backupURL = URL(fileURLWithPath: settingsURL.path + ".bak")
        try originalData.write(to: backupURL, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)

        provider["environment"] = updatedEnv
        providerInstances[providerKey] = provider
        root["providerInstances"] = providerInstances

        let serialized = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        var finalData = serialized
        finalData.append(0x0A) // trailing newline
        try finalData.write(to: settingsURL, options: .atomic)

        return T3SyncResult(
            settingsPath: settingsURL.path,
            providerKey: providerKey,
            backupPath: backupURL.path,
            changed: true,
            appliedKeys: appliedKeys
        )
    }

    /// Returns `true` if `settings.json` already matches the desired outlet proxy environment.
    public func isInSync(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules
    ) -> Bool {
        let settingsURL = resolveSettingsURL(for: target)
        let providerKey = target.t3ProviderKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? target.t3ProviderKey!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Self.defaultProviderKey

        guard let data = try? Data(contentsOf: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providerInstances = root["providerInstances"] as? [String: Any],
              let provider = providerInstances[providerKey] as? [String: Any],
              let existingEnv = provider["environment"] as? [[String: Any]]
        else {
            return false
        }

        let desiredMap = buildDesiredValues(outlet: outlet, bypassRules: bypassRules, extraEnv: target.extraEnv)
        let updatedEnv = mergeEnvironment(existing: existingEnv, desired: desiredMap)
        return environmentsEqual(existingEnv, updatedEnv)
    }

    private func buildDesiredValues(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        extraEnv: [String: String]
    ) -> [String: String] {
        var values: [String: String] = [
            "HTTP_PROXY": outlet.proxyURLString,
            "HTTPS_PROXY": outlet.proxyURLString,
            "ALL_PROXY": "socks5h://\(outlet.listenHost):\(outlet.listenPort)",
            "NO_PROXY": bypassRules.noProxyCSV(),
            "NODE_USE_ENV_PROXY": "1"
        ]
        for (key, value) in extraEnv where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            values[key] = value
        }
        return values
    }

    private func mergeEnvironment(
        existing: [[String: Any]],
        desired: [String: String]
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        var updatedNames = Set<String>()

        for var entry in existing {
            guard let name = entry["name"] as? String else {
                result.append(entry)
                continue
            }

            // Never mutate redacted/secret entries.
            if (entry["valueRedacted"] as? Bool) == true || (entry["sensitive"] as? Bool) == true {
                result.append(entry)
                continue
            }

            if let newValue = desired[name] {
                entry["value"] = newValue
                if entry["sensitive"] == nil {
                    entry["sensitive"] = false
                }
                result.append(entry)
                updatedNames.insert(name)
            } else if Self.lowercaseMirrorKeys.contains(name),
                      let upperValue = desired[name.uppercased()] {
                // Keep any pre-existing lowercase mirror synchronized too.
                entry["value"] = upperValue
                if entry["sensitive"] == nil {
                    entry["sensitive"] = false
                }
                result.append(entry)
                updatedNames.insert(name)
            } else {
                result.append(entry)
            }
        }

        // Append missing managed keys in deterministic order.
        for key in Self.managedProxyKeysOrder where !updatedNames.contains(key) {
            if let value = desired[key] {
                result.append([
                    "name": key,
                    "value": value,
                    "sensitive": false
                ])
                updatedNames.insert(key)
            }
        }

        for key in desired.keys.sorted() where !updatedNames.contains(key) {
            if let value = desired[key] {
                result.append([
                    "name": key,
                    "value": value,
                    "sensitive": false
                ])
                updatedNames.insert(key)
            }
        }

        return result
    }

    private func environmentsEqual(_ lhs: [[String: Any]], _ rhs: [[String: Any]]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }
}
