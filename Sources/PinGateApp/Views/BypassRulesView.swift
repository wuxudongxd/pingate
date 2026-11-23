import AppKit
import PinGateCore
import SwiftUI

struct BypassRulesView: View {
    @Bindable var appState: AppState
    @State private var draftRules: BypassRules = BypassRules()
    @State private var newDomain: String = ""
    @State private var newCIDR: String = ""
    @State private var newNoProxy: String = ""
    @State private var domainError: String?
    @State private var cidrError: String?
    @State private var showPreview: Bool = false
    @State private var showResetConfirm: Bool = false
    @State private var copiedLabel: String?

    private var hasUnsavedChanges: Bool {
        draftRules != appState.config.bypassRules
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow

                HStack(alignment: .top, spacing: 16) {
                    domainsCard
                    cidrsCard
                }

                extraNoProxyCard
                previewSection

                if hasUnsavedChanges {
                    unsavedChangesBar
                }
            }
            .padding(22)
        }
        .onAppear {
            draftRules = appState.config.bypassRules
        }
        .onChange(of: appState.config.bypassRules) { _, updated in
            if !hasUnsavedChanges {
                draftRules = updated
            }
        }
        .confirmationDialog(
            "确定要恢复默认直连白名单吗？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                draftRules = BypassRules()
                domainError = nil
                cidrError = nil
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("这将清空你添加的自定义公司内网域名，并重置私网 CIDR 与本机条目为默认值（点击保存后生效）。")
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("直连白名单")
                    .font(.title2.bold())
                Text("以下域名与私网网段将绕过代理直接走系统网络 / 公司 VPN，且不触发防漏告警。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复默认") {
                showResetConfirm = true
            }
            .buttonStyle(.bordered)
        }
    }

    private var domainsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("公司 / 内网直连域名")
                .font(.headline)

            HStack {
                TextField("如 .corp.example.com", text: $newDomain)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addDomain() }
                    .onChange(of: newDomain) { _, _ in domainError = nil }
                Button("添加") { addDomain() }
                    .buttonStyle(.bordered)
                    .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let domainError {
                Text(domainError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if draftRules.domains.isEmpty {
                Text("暂未配置自定义直连域名。添加公司内网域名后缀后，将自动直连系统 / VPN 网络。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 6) {
                    ForEach(draftRules.domains, id: \.self) { domain in
                        HStack {
                            Text(domain)
                                .font(.body.monospaced())
                            Spacer()
                            Button(role: .destructive) {
                                draftRules.domains.removeAll { $0 == domain }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var cidrsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("私网与直连 IP CIDR")
                .font(.headline)

            HStack {
                TextField("如 10.0.0.0/8", text: $newCIDR)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addCIDR() }
                    .onChange(of: newCIDR) { _, _ in cidrError = nil }
                Button("添加") { addCIDR() }
                    .buttonStyle(.bordered)
                    .disabled(newCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let cidrError {
                Text(cidrError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if draftRules.cidrs.isEmpty {
                Text("暂未配置私网 CIDR，建议保留默认局域网网段。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                VStack(spacing: 6) {
                    ForEach(draftRules.cidrs, id: \.self) { cidr in
                        HStack {
                            Text(cidr)
                                .font(.body.monospaced())
                            Spacer()
                            Button(role: .destructive) {
                                draftRules.cidrs.removeAll { $0 == cidr }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var extraNoProxyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("本机与局域网直连主机")
                .font(.headline)

            HStack {
                TextField("如 localhost、*.local", text: $newNoProxy)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addNoProxy() }
                Button("添加") { addNoProxy() }
                    .buttonStyle(.bordered)
                    .disabled(newNoProxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if draftRules.extraNoProxyEntries.isEmpty {
                Text("暂无额外直连主机条目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                WrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(draftRules.extraNoProxyEntries, id: \.self) { item in
                        HStack(spacing: 5) {
                            Text(item)
                                .font(.caption.monospaced())
                            Button {
                                draftRules.extraNoProxyEntries.removeAll { $0 == item }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.05))
                        )
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var previewSection: some View {
        DisclosureGroup("查看生成的环境变量预览", isExpanded: $showPreview) {
            VStack(alignment: .leading, spacing: 12) {
                previewBlock(title: "NO_PROXY", value: draftRules.noProxyCSV())
                previewBlock(title: "Chromium --proxy-bypass-list", value: draftRules.chromiumBypassList())
            }
            .padding(.top, 10)
        }
        .font(.subheadline.weight(.medium))
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func previewBlock(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(copiedLabel == title ? "已复制" : "复制") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    copiedLabel = title
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        if copiedLabel == title { copiedLabel = nil }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.04))
                )
        }
    }

    private var unsavedChangesBar: some View {
        HStack(spacing: 10) {
            StatusDotLabel(text: "白名单有未保存的更改", color: .orange, emphasized: true)
            Spacer()
            Button("还原") {
                draftRules = appState.config.bypassRules
                domainError = nil
                cidrError = nil
            }
            .buttonStyle(.bordered)
            Button("保存并应用") {
                var cfg = appState.config
                cfg.bypassRules = draftRules
                Task { await appState.saveConfig(cfg, triggerSync: true) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - Validation Helpers

    private func addDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains(" ") || trimmed.contains("://") || trimmed.contains("/") || !trimmed.contains(".") {
            domainError = "请输入有效的域名后缀（如 .corp.example.com）"
            return
        }
        domainError = nil
        if !draftRules.domains.contains(trimmed) {
            draftRules.domains.append(trimmed)
        }
        newDomain = ""
    }

    private func addCIDR() {
        let trimmed = newCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard CIDRNetwork(trimmed) != nil else {
            cidrError = "请输入有效的 IPv4/IPv6 CIDR（如 10.0.0.0/8）"
            return
        }
        cidrError = nil
        if !draftRules.cidrs.contains(trimmed) {
            draftRules.cidrs.append(trimmed)
        }
        newCIDR = ""
    }

    private func addNoProxy() {
        let trimmed = newNoProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draftRules.extraNoProxyEntries.contains(trimmed) {
            draftRules.extraNoProxyEntries.append(trimmed)
        }
        newNoProxy = ""
    }
}

/// Content-sized wrapping flow layout for compact tag chips.
private struct WrappingFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                proposal: ProposedViewSize(width: size.width, height: size.height)
            )
            rowHeight = max(rowHeight, size.height)
            x += size.width + horizontalSpacing
        }
    }
}
