import CryptoKit
import Darwin
import Foundation

// MARK: - SemanticVersion

public struct SemanticVersion: Comparable, Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = max(0, major)
        self.minor = max(0, minor)
        self.patch = max(0, patch)
        if let prerelease, !prerelease.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.prerelease = prerelease.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            self.prerelease = nil
        }
    }

    public init?(string: String) {
        var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("v") || cleaned.hasPrefix("V") {
            cleaned.removeFirst()
        }
        guard !cleaned.isEmpty else { return nil }

        // Strip optional build metadata (+...)
        let withoutBuild = cleaned.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard coreParts.count >= 2 && coreParts.count <= 3 else { return nil }

        guard let maj = Int(coreParts[0]), maj >= 0,
              let min = Int(coreParts[1]), min >= 0 else {
            return nil
        }
        let pat: Int
        if coreParts.count == 3 {
            guard let parsedPatch = Int(coreParts[2]), parsedPatch >= 0 else { return nil }
            pat = parsedPatch
        } else {
            pat = 0
        }

        let pre: String? = parts.count > 1 ? String(parts[1]) : nil
        self.init(major: maj, minor: min, patch: pat, prerelease: pre)
    }

    public var description: String {
        if let prerelease {
            return "\(major).\(minor).\(patch)-\(prerelease)"
        }
        return "\(major).\(minor).\(patch)"
    }

    public var tagString: String {
        "v\(description)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }

        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil):
            return false
        case (.some, nil):
            // Prerelease has lower precedence than normal release
            return true
        case (nil, .some):
            return false
        case (.some(let lPre), .some(let rPre)):
            let lIds = lPre.split(separator: ".")
            let rIds = rPre.split(separator: ".")
            let count = min(lIds.count, rIds.count)
            for idx in 0..<count {
                let lToken = String(lIds[idx])
                let rToken = String(rIds[idx])
                if lToken == rToken { continue }
                switch (Int(lToken), Int(rToken)) {
                case (.some(let ln), .some(let rn)):
                    return ln < rn
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return lToken < rToken
                }
            }
            return lIds.count < rIds.count
        }
    }
}

// MARK: - Release & Update Models

public struct ReleaseInfo: Codable, Sendable, Equatable {
    public let tagName: String
    public let version: SemanticVersion
    public let title: String
    public let releaseNotes: String
    public let htmlURL: URL
    public let publishedAt: Date?
    public let zipAssetName: String
    public let zipDownloadURL: URL
    public let zipSizeBytes: Int64?
    public let checksumsAssetURL: URL?

    public init(
        tagName: String,
        version: SemanticVersion,
        title: String,
        releaseNotes: String,
        htmlURL: URL,
        publishedAt: Date? = nil,
        zipAssetName: String,
        zipDownloadURL: URL,
        zipSizeBytes: Int64? = nil,
        checksumsAssetURL: URL? = nil
    ) {
        self.tagName = tagName
        self.version = version
        self.title = title
        self.releaseNotes = releaseNotes
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.zipAssetName = zipAssetName
        self.zipDownloadURL = zipDownloadURL
        self.zipSizeBytes = zipSizeBytes
        self.checksumsAssetURL = checksumsAssetURL
    }
}

public enum UpdateCheckResult: Sendable, Equatable {
    case upToDate(currentVersion: SemanticVersion, latestRelease: ReleaseInfo?)
    case updateAvailable(currentVersion: SemanticVersion, release: ReleaseInfo)

    public var hasUpdate: Bool {
        if case .updateAvailable = self { return true }
        return false
    }

    public var currentVersion: SemanticVersion {
        switch self {
        case .upToDate(let current, _), .updateAvailable(let current, _):
            return current
        }
    }

    public var release: ReleaseInfo? {
        switch self {
        case .upToDate(_, let latest):
            return latest
        case .updateAvailable(_, let release):
            return release
        }
    }
}

