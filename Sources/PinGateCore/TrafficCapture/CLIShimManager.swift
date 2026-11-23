import Foundation

public enum CLIShimError: Error, LocalizedError, Sendable, Equatable {
    case invalidCommandName(String)
    case missingTargetBinaryPath(String)
    case existingUnmanagedFile(String)
    case unsupportedTargetKind(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCommandName(let name):
            return "无效的 CLI Shim 命令名称：「\(name)」。"
        case .missingTargetBinaryPath(let name):
            return "CLI 目标「\(name)」未配置目标二进制路径（cliTargetBinaryPath）。"
        case .existingUnmanagedFile(let path):
            return "拒绝覆盖非 PinGate 托管的文件：\(path)。"
        case .unsupportedTargetKind(let name):
            return "目标「\(name)」不是 CLI 工具类型。"
        }
    }
}

public struct ShimStatus: Codable, Sendable, Equatable {
    public let commandName: String
    public let shimPath: String
    public let targetBinaryPath: String
    public let isInstalled: Bool
    public let isManagedByPinGate: Bool
    public let configuredPort: Int?

    public init(
        commandName: String,
        shimPath: String,
        targetBinaryPath: String,
        isInstalled: Bool,
        isManagedByPinGate: Bool,
        configuredPort: Int?
    ) {
        self.commandName = commandName
        self.shimPath = shimPath
        self.targetBinaryPath = targetBinaryPath
        self.isInstalled = isInstalled
        self.isManagedByPinGate = isManagedByPinGate
        self.configuredPort = configuredPort
    }
}

/// Idempotently generates, inspects, and removes executable shell shims under `~/.local/bin/<cmd>`
/// that inject an outlet's proxy environment before `exec`-ing the real CLI binary.
public struct CLIShimManager: Sendable {
    public static let managedMarker = "# Managed by PinGate (do not edit manually)"
    private static let portMarkerPrefix = "# PinGate-Outlet-Port: "

    public let shimDirectory: URL

    public init(
        shimDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
    ) {
        self.shimDirectory = shimDirectory
    }

    public func shimURL(for commandName: String) throws -> URL {
        let trimmed = commandName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("/"),
              !trimmed.contains(".."),
              !trimmed.contains("\0")
        else {
            throw CLIShimError.invalidCommandName(commandName)
        }
        return shimDirectory.appendingPathComponent(trimmed, isDirectory: false)
    }

    /// Renders the deterministic shell wrapper script for a CLI target.
    public func renderScript(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules
    ) throws -> String {
        guard target.kind == .cliTool else {
            throw CLIShimError.unsupportedTargetKind(target.name)
        }
        guard let commandName = target.cliCommandName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !commandName.isEmpty
        else {
            throw CLIShimError.invalidCommandName(target.cliCommandName ?? "")
        }
        guard let rawTargetBin = target.cliTargetBinaryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawTargetBin.isEmpty
        else {
            throw CLIShimError.missingTargetBinaryPath(target.name)
        }

        let targetBin = NSString(string: rawTargetBin).expandingTildeInPath
        let env = AppLauncher.buildProxyEnvironment(
            outlet: outlet,
            bypassRules: bypassRules,
            extraEnv: target.extraEnv
        )

        var lines: [String] = [
            "#!/usr/bin/env bash",
            Self.managedMarker,
            "# PinGate-Target: \(target.name)",
            "# PinGate-Command: \(commandName)",
            "\(Self.portMarkerPrefix)\(outlet.listenPort)",
            "set -euo pipefail",
            ""
        ]

        let preferredOrder = [
            "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
            "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy", "NODE_USE_ENV_PROXY"
        ]
        var emitted = Set<String>()
        for key in preferredOrder {
            if let value = env[key] {
                lines.append("export \(key)=\(Self.shellQuote(value))")
                emitted.insert(key)
            }
        }
        for key in env.keys.sorted() where !emitted.contains(key) {
            if let value = env[key], Self.isValidShellIdentifier(key) {
                lines.append("export \(key)=\(Self.shellQuote(value))")
            }
        }

        let quotedBin = Self.shellQuote(targetBin)
        lines.append("")
        lines.append("TARGET_BIN=\(quotedBin)")
        lines.append("if [[ ! -x \"$TARGET_BIN\" ]]; then")
        lines.append("  echo \"PinGate shim error: target binary not found or not executable: $TARGET_BIN\" >&2")
        lines.append("  exit 127")
        lines.append("fi")
        lines.append("exec \"$TARGET_BIN\" \"$@\"")
        lines.append("")

        return lines.joined(separator: "\n")
    }

    /// Idempotently installs or updates a PinGate-managed CLI shim with `0755` permissions.
    @discardableResult
    public func installShim(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        overwriteUnmanaged: Bool = false
    ) throws -> URL {
        guard let commandName = target.cliCommandName else {
            throw CLIShimError.invalidCommandName("")
        }
        let url = try shimURL(for: commandName)
        let content = try renderScript(target: target, outlet: outlet, bypassRules: bypassRules)

        let fm = FileManager.default
        if !fm.fileExists(atPath: shimDirectory.path) {
            try fm.createDirectory(at: shimDirectory, withIntermediateDirectories: true)
        }

        if fm.fileExists(atPath: url.path) {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let managed = existing.contains(Self.managedMarker)
            if !managed && !overwriteUnmanaged {
                throw CLIShimError.existingUnmanagedFile(url.path)
            }
            if existing == content && fm.isExecutableFile(atPath: url.path) {
                return url
            }
        }

        try Data(content.utf8).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Removes a PinGate-managed shim. Refuses to delete unmanaged binaries/scripts unless `force == true`.
    @discardableResult
    public func removeShim(commandName: String, force: Bool = false) throws -> Bool {
        let url = try shimURL(for: commandName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return false
        }

        if !force {
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            guard existing.contains(Self.managedMarker) else {
                throw CLIShimError.existingUnmanagedFile(url.path)
            }
        }

        try fm.removeItem(at: url)
        return true
    }

    /// Inspects installation and port alignment status of a CLI target's shim.
    public func status(for target: ManagedTarget) -> ShimStatus {
        let commandName = target.cliCommandName ?? target.name
        let targetBin = target.cliTargetBinaryPath ?? ""
        guard let url = try? shimURL(for: commandName) else {
            return ShimStatus(
                commandName: commandName,
                shimPath: "",
                targetBinaryPath: targetBin,
                isInstalled: false,
                isManagedByPinGate: false,
                configuredPort: nil
            )
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path),
              let content = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ShimStatus(
                commandName: commandName,
                shimPath: url.path,
                targetBinaryPath: targetBin,
                isInstalled: false,
                isManagedByPinGate: false,
                configuredPort: nil
            )
        }

        let isManaged = content.contains(Self.managedMarker)
        var parsedPort: Int? = nil
        for line in content.split(whereSeparator: \.isNewline) {
            if line.hasPrefix(Self.portMarkerPrefix) {
                let portStr = line.dropFirst(Self.portMarkerPrefix.count).trimmingCharacters(in: .whitespaces)
                parsedPort = Int(portStr)
                break
            }
        }

        return ShimStatus(
            commandName: commandName,
            shimPath: url.path,
            targetBinaryPath: targetBin,
            isInstalled: fm.isExecutableFile(atPath: url.path),
            isManagedByPinGate: isManaged,
            configuredPort: parsedPort
        )
    }

    private static func shellQuote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }

    private static func isValidShellIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
