import PinGateCore
import SwiftUI

private enum ConnectionFilter: String, CaseIterable, Identifiable {
    case key = "外部连接"
    case leaks = "仅漏网"
    case proxied = "已代理"
    case bypass = "直连"

    var id: String { rawValue }
}

struct AuditMonitorView: View {
    @Bindable var appState: AppState
    @State private var connectionFilter: ConnectionFilter = .key
    @State private var showLoopback: Bool = false
    @State private var showEngineDetails: Bool = false
    @State private var targetPendingRestart: ManagedTarget?

    private var allSockets: [SocketRecord] {
        (appState.auditSnapshot?.processes ?? []).flatMap(\.sockets)
    }

    private var loopbackCount: Int {
        deduplicatedLoopbacks(from: allSockets).count
    }

    private var visibleSockets: [SocketRecord] {
        let nonLoopback = allSockets.filter { $0.classification != .loopback }
        let loopbacks = showLoopback ? deduplicatedLoopbacks(from: allSockets) : []

        let base: [SocketRecord]
        switch connectionFilter {
        case .key:
            base = nonLoopback + loopbacks
        case .leaks:
            base = allSockets.filter { $0.classification == .leak }
        case .proxied:
            base = allSockets.filter { $0.classification == .proxied }
        case .bypass:
            base = allSockets.filter { $0.classification == .bypass } + loopbacks
        }

        return base.sorted { lhs, rhs in
            let lRank = sortRank(lhs.classification)
            let rRank = sortRank(rhs.classification)
            if lRank != rRank { return lRank < rRank }
            if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
            return lhs.remoteEndpoint < rhs.remoteEndpoint
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
                advancedEngineSection
            }
            .padding(22)
        }
        .alert(
            "重启「\(targetPendingRestart?.name ?? "")」并走代理？",
            isPresented: Binding(
                get: { targetPendingRestart != nil },
                set: { if !$0 { targetPendingRestart = nil } }
            )
        ) {
            Button("重启并走代理", role: .destructive) {
                if let target = targetPendingRestart {
                    targetPendingRestart = nil
                    Task { await appState.restartTargetWithProxy(target: target) }
                }
            }
            Button("取消", role: .cancel) {
                targetPendingRestart = nil
            }
        } message: {
            Text("将关闭当前未走代理的实例，并通过代理重新启动。")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("运行状态")
                    .font(.title2.bold())
                Text("每 3 秒自动检查活跃连接")
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
        let procCount = snapshot?.processes.count ?? 0
        let portStr = appState.config.primaryOutlet().map { String($0.listenPort) } ?? "17899"

        return HStack(spacing: 12) {
            kpiCard(
                title: "保护状态",
                value: appState.overallHealthState.displayName,
                subtitle: procCount > 0 ? "\(String(procCount)) 个应用进程运行中" : "当前无运行中的代理应用",
                valueColor: appState.healthColor,
                alertHighlight: appState.overallHealthState == .leaking
            )

            kpiCard(
                title: "代理连接",
                value: String(proxied),
                subtitle: bypass > 0
                    ? "命中出口 :\(portStr)，另有 \(String(bypass)) 条直连"
                    : "已走本地代理 :\(portStr)",
                valueColor: .primary,
                alertHighlight: false
            )

            kpiCard(
                title: "直连检查",
                value: leaks == 0 ? "0 漏网" : "\(String(leaks)) 处漏网",
                subtitle: leaks == 0 ? "所有外网流量均已走代理" : "请检查下方未走代理的连接",
                valueColor: leaks == 0 ? .green : .red,
                alertHighlight: leaks > 0
            )
        }
    }

