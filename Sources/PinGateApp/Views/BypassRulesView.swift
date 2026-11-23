import PinGateCore
import SwiftUI

struct BypassRulesView: View {
    @Bindable var appState: AppState
    @State private var draftRules: BypassRules = BypassRules()
    @State private var newDomain: String = ""
    @State private var newCIDR: String = ""
    @State private var newNoProxy: String = ""
    @State private var dirty: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                headerRow
                explanationBanner

                HStack(alignment: .top, spacing: 16) {
                    domainsCard
                    cidrsCard
                }

                extraNoProxyCard
                previewCard
                actionRow
            }
            .padding(22)
        }
        .onAppear {
            draftRules = appState.config.bypassRules
            dirty = false
        }
        .onChange(of: appState.config.bypassRules) { _, updated in
            if !dirty {
                draftRules = updated
            }
        }
    }

    private var headerRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("直连白名单")
                    .font(.title2.bold())
                Text("确保公司 VPN 内网域名、局域网服务与本机回环流量始终直连。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("恢复默认") {
                draftRules = BypassRules()
                dirty = true
            }
            .buttonStyle(.bordered)
        }
    }

    private var explanationBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text("单一事实源：全局统一的 DIRECT 直连规则")
                    .font(.subheadline.weight(.semibold))
                Text("以下条目会同步下发至 mihomo（位于 MATCH 之前的 IP-CIDR / DOMAIN-SUFFIX DIRECT 规则）、NO_PROXY、Chromium --proxy-bypass-list、CLI Shim 与防漏审计白名单，确保公司 VPN（utun）流量不中断且不触发误报。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
        )
    }

    private var domainsCard: some View {
        GroupBox("公司 / 内网直连域名") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("如 .corp.example.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDomain() }
                    Button("添加") { addDomain() }
                        .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if draftRules.domains.isEmpty {
                    Text("暂未配置自定义直连域名。在此添加公司内网域名后缀，使其继续通过系统/VPN 栈直连。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(draftRules.domains, id: \.self) { domain in
                            HStack {
                                Text(domain)
                                    .font(.body.monospaced())
                                Spacer()
                                Button(role: .destructive) {
                                    draftRules.domains.removeAll { $0 == domain }
                                    dirty = true
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }

    private var cidrsCard: some View {
        GroupBox("私网与直连 IP CIDR") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("如 10.0.0.0/8", text: $newCIDR)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addCIDR() }
                    Button("添加") { addCIDR() }
                        .disabled(newCIDR.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                VStack(spacing: 6) {
                    ForEach(draftRules.cidrs, id: \.self) { cidr in
                        HStack {
                            Text(cidr)
                                .font(.body.monospaced())
                            Spacer()
                            Button(role: .destructive) {
                                draftRules.cidrs.removeAll { $0 == cidr }
                                dirty = true
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity)
    }

    private var extraNoProxyCard: some View {
        GroupBox("其他 NO_PROXY 主机条目") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("如 localhost、*.local", text: $newNoProxy)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addNoProxy() }
                    Button("添加") { addNoProxy() }
                        .disabled(newNoProxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                FlowTagList(items: draftRules.extraNoProxyEntries) { entry in
                    draftRules.extraNoProxyEntries.removeAll { $0 == entry }
                    dirty = true
                }
            }
            .padding(8)
        }
    }

    private var previewCard: some View {
        GroupBox("生成的环境变量与规则预览") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("NO_PROXY")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(draftRules.noProxyCSV())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Chromium --proxy-bypass-list")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(draftRules.chromiumBypassList())
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                }
            }
            .padding(8)
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            if dirty {
                Text("白名单有未保存的更改")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("保存并热重载 mihomo") {
                var cfg = appState.config
                cfg.bypassRules = draftRules
                dirty = false
                Task { await appState.saveConfig(cfg, triggerSync: true) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!dirty)
        }
    }

    private func addDomain() {
        let trimmed = newDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draftRules.domains.contains(trimmed) {
            draftRules.domains.append(trimmed)
            dirty = true
        }
        newDomain = ""
    }

    private func addCIDR() {
        let trimmed = newCIDR.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draftRules.cidrs.contains(trimmed) {
            draftRules.cidrs.append(trimmed)
            dirty = true
        }
        newCIDR = ""
    }

    private func addNoProxy() {
        let trimmed = newNoProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !draftRules.extraNoProxyEntries.contains(trimmed) {
            draftRules.extraNoProxyEntries.append(trimmed)
            dirty = true
        }
        newNoProxy = ""
    }
}

private struct FlowTagList: View {
    let items: [String]
    let onRemove: (String) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Button {
                        onRemove(item)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
            }
        }
    }
}
