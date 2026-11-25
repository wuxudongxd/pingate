import Foundation
import XCTest
import Yams
@testable import PinGateCore

final class CoreEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pingate-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - ConfigStore & Models

    func testConfigStoreRoundTripAndPermissions() throws {
        let store = ConfigStore(baseDirectory: tempDir.appendingPathComponent("app-support", isDirectory: true))
        XCTAssertFalse(store.configExists())

        let bootstrapped = try store.loadOrBootstrap()
        XCTAssertEqual(bootstrapped.schemaVersion, PinGateConfig.currentSchemaVersion)
        XCTAssertTrue(store.configExists())
        XCTAssertEqual(bootstrapped.outlets.count, 1)
        XCTAssertFalse(bootstrapped.targets.isEmpty)

        // Verify 0600 on config.json and 0700 on directories
        let configAttrs = try FileManager.default.attributesOfItem(atPath: store.configFileURL.path)
        let configPerms = (configAttrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(configPerms, 0o600)

        for dir in [store.baseDirectory, store.runtimeDirectory, store.logsDirectory, store.binDirectory] {
            let dirAttrs = try FileManager.default.attributesOfItem(atPath: dir.path)
            let dirPerms = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(dirPerms, 0o700)
        }

        // Modify and round-trip
        var updated = bootstrapped
        updated.outlets[0].name = "US-Test-Outlet"
        updated.outlets[0].listenPort = 18899
        updated.outlets[0].controllerPort = 18890
        updated.outlets[0].primaryNodeName = "US-Exit-via-JP"
        updated.outlets[0].fallbackNodeNames = ["SG-Backup"]
        updated.outlets[0].expectedCountryCode = "US"
        updated.bypassRules.domains = [".corp.example.com", ".internal.example.net"]
        updated.auditPolicy.suspiciousDirectIPs = ["10.99.99.99"]

        try store.save(updated)
        let reloaded = try store.load()
        XCTAssertEqual(reloaded, updated)

        // Verify 0600 preserved after atomic replace
        let replacedAttrs = try FileManager.default.attributesOfItem(atPath: store.configFileURL.path)
        XCTAssertEqual((replacedAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDiscoverFlClashProfiles() throws {
        let profilesDir = tempDir.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesDir, withIntermediateDirectories: true)

        let olderURL = profilesDir.appendingPathComponent("older.yaml")
        let newerURL = profilesDir.appendingPathComponent("newer.yml")
        let ignoredURL = profilesDir.appendingPathComponent("readme.txt")

        try "proxies: []\n".write(to: olderURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)],
            ofItemAtPath: olderURL.path
        )
        try "proxies: []\n".write(to: newerURL, atomically: true, encoding: .utf8)
        try "ignored".write(to: ignoredURL, atomically: true, encoding: .utf8)

        let discovered = ConfigStore.discoverFlClashProfiles(in: profilesDir)
        XCTAssertEqual(discovered.map(\.lastPathComponent), ["newer.yml", "older.yaml"])
    }

    func testBypassRulesFormatting() {
        let rules = BypassRules(
            domains: [".corp.example.com", "*.intranet.example.org", "corp.example.com", "  "],
            cidrs: ["127.0.0.0/8", "10.0.0.0/8"],
            extraNoProxyEntries: ["localhost", "127.0.0.1", "::1"]
        )

        let noProxy = rules.noProxyCSV()
        XCTAssertTrue(noProxy.contains("localhost"))
        XCTAssertTrue(noProxy.contains("127.0.0.1"))
        XCTAssertTrue(noProxy.contains("::1"))
        XCTAssertTrue(noProxy.contains("127.0.0.0/8"))
        XCTAssertTrue(noProxy.contains("10.0.0.0/8"))
        // Bypass domains must NOT be placed into NO_PROXY (handled via Mihomo nameserver-policy + DIRECT)
        XCTAssertFalse(noProxy.contains("corp.example.com"))
        XCTAssertFalse(noProxy.contains("intranet.example.org"))

        let chromium = rules.chromiumBypassList()
        XCTAssertTrue(chromium.contains("localhost"))
        XCTAssertTrue(chromium.contains("127.0.0.1"))
        XCTAssertTrue(chromium.contains("[::1]"))
        XCTAssertTrue(chromium.contains("127.0.0.0/8"))
        XCTAssertTrue(chromium.contains("10.0.0.0/8"))
        // Bypass domains must NOT be placed into Chromium --proxy-bypass-list
        XCTAssertFalse(chromium.contains("corp.example.com"))
        XCTAssertFalse(chromium.contains("intranet.example.org"))

        XCTAssertEqual(
            rules.mihomoDomainSuffixes(),
            ["corp.example.com", "intranet.example.org"]
        )
    }

    func testBuiltInTemplates() {
        let outletID = UUID()
        XCTAssertEqual(PinGateTemplates.all.count, 4)
        for template in PinGateTemplates.all {
            let targets = template.makeTargets(outletID: outletID)
            XCTAssertFalse(targets.isEmpty)
            XCTAssertTrue(targets.allSatisfy { $0.outletID == outletID })
        }
        let agTargets = PinGateTemplates.antigravitySuite.makeTargets(outletID: outletID)
        XCTAssertEqual(agTargets.map(\.kind), [.guiApp, .t3Integration, .cliTool])
    }

    // MARK: - ClashProfileParser

    func testRecursiveDialerProxyChainExtraction() throws {
        let sampleYAML = """
        proxies:
          - name: "HK-Edge-Hop"
            type: ss
            server: hk-edge.example.com
            port: 443
            cipher: aes-256-gcm
            password: test-hop-password
            udp: true
          - name: "JP-Relay-Hop"
            type: ss
            server: jp-relay.example.com
            port: 8443
            cipher: aes-128-gcm
            password: test-relay-password
            dialer-proxy: "HK-Edge-Hop"
            udp: true
          - name: "US-Static-Exit"
            type: vless
            server: us-exit.example.com
            port: 443
            uuid: 00000000-0000-0000-0000-000000000001
            network: tcp
            tls: true
            udp: true
            flow: xtls-rprx-vision
            servername: www.example.com
            client-fingerprint: chrome
            reality-opts:
              public-key: test-public-key
              short-id: abcd1234
            dialer-proxy: "JP-Relay-Hop"
          - name: "SG-Backup-Exit"
            type: trojan
            server: sg-backup.example.com
            port: 443
            password: test-sg-password
            dialer-proxy: "JP-Relay-Hop"
          - name: "Unrelated-Node"
            type: ss
            server: unused.example.com
            port: 1234
            cipher: aes-256-gcm
            password: unused
        """

        let parser = ClashProfileParser()
        let names = try parser.listProxyNames(fromYAML: sampleYAML)
        XCTAssertEqual(names.count, 5)

        let chain = try parser.extractChain(
            fromYAML: sampleYAML,
            primaryNodeName: "US-Static-Exit",
            fallbackNodeNames: ["SG-Backup-Exit", "Missing-Fallback"]
        )

        XCTAssertEqual(chain.primaryNodeName, "US-Static-Exit")
        XCTAssertEqual(chain.orderedProxyNames, ["HK-Edge-Hop", "JP-Relay-Hop", "US-Static-Exit", "SG-Backup-Exit"])
        XCTAssertFalse(chain.orderedProxyNames.contains("Unrelated-Node"))
        XCTAssertEqual(chain.outletGroupMembers, ["US-Static-Exit", "SG-Backup-Exit"])
        XCTAssertEqual(chain.availableFallbackNames, ["SG-Backup-Exit"])
        XCTAssertEqual(chain.missingFallbackNames, ["Missing-Fallback"])

        let usNode = try XCTUnwrap(chain.proxies.first(where: { $0.name == "US-Static-Exit" }))
        XCTAssertEqual(usNode.dialerProxy, "JP-Relay-Hop")
        if case .dictionary(let realityOpts) = usNode.fields["reality-opts"] {
            XCTAssertEqual(realityOpts["public-key"], .string("test-public-key"))
            XCTAssertEqual(realityOpts["short-id"], .string("abcd1234"))
        } else {
            XCTFail("Expected reality-opts dictionary to be preserved")
        }
    }

    func testDialerProxyCycleThrows() {
        let cyclicYAML = """
        proxies:
          - name: "Node-A"
            type: ss
            server: a.example.com
            port: 443
            dialer-proxy: "Node-B"
          - name: "Node-B"
            type: ss
            server: b.example.com
            port: 443
            dialer-proxy: "Node-A"
        """

        let parser = ClashProfileParser()
        XCTAssertThrowsError(try parser.extractChain(fromYAML: cyclicYAML, primaryNodeName: "Node-A")) { error in
            guard case ClashProfileParserError.dialerProxyCycle(let chain) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(chain, ["Node-A", "Node-B", "Node-A"])
        }
    }

    func testMissingDialerProxyThrows() {
        let brokenYAML = """
        proxies:
          - name: "Node-A"
            type: vless
            server: a.example.com
            port: 443
            dialer-proxy: "Ghost-Hop"
        """

        let parser = ClashProfileParser()
        XCTAssertThrowsError(try parser.extractChain(fromYAML: brokenYAML, primaryNodeName: "Node-A")) { error in
            guard case ClashProfileParserError.missingDialerProxy(let node, let dialer) = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
            XCTAssertEqual(node, "Node-A")
            XCTAssertEqual(dialer, "Ghost-Hop")
        }
    }

    func testManualYAMLAndUpstreamProxySources() async throws {
        let parser = ClashProfileParser()

        let manualOutlet = OutletConfig(
            name: "Manual",
            source: .manualYAML(yaml: """
            name: "Single-Manual-Node"
            type: http
            server: proxy.example.com
            port: 8080
            """),
            primaryNodeName: ""
        )
        let manualChain = try await parser.resolveProxies(for: manualOutlet)
        XCTAssertEqual(manualChain.primaryNodeName, "Single-Manual-Node")
        XCTAssertEqual(manualChain.orderedProxyNames, ["Single-Manual-Node"])

        let upstreamOutlet = OutletConfig(
            name: "Upstream",
            source: .upstreamProxy(
                scheme: .socks5,
                host: "127.0.0.1",
                port: 10808,
                username: "demo-user",
                password: "demo-password"
            ),
            primaryNodeName: "Corp-SOCKS5"
        )
        let upstreamChain = try await parser.resolveProxies(for: upstreamOutlet)
        XCTAssertEqual(upstreamChain.primaryNodeName, "Corp-SOCKS5")
        XCTAssertEqual(upstreamChain.proxies.first?.fields["type"], .string("socks5"))
        XCTAssertEqual(upstreamChain.proxies.first?.fields["port"], .int(10808))
        XCTAssertEqual(upstreamChain.proxies.first?.fields["udp"], .bool(true))
    }

    // MARK: - MihomoConfigRenderer

    func testMihomoConfigRendererDNSRulesAnd0600Permissions() throws {
        let yaml = """
        proxies:
          - name: "JP-Relay"
            type: ss
            server: jp.example.com
            port: 443
            cipher: aes-256-gcm
            password: demo
          - name: "US-Pinned"
            type: vless
            server: us.example.com
            port: 443
            uuid: 00000000-0000-0000-0000-000000000002
            dialer-proxy: "JP-Relay"
        """
        let parser = ClashProfileParser()
        let chain = try parser.extractChain(fromYAML: yaml, primaryNodeName: "US-Pinned")

        let outlet = OutletConfig(
            name: "Test-Outlet",
            listenHost: "127.0.0.1",
            listenPort: 19899,
            controllerPort: 19890,
            controllerSecret: "test-secret-token",
            source: .manualYAML(yaml: yaml),
            primaryNodeName: "US-Pinned"
        )
        let bypassRules = BypassRules(
            domains: [".internal.example.com", ".corp.example.net"]
        )

        let renderer = MihomoConfigRenderer()
        let outputURL = tempDir.appendingPathComponent("mihomo-test.yaml")
        try renderer.writeConfig(outlet: outlet, chain: chain, bypassRules: bypassRules, to: outputURL)

        // Verify 0600 permissions
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let renderedString = try String(contentsOf: outputURL, encoding: .utf8)
        let parsed = try XCTUnwrap(try Yams.load(yaml: renderedString) as? [String: Any])

        XCTAssertEqual(parsed["mixed-port"] as? Int, 19899)
        XCTAssertEqual(parsed["bind-address"] as? String, "127.0.0.1")
        XCTAssertEqual(parsed["allow-lan"] as? Bool, false)
        XCTAssertEqual(parsed["external-controller"] as? String, "127.0.0.1:19890")
        XCTAssertEqual(parsed["secret"] as? String, "test-secret-token")

        // Verify DNS configuration: domestic default/proxy-server nameservers, remote DoH, use-system-hosts, nameserver-policy, NO dns.listen
        let dns = try XCTUnwrap(parsed["dns"] as? [String: Any])
        XCTAssertEqual(dns["use-system-hosts"] as? Bool, true)
        XCTAssertEqual(dns["default-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        let nameserverPolicy = try XCTUnwrap(dns["nameserver-policy"] as? [String: [String]])
        XCTAssertEqual(nameserverPolicy["+.internal.example.com"], ["system"])
        XCTAssertEqual(nameserverPolicy["+.corp.example.net"], ["system"])
        let remoteDNS = try XCTUnwrap(dns["nameserver"] as? [String])
        XCTAssertTrue(remoteDNS.allSatisfy { $0.hasPrefix("https://") })
        XCTAssertNil(dns["listen"], "Rendered Mihomo config must not bind an unused dns.listen port")

        // Verify rules order: private CIDRs + bypass domains BEFORE telemetry REJECT and MATCH,OUTLET
        let rules = try XCTUnwrap(parsed["rules"] as? [String])
        let matchIndex = try XCTUnwrap(rules.firstIndex(of: "MATCH,OUTLET"))
        let firstRejectIndex = try XCTUnwrap(rules.firstIndex(where: { $0.hasSuffix(",REJECT") }))
        XCTAssertEqual(matchIndex, rules.count - 1)
        XCTAssertLessThan(firstRejectIndex, matchIndex)

        let requiredBeforeRejectAndMatch = [
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "DOMAIN-SUFFIX,internal.example.com,DIRECT",
            "DOMAIN-SUFFIX,corp.example.net,DIRECT"
        ]
        for rule in requiredBeforeRejectAndMatch {
            let idx = try XCTUnwrap(rules.firstIndex(of: rule), "Missing rule: \(rule)")
            XCTAssertLessThan(idx, firstRejectIndex, "Rule \(rule) must appear before REJECT rules")
            XCTAssertLessThan(idx, matchIndex, "Rule \(rule) must appear before MATCH,OUTLET")
        }

        // Verify proxy-groups
        let groups = try XCTUnwrap(parsed["proxy-groups"] as? [[String: Any]])
        XCTAssertEqual(groups.first?["name"] as? String, "OUTLET")
        XCTAssertEqual(groups.first?["proxies"] as? [String], ["US-Pinned"])
    }

    // MARK: - ProfileWatcher

    func testProfileWatcherFiresOnAtomicReplace() throws {
        let watchedURL = tempDir.appendingPathComponent("profile.yaml")
        try "proxies: []\n".write(to: watchedURL, atomically: true, encoding: .utf8)

        let expectation = expectation(description: "ProfileWatcher notifies on atomic replacement")
        let watcher = ProfileWatcher(fileURL: watchedURL, debounceInterval: 0.1) {
            expectation.fulfill()
        }
        try watcher.start()
        defer { watcher.stop() }

        let updatedData = Data("proxies:\n  - name: Updated\n".utf8)
        try ConfigStore.atomicWrite(data: updatedData, to: watchedURL, posixPermissions: 0o600)

        wait(for: [expectation], timeout: 3.0)
    }

    // MARK: - MihomoBinaryManager

    func testMihomoBinaryManagerInstallAndChecksum() throws {
        let sourceBin = tempDir.appendingPathComponent("fake-mihomo")
        let script = "#!/bin/sh\necho 'Mihomo Meta v1.19.test darwin arm64'\n"
        try script.write(to: sourceBin, atomically: true, encoding: .utf8)
        try ConfigStore.setPosixPermissions(0o755, at: sourceBin)

        let binDir = tempDir.appendingPathComponent("managed-bin", isDirectory: true)
        let manager = MihomoBinaryManager(binDirectory: binDir)
        XCTAssertFalse(manager.isInstalled())

        let expectedHash = try manager.sha256Hex(of: sourceBin)
        XCTAssertEqual(expectedHash.count, 64)

        // Wrong checksum must fail
        XCTAssertThrowsError(
            try manager.installFromLocalBinary(at: sourceBin, expectedSHA256: String(repeating: "0", count: 64))
        ) { error in
            guard case MihomoBinaryError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch, got \(error)")
                return
            }
        }

        // Matching checksum succeeds with 0700
        let installedURL = try manager.installFromLocalBinary(at: sourceBin, expectedSHA256: expectedHash)
        XCTAssertTrue(manager.isInstalled())
        let attrs = try FileManager.default.attributesOfItem(atPath: installedURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        let version = try manager.installedVersion()
        XCTAssertTrue(version.contains("Mihomo Meta v1.19.test"))
    }

    // MARK: - MihomoAPIClient

    func testMihomoAPIClientEndpointsAndAuth() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let expectedSecret = "unit-test-secret"
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(expectedSecret)")
            let path = request.url?.path ?? ""
            let method = request.httpMethod ?? "GET"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            if method == "GET" && path == "/version" {
                return (response, Data(#"{"version":"v1.19.34","meta":true}"#.utf8))
            }
            if method == "GET" && path == "/proxies" {
                return (response, Data(#"{"proxies":{"OUTLET":{"name":"OUTLET","type":"Selector","now":"US-Exit","all":["US-Exit","SG-Backup"]},"US-Exit":{"name":"US-Exit","type":"VLESS","alive":true,"history":[{"delay":142}]}}}"#.utf8))
            }
            if method == "GET" && path.hasSuffix("/delay") {
                return (response, Data(#"{"delay":128}"#.utf8))
            }
            if method == "GET" && path == "/connections" {
                return (response, Data(#"{"connections":[{"id":"c1","metadata":{"network":"tcp","sourceIP":"127.0.0.1","destinationIP":"93.184.216.34","sourcePort":"55000","destinationPort":"443","host":"example.com"},"upload":120,"download":480,"start":"2026-11-23T00:00:00Z","chains":["US-Exit","OUTLET"],"rule":"Match","rulePayload":""}]}"#.utf8))
            }
            if method == "PUT" && path == "/proxies/OUTLET" {
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            if method == "PUT" && path == "/configs" {
                XCTAssertEqual(request.url?.query, "force=true")
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.handler = nil }

        let client = MihomoAPIClient(
            baseURL: URL(string: "http://127.0.0.1:19890")!,
            secret: expectedSecret,
            session: session
        )

        let version = try await client.version()
        XCTAssertEqual(version.version, "v1.19.34")
        XCTAssertEqual(version.meta, true)

        let proxies = try await client.proxies()
        XCTAssertEqual(proxies["OUTLET"]?.now, "US-Exit")
        XCTAssertEqual(proxies["US-Exit"]?.delayMs, 142)

        let delay = try await client.proxyDelay(name: "🇺🇸 US / Exit?")
        XCTAssertEqual(delay, 128)

        let connections = try await client.activeConnections()
        XCTAssertEqual(connections.count, 1)
        XCTAssertEqual(connections[0].displayDestination, "example.com:443")
        XCTAssertEqual(connections[0].chains, ["US-Exit", "OUTLET"])

        try await client.selectProxy(group: "OUTLET", nodeName: "SG-Backup")
        try await client.reloadConfig(path: "/var/empty/mock-mihomo.yaml", force: true)
    }

    // MARK: - Simplified Chinese Localization & Codable Compatibility

    func testChineseLocalizationAndCodableRawValuesUnchanged() {
        XCTAssertEqual(HealthState.protected.rawValue, "protected")
        XCTAssertEqual(HealthState.protected.displayName, "保护中")
        XCTAssertEqual(HealthState.warning.displayName, "需注意")
        XCTAssertEqual(HealthState.leaking.displayName, "发现漏网")
        XCTAssertEqual(HealthState.stopped.displayName, "已关闭")
        XCTAssertEqual(SocketClassification.proxied.displayName, "已代理")
        XCTAssertEqual(SocketClassification.loopback.displayName, "本机连接")
        XCTAssertEqual(SocketClassification.bypass.displayName, "直连")
        XCTAssertEqual(SocketClassification.leak.displayName, "未走代理")
        XCTAssertEqual(ProxyEnvStatus.valid.displayName, "代理环境正常")
        XCTAssertEqual(ProxyEnvStatus.missing.displayName, "缺少代理配置")
        XCTAssertEqual(ProxyEnvStatus.unreadable.displayName, "无法读取进程环境")
        XCTAssertEqual(CaptureMode.userSpace.rawValue, "userSpace")
        XCTAssertEqual(CaptureMode.userSpace.displayName, "标准代理模式")
        XCTAssertEqual(CaptureMode.systemExtension.displayName, "系统扩展模式（透明代理）")
        XCTAssertEqual(TargetKind.guiApp.rawValue, "guiApp")
        XCTAssertEqual(TargetKind.guiApp.displayName, "桌面应用")
        XCTAssertEqual(TargetKind.cliTool.displayName, "命令行工具")
        XCTAssertEqual(TargetKind.t3Integration.displayName, "T3 Code 集成")
        XCTAssertEqual(MihomoProcessState.running.displayName, "运行中")

        XCTAssertTrue(
            ClashProfileParserError.missingProxiesSection.localizedDescription.contains("未找到代理节点")
        )
        XCTAssertTrue(
            ClashProfileParserError.nodeNotFound(name: "X", availableCount: 1).localizedDescription.contains("「X」")
        )
        XCTAssertTrue(
            ClashProfileParserError.remoteFetchFailed("timeout").localizedDescription.contains("获取远程订阅失败")
        )
        XCTAssertTrue(
            ConfigStoreError.unsupportedSchemaVersion(99).localizedDescription.contains("不支持的 PinGate 配置版本")
        )
        XCTAssertTrue(
            MihomoConfigRendererError.emptyProxyList.localizedDescription.contains("代理节点列表为空")
        )
        XCTAssertTrue(
            MihomoProcessError.processExitedEarly(1).localizedDescription.contains("意外退出")
        )
    }

    // MARK: - Telemetry Blocking & Backward Compatibility

    func testTelemetryBlockingRulesAndBackwardCompatibility() throws {
        // 1. Legacy JSON missing `blockTelemetry` and `autoCheckUpdates` must decode with both defaulting to `true`
        let outletID = UUID()
        let legacyJSON = """
        {
          "schemaVersion": 1,
          "outlets": [{
            "id": "\(outletID.uuidString)",
            "name": "Test",
            "listenHost": "127.0.0.1",
            "listenPort": 19899,
            "controllerPort": 19890,
            "controllerSecret": "sec",
            "source": { "manualYAML": { "yaml": "name: N\\ntype: http\\nserver: 127.0.0.1\\nport: 8080" } },
            "primaryNodeName": "N",
            "fallbackNodeNames": [],
            "enabled": true
          }],
          "targets": [],
          "bypassRules": {
            "domains": [".corp.example.com"],
            "cidrs": ["127.0.0.0/8", "10.0.0.0/8"],
            "extraNoProxyEntries": ["localhost"]
          },
          "auditPolicy": {
            "pollIntervalSeconds": 3,
            "failClosedOnPortDown": true,
            "warnOnExitIPChange": true,
            "notifyOnLeak": true,
            "suspiciousDirectIPs": [],
            "probeTimeoutSeconds": 6
          },
          "captureMode": "userSpace"
        }
        """
        let decoded = try JSONDecoder().decode(PinGateConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertTrue(decoded.autoCheckUpdates)
        XCTAssertTrue(decoded.bypassRules.blockTelemetry)
        XCTAssertTrue(decoded.blockTelemetry)

        // 2. Render with blockTelemetry == true -> all 14 REJECT rules appear AFTER DIRECT and BEFORE MATCH,OUTLET
        let node = RawProxyNode(
            name: "N",
            fields: ["name": .string("N"), "type": .string("http"), "server": .string("127.0.0.1"), "port": .int(8080)]
        )
        let chain = ExtractedProxyChain(
            primaryNodeName: "N",
            orderedProxyNames: ["N"],
            outletGroupMembers: ["N"],
            availableFallbackNames: [],
            missingFallbackNames: [],
            proxies: [node]
        )
        let renderer = MihomoConfigRenderer()
        let yamlOn = try renderer.renderYAML(outlet: decoded.outlets[0], chain: chain, bypassRules: decoded.bypassRules)
        let parsedOn = try XCTUnwrap(try Yams.load(yaml: yamlOn) as? [String: Any])
        let rulesOn = try XCTUnwrap(parsedOn["rules"] as? [String])

        let lastDirectIndex = try XCTUnwrap(rulesOn.lastIndex(where: { $0.contains(",DIRECT") }))
        let matchIndex = try XCTUnwrap(rulesOn.firstIndex(of: "MATCH,OUTLET"))
        XCTAssertEqual(MihomoConfigRenderer.builtInTelemetryRules.count, 14)

        for rejectRule in MihomoConfigRenderer.builtInTelemetryRules {
            let idx = try XCTUnwrap(rulesOn.firstIndex(of: rejectRule), "Missing telemetry rule: \(rejectRule)")
            XCTAssertGreaterThan(idx, lastDirectIndex, "Telemetry REJECT rule must appear after DIRECT rules")
            XCTAssertLessThan(idx, matchIndex, "Telemetry REJECT rule must appear before MATCH,OUTLET")
        }

        // 3. Verify NONE of the 6 allowed model/login/asset domains match any telemetry suffix or wildcard rule
        let allowedDomains = [
            "daily-cloudcode-pa.googleapis.com",
            "aicode.googleapis.com",
            "www.googleapis.com",
            "oauth2.googleapis.com",
            "gstatic.com",
            "lh3.googleusercontent.com"
        ]
        for domain in allowedDomains {
            for suffix in MihomoConfigRenderer.builtInTelemetryDomainSuffixes {
                XCTAssertFalse(
                    domain == suffix || domain.hasSuffix("." + suffix),
                    "Allowed domain \(domain) must NOT match telemetry suffix \(suffix)"
                )
            }
            for wildcard in MihomoConfigRenderer.builtInTelemetryDomainWildcards {
                let regexPattern = "^" + NSRegularExpression.escapedPattern(for: wildcard)
                    .replacingOccurrences(of: "\\*", with: "[^.]*") + "$"
                let matches = domain.range(of: regexPattern, options: .regularExpression) != nil
                XCTAssertFalse(matches, "Allowed domain \(domain) must NOT match telemetry wildcard \(wildcard)")
            }
        }

        // 4. Verify blockTelemetry == false omits all 14 REJECT rules
        var disabledRules = decoded.bypassRules
        disabledRules.blockTelemetry = false
        let yamlOff = try renderer.renderYAML(outlet: decoded.outlets[0], chain: chain, bypassRules: disabledRules)
        let parsedOff = try XCTUnwrap(try Yams.load(yaml: yamlOff) as? [String: Any])
        let rulesOff = try XCTUnwrap(parsedOff["rules"] as? [String])
        for rejectRule in MihomoConfigRenderer.builtInTelemetryRules {
            XCTAssertFalse(rulesOff.contains(rejectRule), "Rule \(rejectRule) must be omitted when blockTelemetry is false")
        }
    }

    // MARK: - AppUpdater

    func testAppUpdaterSemVerAndSHA256SumsParsing() throws {
        let v009 = try XCTUnwrap(SemanticVersion(string: "0.0.9"))
        let v010 = try XCTUnwrap(SemanticVersion(string: "v0.1.0"))
        let v010Beta1 = try XCTUnwrap(SemanticVersion(string: "v0.1.0-beta.1"))
        let v010Beta2 = try XCTUnwrap(SemanticVersion(string: "0.1.0-beta.2+build42"))
        let v12 = try XCTUnwrap(SemanticVersion(string: "1.2"))

        XCTAssertLessThan(v009, v010)
        XCTAssertLessThan(v010Beta1, v010Beta2)
        XCTAssertLessThan(v010Beta2, v010)
        XCTAssertEqual(v12, SemanticVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(v010.tagString, "v0.1.0")
        XCTAssertNil(SemanticVersion(string: "not-a-version"))

        let sampleHash = String(repeating: "a", count: 64)
        let sumsText = """
        # comment line
        \(sampleHash)  PinGate-v0.1.0-arm64.zip
        \(String(repeating: "b", count: 64)) *./dist/PinGate-v0.1.0-arm64.dmg
        """
        let parsed = AppUpdater.parseSHA256Sums(sumsText)
        XCTAssertEqual(parsed["PinGate-v0.1.0-arm64.zip"], sampleHash)
        XCTAssertEqual(parsed["PinGate-v0.1.0-arm64.dmg"], String(repeating: "b", count: 64))
    }

    func testAppUpdaterCheckDownloadVerifyAndUpgradeScript() async throws {
        // Build a synthetic ad-hoc signed PinGate.app and zip it with ditto
        let syntheticRoot = tempDir.appendingPathComponent("synthetic-release", isDirectory: true)
        let appBundle = syntheticRoot.appendingPathComponent("PinGate.app", isDirectory: true)
        let macOSDir = appBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let resourcesBinDir = appBundle.appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: macOSDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resourcesBinDir, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>CFBundleIdentifier</key><string>com.pingate.test</string>
          <key>CFBundleExecutable</key><string>PinGateApp</string>
          <key>CFBundleShortVersionString</key><string>0.1.0</string>
        </dict></plist>
        """
        try infoPlist.write(to: appBundle.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let fakeExec = macOSDir.appendingPathComponent("PinGateApp")
        try "#!/bin/sh\necho ok\n".write(to: fakeExec, atomically: true, encoding: .utf8)
        try ConfigStore.setPosixPermissions(0o755, at: fakeExec)

        let fakeCLI = resourcesBinDir.appendingPathComponent("pingate")
        try "#!/bin/sh\necho cli\n".write(to: fakeCLI, atomically: true, encoding: .utf8)
        try ConfigStore.setPosixPermissions(0o755, at: fakeCLI)

        // Ad-hoc sign the synthetic bundle and zip it
        let signProc = Process()
        signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signProc.arguments = ["--force", "--deep", "--sign", "-", appBundle.path]
        try signProc.run()
        signProc.waitUntilExit()
        XCTAssertEqual(signProc.terminationStatus, 0)

        let zipURL = syntheticRoot.appendingPathComponent("PinGate-v0.1.0-arm64.zip")
        let dittoProc = Process()
        dittoProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        dittoProc.arguments = ["-c", "-k", "--keepParent", appBundle.path, zipURL.path]
        try dittoProc.run()
        dittoProc.waitUntilExit()
        XCTAssertEqual(dittoProc.terminationStatus, 0)

        let zipData = try Data(contentsOf: zipURL)
        let store = ConfigStore(baseDirectory: tempDir.appendingPathComponent("updater-store", isDirectory: true))
        _ = try store.loadOrBootstrap()

        let sessionFactory: @Sendable (OutletConfig?) -> URLSession = { _ in
            let cfg = URLSessionConfiguration.ephemeral
            cfg.protocolClasses = [MockURLProtocol.self]
            return URLSession(configuration: cfg)
        }
        let updater = AppUpdater(repository: "example/pingate", configStore: store, sessionFactory: sessionFactory)
        let validHash = try updater.sha256Hex(of: zipURL)

        let releaseJSON = """
        {
          "tag_name": "v0.1.0",
          "name": "PinGate v0.1.0",
          "body": "Initial release notes",
          "html_url": "https://github.com/example/pingate/releases/tag/v0.1.0",
          "published_at": "2026-11-23T08:00:00Z",
          "assets": [
            {
              "name": "PinGate-v0.1.0-arm64.zip",
              "browser_download_url": "https://downloads.example.com/PinGate-v0.1.0-arm64.zip",
              "size": \(zipData.count)
            },
            {
              "name": "SHA256SUMS.txt",
              "browser_download_url": "https://downloads.example.com/SHA256SUMS.txt",
              "size": 90
            }
          ]
        }
        """

        var servedChecksums = "\(validHash)  PinGate-v0.1.0-arm64.zip\n"
        MockURLProtocol.handler = { request in
            let url = request.url!
            if url.path.hasSuffix("/releases/latest") {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
                    Data(releaseJSON.utf8)
                )
            }
            if url.lastPathComponent == "SHA256SUMS.txt" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/plain"])!,
                    Data(servedChecksums.utf8)
                )
            }
            if url.lastPathComponent == "PinGate-v0.1.0-arm64.zip" {
                return (
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "\(zipData.count)"])!,
                    zipData
                )
            }
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { MockURLProtocol.handler = nil }

        // 1. Check 0.0.9 -> 0.1.0 reports updateAvailable
        let checkResult = try await updater.checkForUpdates(currentVersion: SemanticVersion(major: 0, minor: 0, patch: 9))
        guard case .updateAvailable(_, let release) = checkResult else {
            XCTFail("Expected updateAvailable for 0.0.9 -> 0.1.0")
            return
        }
        XCTAssertEqual(release.tagName, "v0.1.0")

        // 2. Check 0.1.0 -> 0.1.0 reports upToDate
        let sameResult = try await updater.checkForUpdates(currentVersion: SemanticVersion(major: 0, minor: 1, patch: 0))
        XCTAssertFalse(sameResult.hasUpdate)

        // 3. Download, SHA-256 verify, extract, and codesign verify
        let prepared = try await updater.downloadAndVerify(release: release, verifyCodeSign: true)
        XCTAssertEqual(prepared.verifiedSHA256, validHash)
        XCTAssertTrue(prepared.stagingDirectory.path.hasPrefix(updater.updatesDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagedAppURL.path))
        let updatesAttrs = try FileManager.default.attributesOfItem(atPath: updater.updatesDirectory.path)
        XCTAssertEqual((updatesAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)

        // 4. Config backup is 0600 and update script contains expected safe swap steps
        let backupURL = try XCTUnwrap(try updater.backupConfigIfPresent())
        let backupAttrs = try FileManager.default.attributesOfItem(atPath: backupURL.path)
        XCTAssertEqual((backupAttrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let script = AppUpdater.renderUpdateScript(
            stagedAppPath: prepared.stagedAppURL.path,
            targetAppPath: "/Applications/PinGate.app",
            stagingDirectoryPath: prepared.stagingDirectory.path,
            cliInstallPath: "/Users/example/.local/bin/pingate",
            waitForPID: 12345,
            relaunchApp: true
        )
        XCTAssertTrue(script.contains("WAIT_PID=12345"))
        XCTAssertTrue(script.contains("kill -TERM \"$WAIT_PID\""))
        XCTAssertTrue(script.contains("kill -KILL \"$WAIT_PID\""))
        XCTAssertTrue(script.contains("TRASH_DIR=\"$HOME/.Trash\""))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("Contents/Resources/bin/pingate"))
        XCTAssertTrue(
            script.contains(
                "/usr/bin/env -u ELECTRON_RUN_AS_NODE -u ELECTRON_NO_ASAR -u ELECTRON_NO_ATTACH_CONSOLE -u NODE_OPTIONS /usr/bin/open -a \"$TARGET_APP\""
            )
        )

        // 4b. scheduleSelfUpdate fails fast when staged app directory is missing
        let missingPrepared = PreparedUpdate(
            release: release,
            archiveURL: prepared.archiveURL,
            stagingDirectory: tempDir.appendingPathComponent("nonexistent-stage", isDirectory: true),
            stagedAppURL: tempDir.appendingPathComponent("nonexistent-stage/extracted/PinGate.app", isDirectory: true),
            verifiedSHA256: validHash
        )
        XCTAssertThrowsError(try updater.scheduleSelfUpdate(prepared: missingPrepared, relaunchApp: false)) { error in
            guard case AppUpdaterError.invalidAppBundle = error else {
                XCTFail("Expected invalidAppBundle for missing staged app, got \(error)")
                return
            }
        }

        // 5. Tampered checksum MUST fail with checksumMismatch
        servedChecksums = "\(String(repeating: "f", count: 64))  PinGate-v0.1.0-arm64.zip\n"
        do {
            _ = try await updater.downloadAndVerify(release: release, verifyCodeSign: true)
            XCTFail("Expected checksumMismatch for tampered SHA256SUMS")
        } catch AppUpdaterError.checksumMismatch {
            // Expected
        }
    }

    func testAppUpdaterRenderUpdateScriptSanitizesElectronEnvironment() {
        let script = AppUpdater.renderUpdateScript(
            stagedAppPath: "/var/empty/staged/PinGate.app",
            targetAppPath: "/Applications/PinGate.app",
            stagingDirectoryPath: "/var/empty/staged",
            cliInstallPath: nil,
            waitForPID: nil,
            relaunchApp: true
        )

        XCTAssertTrue(script.contains("env -u ELECTRON_RUN_AS_NODE"))
        XCTAssertTrue(script.contains("-u ELECTRON_NO_ASAR"))
        XCTAssertTrue(script.contains("-u ELECTRON_NO_ATTACH_CONSOLE"))
        XCTAssertTrue(script.contains("-u NODE_OPTIONS"))
        XCTAssertTrue(script.contains("open -a \"$TARGET_APP\""))

        let noRelaunchScript = AppUpdater.renderUpdateScript(
            stagedAppPath: "/var/empty/staged/PinGate.app",
            targetAppPath: "/Applications/PinGate.app",
            stagingDirectoryPath: "/var/empty/staged",
            cliInstallPath: nil,
            waitForPID: nil,
            relaunchApp: false
        )
        XCTAssertFalse(noRelaunchScript.contains("open -a \"$TARGET_APP\""))
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