    private func kpiCard(
        title: String,
        value: String,
        subtitle: String,
        valueColor: Color,
        alertHighlight: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(valueColor)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(alertHighlight ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(alertHighlight ? Color.red.opacity(0.32) : Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var socketTableSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("实时连接（\(String(visibleSockets.count))）")
                    .font(.headline)

                Spacer()

                if connectionFilter == .key || connectionFilter == .bypass {
                    Toggle("显示本机连接（\(String(loopbackCount))）", isOn: $showLoopback)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("筛选", selection: $connectionFilter) {
                    ForEach(ConnectionFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 268)
            }

            if visibleSockets.isEmpty {
                VStack(spacing: 6) {
                    Text(emptySocketsMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false)
                )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("PID").frame(width: 56, alignment: .leading)
                        Text("进程").frame(width: 150, alignment: .leading)
                        Text("远端地址").frame(maxWidth: .infinity, alignment: .leading)
                        Text("状态").frame(width: 100, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    ForEach(visibleSockets) { sock in
                        HStack(spacing: 8) {
                            Text(String(sock.pid))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)
                            Text(sock.processName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)

                            HStack(spacing: 6) {
                                Text(sock.remoteEndpoint)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                if sock.classification == .leak || sock.classification == .bypass,
                                   let reason = sock.reason, !reason.isEmpty
                                {
                                    Text("· \(reason)")
                                        .font(.caption2)
                                        .foregroundStyle(sock.classification == .leak ? Color.red : .secondary)
                                        .lineLimit(1)
                                }
                                if sock.tcpState != "ESTABLISHED" && !sock.tcpState.isEmpty {
                                    Text("(\(sock.tcpState))")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help("TCP 状态：\(sock.tcpState)")

                            classificationIndicator(sock.classification)
                                .frame(width: 100, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(sock.classification == .leak ? Color.red.opacity(0.08) : Color.clear)

                        if sock.id != visibleSockets.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
        }
    }

    private var emptySocketsMessage: String {
        switch connectionFilter {
        case .leaks:
            return "未发现未走代理的连接。"
        case .key:
            return loopbackCount > 0
                ? "当前无外部连接（已隐藏 \(String(loopbackCount)) 条本机连接）。"
                : "当前无活跃连接。"
        case .proxied:
            return "当前暂无代理连接。"
        case .bypass:
            return "当前无直连记录。"
        }
    }

    private var processesSection: some View {
        let processes = appState.auditSnapshot?.processes ?? []
        return VStack(alignment: .leading, spacing: 10) {
            Text("受保护进程（\(String(processes.count))）")
                .font(.headline)

            if processes.isEmpty {
                Text("当前没有运行中的代理应用进程。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            } else {
                VStack(spacing: 0) {
                    ForEach(processes) { proc in
                        HStack(spacing: 10) {
                            Text(String(proc.pid))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .leading)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(proc.processName)
                                    .font(.subheadline.weight(.medium))
                                Text(AppState.shortenedPath(proc.executablePath))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            envStatusIndicator(proc.proxyEnvStatus)

                            Text("\(String(proc.proxiedSocketCount)) 条连接")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 68, alignment: .trailing)

                            if proc.isLeaking,
                               let tid = proc.targetID,
                               let target = appState.config.targets.first(where: { $0.id == tid && $0.kind == .guiApp })
                            {
                                Button("重启并走代理") {
                                    targetPendingRestart = target
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(proc.isLeaking ? Color.red.opacity(0.08) : Color.clear)

                        if proc.id != processes.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
        }
    }

    private var mihomoConnectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("活跃代理连接（\(String(appState.activeConnections.count))）")
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
                Text("开启代理保护后即可查看实时连接。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            } else if appState.activeConnections.isEmpty {
                Text("当前暂无活跃代理连接。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            .allowsHitTesting(false)
                    )
            } else {
                VStack(spacing: 0) {
                    HStack {
                        Text("目标地址").frame(maxWidth: .infinity, alignment: .leading)
                        Text("协议").frame(width: 48, alignment: .leading)
                        Text("命中规则").frame(width: 120, alignment: .leading)
                        Text("代理链").frame(width: 165, alignment: .leading)
                        Text("上传 / 下载").frame(width: 115, alignment: .trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                    Divider()

                    let displayed = Array(appState.activeConnections.prefix(40))
                    ForEach(displayed) { conn in
                        HStack {
                            Text(conn.displayDestination)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(conn.network.uppercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 48, alignment: .leading)
                            Text(conn.rulePayload.isEmpty ? conn.rule : "\(conn.rule)(\(conn.rulePayload))")
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)
                            Text(conn.chains.joined(separator: " → "))
                                .font(.caption2)
                                .lineLimit(1)
                                .frame(width: 165, alignment: .leading)
                            Text("\(formatBytes(conn.upload)) / \(formatBytes(conn.download))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(width: 115, alignment: .trailing)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)

                        if conn.id != displayed.last?.id {
                            Divider()
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        .allowsHitTesting(false)
                )
            }
        }
    }

    private var advancedEngineSection: some View {
        CollapsibleCard(title: "引擎与高级信息", isExpanded: $showEngineDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自动检查更新")
                            .font(.subheadline.weight(.medium))
                        Text("当前版本 \(appState.currentAppVersion.tagString)，启动时与每 6 小时自动检查 GitHub Releases。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle(
                        "自动检查更新",
                        isOn: Binding(
                            get: { appState.config.autoCheckUpdates },
                            set: { enabled in
                                Task { await appState.setAutoCheckUpdates(enabled) }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    Button(appState.isCheckingUpdate ? "检查中…" : "检查更新") {
                        Task { await appState.checkForUpdates(userInitiated: true) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(appState.isCheckingUpdate)
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("当前模式：")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(appState.config.captureMode.displayName)
                            .font(.caption)
                    }
                    Text(appState.captureModeStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("已预留 macOS 系统扩展透明代理支持（非 TUN 模式，可与公司 VPN 共存），具备 Apple Developer ID 网络扩展签名后即可启用。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func envStatusIndicator(_ status: ProxyEnvStatus) -> some View {
        switch status {
        case .valid:
            StatusDotLabel(text: status.displayName, color: .green)
        case .missing, .wrongPort:
            Text(status.displayName)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.18)))
                .foregroundStyle(.red)
        case .unreadable:
            StatusDotLabel(text: status.displayName, color: .orange)
        }
    }

    @ViewBuilder
    private func classificationIndicator(_ cls: SocketClassification) -> some View {
        switch cls {
        case .leak:
            Text(cls.displayName)
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red.opacity(0.20)))
                .foregroundStyle(.red)
        case .proxied:
            StatusDotLabel(text: cls.displayName, color: .green)
        case .bypass:
            StatusDotLabel(text: cls.displayName, color: .blue)
        case .loopback:
            StatusDotLabel(text: cls.displayName, color: .secondary.opacity(0.6))
        }
    }

    private func sortRank(_ cls: SocketClassification) -> Int {
        switch cls {
        case .leak: return 0
        case .proxied: return 1
        case .bypass: return 2
        case .loopback: return 3
        }
    }

    private func deduplicatedLoopbacks(from records: [SocketRecord]) -> [SocketRecord] {
        var seen = Set<String>()
        var result: [SocketRecord] = []
        for sock in records where sock.classification == .loopback {
            let key = "\(sock.pid)-\(sock.remoteEndpoint)"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(sock)
            }
        }
        return result
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
}
