import AppKit
import Darwin
import Foundation

/// Outcome of attempting to launch or focus a managed GUI application through PinGate.
public enum AppLaunchOutcome: Sendable, Equatable {
    case launched(pid: Int32?, targetName: String, outletPort: Int)
    case activatedExisting(pids: [Int32], targetName: String)
    case runningWithoutProxy(pids: [Int32], targetName: String, expectedPort: Int)
    case restartedWithProxy(terminatedPIDs: [Int32], newPID: Int32?, targetName: String, outletPort: Int)
    case blockedPortClosed(host: String, port: Int, targetName: String)

    public var isProtectedOutcome: Bool {
        switch self {
        case .launched, .activatedExisting, .restartedWithProxy:
            return true
        case .runningWithoutProxy, .blockedPortClosed:
            return false
        }
    }
}

public enum AppLaunchError: Error, LocalizedError, Sendable {
    case unsupportedTargetKind(String)
    case missingAppPath(String)
    case appNotFound(String)
    case failedToTerminateExisting([Int32])
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTargetKind(let name):
            return "应用「\(name)」不是桌面应用。"
        case .missingAppPath(let name):
            return "应用「\(name)」未配置应用路径（appPath）。"
        case .appNotFound(let path):
            return "未在 \(path) 找到应用程序包。"
        case .failedToTerminateExisting(let pids):
            return "无法结束未走代理的已有进程（PID：\(pids.map(String.init).joined(separator: ", "))）。"
        case .launchFailed(let message):
            return "启动应用失败：\(message)"
        }
    }
}

/// Pure, inspectable launch specification built prior to invoking `NSWorkspace`.
public struct LaunchPlan: Sendable, Equatable {
    public let appURL: URL
    public let environment: [String: String]
    public let arguments: [String]

    public init(appURL: URL, environment: [String: String], arguments: [String]) {
        self.appURL = appURL
        self.environment = environment
        self.arguments = arguments
    }
}

/// Launches managed GUI applications with full proxy environment injection, Chromium proxy flags,
/// Fail-Closed port gating, and smart already-running detection via `DarwinProcessInspector`.
public struct AppLauncher: Sendable {
    public let inspector: any ProcessInspecting

    public init(inspector: any ProcessInspecting = DarwinProcessInspector()) {
        self.inspector = inspector
    }

    /// Builds the complete set of proxy environment variables (upper/lower case pairs + `NODE_USE_ENV_PROXY=1`).
    public static func buildProxyEnvironment(
        outlet: OutletConfig,
        bypassRules: BypassRules,
        extraEnv: [String: String] = [:]
    ) -> [String: String] {
        let httpProxy = outlet.proxyURLString
        let socksProxy = "socks5h://\(outlet.listenHost):\(outlet.listenPort)"
        let noProxy = bypassRules.noProxyCSV()

        var env: [String: String] = [
            "HTTP_PROXY": httpProxy,
            "HTTPS_PROXY": httpProxy,
            "http_proxy": httpProxy,
            "https_proxy": httpProxy,
            "ALL_PROXY": socksProxy,
            "all_proxy": socksProxy,
            "NO_PROXY": noProxy,
            "no_proxy": noProxy,
            "NODE_USE_ENV_PROXY": "1"
        ]

        for (key, value) in extraEnv where !key.trimmingCharacters(in: .whitespaces).isEmpty {
            env[key] = value
        }
        return env
    }

    /// Builds Chromium/Electron proxy flags synchronized with `BypassRules` and disabling QUIC.
    public static func buildChromiumArguments(
        outlet: OutletConfig,
        bypassRules: BypassRules
    ) -> [String] {
        let bypassList = bypassRules.chromiumBypassList()
        var args: [String] = [
            "--proxy-server=\(outlet.proxyURLString)",
            "--disable-quic"
        ]
        if !bypassList.isEmpty {
            args.insert("--proxy-bypass-list=\(bypassList)", at: 1)
        }
        return args
    }

    /// Constructs a validated `LaunchPlan` without side effects (ideal for unit testing and previews).
    public static func buildLaunchPlan(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        verifyExists: Bool = true
    ) throws -> LaunchPlan {
        guard target.kind == .guiApp else {
            throw AppLaunchError.unsupportedTargetKind(target.name)
        }
        guard let rawPath = target.appPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            throw AppLaunchError.missingAppPath(target.name)
        }

        let expandedPath = NSString(string: rawPath).expandingTildeInPath
        if verifyExists && !FileManager.default.fileExists(atPath: expandedPath) {
            throw AppLaunchError.appNotFound(expandedPath)
        }

        let env = buildProxyEnvironment(
            outlet: outlet,
            bypassRules: bypassRules,
            extraEnv: target.extraEnv
        )
        let args = target.chromiumProxyFlags
            ? buildChromiumArguments(outlet: outlet, bypassRules: bypassRules)
            : []

