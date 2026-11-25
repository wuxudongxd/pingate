import Darwin
import Foundation
import PinGateCore

// MARK: - CLI Argument Helpers

struct ParsedCLI {
    let configDir: URL?
    let jsonOutput: Bool
    let command: String
    let args: [String]
}

func parseGlobalArguments(_ rawArgs: [String]) -> ParsedCLI {
    var configDir: URL? = nil
    if let envDir = ProcessInfo.processInfo.environment["PINGATE_CONFIG_DIR"],
       !envDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let expanded = NSString(string: envDir).expandingTildeInPath
        configDir = URL(fileURLWithPath: expanded, isDirectory: true)
    }

    var jsonOutput = false
    var remaining: [String] = []
    var i = 0
    while i < rawArgs.count {
        let arg = rawArgs[i]
        if arg == "--config-dir", i + 1 < rawArgs.count {
            let expanded = NSString(string: rawArgs[i + 1]).expandingTildeInPath
            configDir = URL(fileURLWithPath: expanded, isDirectory: true)
            i += 2
            continue
        }
        if arg.hasPrefix("--config-dir=") {
            let value = String(arg.dropFirst("--config-dir=".count))
            let expanded = NSString(string: value).expandingTildeInPath
            configDir = URL(fileURLWithPath: expanded, isDirectory: true)
            i += 1
            continue
        }
        if arg == "--json" {
            jsonOutput = true
            i += 1
            continue
        }
        remaining.append(arg)
        i += 1
    }

    let command = remaining.first ?? "help"
    let subArgs = remaining.count > 1 ? Array(remaining.dropFirst()) : []
    return ParsedCLI(configDir: configDir, jsonOutput: jsonOutput, command: command, args: subArgs)
}

func makeConfigStore(configDir: URL?) -> ConfigStore {
    if let configDir {
        return ConfigStore(baseDirectory: configDir)
    }
    return ConfigStore()
}

