import Darwin
import Foundation
import Testing
@testable import PinGateCore

// MARK: - Mock Inspector

private struct MockProcessInspector: ProcessInspecting {
    var processes: [InspectedProcess]
    var listeningPorts: Set<Int>

    func listPIDs() -> [Int32] {
        processes.map(\.pid)
    }

    func inspectProcess(pid: Int32, includeSockets: Bool, includeEnvironment: Bool) -> InspectedProcess? {
        processes.first { $0.pid == pid }
    }

    func inspectAllProcesses(
        matching predicate: @Sendable (_ name: String, _ executablePath: String) -> Bool,
        includeSockets: Bool,
        includeEnvironment: Bool
    ) -> [InspectedProcess] {
        processes.filter { predicate($0.name, $0.executablePath) }
    }

    func isLocalPortListening(host: String, port: Int, timeout: TimeInterval) -> Bool {
        listeningPorts.contains(port)
    }
}

// MARK: - Test Helpers

private func makeTempDir(prefix: String = "pingate-capture-tests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeSampleOutlet(port: Int = 17899) -> OutletConfig {
    OutletConfig(
        name: "Test Outlet",
        listenHost: "127.0.0.1",
        listenPort: port,
        controllerPort: 17890,
        source: .manualYAML(yaml: "name: TestNode\ntype: http\nserver: 203.0.113.5\nport: 8080\n"),
        primaryNodeName: "TestNode",
        expectedCountryCode: "US"
    )
}

private func makeSampleBypassRules() -> BypassRules {
    BypassRules(
        domains: [".internal.example", "corp.example.org"],
        cidrs: BypassRules.defaultPrivateCIDRs,
        extraNoProxyEntries: BypassRules.defaultNoProxyEntries
    )
}

private func buildProcArgs2Buffer(
    execPath: String,
    arguments: [String],
    environment: [(String, String)]
) -> Data {
    var data = Data()
    var argc = Int32(arguments.count)
    withUnsafeBytes(of: &argc) { data.append(contentsOf: $0) }
    data.append(contentsOf: execPath.utf8)
    data.append(contentsOf: [0, 0, 0, 0]) // alignment NUL padding
    for arg in arguments {
        data.append(contentsOf: arg.utf8)
        data.append(0)
    }
    for (k, v) in environment {
        data.append(contentsOf: "\(k)=\(v)".utf8)
        data.append(0)
    }
    data.append(0) // terminator before apple strings
    return data
}

// MARK: - Test Suite

@Suite("Capture, Leak Auditor & Integration Tests")
struct CaptureAuditTests {

    // MARK: 1. CIDR Matching

    @Test("CIDRNetwork accurately matches IPv4, IPv6, IPv4-mapped IPv6, and rejects out-of-range IPs")
    func cidrMatching() throws {
        let rfc1918A = try #require(CIDRNetwork("10.0.0.0/8"))
        let rfc1918B = try #require(CIDRNetwork("172.16.0.0/12"))
        let rfc1918C = try #require(CIDRNetwork("192.168.0.0/16"))
        let cgnat = try #require(CIDRNetwork("100.64.0.0/10"))
        let singleHost = try #require(CIDRNetwork("198.51.100.25"))
        let ipv6LinkLocal = try #require(CIDRNetwork("fe80::/10"))
        let ipv6Loopback = try #require(CIDRNetwork("::1/128"))

        #expect(rfc1918A.contains(ipAddress: "10.0.0.1"))
        #expect(rfc1918A.contains(ipAddress: "10.255.255.254"))
        #expect(rfc1918A.contains(ipAddress: "::ffff:10.42.1.7"))
        #expect(!rfc1918A.contains(ipAddress: "11.0.0.1"))

        #expect(rfc1918B.contains(ipAddress: "172.16.0.1"))
        #expect(rfc1918B.contains(ipAddress: "172.31.255.254"))
        #expect(!rfc1918B.contains(ipAddress: "172.32.0.1"))
        #expect(!rfc1918B.contains(ipAddress: "172.15.255.255"))

        #expect(rfc1918C.contains(ipAddress: "192.168.1.10"))
        #expect(!rfc1918C.contains(ipAddress: "192.169.1.10"))

        #expect(cgnat.contains(ipAddress: "100.64.0.1"))
        #expect(cgnat.contains(ipAddress: "100.127.255.254"))
        #expect(!cgnat.contains(ipAddress: "100.128.0.1"))

        #expect(singleHost.contains(ipAddress: "198.51.100.25"))
        #expect(!singleHost.contains(ipAddress: "198.51.100.26"))

        #expect(ipv6LinkLocal.contains(ipAddress: "fe80::1%en0"))
        #expect(!ipv6LinkLocal.contains(ipAddress: "2001:db8::1"))

        #expect(ipv6Loopback.contains(ipAddress: "::1"))
        #expect(ipv6Loopback.contains(ipAddress: "[::1]"))
        #expect(!ipv6Loopback.contains(ipAddress: "::2"))

        #expect(CIDRNetwork("10.0.0.0/33") == nil)
        #expect(CIDRNetwork("not-an-ip/24") == nil)
    }

