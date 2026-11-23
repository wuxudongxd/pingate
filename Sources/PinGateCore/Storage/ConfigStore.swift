import Foundation

public enum ConfigStoreError: Error, LocalizedError, Sendable {
    case unsupportedSchemaVersion(Int)
    case encodingFailed(String)
    case decodingFailed(String)
    case ioFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "不支持的 PinGate 配置版本 \(version)，当前支持版本为 \(PinGateConfig.currentSchemaVersion)。"
        case .encodingFailed(let message):
            return "PinGate 配置编码失败：\(message)"
        case .decodingFailed(let message):
            return "PinGate 配置解析失败：\(message)"
        case .ioFailed(let message):
            return "配置文件读写失败：\(message)"
        }
    }
}

public final class ConfigStore: Sendable {
    public static var defaultBaseDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/PinGate", isDirectory: true)
    }

    public let baseDirectory: URL

    public var configFileURL: URL {
        baseDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    public var runtimeDirectory: URL {
        baseDirectory.appendingPathComponent("runtime", isDirectory: true)
    }

    public var logsDirectory: URL {
        baseDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public var binDirectory: URL {
        baseDirectory.appendingPathComponent("bin", isDirectory: true)
    }

    public init(baseDirectory: URL = ConfigStore.defaultBaseDirectory) {
        self.baseDirectory = baseDirectory
    }

    public func renderedMihomoConfigURL(for outlet: OutletConfig) -> URL {
        runtimeDirectory.appendingPathComponent("mihomo-\(outlet.id.uuidString.lowercased()).yaml", isDirectory: false)
    }

    public func logFileURL(for outlet: OutletConfig) -> URL {
        logsDirectory.appendingPathComponent("mihomo-\(outlet.id.uuidString.lowercased()).log", isDirectory: false)
    }

    public func ensureDirectories() throws {
        let fm = FileManager.default
        let dirs = [baseDirectory, runtimeDirectory, logsDirectory, binDirectory]
        for dir in dirs {
            do {
                if !fm.fileExists(atPath: dir.path) {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                }
                try Self.setPosixPermissions(0o700, at: dir)
            } catch {
                throw ConfigStoreError.ioFailed("无法准备目录 \(dir.path)：\(error.localizedDescription)")
            }
        }
    }

    public func configExists() -> Bool {
        FileManager.default.fileExists(atPath: configFileURL.path)
    }

    public func load() throws -> PinGateConfig {
        let data: Data
        do {
            data = try Data(contentsOf: configFileURL)
        } catch {
            throw ConfigStoreError.ioFailed("无法读取配置文件 \(configFileURL.path)：\(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let config: PinGateConfig
        do {
            config = try decoder.decode(PinGateConfig.self, from: data)
        } catch {
            throw ConfigStoreError.decodingFailed(error.localizedDescription)
        }

        guard config.schemaVersion <= PinGateConfig.currentSchemaVersion else {
            throw ConfigStoreError.unsupportedSchemaVersion(config.schemaVersion)
        }
        return config
    }

    public func loadOrBootstrap() throws -> PinGateConfig {
        try ensureDirectories()
        if configExists() {
            return try load()
        }
        let bootstrap = PinGateConfig.defaultBootstrapConfig()
        try save(bootstrap)
        return bootstrap
    }

    public func save(_ config: PinGateConfig) throws {
        try ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data: Data
        do {
            data = try encoder.encode(config)
        } catch {
            throw ConfigStoreError.encodingFailed(error.localizedDescription)
        }

        try Self.atomicWrite(data: data, to: configFileURL, posixPermissions: 0o600)
    }

    public static func discoverFlClashProfiles(in directory: URL? = nil) -> [URL] {
        PinGateConfig.discoverFlClashProfiles(in: directory)
    }

    /// Writes `data` atomically into a sibling temporary file with `posixPermissions` applied BEFORE rename,
    /// avoiding any window where credentials exist on disk with looser permissions.
    public static func atomicWrite(data: Data, to destinationURL: URL, posixPermissions: Int16 = 0o600) throws {
        let fm = FileManager.default
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        let tempURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        let created = fm.createFile(
            atPath: tempURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: posixPermissions)]
        )
        guard created else {
            throw ConfigStoreError.ioFailed("无法在 \(tempURL.path) 创建临时文件")
        }

        do {
            try setPosixPermissions(posixPermissions, at: tempURL)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer {
                try? handle.close()
            }
            try handle.write(contentsOf: data)
            try handle.synchronize()

            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: destinationURL)
            }
            try setPosixPermissions(posixPermissions, at: destinationURL)
        } catch {
            try? fm.removeItem(at: tempURL)
            throw ConfigStoreError.ioFailed("原子写入 \(destinationURL.path) 失败：\(error.localizedDescription)")
        }
    }

    public static func setPosixPermissions(_ permissions: Int16, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions)],
            ofItemAtPath: url.path
        )
    }
}