func loadConfig(store: ConfigStore) throws -> PinGateConfig {
    if store.configExists() {
        return try store.load()
    }
    return try store.loadOrBootstrap()
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    if let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func findTarget(named query: String, in config: PinGateConfig, kind: TargetKind? = nil) -> ManagedTarget? {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let candidates = config.targets.filter { target in
        if let kind, target.kind != kind { return false }
        return true
    }

    return candidates.first { target in
        target.name.lowercased() == needle ||
        target.id.uuidString.lowercased() == needle ||
        (target.cliCommandName?.lowercased() == needle) ||
        (target.bundleID?.lowercased() == needle) ||
        (target.t3ProviderKey?.lowercased() == needle)
    } ?? candidates.first { target in
        target.name.lowercased().contains(needle)
    }
}

func printUsage() {
    print("""
    PinGate CLI — Application-level Fixed Outlet & Leak Guard

    USAGE:
      pingate [--config-dir <dir>] [--json] <command> [options]

    COMMANDS:
      status [--no-probe]                   Show outlets, active proxy, exit IP, targets, and audit health
      audit [--verbose]                     Audit live target processes & TCP sockets (exit 0=protected, 2=leaking, 3=stopped)
      sync [--no-reload] [--apply-targets]  Sync & render 0600 Mihomo configs (and hot-reload running controller)
      launch <target> [--force-restart]     Launch a GUI app with injected proxy env & Chromium flags (Fail-Closed)
      shim install <target> [--dir <dir>] [--force]
      shim remove  <target> [--dir <dir>] [--force]
      shim status  [target] [--dir <dir>]
      t3 sync [target]                      Sync T3 Code provider environment in settings.json (with .bak backup)
      t3 status [target]                    Check whether T3 Code provider environment is in sync
      update [--check|--apply] [--force]    Check or apply PinGate updates from GitHub Releases (SHA-256 verified)
      help                                  Show this help message
    """)
}

// MARK: - Subcommands

struct StatusOutletReport: Codable {
    let name: String
    let listenAddress: String
    let listening: Bool
    let controllerReachable: Bool
    let mihomoVersion: String?
    let activeNode: String?
    let exitProbe: ExitProbeResult?
}

struct StatusReport: Codable {
    let configPath: String
    let captureMode: CaptureMode
    let outlets: [StatusOutletReport]
    let audit: AuditSnapshot
}

func runStatus(store: ConfigStore, args: [String], jsonOutput: Bool) async -> Int32 {
    let noProbe = args.contains("--no-probe")
    do {
        let config = try loadConfig(store: store)
        let inspector = DarwinProcessInspector()
        let auditor = LeakAuditor(inspector: inspector)
        let prober = ExitIPProber(timeoutSeconds: min(config.auditPolicy.probeTimeoutSeconds, 5.0))
        let shimManager = CLIShimManager()
        let t3Adapter = T3CodeSyncAdapter()

        var outletReports: [StatusOutletReport] = []
        var primaryRunning = false

        for outlet in config.outlets {
            let listening = inspector.isLocalPortListening(
                host: outlet.listenHost,
                port: outlet.listenPort,
                timeout: 0.5
            )
            if outlet.id == config.primaryOutlet()?.id {
                primaryRunning = listening
            }

            let apiClient = MihomoAPIClient(outlet: outlet)
            var versionStr: String? = nil
            var activeNode: String? = nil
            var controllerReachable = false

            if let ver = try? await apiClient.version(timeout: 1.5) {
                controllerReachable = true
                versionStr = ver.version
                if let proxies = try? await apiClient.proxies(timeout: 1.5),
                   let group = proxies[MihomoConfigRenderer.outletGroupName] {
                    activeNode = group.now
                }
            }

            var probeResult: ExitProbeResult? = nil
            if listening && !noProbe {
                probeResult = try? await prober.probe(outlet: outlet)
            }

            outletReports.append(
                StatusOutletReport(
                    name: outlet.name,
                    listenAddress: "\(outlet.listenHost):\(outlet.listenPort)",
                    listening: listening,
                    controllerReachable: controllerReachable,
                    mihomoVersion: versionStr,
                    activeNode: activeNode,
                    exitProbe: probeResult
                )
            )
        }

        let auditSnapshot = auditor.audit(config: config, outletRunningOverride: primaryRunning)

        if jsonOutput {
            let report = StatusReport(
                configPath: store.configFileURL.path,
                captureMode: config.captureMode,
                outlets: outletReports,
                audit: auditSnapshot
            )
            try printJSON(report)
            return 0
        }

        print("PinGate Status")
        print("  Config:       \(store.configFileURL.path)")
        print("  Capture Mode: \(config.captureMode.displayName)")
        print("  Health:       \(healthBadge(auditSnapshot.overallState)) — \(auditSnapshot.summary)")
        print("")
        print("Outlets:")
        for report in outletReports {
            let stateLabel = report.listening ? "LISTENING" : "STOPPED"
            print("  - \(report.name) [\(report.listenAddress)] : \(stateLabel)")
            if report.controllerReachable {
                let ver = report.mihomoVersion ?? "unknown"
                let node = report.activeNode ?? "n/a"
                print("    Controller: reachable (mihomo \(ver)), active node: \(node)")
            } else {
                print("    Controller: unreachable")
            }
            if let exit = report.exitProbe {
                let geo = [exit.country, exit.region, exit.city].compactMap { $0 }.joined(separator: ", ")
                let org = exit.org.map { " | \($0)" } ?? ""
                print("    Exit IP:    \(exit.ip)\(geo.isEmpty ? "" : " (\(geo))")\(org) via \(exit.provider) (\(exit.latencyMs)ms)")
            }
        }

        print("")
        print("Targets:")
        for target in config.targets {
            let outletPort = (config.outlet(id: target.outletID) ?? config.primaryOutlet())?.listenPort ?? 0
            switch target.kind {
            case .guiApp:
                let matchingProcs = auditSnapshot.processes.filter { $0.targetID == target.id }
                let leakCount = matchingProcs.filter(\.isLeaking).count
                let statusText: String
                if matchingProcs.isEmpty {
                    statusText = "not running"
                } else if leakCount > 0 {
                    statusText = "LEAKING (\(leakCount)/\(matchingProcs.count) process(es))"
                } else {
                    statusText = "protected (\(matchingProcs.count) process(es))"
                }
                print("  - [GUI] \(target.name) (port \(outletPort)): \(statusText)")

            case .cliTool:
                let st = shimManager.status(for: target)
                let portInfo = st.configuredPort.map { "port \($0)" } ?? "unknown port"
                let state = st.isInstalled && st.isManagedByPinGate
                    ? "shim installed (\(portInfo)) at \(st.shimPath)"
                    : "shim not installed"
                print("  - [CLI] \(target.name): \(state)")

            case .t3Integration:
                if let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() {
                    let synced = t3Adapter.isInSync(target: target, outlet: outlet, bypassRules: config.bypassRules)
                    let settingsPath = t3Adapter.resolveSettingsURL(for: target).path
                    print("  - [T3]  \(target.name) (\(target.t3ProviderKey ?? "antigravity")): \(synced ? "in sync" : "out of sync / missing") (\(settingsPath))")
                }
            }
        }

        return 0
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func runAudit(store: ConfigStore, args: [String], jsonOutput: Bool) -> Int32 {
    let verbose = args.contains("--verbose") || args.contains("-v")
    do {
        let config = try loadConfig(store: store)
        let auditor = LeakAuditor()
        let snapshot = auditor.audit(config: config)

        if jsonOutput {
            try printJSON(snapshot)
        } else {
            print("PinGate Leak Audit — \(healthBadge(snapshot.overallState))")
            print("  Summary: \(snapshot.summary)")
            print("  Outlet:  \(snapshot.outletRunning ? "LISTENING" : "STOPPED")")
            print("  Sockets: \(snapshot.totalProxiedSockets) proxied, \(snapshot.totalBypassSockets) bypass, \(snapshot.totalLeakSockets) leak")

            if !snapshot.processes.isEmpty {
                print("")
                print("Inspected Processes (\(snapshot.processes.count)):")
                for proc in snapshot.processes {
                    let flag = proc.isLeaking ? "LEAK" : "OK"
                    let envDesc = proc.proxyEnvStatus.displayName
                    print("  [\(flag)] PID \(proc.pid) \(proc.processName) (target: \(proc.targetName)) | env: \(envDesc) | proxied=\(proc.proxiedSocketCount) bypass=\(proc.bypassSocketCount) leak=\(proc.leakSockets.count)")
                    if verbose || proc.isLeaking {
                        if let hp = proc.observedHTTPSProxy {
                            print("         HTTPS_PROXY=\(hp)")
                        }
                        if let ap = proc.observedAllProxy {
                            print("         ALL_PROXY=\(ap)")
                        }
                        for sock in proc.sockets {
                            if verbose || sock.classification == .leak {
                                let detail = sock.reason.map { " (\($0))" } ?? ""
                                print("         [\(sock.classification.displayName)] \(sock.tcpState) \(sock.localAddress):\(sock.localPort) -> \(sock.remoteEndpoint)\(detail)")
                            }
                        }
                    }
                }
            }
        }

        switch snapshot.overallState {
        case .protected:
            return 0
        case .warning:
            return snapshot.totalLeakSockets > 0 ? 2 : 0
        case .leaking:
            return 2
        case .stopped:
            return 3
        }
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func runSync(store: ConfigStore, args: [String], jsonOutput: Bool) async -> Int32 {
    let noReload = args.contains("--no-reload")
    let applyTargets = args.contains("--apply-targets")
    do {
        let config = try loadConfig(store: store)
        let processManager = MihomoProcessManager(configStore: store)
        var results: [NodeSyncResult] = []

        for outlet in config.outlets where outlet.enabled {
            let result = try await processManager.syncAndRender(
                outlet: outlet,
                bypassRules: config.bypassRules,
                hotReloadIfRunning: !noReload
            )
            results.append(result)
        }

        var applyReport: InterceptorApplyReport? = nil
        if applyTargets {
            let interceptor = UserSpaceInterceptor()
            applyReport = try await interceptor.applyRules(config: config)
        }

        if jsonOutput {
            struct SyncOutput: Codable {
                let outlets: [NodeSyncResult]
                let targets: InterceptorApplyReport?
            }
            try printJSON(SyncOutput(outlets: results, targets: applyReport))
            return 0
        }

        for result in results {
            print("Synced outlet '\(result.outletName)':")
            print("  Primary Node:    \(result.primaryNode)")
            print("  Proxy Chain:     \(result.extractedProxyNames.joined(separator: ", "))")
            if !result.missingFallbackNodes.isEmpty {
                print("  Missing Fallbacks: \(result.missingFallbackNodes.joined(separator: ", "))")
            }
            print("  Rendered Config: \(result.renderedConfigPath)")
            print("  Live Reloaded:   \(result.reloadedLive ? "yes" : "no (controller not running or --no-reload)")")
        }

        if let applyReport {
            if !applyReport.syncedCLIShims.isEmpty {
                print("Updated CLI Shims: \(applyReport.syncedCLIShims.joined(separator: ", "))")
            }
            if !applyReport.syncedT3Targets.isEmpty {
                print("Synced T3 Targets: \(applyReport.syncedT3Targets.joined(separator: ", "))")
            }
            for warning in applyReport.warnings {
                print("Warning: \(warning)")
            }
        }
        return 0
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func runLaunch(store: ConfigStore, args: [String]) async -> Int32 {
    let forceRestart = args.contains("--force-restart")
    let positional = args.filter { !$0.hasPrefix("-") }
    guard let targetQuery = positional.first else {
        printError("Usage: pingate launch <target> [--force-restart]")
        return 1
    }

    do {
        let config = try loadConfig(store: store)
        guard let target = findTarget(named: targetQuery, in: config, kind: .guiApp) else {
            printError("No GUI target matching '\(targetQuery)' found in config.")
            return 1
        }
        guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else {
            printError("Target '\(target.name)' has no associated outlet.")
            return 1
        }

        let launcher = AppLauncher()
        let outcome = try await launcher.launch(
            target: target,
            outlet: outlet,
            bypassRules: config.bypassRules,
            policy: config.auditPolicy,
            forceRestart: forceRestart
        )

        switch outcome {
        case .launched(let pid, let name, let port):
            print("Launched '\(name)'\(pid.map { " (PID \($0))" } ?? "") pinned to 127.0.0.1:\(port).")
            return 0
        case .activatedExisting(let pids, let name):
            print("'\(name)' is already running with valid proxy (PIDs: \(pids.map(String.init).joined(separator: ", "))); activated window.")
            return 0
        case .restartedWithProxy(let terminated, let newPID, let name, let port):
            print("Restarted '\(name)' (terminated PIDs: \(terminated.map(String.init).joined(separator: ", "))) -> new PID \(newPID.map(String.init) ?? "unknown") pinned to 127.0.0.1:\(port).")
            return 0
        case .runningWithoutProxy(let pids, let name, let port):
            printError("'\(name)' is already running WITHOUT proxy port \(port) (PIDs: \(pids.map(String.init).joined(separator: ", "))). Re-run with --force-restart to restart with PinGate proxy.")
            return 2
        case .blockedPortClosed(let host, let port, let name):
            printError("Fail-Closed: refused to launch '\(name)' because local outlet \(host):\(port) is not listening.")
            return 1
        }
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func runShim(store: ConfigStore, args: [String], jsonOutput: Bool) -> Int32 {
    guard let action = args.first else {
        printError("Usage: pingate shim install|remove|status <target> [--dir <dir>] [--force]")
        return 1
    }

    var customDir: URL? = nil
    var force = false
    var positional: [String] = []
    var i = 1
    while i < args.count {
        let arg = args[i]
        if arg == "--dir", i + 1 < args.count {
            let expanded = NSString(string: args[i + 1]).expandingTildeInPath
            customDir = URL(fileURLWithPath: expanded, isDirectory: true)
            i += 2
            continue
        }
        if arg == "--force" {
            force = true
            i += 1
            continue
        }
        positional.append(arg)
        i += 1
    }

    let manager = customDir.map { CLIShimManager(shimDirectory: $0) } ?? CLIShimManager()

    do {
        let config = try loadConfig(store: store)
        switch action {
        case "install":
            guard let targetQuery = positional.first else {
                printError("Usage: pingate shim install <target> [--dir <dir>] [--force]")
                return 1
            }
            guard let target = findTarget(named: targetQuery, in: config, kind: .cliTool) else {
                printError("No CLI tool target matching '\(targetQuery)' found in config.")
                return 1
            }
            guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else {
                printError("Target '\(target.name)' has no associated outlet.")
                return 1
            }
            let url = try manager.installShim(
                target: target,
                outlet: outlet,
                bypassRules: config.bypassRules,
                overwriteUnmanaged: force
            )
            print("Installed CLI shim for '\(target.name)' at \(url.path) -> \(outlet.proxyURLString)")
            return 0

        case "remove":
            guard let targetQuery = positional.first else {
                printError("Usage: pingate shim remove <target> [--dir <dir>] [--force]")
                return 1
            }
            let commandName: String
            if let target = findTarget(named: targetQuery, in: config, kind: .cliTool),
               let cmd = target.cliCommandName {
                commandName = cmd
            } else {
                commandName = targetQuery
            }
            let removed = try manager.removeShim(commandName: commandName, force: force)
            if removed {
                print("Removed CLI shim '\(commandName)'.")
            } else {
                print("CLI shim '\(commandName)' was not installed.")
            }
            return 0

        case "status":
            let targets: [ManagedTarget]
            if let query = positional.first {
                guard let found = findTarget(named: query, in: config, kind: .cliTool) else {
                    printError("No CLI tool target matching '\(query)' found in config.")
                    return 1
                }
                targets = [found]
            } else {
                targets = config.targets.filter { $0.kind == .cliTool }
            }

            let statuses = targets.map { manager.status(for: $0) }
            if jsonOutput {
                try printJSON(statuses)
                return 0
            }
            for st in statuses {
                print("\(st.commandName): installed=\(st.isInstalled) managed=\(st.isManagedByPinGate) port=\(st.configuredPort.map(String.init) ?? "n/a") path=\(st.shimPath)")
            }
            return 0

        default:
            printError("Unknown shim action '\(action)'. Expected install, remove, or status.")
            return 1
        }
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func runT3(store: ConfigStore, args: [String], jsonOutput: Bool) -> Int32 {
    guard let action = args.first else {
        printError("Usage: pingate t3 sync|status [target]")
        return 1
    }
    let query = args.dropFirst().first { !$0.hasPrefix("-") }

    do {
        let config = try loadConfig(store: store)
        let targets: [ManagedTarget]
        if let query {
            guard let found = findTarget(named: query, in: config, kind: .t3Integration) else {
                printError("No T3 integration target matching '\(query)' found in config.")
                return 1
            }
            targets = [found]
        } else {
            targets = config.targets.filter { $0.kind == .t3Integration && $0.enabled }
        }

        let adapter = T3CodeSyncAdapter()
        switch action {
        case "sync":
            var results: [T3SyncResult] = []
            for target in targets {
                guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { continue }
                let result = try adapter.sync(target: target, outlet: outlet, bypassRules: config.bypassRules)
                results.append(result)
            }
            if jsonOutput {
                try printJSON(results)
                return 0
            }
            for r in results {
                let changeNote = r.changed ? "updated (backup: \(r.backupPath ?? "none"))" : "already in sync"
                print("T3 provider '\(r.providerKey)' at \(r.settingsPath): \(changeNote)")
            }
            return 0

        case "status":
            for target in targets {
                guard let outlet = config.outlet(id: target.outletID) ?? config.primaryOutlet() else { continue }
                let synced = adapter.isInSync(target: target, outlet: outlet, bypassRules: config.bypassRules)
                let path = adapter.resolveSettingsURL(for: target).path
                print("T3 provider '\(target.t3ProviderKey ?? T3CodeSyncAdapter.defaultProviderKey)': \(synced ? "IN SYNC" : "OUT OF SYNC") (\(path))")
            }
            return 0

        default:
            printError("Unknown t3 action '\(action)'. Expected sync or status.")
            return 1
        }
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

struct UpdateCLIReport: Codable {
    let currentVersion: String
    let latestVersion: String?
    let updateAvailable: Bool
    let applied: Bool
    let releaseTag: String?
    let releaseURL: String?
    let verifiedSHA256: String?
    let message: String
}

func resolveInstalledAppVersion(targetAppURL: URL, overrideString: String?) throws -> SemanticVersion {
    if let overrideString {
        guard let parsed = SemanticVersion(string: overrideString) else {
            throw AppUpdaterError.invalidVersion(overrideString)
        }
        return parsed
    }
    if FileManager.default.fileExists(atPath: targetAppURL.path),
       let bundle = Bundle(url: targetAppURL) {
        return AppUpdater.currentAppVersion(bundle: bundle)
    }
    return AppUpdater.currentAppVersion()
}

func runUpdate(store: ConfigStore, args: [String], jsonOutput: Bool) async -> Int32 {
    var apply = false
    var force = false
    var relaunch = true
    var targetAppURL = URL(fileURLWithPath: "/Applications/PinGate.app")
    var overrideVersion: String? = nil

    var i = 0
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--check":
            apply = false
            i += 1
        case "--apply":
            apply = true
            i += 1
        case "--force":
            force = true
            i += 1
        case "--no-relaunch":
            relaunch = false
            i += 1
        case "--target-app":
            if i + 1 < args.count {
                let expanded = NSString(string: args[i + 1]).expandingTildeInPath
                targetAppURL = URL(fileURLWithPath: expanded)
                i += 2
            } else {
                printError("Usage: pingate update [--check|--apply] [--force] [--target-app <path>] [--current-version <semver>]")
                return 1
            }
        case "--current-version":
            if i + 1 < args.count {
                overrideVersion = args[i + 1]
                i += 2
            } else {
                printError("Missing value for --current-version")
                return 1
            }
        default:
            printError("Unknown option '\(arg)' for update.")
            return 1
        }
    }

    do {
        let currentVersion = try resolveInstalledAppVersion(
            targetAppURL: targetAppURL,
            overrideString: overrideVersion
        )

        // Use local active outlet proxy if available (AppUpdater automatically falls back to direct).
        let proxyOutlet: OutletConfig?
        if store.configExists(), let config = try? store.load(), let primary = config.primaryOutlet() {
            let inspector = DarwinProcessInspector()
            proxyOutlet = inspector.isLocalPortListening(
                host: primary.listenHost,
                port: primary.listenPort,
                timeout: 0.4
            ) ? primary : nil
        } else {
            proxyOutlet = nil
        }

        let updater = AppUpdater(configStore: store)
        let checkResult = try await updater.checkForUpdates(
            currentVersion: currentVersion,
            proxyOutlet: proxyOutlet
        )

        if !apply {
            switch checkResult {
            case .upToDate(let current, let latest):
                let msg = latest.map { "已是最新版本（当前 v\(current)，最新 \($0.tagName)）" }
                    ?? "当前版本 v\(current)（尚无已发布的正式版本）"
                if jsonOutput {
                    try printJSON(UpdateCLIReport(
                        currentVersion: current.description,
                        latestVersion: latest?.version.description,
                        updateAvailable: false,
                        applied: false,
                        releaseTag: latest?.tagName,
                        releaseURL: latest?.htmlURL.absoluteString,
                        verifiedSHA256: nil,
                        message: msg
                    ))
                } else {
                    print(msg)
                    if let latest {
                        print("  发布页面：\(latest.htmlURL.absoluteString)")
                    }
                }
                return 0

            case .updateAvailable(let current, let release):
                let msg = "发现新版本 \(release.tagName)（当前 v\(current)）"
                if jsonOutput {
                    try printJSON(UpdateCLIReport(
                        currentVersion: current.description,
                        latestVersion: release.version.description,
                        updateAvailable: true,
                        applied: false,
                        releaseTag: release.tagName,
                        releaseURL: release.htmlURL.absoluteString,
                        verifiedSHA256: nil,
                        message: msg
                    ))
                } else {
                    print(msg)
                    print("  发布页面：\(release.htmlURL.absoluteString)")
                    print("  安装包：  \(release.zipAssetName)")
                    if !release.releaseNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        print("  更新日志：")
                        for line in release.releaseNotes.split(whereSeparator: \.isNewline).prefix(10) {
                            print("    \(line)")
                        }
                    }
                    print("运行 `pingate update --apply` 即可自动下载校验并升级。")
                }
                return 0
            }
        }

        // --apply mode
        let targetRelease: ReleaseInfo
        switch checkResult {
        case .updateAvailable(_, let release):
            targetRelease = release
        case .upToDate(let current, let latest):
            if force, let latest {
                targetRelease = latest
            } else {
                let msg = "已是最新版本 v\(current)，无需更新。"
                if jsonOutput {
                    try printJSON(UpdateCLIReport(
                        currentVersion: current.description,
                        latestVersion: latest?.version.description,
                        updateAvailable: false,
                        applied: false,
                        releaseTag: latest?.tagName,
                        releaseURL: latest?.htmlURL.absoluteString,
                        verifiedSHA256: nil,
                        message: msg
                    ))
                } else {
                    print(msg)
                }
                return 0
            }
        }

        if !jsonOutput {
            print("正在更新 PinGate：v\(currentVersion) -> \(targetRelease.tagName)…")
        }

        let quiet = jsonOutput
        let prepared = try await updater.downloadAndVerify(
            release: targetRelease,
            proxyOutlet: proxyOutlet,
            verifyCodeSign: true
        ) { progress in
            if !quiet {
                FileHandle.standardError.write(Data("  \(progress.displayName)\n".utf8))
            }
        }

        // Check if PinGateApp is currently running so the self-update helper waits for clean shutdown.
        let inspector = DarwinProcessInspector()
        let appPathPrefix = targetAppURL.path
        let runningApps = inspector.inspectAllProcesses(
            matching: { name, path in
                name == "PinGateApp" && path.hasPrefix(appPathPrefix)
            },
            includeSockets: false,
            includeEnvironment: false
        )
        let runningAppPID = runningApps.first?.pid

        _ = try updater.scheduleSelfUpdate(
            prepared: prepared,
            targetAppURL: targetAppURL,
            waitForPID: runningAppPID,
            relaunchApp: relaunch
        )

        if let pid = runningAppPID {
            _ = kill(pid, SIGTERM)
        }

        let msg = "已校验 SHA-256（\(prepared.verifiedSHA256.prefix(12))…）并启动原子替换安装程序，即将升级到 \(targetRelease.tagName)。"
        if jsonOutput {
            try printJSON(UpdateCLIReport(
                currentVersion: currentVersion.description,
                latestVersion: targetRelease.version.description,
                updateAvailable: true,
                applied: true,
                releaseTag: targetRelease.tagName,
                releaseURL: targetRelease.htmlURL.absoluteString,
                verifiedSHA256: prepared.verifiedSHA256,
                message: msg
            ))
        } else {
            print(msg)
        }
        return 0
    } catch {
        printError(error.localizedDescription)
        return 1
    }
}

func healthBadge(_ state: HealthState) -> String {
    switch state {
    case .protected: return "[PROTECTED]"
    case .warning: return "[WARNING]"
    case .leaking: return "[LEAKING]"
    case .stopped: return "[STOPPED]"
    }
}

// MARK: - Entry Point

AppLauncher.sanitizeCurrentProcessEnvironment()

let parsed = parseGlobalArguments(Array(CommandLine.arguments.dropFirst()))
let store = makeConfigStore(configDir: parsed.configDir)

let exitCode: Int32
switch parsed.command {
case "status":
    exitCode = await runStatus(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "audit":
    exitCode = runAudit(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "sync":
    exitCode = await runSync(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "launch":
    exitCode = await runLaunch(store: store, args: parsed.args)
case "shim":
    exitCode = runShim(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "t3":
    exitCode = runT3(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "update":
    exitCode = await runUpdate(store: store, args: parsed.args, jsonOutput: parsed.jsonOutput)
case "help", "--help", "-h":
    printUsage()
    exitCode = 0
default:
    printError("Unknown command '\(parsed.command)'.")
    printUsage()
    exitCode = 1
}

Darwin.exit(exitCode)
