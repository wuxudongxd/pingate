import PinGateCore
import SwiftUI

private enum SocketFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case leaks = "仅漏网"
    case proxied = "已代理"
    case bypass = "直连/本地"

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
                Text("实时防漏审计与监控")
                    .font(.title2.bold())
                Text("基于 macOS 原生 Darwin libproc 检查（每 3 秒扫描，零子进程开销）。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let ts = appState.auditSnapshot?.timestamp {
                Text("更新于 \(AppState.clockTimeString(from: ts))")
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
                title: "保护状态",
                value: appState.overallHealthState.displayName,
                subtitle: snapshot?.summary ?? "等待首次扫描…",
                color: appState.healthColor,
                icon: appState.menuBarSymbolName
            )
            kpiCard(
                title: "已代理 Socket",
                value: String(proxied),
                subtitle: "已验证命中固定出口端口",
                color: .green,
                icon: "checkmark.circle.fill"
            )
            kpiCard(
                title: "直连白名单",
                value: String(bypass),
                subtitle: "命中私有 CIDR / VPN 白名单",
                color: .blue,
                icon: "arrow.triangle.branch"
            )
            kpiCard(
                title: "漏网检测",
                value: leaks == 0 ? "0 漏网" : "\(String(leaks)) 处漏网！",
                subtitle: leaks == 0 ? "零公网直连漏网" : "发现漏网，请立即处理",
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
        return GroupBox("纳管进程状态（\(String(processes.count))）") {
            if processes.isEmpty {
                Text("当前没有正在运行的纳管目标进程。")
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
                            Text("\(String(proc.proxiedSocketCount)) 条代理")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 74, alignment: .trailing)

                            if proc.isLeaking,
                               let tid = proc.targetID,
                               let target = appState.config.targets.first(where: { $0.id == tid && $0.kind == .guiApp })
                            {
                                Button("用代理重启") {
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
                    Text("实时 Socket 防漏审计（\(String(filteredSockets.count))）")
                        .font(.headline)
                    Spacer()
                    Picker("筛选", selection: $socketFilter) {
                        ForEach(SocketFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }

                if filteredSockets.isEmpty {
                    Text(socketFilter == .leaks ? "未检测到任何漏网 Socket。" : "当前筛选条件下无活跃 Socket。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("PID").frame(width: 58, alignment: .leading)
                            Text("进程").frame(width: 150, alignment: .leading)
                            Text("远端地址").frame(maxWidth: .infinity, alignment: .leading)
                            Text("状态").frame(width: 96, alignment: .leading)
                            Text("分类").frame(width: 110, alignment: .trailing)
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
                    Text("mihomo 实时活跃连接（\(String(appState.activeConnections.count))）")
                        .font(.headline)
                    Spacer()
                    Button("刷新") {
                        Task { await appState.refreshActiveConnections() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!appState.outletRunning)
                }

                if !appState.outletRunning {
                    Text("请先启动托管出口以查看 mihomo 实时代理连接。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else if appState.activeConnections.isEmpty {
                    Text("当前暂无经由 mihomo 的活跃连接。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Text("目标地址").frame(maxWidth: .infinity, alignment: .leading)
                            Text("协议").frame(width: 52, alignment: .leading)
                            Text("命中规则").frame(width: 120, alignment: .leading)
                            Text("代理链").frame(width: 170, alignment: .leading)
                            Text("上传 / 下载").frame(width: 120, alignment: .trailing)
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
        GroupBox("流量接管模式与 Phase 3 系统扩展就绪状态") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(appState.config.captureMode.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("已预留 NETransparentProxyProvider 架构")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.blue.opacity(0.14)))
                            .foregroundStyle(.blue)
                    }

                    Text(appState.captureModeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Phase 3 基于 macOS NETransparentProxyProvider（按进程 audit_token_t 实现 L4 流级透明拦截，非 TUN 模式），可与公司 VPN（utun）无冲突共存。启用需具备带 Network Extension 权限的 Apple Developer ID 签名证书，详见 Docs/system-extension-design.md。")
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