        return LaunchPlan(
            appURL: URL(fileURLWithPath: expandedPath),
            environment: env,
            arguments: args
        )
    }

    /// Evaluates already-running processes for `target` to decide whether the app is unlaunched,
    /// already properly proxied, or running without the expected proxy (e.g. after Squirrel auto-update).
    public func inspectRunningState(
        target: ManagedTarget,
        outlet: OutletConfig
    ) -> (proxiedPIDs: [Int32], unproxiedPIDs: [Int32]) {
        let matched = inspector.inspectAllProcesses(
            matching: { name, path in
                LeakAuditor.matchTarget(name: name, executablePath: path, in: [target]) != nil
            },
            includeSockets: false,
            includeEnvironment: true
        )

        var proxied: [Int32] = []
        var unproxied: [Int32] = []

        for proc in matched {
            let eval = LeakAuditor.evaluateProxyEnvironment(
                proc.environment,
                expectedPort: outlet.listenPort,
                expectedHost: outlet.listenHost,
                arguments: proc.arguments
            )
            switch eval.status {
            case .valid:
                proxied.append(proc.pid)
            case .missing, .wrongPort:
                unproxied.append(proc.pid)
            case .unreadable:
                // Treat unreadable helper conservatively if no other info exists.
                unproxied.append(proc.pid)
            }
        }

        return (proxied.sorted(), unproxied.sorted())
    }

    /// Launches a managed GUI application through `NSWorkspace.OpenConfiguration`.
    /// - Enforces Fail-Closed when `policy.failClosedOnPortDown` is `true` and the outlet port is closed.
    /// - Activates existing window if already running with valid proxy env.
    /// - Returns `.runningWithoutProxy` if already running without proxy (unless `forceRestart` is `true`).
    public func launch(
        target: ManagedTarget,
        outlet: OutletConfig,
        bypassRules: BypassRules,
        policy: AuditPolicy = AuditPolicy(),
        forceRestart: Bool = false
    ) async throws -> AppLaunchOutcome {
        let plan = try Self.buildLaunchPlan(
            target: target,
            outlet: outlet,
            bypassRules: bypassRules,
            verifyExists: true
        )

        // 1. Fail-Closed guard: never launch if local outlet port is down.
        if policy.failClosedOnPortDown {
            let listening = inspector.isLocalPortListening(
                host: outlet.listenHost,
                port: outlet.listenPort,
                timeout: 0.5
            )
            if !listening {
                return .blockedPortClosed(
                    host: outlet.listenHost,
                    port: outlet.listenPort,
                    targetName: target.name
                )
            }
        }

        // 2. Smart already-running check via DarwinProcessInspector.
        let running = inspectRunningState(target: target, outlet: outlet)
        let allRunningPIDs = (running.proxiedPIDs + running.unproxiedPIDs).sorted()

        if !allRunningPIDs.isEmpty {
            if !running.unproxiedPIDs.isEmpty {
                guard forceRestart else {
                    return .runningWithoutProxy(
                        pids: running.unproxiedPIDs,
                        targetName: target.name,
                        expectedPort: outlet.listenPort
                    )
                }
                let terminated = try await terminateExisting(target: target, pids: allRunningPIDs)
                let newPID = try await openApplication(plan: plan)
                return .restartedWithProxy(
                    terminatedPIDs: terminated,
                    newPID: newPID,
                    targetName: target.name,
                    outletPort: outlet.listenPort
                )
            } else if !forceRestart {
                await activateApplications(bundleID: target.bundleID, pids: running.proxiedPIDs)
                return .activatedExisting(pids: running.proxiedPIDs, targetName: target.name)
            } else {
                let terminated = try await terminateExisting(target: target, pids: allRunningPIDs)
                let newPID = try await openApplication(plan: plan)
                return .restartedWithProxy(
                    terminatedPIDs: terminated,
                    newPID: newPID,
                    targetName: target.name,
                    outletPort: outlet.listenPort
                )
            }
        }

        // 3. Fresh launch with injected proxy environment and Chromium flags.
        let pid = try await openApplication(plan: plan)
        return .launched(pid: pid, targetName: target.name, outletPort: outlet.listenPort)
    }

    @MainActor
    private func openApplication(plan: LaunchPlan) async throws -> Int32? {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        config.createsNewApplicationInstance = false
        config.environment = plan.environment
        config.arguments = plan.arguments

        do {
            let app = try await NSWorkspace.shared.openApplication(at: plan.appURL, configuration: config)
            return app.processIdentifier > 0 ? app.processIdentifier : nil
        } catch {
            throw AppLaunchError.launchFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func activateApplications(bundleID: String?, pids: [Int32]) {
        if let bundleID, !bundleID.isEmpty {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let first = apps.first {
                first.activate()
                return
            }
        }
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate()
                return
            }
        }
    }

    private func terminateExisting(target: ManagedTarget, pids: [Int32]) async throws -> [Int32] {
        // First ask NSRunningApplication to terminate gracefully on MainActor.
        await MainActor.run {
            if let bundleID = target.bundleID, !bundleID.isEmpty {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                    app.terminate()
                }
            }
            for pid in pids {
                NSRunningApplication(processIdentifier: pid)?.terminate()
            }
        }

        // Wait up to 4 seconds for graceful exit.
        if await waitForExit(pids: pids, timeoutSeconds: 4.0) {
            return pids
        }

        // Send SIGTERM to remaining processes.
        for pid in pids where kill(pid, 0) == 0 {
            _ = kill(pid, SIGTERM)
        }
        if await waitForExit(pids: pids, timeoutSeconds: 2.0) {
            return pids
        }

        // Force-terminate stubborn processes so restart can proceed cleanly.
        for pid in pids where kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
        if await waitForExit(pids: pids, timeoutSeconds: 2.0) {
            return pids
        }

        let remaining = pids.filter { kill($0, 0) == 0 }
        throw AppLaunchError.failedToTerminateExisting(remaining)
    }

    private func waitForExit(pids: [Int32], timeoutSeconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            let anyAlive = pids.contains { kill($0, 0) == 0 }
            if !anyAlive {
                return true
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return !pids.contains { kill($0, 0) == 0 }
    }
}
