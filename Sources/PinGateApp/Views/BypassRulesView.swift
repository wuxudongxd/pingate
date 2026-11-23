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
                Text("Bypass Rules")
                    .font(.title2.bold())
                Text("Keep corporate VPN domains, LAN services, and loopback addresses routed directly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Reset Defaults") {
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
                Text("Single Source of Truth for DIRECT Routing")
                    .font(.subheadline.weight(.semibold))
                Text("Entries below are injected simultaneously into Mihomo (`IP-CIDR` / `DOMAIN-SUFFIX` DIRECT rules before `MATCH`), `NO_PROXY`, Chromium `--proxy-bypass-list`, CLI shims, and `LeakAuditor`'s allowlist so corporate VPN (`utun`) traffic never breaks or triggers false leak alerts.")
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
        GroupBox("Corporate / Internal Bypass Domains") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("e.g. .corp.example.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addDomain() }
                    Button("Add") { addDomain() }
                        .disabled(newDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if draftRules.domains.isEmpty {
                    Text("No custom bypass domains configured. Add internal corporate domains here so they route directly via your system/VPN stack.")
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
        GroupBox("Private & Direct IP CIDRs") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("e.g. 10.0.0.0/8", text: $newCIDR)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addCIDR() }
                    Button("Add") { addCIDR() }
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
        GroupBox("Extra NO_PROXY Hosts") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("e.g. localhost, *.local", text: $newNoProxy)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addNoProxy() }
                    Button("Add") { addNoProxy() }
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
        GroupBox("Generated Environment & Mihomo Rule Preview") {
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
                Text("Unsaved bypass changes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Button("Save & Hot-Reload Mihomo") {
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
