import CryptoKit
import Foundation

public enum MihomoBinaryError: Error, LocalizedError, Sendable {
    case binaryNotFound(String)
    case checksumMismatch(expected: String, actual: String)
    case downloadFailed(String)
    case decompressionFailed(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryNotFound(let message):
            return "未找到 mihomo 可执行文件：\(message)"
        case .checksumMismatch(let expected, let actual):
            return "mihomo 二进制 SHA-256 校验不匹配：期望 \(expected)，实际 \(actual)"
        case .downloadFailed(let message):
            return "下载 mihomo 二进制失败：\(message)"
        case .decompressionFailed(let message):
            return "解压 mihomo 压缩包失败：\(message)"
        case .executionFailed(let message):
            return "执行 mihomo 二进制失败：\(message)"
        }
    }
}

public struct MihomoBinaryManager: Sendable {
    public let binDirectory: URL

    public var binaryURL: URL {
        binDirectory.appendingPathComponent("mihomo", isDirectory: false)
    }

    public init(
        binDirectory: URL = ConfigStore.defaultBaseDirectory.appendingPathComponent("bin", isDirectory: true)
    ) {
        self.binDirectory = binDirectory
    }

    public func isInstalled() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: binaryURL.path) && fm.isExecutableFile(atPath: binaryURL.path)
    }

    public static func defaultSeedCandidateURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Library/Application Support/AntigravityProxy/mihomo", isDirectory: false),
            URL(fileURLWithPath: "/opt/homebrew/bin/mihomo"),
            URL(fileURLWithPath: "/usr/local/bin/mihomo")
        ]
    }

    public func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 256) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    public func installFromLocalBinary(
        at sourceURL: URL,
        expectedSHA256: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceURL.path) else {
            throw MihomoBinaryError.binaryNotFound(sourceURL.path)
        }

        if let expected = expectedSHA256?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !expected.isEmpty {
            let actual = try sha256Hex(of: sourceURL)
            guard actual == expected else {
                throw MihomoBinaryError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        if !fm.fileExists(atPath: binDirectory.path) {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        }
        try ConfigStore.setPosixPermissions(0o700, at: binDirectory)

        let data = try Data(contentsOf: sourceURL)
        try ConfigStore.atomicWrite(data: data, to: binaryURL, posixPermissions: 0o700)
        return binaryURL
    }

    /// Downloads an official arm64 Mihomo binary (raw or `.gz`), verifies SHA-256 against the downloaded payload,
    /// decompresses if `.gz`, and installs atomically at `binaryURL` with `0700` permissions.
    @discardableResult
    public func downloadOfficialRelease(
        downloadURL: URL,
        expectedSHA256: String,
        session: URLSession = .shared
    ) async throws -> URL {
        let fm = FileManager.default
        if !fm.fileExists(atPath: binDirectory.path) {
            try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        }
        try ConfigStore.setPosixPermissions(0o700, at: binDirectory)

        var request = URLRequest(url: downloadURL, timeoutInterval: 120)
        request.setValue("PinGate/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw MihomoBinaryError.downloadFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MihomoBinaryError.downloadFailed("下载返回 HTTP \(http.statusCode)（\(downloadURL.absoluteString)）")
        }

        let stagingURL = binDirectory.appendingPathComponent(".mihomo-download-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: stagingURL) }
        try ConfigStore.atomicWrite(data: data, to: stagingURL, posixPermissions: 0o600)

        let normalizedExpected = expectedSHA256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actualHash = try sha256Hex(of: stagingURL)
        guard actualHash == normalizedExpected else {
            throw MihomoBinaryError.checksumMismatch(expected: normalizedExpected, actual: actualHash)
        }

        let finalData: Data
        if downloadURL.pathExtension.lowercased() == "gz" {
            finalData = try gunzipFile(at: stagingURL)
        } else {
            finalData = data
        }

        try ConfigStore.atomicWrite(data: finalData, to: binaryURL, posixPermissions: 0o700)
        return binaryURL
    }

    /// Ensures the managed mihomo binary is installed at `binaryURL`, optionally seeding from local candidate paths.
    @discardableResult
    public func ensureBinary(seedPaths: [URL] = MihomoBinaryManager.defaultSeedCandidateURLs()) throws -> URL {
        if isInstalled() {
            try? ConfigStore.setPosixPermissions(0o700, at: binaryURL)
            return binaryURL
        }

        let fm = FileManager.default
        for candidate in seedPaths {
            if fm.fileExists(atPath: candidate.path), fm.isExecutableFile(atPath: candidate.path) {
                return try installFromLocalBinary(at: candidate)
            }
        }

        throw MihomoBinaryError.binaryNotFound(
            "本地路径 \(binaryURL.path) 不存在，且未找到可用的本地种子二进制文件。"
        )
    }

    public func installedVersion() throws -> String {
        guard isInstalled() else {
            throw MihomoBinaryError.binaryNotFound(binaryURL.path)
        }
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-v"]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw MihomoBinaryError.executionFailed(error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 {
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MihomoBinaryError.executionFailed(errText.isEmpty ? "退出码 \(process.terminationStatus)" : errText)
        }
        return output
    }

    private func gunzipFile(at sourceURL: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", sourceURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw MihomoBinaryError.decompressionFailed(error.localizedDescription)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0, !outData.isEmpty else {
            let errText = String(data: errData, encoding: .utf8) ?? "gunzip 解压失败，退出码 \(process.terminationStatus)"
            throw MihomoBinaryError.decompressionFailed(errText)
        }
        return outData
    }
}