    // MARK: 2. Socket Classification

    @Test("LeakAuditor classifies proxied, loopback, bypass, suspicious private IPs, and public leaks")
    func socketClassification() {
        let bypassCIDRs = BypassRules.defaultPrivateCIDRs.compactMap(CIDRNetwork.init)
        let suspiciousIPs: Set<String> = ["10.99.0.50"]

        let proxiedV4 = RawSocketInfo(
            localAddress: "127.0.0.1", localPort: 54321,
            remoteAddress: "127.0.0.1", remotePort: 17899,
            tcpState: "ESTABLISHED", ipVersion: 4
        )
        #expect(LeakAuditor.classifySocket(proxiedV4, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .proxied)

        let proxiedMappedV6 = RawSocketInfo(
            localAddress: "::1", localPort: 54322,
            remoteAddress: "::ffff:127.0.0.1", remotePort: 17899,
            tcpState: "ESTABLISHED", ipVersion: 6
        )
        #expect(LeakAuditor.classifySocket(proxiedMappedV6, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .proxied)

        let localIPC = RawSocketInfo(
            localAddress: "127.0.0.1", localPort: 51000,
            remoteAddress: "127.0.0.1", remotePort: 51001,
            tcpState: "ESTABLISHED", ipVersion: 4
        )
        #expect(LeakAuditor.classifySocket(localIPC, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .loopback)

        let privateBypass = RawSocketInfo(
            localAddress: "10.1.2.3", localPort: 52000,
            remoteAddress: "10.20.30.40", remotePort: 443,
            tcpState: "ESTABLISHED", ipVersion: 4
        )
        #expect(LeakAuditor.classifySocket(privateBypass, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .bypass)

        // Suspicious IP inside 10.0.0.0/8 must be flagged as LEAK before bypass CIDR matches
        let suspiciousHijack = RawSocketInfo(
            localAddress: "10.1.2.3", localPort: 52001,
            remoteAddress: "10.99.0.50", remotePort: 443,
            tcpState: "ESTABLISHED", ipVersion: 4
        )
        #expect(LeakAuditor.classifySocket(suspiciousHijack, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .leak)

        // Direct public IP connection -> LEAK
        let publicLeak = RawSocketInfo(
            localAddress: "192.168.1.5", localPort: 53000,
            remoteAddress: "203.0.113.42", remotePort: 443,
            tcpState: "ESTABLISHED", ipVersion: 4
        )
        #expect(LeakAuditor.classifySocket(publicLeak, outletHost: "127.0.0.1", outletPort: 17899, bypassCIDRs: bypassCIDRs, suspiciousDirectIPs: suspiciousIPs).0 == .leak)
    }

    // MARK: 3. KERN_PROCARGS2 Parser & Live Darwin Inspection

