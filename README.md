# PinGate

**App-level fixed proxy outlet & real-time leak guard for macOS.**

PinGate pins selected macOS applications, their subprocess trees, and companion CLIs (such as `Antigravity.app`, `T3 Code`, and `agy`) to a dedicated, fixed proxy outlet—completely decoupled from your main system proxy and safe alongside corporate VPNs (`utun`).

---

## Key Capabilities

- **Single Source of Truth, Zero Hardcoding**: All outlets, managed targets, bypass rules, and policies live in structured JSON (`~/Library/Application Support/PinGate/config.json`, mode `0600`). No hardcoded exit IPs, no plaintext credentials in `/tmp`.
- **Managed Mihomo Core + Auto-Sync**:
  - Supervises an isolated Mihomo instance (`~/Library/Application Support/PinGate/bin/mihomo`, mode `0700`) with loopback controller API.
  - Watches local FlClash profiles via `DispatchSource` (or fetches remote subscriptions / manual YAML / upstream proxies), recursively resolves `dialer-proxy` chains, renders a hardened `0600` `mihomo.yaml`, and hot-reloads via `PUT /configs?force=true`.
  - Enforces domestic `default-nameserver` / `proxy-server-nameserver` (`223.5.5.5`, `119.29.29.29`) for relay resolution, remote DoH for proxied traffic, and private CIDR + corporate `DOMAIN-SUFFIX` `DIRECT` rules before `MATCH`.
- **Real-Time Native `libproc` Leak Auditing**:
  - Inspects protected processes' live environment variables (`sysctl KERN_PROCARGS2`) and active TCP sockets (`proc_pidinfo`) every 3 seconds with zero `lsof` subprocess overhead.
  - Surfaces immediate status in the macOS menu bar (**Protected / Warning / Leaking / Stopped**), triggers native notifications on leaks, and offers one-click **Restart with Proxy** recovery if an app auto-updates and drops its proxy environment.
- **Dual-Mode Traffic Capture Architecture**:
  - **Mode 1 (Available Now)**: User-space managed launcher (`NSWorkspace` + Chromium proxy flags + `NODE_USE_ENV_PROXY=1`), `~/.local/bin/<cmd>` CLI shims, and idempotent T3 Code settings sync.
  - **Mode 2 (Phase 3 Blueprint)**: Protocol-decoupled `NETransparentProxyProvider` System Extension design ([Docs/system-extension-design.md](Docs/system-extension-design.md)) for OS-level per-process transparent proxying without touching corporate VPN `utun`.

---

## Requirements

- macOS 15.0+ (Apple Silicon / Intel)
- Swift 6.0+ / Xcode Command Line Tools

---

## Build, Test & Package

```bash
# Run unit tests
swift test

# Build release binaries & assemble /Applications/PinGate.app + ~/.local/bin/pingate
./Scripts/bundle_app.sh

# Optional: bundle into a custom directory instead of /Applications
./Scripts/bundle_app.sh --output-dir ./build
```

`Scripts/bundle_app.sh` compiles `PinGateApp` and `pingate-cli` in release mode, generates `AppIcon.icns`, writes a hardened `Info.plist` (`com.pingate.app`, `LSUIElement=true`), ad-hoc signs `/Applications/PinGate.app`, and installs the `pingate` CLI into `~/.local/bin/pingate`.

---

## CLI Usage (`pingate`)

```bash
pingate status              # Show managed Mihomo status, active outlet, exit IP, and target health
pingate audit               # Run real-time libproc process & socket leak audit
pingate sync                # Re-sync nodes from FlClash/subscription and hot-reload Mihomo
pingate launch <target>     # Launch or activate a managed app with proxy injection & fail-closed checks
```

---

## Migrating from Legacy `AntigravityProxy`

A safe, idempotent migration script is included to transition away from the legacy LaunchAgent and clean up plaintext `/tmp` artifacts. It defaults to `--dry-run`:

```bash
# Preview every action without modifying anything
./Scripts/migrate_from_legacy.sh --dry-run

# Execute migration (stops legacy LaunchAgent, preserves mihomo binary, moves legacy app/dir to Trash, removes /tmp remnants)
./Scripts/migrate_from_legacy.sh --apply
```

What `--apply` does:
1. Unloads any legacy `*antigravity-proxy*` LaunchAgent and moves its `.plist` to `~/.Trash`.
2. Moves `/Applications/Antigravity Proxy.app` to `~/.Trash` (reversible).
3. Copies & SHA-256 verifies `mihomo` from `~/Library/Application Support/AntigravityProxy/mihomo` into `~/Library/Application Support/PinGate/bin/mihomo` (`0700`) and seeds non-secret local outlet/bypass preferences before moving the legacy directory to `~/.Trash`.
4. Deletes plaintext temporary directories: `/tmp/agpin`, `/tmp/asar`, `/tmp/server`, `/tmp/t3code-install`.

---

## Security & File Permissions

| Path | Mode | Purpose |
| :--- | :---: | :--- |
| `~/Library/Application Support/PinGate/` | `0700` | Application state root |
| `~/Library/Application Support/PinGate/config.json` | `0600` | Outlets, managed targets, bypass rules |
| `~/Library/Application Support/PinGate/mihomo.yaml` | `0600` | Rendered Mihomo runtime config (contains node credentials & controller secret) |
| `~/Library/Application Support/PinGate/bin/mihomo` | `0700` | Managed Mihomo binary |

---

## Project Layout

```text
Sources/
├── PinGateCore/       # Models, ConfigStore, NodeSync, ProxyEngine, TrafficCapture, LeakAuditor
├── PinGateApp/        # Native SwiftUI MenuBarExtra + Dashboard Window
└── PinGateCLI/        # `pingate` command-line tool
Tests/
└── PinGateCoreTests/  # Unit tests for parser, renderer, bypass matching, auditor & adapters
Scripts/
├── bundle_app.sh      # Release build & .app packager
└── migrate_from_legacy.sh
Docs/
└── system-extension-design.md
```
