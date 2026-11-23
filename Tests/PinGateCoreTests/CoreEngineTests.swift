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
        XCTAssertTrue(noProxy.contains(".corp.example.com"))
        XCTAssertTrue(noProxy.contains("10.0.0.0/8"))

        let chromium = rules.chromiumBypassList()
        XCTAssertTrue(chromium.contains("[::1]"))
        XCTAssertTrue(chromium.contains("*.corp.example.com"))
        XCTAssertTrue(chromium.contains("*.intranet.example.org"))
        XCTAssertTrue(chromium.contains("10.0.0.0/8"))

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

        // Verify DNS configuration: domestic default/proxy-server nameservers, remote DoH, NO dns.listen
        let dns = try XCTUnwrap(parsed["dns"] as? [String: Any])
        XCTAssertEqual(dns["default-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        XCTAssertEqual(dns["proxy-server-nameserver"] as? [String], ["223.5.5.5", "119.29.29.29"])
        let remoteDNS = try XCTUnwrap(dns["nameserver"] as? [String])
        XCTAssertTrue(remoteDNS.allSatisfy { $0.hasPrefix("https://") })
        XCTAssertNil(dns["listen"], "Rendered Mihomo config must not bind an unused dns.listen port")

        // Verify rules order: private CIDRs + bypass domains BEFORE MATCH,OUTLET
        let rules = try XCTUnwrap(parsed["rules"] as? [String])
        let matchIndex = try XCTUnwrap(rules.firstIndex(of: "MATCH,OUTLET"))
        XCTAssertEqual(matchIndex, rules.count - 1)

        let requiredBeforeMatch = [
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
            "DOMAIN-SUFFIX,internal.example.com,DIRECT",
            "DOMAIN-SUFFIX,corp.example.net,DIRECT"
        ]
        for rule in requiredBeforeMatch {
            let idx = try XCTUnwrap(rules.firstIndex(of: rule), "Missing rule: \(rule)")
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
        XCTAssertEqual(HealthState.protected.displayName, "已受保护")
        XCTAssertEqual(HealthState.leaking.displayName, "发现漏网")
        XCTAssertEqual(SocketClassification.proxied.displayName, "已走代理")
        XCTAssertEqual(SocketClassification.leak.displayName, "疑似漏网")
        XCTAssertEqual(ProxyEnvStatus.missing.displayName, "缺少代理环境变量")
        XCTAssertEqual(CaptureMode.userSpace.rawValue, "userSpace")
        XCTAssertEqual(CaptureMode.userSpace.displayName, "用户态托管模式（阶段 1–2）")
        XCTAssertEqual(TargetKind.guiApp.rawValue, "guiApp")
        XCTAssertEqual(TargetKind.guiApp.displayName, "桌面应用")
        XCTAssertEqual(MihomoProcessState.running.displayName, "运行中")

        XCTAssertTrue(
            ClashProfileParserError.missingProxiesSection.localizedDescription.contains("未找到代理节点")
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