    @Test("DarwinProcessInspector.parseProcArgs2 parses argv and proxy environment accurately")
    func parseProcArgs2Buffer() throws {
        let buf = buildProcArgs2Buffer(
            execPath: "/Applications/ExampleApp.app/Contents/MacOS/ExampleApp",
            arguments: [
                "/Applications/ExampleApp.app/Contents/MacOS/ExampleApp",
                "--proxy-server=http://127.0.0.1:17899",
                "--disable-quic"
            ],
            environment: [
                ("PATH", "/usr/bin:/bin"),
                ("HTTPS_PROXY", "http://127.0.0.1:17899"),
                ("ALL_PROXY", "socks5h://127.0.0.1:17899"),
                ("NO_PROXY", "localhost,127.0.0.1,::1"),
                ("NODE_USE_ENV_PROXY", "1")
            ]
        )

        let parsed = try #require(DarwinProcessInspector.parseProcArgs2(buf))
        #expect(parsed.execPath == "/Applications/ExampleApp.app/Contents/MacOS/ExampleApp")
        #expect(parsed.arguments.count == 3)
        #expect(parsed.arguments[1] == "--proxy-server=http://127.0.0.1:17899")
        #expect(parsed.environment["HTTPS_PROXY"] == "http://127.0.0.1:17899")
        #expect(parsed.environment["ALL_PROXY"] == "socks5h://127.0.0.1:17899")
        #expect(parsed.environment["NODE_USE_ENV_PROXY"] == "1")
    }