public enum UpdateProgress: Sendable, Equatable {
    case checking
    case downloading(fractionCompleted: Double, receivedBytes: Int64, totalBytes: Int64)
    case verifyingChecksum
    case extracting
    case verifyingSignature
    case readyToInstall(stagedAppURL: URL)

    public var displayName: String {
        switch self {
        case .checking:
            return "正在检查更新…"
        case .downloading(let fraction, _, _):
            let pct = Int((min(max(fraction, 0), 1) * 100).rounded())
            return "正在下载更新（\(pct)%）…"
        case .verifyingChecksum:
            return "正在校验安装包完整性…"
        case .extracting:
            return "正在解压更新包…"
        case .verifyingSignature:
            return "正在验证应用签名…"
        case .readyToInstall:
            return "更新已准备就绪"
        }
    }
}

public struct PreparedUpdate: Sendable, Equatable {
    public let release: ReleaseInfo
    public let archiveURL: URL
    public let stagingDirectory: URL
    public let stagedAppURL: URL
    public let verifiedSHA256: String

    public init(
        release: ReleaseInfo,
        archiveURL: URL,
        stagingDirectory: URL,
        stagedAppURL: URL,
        verifiedSHA256: String
    ) {
        self.release = release
        self.archiveURL = archiveURL
        self.stagingDirectory = stagingDirectory
        self.stagedAppURL = stagedAppURL
        self.verifiedSHA256 = verifiedSHA256
    }
}

public enum AppUpdaterError: Error, LocalizedError, Sendable, Equatable {
    case invalidVersion(String)
    case networkFailed(String)
    case noReleasesPublished
    case missingAsset(String)
    case checksumMissing(assetName: String)
    case checksumMismatch(expected: String, actual: String)
    case extractionFailed(String)
    case invalidAppBundle(String)
    case signatureVerificationFailed(String)
    case installScriptFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidVersion(let raw):
            return "无法识别的版本号：\(raw)"
        case .networkFailed(let detail):
            return "检查或下载更新失败：\(detail)"
        case .noReleasesPublished:
            return "当前尚无已发布的正式版本。"
        case .missingAsset(let detail):
            return "发布版本中缺少可用的安装包：\(detail)"
        case .checksumMissing(let assetName):
            return "校验文件 SHA256SUMS.txt 中未找到 \(assetName) 的校验值。"
        case .checksumMismatch(let expected, let actual):
            return "安装包 SHA-256 校验失败，已中止更新（期望 \(expected.prefix(12))…，实际 \(actual.prefix(12))…）。"
        case .extractionFailed(let detail):
            return "解压更新包失败：\(detail)"
        case .invalidAppBundle(let detail):
            return "更新包中的应用结构无效：\(detail)"
        case .signatureVerificationFailed(let detail):
            return "应用签名校验未通过：\(detail)"
        case .installScriptFailed(let detail):
            return "启动更新安装程序失败：\(detail)"
        }
    }
}

// MARK: - AppUpdater

public struct AppUpdater: Sendable {
    public static let defaultRepository = "wuxudongxd/pingate"
    public static let fallbackVersionString = "0.1.0"

    public let repository: String
    public let configStore: ConfigStore
    private let sessionFactory: @Sendable (OutletConfig?) -> URLSession

    public var updatesDirectory: URL {
        configStore.baseDirectory.appendingPathComponent("updates", isDirectory: true)
    }

    public static func resolvedDefaultRepository(bundle: Bundle = .main) -> String {
        if let configured = bundle.object(forInfoDictionaryKey: "PinGateGitHubRepository") as? String {
            let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return defaultRepository
    }

    public static func currentAppVersion(bundle: Bundle = .main) -> SemanticVersion {
        if let raw = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           let parsed = SemanticVersion(string: raw) {
            return parsed
        }
        return SemanticVersion(string: fallbackVersionString) ?? SemanticVersion(major: 0, minor: 1, patch: 0)
    }

    public init(
        repository: String = AppUpdater.resolvedDefaultRepository(),
        configStore: ConfigStore = ConfigStore(),
        sessionFactory: (@Sendable (OutletConfig?) -> URLSession)? = nil
    ) {
        self.repository = repository
        self.configStore = configStore
        self.sessionFactory = sessionFactory ?? { outlet in
            Self.makeURLSession(proxyOutlet: outlet)
        }
    }

    public func latestReleaseAPIURL() throws -> URL {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw AppUpdaterError.networkFailed("无效的仓库地址：\(repository)")
        }
        return url
    }

