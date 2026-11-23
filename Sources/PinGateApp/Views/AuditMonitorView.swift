import PinGateCore
import SwiftUI

private enum SocketFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case leaks = "Leaks"
    case proxied = "Proxied"
    case bypass = "Bypass"

    var id: String { rawValue }
}

struct AuditMonitorView: View {
    @Bindable var appState: AppState
    @State private var socketFilter: SocketFilter = .all

    private var allSockets: [SocketRecord] {
        (appState.auditSnapshot?.processes ?? []).flatMap(\.sockets)
    }

    private var filteredSockets: [SocketRecord] {
        switch socketFilter {
        case .all:
            return allSockets
        case .leaks:
            return allSockets.filter { $0.classification == .leak }
        case .proxied:
            return allSockets.filter { $0.classification == .proxied }
        case .bypass:
            return allSockets.filter { $0.classification == .bypass || $0.classification == .loopback }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                kpiRow
                socketTableSection
                processesSection
                mihomoConnectionsSection
                systemExtensionCard
            }
            .padding(22)
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Real-Time Leak Audit & Monitor")
                    .font(.title2.bold())
                Text("Native Darwin libproc inspection (3s cadence, zero subprocess polling).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ts = appState.auditSnapshot?.timestamp {
                Text("Updated \(ts, style: .time)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var kpiRow: some View {
        let snapshot = appState.auditSnapshot
        let leaks = snapshot?.totalLeakSockets ?? 0
        let proxied = snapshot?.totalProxiedSockets ?? 0
        let bypass = snapshot?.totalBypassSockets ?? 0

        return HStack(spacing: 12) {
            kpiCard(
                title: "Protection State",
                value: appState.overallHealthState.displayName,
                subtitle: snapshot?.summary ?? "Waiting for first scan…",
                color: appState.healthColor,
                icon: appState.menuBarSymbolName
            )
            kpiCard(
                title: "Proxied Sockets",
                value: "\(proxied)",
                subtitle: "Verified on outlet port",
                color: .green,
                icon: "checkmark.circle.fill"
            )
            kpiCard(
                title: "Direct Bypass",
                value: "\(bypass)",
                subtitle: "Private CIDR / VPN allowlisted",
                color: .blue,
                icon: "arrow.triangle.branch"
            )
            kpiCard(
                title: "Detected Leaks",
                value: leaks == 0 ? "0 Leaks" : "\(leaks) LEAK!",
                subtitle: leaks == 0 ? "Zero unproxied public sockets" : "Action required",
                color: leaks == 0 ? .green : .red,
                icon: leaks == 0 ? "lock.shield.fill" : "exclamationmark.octagon.fill"
            )
        }
    }

    private func kpiCard(title: String, value: String, subtitle: String, color: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: icon)
                    .foregroundStyle(color)
            }
            Text(value)
                .font(.title3.bold())
                .foregroundStyle(color)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        )
    }

    private var processesSection: some View {
        let processes = appState.auditSnapshot?.processes ?? []
        return GroupBox("Managed Processes (\(processes.count))") {
            if processes.isEmpty {
                Text("No running processes currently match your managed targets.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(processes) { proc in
                        HStack(spacing: 10) {
                            Text(String(proc.pid))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(proc.processName)
                                    .font(.subheadline.weight(.medium))
                                Text(proc.executablePath)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            envBadge(proc.proxyEnvStatus)
                            Text("\(proc.proxiedSocketCount) proxied")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 74, alignment: .trailing)

                            if proc.isLeaking,
                               let tid = proc.targetID,
                               let target = appState.config.targets.first(where: { $0.id == tid && $0.kind == .guiApp })
                            {
                                Button("Restart with Proxy") {
                                    Task { await appState.restartTargetWithProxy(target: target) }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(proc.isLeaking ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
                        )
                    }
                }
                .padding(6)
            }
        }
    }

    private var socketTableSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Live Socket Leak Audit (\(filteredSockets.count))")
                        .font(.headline)
                    Spacer()
                    Picker("Filter", selection: $socketFilter) {
                        ForEach(SocketFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                }

                if filteredSockets.isEmpty {
                    Text(socketFilter == .leaks ? "Zero leaked sockets detected." : "No active sockets matching filter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("PID").frame(width: 58, alignment: .leading)
                            Text("Process").frame(width: 150, alignment: .leading)
                            Text("Remote Endpoint").frame(maxWidth: .infinity, alignment: .leading)
                            Text("State").frame(width: 96, alignment: .leading)
                            Text("Classification").frame(width: 110, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        Divider()

                        ForEach(filteredSockets) { sock in
                            HStack {
                                Text(String(sock.pid))
                                    .font(.caption.monospaced())
                                    .frame(width: 58, alignment: .leading)
                                Text(sock.processName)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 150, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(sock.remoteEndpoint)
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                    if let reason = sock.reason, !reason.isEmpty {
                                        Text(reason)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Text(sock.tcpState)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 96, alignment: .leading)
                                classificationBadge(sock.classification)
                                    .frame(width: 110, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(sock.classification == .leak ? Color.red.opacity(0.08) : Color.clear)
                            Divider()
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(6)
        }
    }

    private var mihomoConnectionsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Live Mihomo Active Connections (\(appState.activeConnections.count))")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        Task { await appState.refreshActiveConnections() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning)
                }

                if !appState.outletRunning {
                    Text("Start the managed outlet to inspect active Mihomo proxy connections.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else if appState.activeConnections.isEmpty {
                    Text("No active connections through Mihomo right now.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("Destination").frame(maxWidth: .infinity, alignment: .leading)
                            Text("Proto").frame(width: 52, alignment: .leading)
                            Text("Rule").frame(width: 120, alignment: .leading)
                            Text("Chain").frame(width: 170, alignment: .leading)
                            Text("Up / Down").frame(width: 120, alignment: .trailing)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)

                        Divider()

                        ForEach(appState.activeConnections.prefix(40)) { conn in
                            HStack {
                                Text(conn.displayDestination)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(conn.network.uppercased())
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .leading)
                                Text(conn.rulePayload.isEmpty ? conn.rule : "\(conn.rule)(\(conn.rulePayload))")
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 120, alignment: .leading)
                                Text(conn.chains.joined(separator: " → "))
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 170, alignment: .leading)
                                Text("\(formatBytes(conn.upload)) / \(formatBytes(conn.download))")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 120, alignment: .trailing)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(6)
        }
    }

    private var systemExtensionCard: some View {
        GroupBox("Capture Mode & Phase 3 System Extension Readiness") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(appState.config.captureMode.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("NETransparentProxyProvider Ready")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.14)))
                            .foregroundStyle(.blue)
                    }

                    Text(appState.captureModeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Phase 3 uses macOS NETransparentProxyProvider (L4 per-process flow interception via audit_token_t—NOT a TUN interface) so it coexists cleanly with corporate VPN utun interfaces. Requires Developer ID signing with the Network Extension entitlement; see Docs/system-extension-design.md.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(8)
        }
    }

    private func envBadge(_ status: ProxyEnvStatus) -> some View {
        let color: Color
        switch status {
        case .valid: color = .green
        case .missing, .wrongPort: color = .red
        case .unreadable: color = .orange
        }
        return Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func classificationBadge(_ cls: SocketClassification) -> some View {
        let color: Color
        switch cls {
        case .proxied: color = .green
        case .bypass: color = .blue
        case .loopback: color = .secondary
        case .leak: color = .red
        }
        return Text(cls.displayName)
            .font(.caption2.weight(cls == .leak ? .bold : .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(cls == .leak ? 0.22 : 0.14)))
            .foregroundStyle(color)
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