    @Test("DarwinProcessInspector inspects live current process natively via libproc and sysctl")
    func inspectCurrentProcessLive() throws {
        let inspector = DarwinProcessInspector()
        let pids = inspector.listPIDs()
        let selfPID = getpid()
        #expect(pids.contains(selfPID))

        let inspected = try #require(
            inspector.inspectProcess(pid: selfPID, includeSockets: true, includeEnvironment: true)
        )
        #expect(inspected.pid == selfPID)
        #expect(!inspected.executablePath.isEmpty)
        #expect(!inspected.name.isEmpty)
        #expect(inspected.environment != nil)
    }

    // MARK: 4. Proxy Env & LeakAuditor End-to-End

    @Test("LeakAuditor detects protected state, Squirrel missing-env restart, wrong port, and direct leaks")
    func leakAuditorScenarios() {
        let outlet = makeSampleOutlet(port: 17899)
        let targets = PinGateTemplates.antigravitySuite.makeTargets(outletID: outlet.id)
        let config = PinGateConfig(
            outlets: [outlet],
            targets: targets,
            bypassRules: makeSampleBypassRules(),
            auditPolicy: AuditPolicy(suspiciousDirectIPs: ["10.99.0.50"])
        )
        let auditor = LeakAuditor()

        // 4a. Protected scenario (plus T3 Code host without global HTTPS_PROXY must NOT cause false positive)
        let protectedProcs: [InspectedProcess] = [
            InspectedProcess(
                pid: 1001,
                name: "Antigravity",
                executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
                environment: [
                    "HTTPS_PROXY": "http://127.0.0.1:17899",
                    "ALL_PROXY": "socks5h://127.0.0.1:17899",
                    "NO_PROXY": "localhost,127.0.0.1"
                ],
                sockets: [
                    RawSocketInfo(localAddress: "127.0.0.1", localPort: 50001, remoteAddress: "127.0.0.1", remotePort: 17899, tcpState: "ESTABLISHED"),
                    RawSocketInfo(localAddress: "127.0.0.1", localPort: 50002, remoteAddress: "127.0.0.1", remotePort: 51234, tcpState: "ESTABLISHED"),
                    RawSocketInfo(localAddress: "0.0.0.0", localPort: 51234, remoteAddress: "0.0.0.0", remotePort: 0, tcpState: "LISTEN")
                ]
            ),
            InspectedProcess(
                pid: 1002,
                name: "language_server_macos_arm",
                executablePath: "/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm",
                environment: ["HTTPS_PROXY": "http://127.0.0.1:17899"],
                sockets: [
                    RawSocketInfo(localAddress: "127.0.0.1", localPort: 50010, remoteAddress: "127.0.0.1", remotePort: 17899, tcpState: "ESTABLISHED"),
                    RawSocketInfo(localAddress: "10.0.0.2", localPort: 50011, remoteAddress: "10.1.2.3", remotePort: 443, tcpState: "ESTABLISHED")
                ]
            ),
            InspectedProcess(
                pid: 1003,
                name: "T3 Code",
                executablePath: "/Applications/T3 Code.app/Contents/MacOS/T3 Code",
                environment: ["PATH": "/usr/bin"],
                sockets: []
            )
        ]

        let protectedSnap = auditor.audit(config: config, processes: protectedProcs, outletRunning: true)
        #expect(protectedSnap.overallState == .protected)
        #expect(protectedSnap.processes.count == 2) // T3 host skipped, Antigravity + language_server audited
        #expect(protectedSnap.totalProxiedSockets == 2)
        #expect(protectedSnap.totalBypassSockets == 1)
        #expect(protectedSnap.totalLeakSockets == 0)

        // 4b. Squirrel auto-update restart lost proxy env
        let missingEnvProc = InspectedProcess(
            pid: 2001,
            name: "Antigravity",
            executablePath: "/Applications/Antigravity.app/Contents/MacOS/Antigravity",
            environment: ["PATH": "/usr/bin:/bin"],
            sockets: []
        )
        let missingSnap = auditor.audit(config: config, processes: [missingEnvProc], outletRunning: true)
        #expect(missingSnap.overallState == .leaking)
        #expect(missingSnap.processes.first?.proxyEnvStatus == .missing)
        #expect(missingSnap.processes.first?.isLeaking == true)

        // 4c. Wrong proxy port (e.g. system Clash 7890 instead of PinGate 17899)
        let wrongPortProc = InspectedProcess(
            pid: 2002,
            name: "language_server_macos_arm",
            executablePath: "/Applications/Antigravity.app/Contents/Resources/language_server_macos_arm",
            environment: ["HTTPS_PROXY": "http://127.0.0.1:7890"],
            sockets: []
        )
        let wrongPortSnap = auditor.audit(config: config, processes: [wrongPortProc], outletRunning: true)
        #expect(wrongPortSnap.overallState == .leaking)
        #expect(wrongPortSnap.processes.first?.proxyEnvStatus == .wrongPort)

        // 4d. Direct public IP socket leak even if env looks valid
        let socketLeakProc = InspectedProcess(
            pid: 2003,
            name: "Antigravity Helper",
            executablePath: "/Applications/Antigravity.app/Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper",
            environment: ["HTTPS_PROXY": "http://127.0.0.1:17899"],
            sockets: [
                RawSocketInfo(localAddress: "192.168.1.10", localPort: 55000, remoteAddress: "198.51.100.77", remotePort: 443, tcpState: "ESTABLISHED")
            ]
        )
        let leakSnap = auditor.audit(config: config, processes: [socketLeakProc], outletRunning: true)
        #expect(leakSnap.overallState == .leaking)
        #expect(leakSnap.totalLeakSockets == 1)
        #expect(leakSnap.processes.first?.leakSockets.first?.remoteAddress == "198.51.100.77")

        // 4e. Outlet stopped with no running target processes
        let stoppedSnap = auditor.audit(config: config, processes: [], outletRunning: false)
        #expect(stoppedSnap.overallState == .stopped)
    }

    // MARK: 5. ExitIPProber Multi-Provider Parsing

    @Test("ExitIPProber parses ipinfo, cloudflare trace, ipify, and ifconfig.co responses")
    func exitIPProberParsers() throws {
        let ipinfoJSON = Data("""
        {"ip":"203.0.113.10","city":"Los Angeles","region":"California","country":"US","org":"AS64512 Example ISP"}
        """.utf8)
        let r1 = try #require(ExitIPProber.parseResponse(provider: .ipinfo, data: ipinfoJSON, latencyMs: 120))
        #expect(r1.ip == "203.0.113.10")
        #expect(r1.country == "US")
        #expect(r1.org == "AS64512 Example ISP")
        #expect(r1.provider == "ipinfo.io")

        let cfTrace = Data("""
        fl=29f1
        h=cloudflare.com
        ip=198.51.100.8
        loc=US
        colo=LAX
        """.utf8)
        let r2 = try #require(ExitIPProber.parseResponse(provider: .cloudflare, data: cfTrace, latencyMs: 85))
        #expect(r2.ip == "198.51.100.8")
        #expect(r2.country == "US")
        #expect(r2.provider == "cloudflare")

        let ipifyJSON = Data(#"{"ip":"192.0.2.55"}"#.utf8)
        let r3 = try #require(ExitIPProber.parseResponse(provider: .ipify, data: ipifyJSON, latencyMs: 95))
        #expect(r3.ip == "192.0.2.55")
        #expect(r3.provider == "api.ipify.org")

        let ifconfigJSON = Data(#"{"ip":"203.0.113.99","country_iso":"US","region_name":"Oregon","city":"Portland","asn_org":"Example Cloud"}"#.utf8)
        let r4 = try #require(ExitIPProber.parseResponse(provider: .ifconfigCo, data: ifconfigJSON, latencyMs: 140))
        #expect(r4.ip == "203.0.113.99")
        #expect(r4.country == "US")
        #expect(r4.org == "Example Cloud")
    }

    // MARK: 6. AppLauncher Plan, Fail-Closed & Already-Running Detection

    @Test("AppLauncher builds complete env + Chromium args, enforces Fail-Closed, and detects unproxied running app")
    func appLauncherLogic() async throws {
        let tempDir = try makeTempDir(prefix: "pingate-app")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fakeAppURL = tempDir.appendingPathComponent("ExampleApp.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeAppURL, withIntermediateDirectories: true)

        let outlet = makeSampleOutlet(port: 17899)
        let bypass = makeSampleBypassRules()
        let target = ManagedTarget(
            name: "ExampleApp",
            kind: .guiApp,
            outletID: outlet.id,
            bundleID: "com.example.app",
            appPath: fakeAppURL.path,
            processMatchNames: ["ExampleApp"],
            chromiumProxyFlags: true,
            extraEnv: ["CUSTOM_FLAG": "enabled"]
        )

        let plan = try AppLauncher.buildLaunchPlan(target: target, outlet: outlet, bypassRules: bypass, verifyExists: true)
        #expect(plan.environment["HTTP_PROXY"] == "http://127.0.0.1:17899")
        #expect(plan.environment["HTTPS_PROXY"] == "http://127.0.0.1:17899")
        #expect(plan.environment["http_proxy"] == "http://127.0.0.1:17899")
        #expect(plan.environment["https_proxy"] == "http://127.0.0.1:17899")
        #expect(plan.environment["ALL_PROXY"] == "socks5h://127.0.0.1:17899")
        #expect(plan.environment["all_proxy"] == "socks5h://127.0.0.1:17899")
        #expect(plan.environment["NODE_USE_ENV_PROXY"] == "1")
        #expect(plan.environment["CUSTOM_FLAG"] == "enabled")
        #expect(plan.environment["NO_PROXY"]?.contains(".internal.example") == true)
        #expect(plan.environment["no_proxy"] == plan.environment["NO_PROXY"])

        #expect(plan.arguments.contains("--proxy-server=http://127.0.0.1:17899"))
        #expect(plan.arguments.contains("--disable-quic"))
        let bypassArg = try #require(plan.arguments.first { $0.hasPrefix("--proxy-bypass-list=") })
        #expect(bypassArg.contains("*.internal.example"))
        #expect(bypassArg.contains("10.0.0.0/8"))

        // Fail-Closed when port is NOT listening
        let closedInspector = MockProcessInspector(processes: [], listeningPorts: [])
        let closedLauncher = AppLauncher(inspector: closedInspector)
        let closedOutcome = try await closedLauncher.launch(
            target: target,
            outlet: outlet,
            bypassRules: bypass,
            policy: AuditPolicy(failClosedOnPortDown: true),
            forceRestart: false
        )
        #expect(closedOutcome == .blockedPortClosed(host: "127.0.0.1", port: 17899, targetName: "ExampleApp"))

        // Already running WITHOUT proxy -> returns .runningWithoutProxy(pids)
        let unproxiedProc = InspectedProcess(
            pid: 9876,
            name: "ExampleApp",
            executablePath: fakeAppURL.appendingPathComponent("Contents/MacOS/ExampleApp").path,
            environment: ["PATH": "/usr/bin"]
        )
        let runningInspector = MockProcessInspector(processes: [unproxiedProc], listeningPorts: [17899])
        let runningLauncher = AppLauncher(inspector: runningInspector)
        let runningOutcome = try await runningLauncher.launch(
            target: target,
            outlet: outlet,
            bypassRules: bypass,
            policy: AuditPolicy(failClosedOnPortDown: true),
            forceRestart: false
        )
        #expect(runningOutcome == .runningWithoutProxy(pids: [9876], targetName: "ExampleApp", expectedPort: 17899))
    }

    @Test("AppLauncher.sanitizeCurrentProcessEnvironment strips Electron/Node contamination and respects preserved keys")
    func sanitizeLaunchEnvironment() {
        let keys = AppLauncher.contaminatedLaunchEnvironmentKeys
        #expect(keys == ["ELECTRON_RUN_AS_NODE", "ELECTRON_NO_ASAR", "ELECTRON_NO_ATTACH_CONSOLE", "NODE_OPTIONS"])

        let sentinelKey = "PINGATE_TEST_UNRELATED_ENV_\(UUID().uuidString.prefix(8))"
        var savedValues: [String: String?] = [:]
        for key in keys {
            savedValues[key] = getenv(key).map { String(cString: $0) }
        }
        defer {
            _ = unsetenv(sentinelKey)
            for (key, value) in savedValues {
                if let value {
                    _ = setenv(key, value, 1)
                } else {
                    _ = unsetenv(key)
                }
            }
        }

        // 1. Default sanitize removes all contaminated keys while preserving unrelated env vars.
        _ = setenv("ELECTRON_RUN_AS_NODE", "1", 1)
        _ = setenv("ELECTRON_NO_ASAR", "1", 1)
        _ = setenv("ELECTRON_NO_ATTACH_CONSOLE", "1", 1)
        _ = setenv("NODE_OPTIONS", "--max-old-space-size=4096", 1)
        _ = setenv(sentinelKey, "keep", 1)

        AppLauncher.sanitizeCurrentProcessEnvironment()

        for key in keys {
            #expect(getenv(key) == nil)
        }
        #expect(getenv(sentinelKey).map { String(cString: $0) } == "keep")

        // 2. Preserving explicitly requested keys keeps them intact while stripping the rest.
        _ = setenv("ELECTRON_RUN_AS_NODE", "1", 1)
        _ = setenv("NODE_OPTIONS", "--max-old-space-size=2048", 1)

        AppLauncher.sanitizeCurrentProcessEnvironment(preserving: ["NODE_OPTIONS"])

        #expect(getenv("ELECTRON_RUN_AS_NODE") == nil)
        #expect(getenv("NODE_OPTIONS").map { String(cString: $0) } == "--max-old-space-size=2048")
    }

    // MARK: 7. CLIShimManager

    @Test("CLIShimManager idempotently installs, protects unmanaged files, reports status, and removes shims")
    func cliShimLifecycle() throws {
        let tempBinDir = try makeTempDir(prefix: "pingate-shims")
        defer { try? FileManager.default.removeItem(at: tempBinDir) }

        let outlet = makeSampleOutlet(port: 17899)
        let bypass = makeSampleBypassRules()
        let target = ManagedTarget(
            name: "example-cli",
            kind: .cliTool,
            outletID: outlet.id,
            processMatchNames: ["example-cli"],
            extraEnv: ["NODE_USE_ENV_PROXY": "1"],
            cliCommandName: "example-cli",
            cliTargetBinaryPath: "/opt/homebrew/bin/example-cli"
        )

        let manager = CLIShimManager(shimDirectory: tempBinDir)

        // Install
        let shimURL = try manager.installShim(target: target, outlet: outlet, bypassRules: bypass)
        #expect(FileManager.default.isExecutableFile(atPath: shimURL.path))
        let script = try String(contentsOf: shimURL, encoding: .utf8)
        #expect(script.contains(CLIShimManager.managedMarker))
        #expect(script.contains("export HTTPS_PROXY='http://127.0.0.1:17899'"))
        #expect(script.contains("export ALL_PROXY='socks5h://127.0.0.1:17899'"))
        #expect(script.contains("export NODE_USE_ENV_PROXY='1'"))
        #expect(script.contains("TARGET_BIN='/opt/homebrew/bin/example-cli'"))

        // Idempotent reinstall
        let secondURL = try manager.installShim(target: target, outlet: outlet, bypassRules: bypass)
        #expect(secondURL == shimURL)

        // Status check
        let status = manager.status(for: target)
        #expect(status.isInstalled)
        #expect(status.isManagedByPinGate)
        #expect(status.configuredPort == 17899)

        // Remove managed shim
        let removed = try manager.removeShim(commandName: "example-cli")
        #expect(removed == true)
        #expect(!FileManager.default.fileExists(atPath: shimURL.path))

        // Refuse to overwrite or remove unmanaged file
        try Data("#!/bin/sh\necho custom\n".utf8).write(to: shimURL)
        #expect(throws: CLIShimError.existingUnmanagedFile(shimURL.path)) {
            try manager.installShim(target: target, outlet: outlet, bypassRules: bypass)
        }
        #expect(throws: CLIShimError.existingUnmanagedFile(shimURL.path)) {
            try manager.removeShim(commandName: "example-cli")
        }
    }

    // MARK: 8. T3CodeSyncAdapter

    @Test("T3CodeSyncAdapter idempotently syncs provider environment with .bak backup while preserving other keys and redacted secrets")
    func t3CodeSyncIdempotentAndPreserving() throws {
        let tempDir = try makeTempDir(prefix: "pingate-t3")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let settingsURL = tempDir.appendingPathComponent("settings.json")
        let fixtureJSON = """
        {
          "usageHistoryRetentionDays": 180,
          "favorites": [
            { "provider": "codex", "model": "example-model" }
          ],
          "providerInstances": {
            "claudeAgent": {
              "driver": "claudeAgent",
              "enabled": true,
              "environment": [
                { "name": "ANTHROPIC_AUTH_TOKEN", "value": "", "sensitive": true, "valueRedacted": true }
              ]
            },
            "antigravity": {
              "driver": "antigravity",
              "displayName": "Antigravity",
              "enabled": true,
              "environment": [
                { "name": "HTTP_PROXY", "value": "http://127.0.0.1:7890", "sensitive": false },
                { "name": "CUSTOM_SECRET", "value": "", "sensitive": true, "valueRedacted": true },
                { "name": "KEEP_ME", "value": "hello", "sensitive": false }
              ],
              "config": { "authMethod": "oauth-personal" }
            }
          }
        }
        """
        try Data(fixtureJSON.utf8).write(to: settingsURL)

        let outlet = makeSampleOutlet(port: 17899)
        let bypass = makeSampleBypassRules()
        let target = ManagedTarget(
            name: "T3 Code",
            kind: .t3Integration,
            outletID: outlet.id,
            t3SettingsPath: settingsURL.path,
            t3ProviderKey: "antigravity"
        )

        let adapter = T3CodeSyncAdapter()
        #expect(!adapter.isInSync(target: target, outlet: outlet, bypassRules: bypass))

        // First sync writes changes and creates .bak
        let first = try adapter.sync(target: target, outlet: outlet, bypassRules: bypass)
        #expect(first.changed == true)
        let backupPath = try #require(first.backupPath)
        #expect(FileManager.default.fileExists(atPath: backupPath))
        let backupText = try String(contentsOfFile: backupPath, encoding: .utf8)
        #expect(backupText.contains("http://127.0.0.1:7890"))

        // Verify updated JSON preserves unrelated keys & redacted secrets
        let updatedData = try Data(contentsOf: settingsURL)
        let root = try #require(JSONSerialization.jsonObject(with: updatedData) as? [String: Any])
        #expect(root["usageHistoryRetentionDays"] as? Int == 180)
        #expect((root["favorites"] as? [[String: Any]])?.count == 1)

        let providers = try #require(root["providerInstances"] as? [String: Any])
        let claude = try #require(providers["claudeAgent"] as? [String: Any])
        let claudeEnv = try #require(claude["environment"] as? [[String: Any]])
        #expect(claudeEnv.first?["valueRedacted"] as? Bool == true)

        let ag = try #require(providers["antigravity"] as? [String: Any])
        let agEnv = try #require(ag["environment"] as? [[String: Any]])
        let byName = Dictionary(uniqueKeysWithValues: agEnv.compactMap { entry -> (String, [String: Any])? in
            guard let n = entry["name"] as? String else { return nil }
            return (n, entry)
        })
        #expect(byName["HTTP_PROXY"]?["value"] as? String == "http://127.0.0.1:17899")
        #expect(byName["HTTPS_PROXY"]?["value"] as? String == "http://127.0.0.1:17899")
        #expect(byName["ALL_PROXY"]?["value"] as? String == "socks5h://127.0.0.1:17899")
        #expect(byName["NODE_USE_ENV_PROXY"]?["value"] as? String == "1")
        #expect((byName["NO_PROXY"]?["value"] as? String)?.contains(".internal.example") == true)
        #expect(byName["CUSTOM_SECRET"]?["valueRedacted"] as? Bool == true)
        #expect(byName["KEEP_ME"]?["value"] as? String == "hello")

        // Second sync is a pure idempotent no-op
        #expect(adapter.isInSync(target: target, outlet: outlet, bypassRules: bypass))
        let second = try adapter.sync(target: target, outlet: outlet, bypassRules: bypass)
        #expect(second.changed == false)
        #expect(second.backupPath == nil)
    }

    // MARK: 9. TrafficInterceptor & ExtensionRuleSnapshot

    @Test("UserSpaceInterceptor applies rules and writes 0600 ExtensionRuleSnapshot roundtrip")
    func interceptorAndExtensionSnapshot() async throws {
        let tempDir = try makeTempDir(prefix: "pingate-interceptor")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outlet = makeSampleOutlet(port: 17899)
        let bypass = makeSampleBypassRules()
        let shimDir = tempDir.appendingPathComponent("bin", isDirectory: true)
        let snapshotURL = tempDir.appendingPathComponent("extension-rules.json")
        let t3URL = tempDir.appendingPathComponent("t3-settings.json")
        try Data(#"{"providerInstances":{"antigravity":{"driver":"antigravity","environment":[]}}}"#.utf8).write(to: t3URL)

        let config = PinGateConfig(
            outlets: [outlet],
            targets: [
                ManagedTarget(
                    name: "cli-test",
                    kind: .cliTool,
                    outletID: outlet.id,
                    cliCommandName: "cli-test",
                    cliTargetBinaryPath: "/usr/bin/true"
                ),
                ManagedTarget(
                    name: "T3 Code",
                    kind: .t3Integration,
                    outletID: outlet.id,
                    t3SettingsPath: t3URL.path,
                    t3ProviderKey: "antigravity"
                )
            ],
            bypassRules: bypass
        )

        let interceptor = UserSpaceInterceptor(
            shimManager: CLIShimManager(shimDirectory: shimDir),
            t3Adapter: T3CodeSyncAdapter(),
            snapshotURL: snapshotURL
        )

        let report = try await interceptor.applyRules(config: config)
        #expect(report.mode == .userSpace)
        #expect(report.syncedCLIShims.count == 1)
        #expect(report.syncedT3Targets.count == 1)
        #expect(report.snapshotPath == snapshotURL.path)
        #expect(report.warnings.isEmpty)

        // Verify 0600 permissions and JSON roundtrip on ExtensionRuleSnapshot
        let attrs = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        #expect((perms & 0o777) == 0o600)

        let loaded = try ExtensionRuleSnapshot.read(from: snapshotURL)
        #expect(loaded.outlets.first?.listenPort == 17899)
        #expect(loaded.bypassDomains.contains("internal.example"))
        #expect(loaded.targets.count == 2)
    }
}