    public func fetchLatestRelease(proxyOutlet: OutletConfig? = nil) async throws -> ReleaseInfo {
        let apiURL = try latestReleaseAPIURL()
        var request = URLRequest(url: apiURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("PinGate/\(Self.currentAppVersion().description)", forHTTPHeaderField: "User-Agent")

        let (data, httpResponse) = try await performDataWithFallback(request: request, proxyOutlet: proxyOutlet)
        if httpResponse.statusCode == 404 {
            throw AppUpdaterError.noReleasesPublished
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw AppUpdaterError.networkFailed("GitHub API 返回 HTTP \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let dto: GitHubReleaseDTO
        do {
            dto = try decoder.decode(GitHubReleaseDTO.self, from: data)
        } catch {
            throw AppUpdaterError.networkFailed("解析发布信息失败：\(error.localizedDescription)")
        }

        guard let version = SemanticVersion(string: dto.tagName) else {
            throw AppUpdaterError.invalidVersion(dto.tagName)
        }
        guard let htmlURL = URL(string: dto.htmlURL) else {
            throw AppUpdaterError.networkFailed("发布页面链接无效")
        }

        // Prefer PinGate-*-arm64.zip, then any .zip
        let zipAsset = dto.assets.first(where: {
            $0.name.lowercased().hasSuffix("-arm64.zip")
        }) ?? dto.assets.first(where: {
            $0.name.lowercased().hasSuffix(".zip")
        })

        guard let zipAsset, let zipURL = URL(string: zipAsset.browserDownloadURL) else {
            throw AppUpdaterError.missingAsset("未找到 arm64 ZIP 安装包（PinGate-\(dto.tagName)-arm64.zip）")
        }

        let checksumAsset = dto.assets.first(where: {
            $0.name.caseInsensitiveCompare("SHA256SUMS.txt") == .orderedSame ||
            $0.name.lowercased().contains("sha256")
        })
        let checksumURL = checksumAsset.flatMap { URL(string: $0.browserDownloadURL) }

        return ReleaseInfo(
            tagName: dto.tagName,
            version: version,
            title: (dto.name?.isEmpty == false ? dto.name! : dto.tagName),
            releaseNotes: dto.body ?? "",
            htmlURL: htmlURL,
            publishedAt: dto.publishedAt,
            zipAssetName: zipAsset.name,
            zipDownloadURL: zipURL,
            zipSizeBytes: zipAsset.size,
            checksumsAssetURL: checksumURL
        )
    }

    public func checkForUpdates(
        currentVersion: SemanticVersion = AppUpdater.currentAppVersion(),
        proxyOutlet: OutletConfig? = nil
    ) async throws -> UpdateCheckResult {
        do {
            let latest = try await fetchLatestRelease(proxyOutlet: proxyOutlet)
            if latest.version > currentVersion {
                return .updateAvailable(currentVersion: currentVersion, release: latest)
            }
            return .upToDate(currentVersion: currentVersion, latestRelease: latest)
        } catch AppUpdaterError.noReleasesPublished {
            return .upToDate(currentVersion: currentVersion, latestRelease: nil)
        }
    }

    public static func parseSHA256Sums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { continue }
            let hash = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            var fileName = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            if fileName.hasPrefix("*") {
                fileName.removeFirst()
            }
            if fileName.hasPrefix("./") {
                fileName.removeFirst(2)
            }
            let baseName = URL(fileURLWithPath: fileName).lastPathComponent
            result[fileName] = hash
            result[baseName] = hash
        }
        return result
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
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads `SHA256SUMS.txt` and the release ZIP into `~/Library/Application Support/PinGate/updates/` (0700),
    /// verifies SHA-256 via CryptoKit, extracts with `ditto -xk`, and validates the `.app` bundle & codesign signature.
    public func downloadAndVerify(
        release: ReleaseInfo,
        proxyOutlet: OutletConfig? = nil,
        verifyCodeSign: Bool = true,
        onProgress: (@Sendable (UpdateProgress) -> Void)? = nil
    ) async throws -> PreparedUpdate {
        try ensureUpdatesDirectory()

        guard let checksumsURL = release.checksumsAssetURL else {
            throw AppUpdaterError.checksumMissing(assetName: release.zipAssetName)
        }

        // 1. Download and parse SHA256SUMS.txt
        var checksumReq = URLRequest(url: checksumsURL, timeoutInterval: 30)
        checksumReq.setValue("PinGate/\(Self.currentAppVersion().description)", forHTTPHeaderField: "User-Agent")
        let (checksumData, checksumResp) = try await performDataWithFallback(request: checksumReq, proxyOutlet: proxyOutlet)
        guard (200...299).contains(checksumResp.statusCode),
              let checksumText = String(data: checksumData, encoding: .utf8) else {
            throw AppUpdaterError.networkFailed("下载校验文件失败（HTTP \(checksumResp.statusCode)）")
        }
        let checksumMap = Self.parseSHA256Sums(checksumText)
        guard let expectedHash = checksumMap[release.zipAssetName] else {
            throw AppUpdaterError.checksumMissing(assetName: release.zipAssetName)
        }

        // 2. Create private 0700 staging directory under updates/
        let fm = FileManager.default
        let safeTag = release.tagName.replacingOccurrences(of: "/", with: "_")
        let stagingDir = updatesDirectory.appendingPathComponent("\(safeTag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try ConfigStore.setPosixPermissions(0o700, at: stagingDir)

        let archiveURL = stagingDir.appendingPathComponent(release.zipAssetName, isDirectory: false)
        let extractDir = stagingDir.appendingPathComponent("extracted", isDirectory: true)
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        try ConfigStore.setPosixPermissions(0o700, at: extractDir)

        // 3. Download ZIP archive with progress reporting
        var zipReq = URLRequest(url: release.zipDownloadURL, timeoutInterval: 300)
        zipReq.setValue("PinGate/\(Self.currentAppVersion().description)", forHTTPHeaderField: "User-Agent")
        try await downloadFileWithFallback(
            request: zipReq,
            destinationURL: archiveURL,
            expectedTotalBytes: release.zipSizeBytes ?? -1,
            proxyOutlet: proxyOutlet,
            onProgress: onProgress
        )
        try ConfigStore.setPosixPermissions(0o600, at: archiveURL)

        // 4. Verify SHA-256 checksum
        onProgress?(.verifyingChecksum)
        let actualHash = try sha256Hex(of: archiveURL)
        guard actualHash == expectedHash else {
            try? fm.removeItem(at: stagingDir)
            throw AppUpdaterError.checksumMismatch(expected: expectedHash, actual: actualHash)
        }

        // 5. Extract ZIP using ditto -xk
        onProgress?(.extracting)
        try runProcess(
            executable: "/usr/bin/ditto",
            arguments: ["-xk", archiveURL.path, extractDir.path],
            errorMapper: { AppUpdaterError.extractionFailed($0) }
        )

        // 6. Locate and validate .app bundle
        let stagedAppURL = try locateAppBundle(in: extractDir)
        let infoPlistURL = stagedAppURL.appendingPathComponent("Contents/Info.plist")
        let macOSDirURL = stagedAppURL.appendingPathComponent("Contents/MacOS")
        guard fm.fileExists(atPath: infoPlistURL.path), fm.fileExists(atPath: macOSDirURL.path) else {
            try? fm.removeItem(at: stagingDir)
            throw AppUpdaterError.invalidAppBundle("缺少 Contents/Info.plist 或 Contents/MacOS")
        }

        // 7. Verify codesign integrity
        if verifyCodeSign {
            onProgress?(.verifyingSignature)
            try runProcess(
                executable: "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", stagedAppURL.path],
                errorMapper: { AppUpdaterError.signatureVerificationFailed($0) }
            )
        }

        onProgress?(.readyToInstall(stagedAppURL: stagedAppURL))
        return PreparedUpdate(
            release: release,
            archiveURL: archiveURL,
            stagingDirectory: stagingDir,
            stagedAppURL: stagedAppURL,
            verifiedSHA256: actualHash
        )
    }

    /// Creates a `0600` pre-update backup of `config.json` before applying an update.
    @discardableResult
    public func backupConfigIfPresent() throws -> URL? {
        guard configStore.configExists() else { return nil }
        let backupURL = configStore.baseDirectory.appendingPathComponent("config.json.pre-update.bak", isDirectory: false)
        let data = try Data(contentsOf: configStore.configFileURL)
        try ConfigStore.atomicWrite(data: data, to: backupURL, posixPermissions: 0o600)
        return backupURL
    }

    /// Generates and spawns a detached, self-cleaning update helper script inside `prepared.stagingDirectory`
    /// (never `/tmp`). The script backs up config, waits for `waitForPID` (if provided) to exit, moves the old
    /// `.app` to `~/.Trash`, installs the verified new `.app`, clears quarantine, syncs `~/.local/bin/pingate`
    /// from `Contents/Resources/bin/pingate`, relaunches the app, and removes the staging directory.
    @discardableResult
    public func scheduleSelfUpdate(
        prepared: PreparedUpdate,
        targetAppURL: URL = URL(fileURLWithPath: "/Applications/PinGate.app"),
        installCLITo: URL? = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pingate"),
        waitForPID: Int32? = getpid(),
        relaunchApp: Bool = true
    ) throws -> URL {
        _ = try backupConfigIfPresent()
        let scriptContent = Self.renderUpdateScript(
            stagedAppPath: prepared.stagedAppURL.path,
            targetAppPath: targetAppURL.path,
            stagingDirectoryPath: prepared.stagingDirectory.path,
            cliInstallPath: installCLITo?.path,
            waitForPID: waitForPID,
            relaunchApp: relaunchApp
        )

        let scriptURL = prepared.stagingDirectory.appendingPathComponent("apply-update.sh", isDirectory: false)
        guard let scriptData = scriptContent.data(using: .utf8) else {
            throw AppUpdaterError.installScriptFailed("无法编码安装脚本")
        }
        try ConfigStore.atomicWrite(data: scriptData, to: scriptURL, posixPermissions: 0o700)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
        launcher.arguments = ["-c", "nohup /bin/bash \(Self.shellQuote(scriptURL.path)) >/dev/null 2>&1 </dev/null &"]
        do {
            try launcher.run()
            launcher.waitUntilExit()
        } catch {
            throw AppUpdaterError.installScriptFailed(error.localizedDescription)
        }
        guard launcher.terminationStatus == 0 else {
            throw AppUpdaterError.installScriptFailed("启动器退出码 \(launcher.terminationStatus)")
        }
        return scriptURL
    }

    /// Renders the atomic self-update shell script (exposed internally/publicly for testing).
    public static func renderUpdateScript(
        stagedAppPath: String,
        targetAppPath: String,
        stagingDirectoryPath: String,
        cliInstallPath: String?,
        waitForPID: Int32?,
        relaunchApp: Bool
    ) -> String {
        let waitBlock: String
        if let pid = waitForPID, pid > 0 {
            waitBlock = """
            WAIT_PID=\(pid)
            for _ in $(seq 1 120); do
              if ! kill -0 "$WAIT_PID" 2>/dev/null; then
                break
              fi
              sleep 0.25
            done
            """
        } else {
            waitBlock = "# No PID wait requested"
        }

        let cliBlock: String
        if let cliPath = cliInstallPath, !cliPath.isEmpty {
            cliBlock = """
            BUNDLED_CLI="$TARGET_APP/Contents/Resources/bin/pingate"
            if [ -x "$BUNDLED_CLI" ]; then
              CLI_DEST=\(shellQuote(cliPath))
              mkdir -p "$(dirname "$CLI_DEST")"
              TMP_CLI="${CLI_DEST}.tmp.$$"
              cp "$BUNDLED_CLI" "$TMP_CLI"
              chmod 0755 "$TMP_CLI"
              mv -f "$TMP_CLI" "$CLI_DEST"
            fi
            """
        } else {
            cliBlock = "# CLI sync disabled"
        }

        let relaunchBlock = relaunchApp
            ? """
            /usr/bin/open "$TARGET_APP" >/dev/null 2>&1 || true
            """
            : "# Relaunch disabled"

        return """
        #!/bin/bash
        set -euo pipefail

        STAGED_APP=\(shellQuote(stagedAppPath))
        TARGET_APP=\(shellQuote(targetAppPath))
        STAGING_DIR=\(shellQuote(stagingDirectoryPath))

        cleanup() {
          rm -rf "$STAGING_DIR" 2>/dev/null || true
        }
        trap cleanup EXIT

        \(waitBlock)

        if [ ! -d "$STAGED_APP" ]; then
          exit 1
        fi

        TARGET_PARENT="$(dirname "$TARGET_APP")"
        mkdir -p "$TARGET_PARENT"

        if [ -e "$TARGET_APP" ]; then
          TRASH_DIR="$HOME/.Trash"
          mkdir -p "$TRASH_DIR"
          STAMP="$(date +%Y%m%d-%H%M%S)"
          TRASH_DEST="$TRASH_DIR/PinGate-previous-${STAMP}.app"
          if [ -e "$TRASH_DEST" ]; then
            TRASH_DEST="$TRASH_DIR/PinGate-previous-${STAMP}-$$.app"
          fi
          mv "$TARGET_APP" "$TRASH_DEST"
        fi

        mv "$STAGED_APP" "$TARGET_APP"
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true

        \(cliBlock)

        \(relaunchBlock)
        """
    }

    // MARK: - Internal Helpers

    private func ensureUpdatesDirectory() throws {
        try configStore.ensureDirectories()
        let fm = FileManager.default
        if !fm.fileExists(atPath: updatesDirectory.path) {
            try fm.createDirectory(at: updatesDirectory, withIntermediateDirectories: true)
        }
        try ConfigStore.setPosixPermissions(0o700, at: updatesDirectory)
    }

    private func performDataWithFallback(
        request: URLRequest,
        proxyOutlet: OutletConfig?
    ) async throws -> (Data, HTTPURLResponse) {
        if let outlet = proxyOutlet, outlet.enabled {
            let proxySession = sessionFactory(outlet)
            defer { proxySession.finishTasksAndInvalidate() }
            if let result = try? await executeData(request: request, session: proxySession) {
                return result
            }
        }
        let directSession = sessionFactory(nil)
        defer { directSession.finishTasksAndInvalidate() }
        return try await executeData(request: request, session: directSession)
    }

    private func executeData(request: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw AppUpdaterError.networkFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdaterError.networkFailed("收到非 HTTP 响应")
        }
        return (data, http)
    }

    private func downloadFileWithFallback(
        request: URLRequest,
        destinationURL: URL,
        expectedTotalBytes: Int64,
        proxyOutlet: OutletConfig?,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws {
        if let outlet = proxyOutlet, outlet.enabled {
            let proxySession = sessionFactory(outlet)
            defer { proxySession.finishTasksAndInvalidate() }
            if (try? await executeDownload(
                request: request,
                destinationURL: destinationURL,
                expectedTotalBytes: expectedTotalBytes,
                session: proxySession,
                onProgress: onProgress
            )) != nil {
                return
            }
        }
        let directSession = sessionFactory(nil)
        defer { directSession.finishTasksAndInvalidate() }
        try await executeDownload(
            request: request,
            destinationURL: destinationURL,
            expectedTotalBytes: expectedTotalBytes,
            session: directSession,
            onProgress: onProgress
        )
    }

    private func executeDownload(
        request: URLRequest,
        destinationURL: URL,
        expectedTotalBytes: Int64,
        session: URLSession,
        onProgress: (@Sendable (UpdateProgress) -> Void)?
    ) async throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destinationURL)
        fm.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )

        let handle = try FileHandle(forWritingTo: destinationURL)
        defer { try? handle.close() }

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch {
            throw AppUpdaterError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppUpdaterError.networkFailed("收到非 HTTP 下载响应")
        }
        guard (200...299).contains(http.statusCode) else {
            throw AppUpdaterError.networkFailed("安装包下载返回 HTTP \(http.statusCode)")
        }

        let totalBytes = http.expectedContentLength > 0 ? http.expectedContentLength : expectedTotalBytes
        var receivedBytes: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(65536)
        var lastReportedBytes: Int64 = 0

        onProgress?(.downloading(fractionCompleted: 0, receivedBytes: 0, totalBytes: totalBytes))

        do {
            for try await byte in asyncBytes {
                buffer.append(byte)
                if buffer.count >= 65536 {
                    try handle.write(contentsOf: buffer)
                    receivedBytes += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if receivedBytes - lastReportedBytes >= 131072 {
                        lastReportedBytes = receivedBytes
                        let fraction = totalBytes > 0 ? min(Double(receivedBytes) / Double(totalBytes), 1.0) : 0
                        onProgress?(.downloading(fractionCompleted: fraction, receivedBytes: receivedBytes, totalBytes: totalBytes))
                    }
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                receivedBytes += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: false)
            }
            try handle.synchronize()
            onProgress?(.downloading(fractionCompleted: 1.0, receivedBytes: receivedBytes, totalBytes: max(totalBytes, receivedBytes)))
        } catch {
            throw AppUpdaterError.networkFailed(error.localizedDescription)
        }
    }

    private func locateAppBundle(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let direct = directory.appendingPathComponent("PinGate.app", isDirectory: true)
        if fm.fileExists(atPath: direct.path) {
            return direct
        }
        let items = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        if let app = items.first(where: { $0.pathExtension.lowercased() == "app" }) {
            return app
        }
        throw AppUpdaterError.invalidAppBundle("解压目录中未找到 .app 应用包")
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        errorMapper: (String) -> AppUpdaterError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw errorMapper(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw errorMapper(errText.isEmpty ? "退出码 \(process.terminationStatus)" : errText)
        }
    }

    private static func makeURLSession(proxyOutlet: OutletConfig?) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let outlet = proxyOutlet {
            config.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: true,
                kCFNetworkProxiesHTTPProxy as String: outlet.listenHost,
                kCFNetworkProxiesHTTPPort as String: outlet.listenPort,
                kCFNetworkProxiesHTTPSEnable as String: true,
                kCFNetworkProxiesHTTPSProxy as String: outlet.listenHost,
                kCFNetworkProxiesHTTPSPort as String: outlet.listenPort
            ]
        }
        return URLSession(configuration: config)
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    // MARK: - GitHub API DTOs

    private struct GitHubReleaseDTO: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let publishedAt: Date?
        let assets: [GitHubAssetDTO]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct GitHubAssetDTO: Decodable {
        let name: String
        let browserDownloadURL: String
        let size: Int64?

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case size
        }
    }
}
