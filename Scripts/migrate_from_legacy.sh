#!/usr/bin/env bash
set -euo pipefail

# PinGate Legacy Migration & Cleanup Script
# Safely migrates from legacy AntigravityProxy to PinGate.
# Defaults to --dry-run; pass --apply to execute changes.

MODE="dry-run"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
UID_NUM="$(id -u)"

LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
LEGACY_APP="/Applications/Antigravity Proxy.app"
LEGACY_SUPPORT_DIR="${HOME}/Library/Application Support/AntigravityProxy"
LEGACY_MIHOMO="${LEGACY_SUPPORT_DIR}/mihomo"
LEGACY_CONFIG="${LEGACY_SUPPORT_DIR}/config.yaml"
T3_SETTINGS="${HOME}/.t3/userdata/settings.json"
FLCLASH_PROFILES_DIR="${HOME}/Library/Application Support/com.follow.clash/profiles"

PINGATE_SUPPORT_DIR="${HOME}/Library/Application Support/PinGate"
PINGATE_BIN_DIR="${PINGATE_SUPPORT_DIR}/bin"
PINGATE_MIHOMO="${PINGATE_BIN_DIR}/mihomo"
PINGATE_CONFIG="${PINGATE_SUPPORT_DIR}/config.json"
TRASH_DIR="${HOME}/.Trash"

TMP_CLEANUP_PATHS=(
    "/tmp/agpin"
    "/tmp/asar"
    "/tmp/server"
    "/tmp/t3code-install"
)

usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run | --apply]

Safely migrates from legacy AntigravityProxy to PinGate:
  1. Discovers, stops & unloads legacy *antigravity-proxy* LaunchAgent(s) and moves plist(s) to ~/.Trash
  2. Moves /Applications/Antigravity Proxy.app to ~/.Trash (reversible)
  3. Copies & SHA-256 verifies mihomo into ~/Library/Application Support/PinGate/bin/mihomo (0700)
  4. Dynamically seeds ~/Library/Application Support/PinGate/config.json (0600) from existing local
     FlClash profile, legacy config.yaml, and T3 Code NO_PROXY settings (if config.json does not exist)
  5. Moves ~/Library/Application Support/AntigravityProxy to ~/.Trash (only after steps 3 & 4 succeed)
  6. Removes plaintext /tmp remnants (/tmp/agpin, /tmp/asar, /tmp/server, /tmp/t3code-install)

Options:
  --dry-run   Preview planned changes without modifying the system (default)
  --apply     Execute the migration and cleanup
  -h, --help  Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --apply)
            MODE="apply"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

tag() {
    if [[ "${MODE}" == "dry-run" ]]; then
        printf '[DRY-RUN]'
    else
        printf '[APPLY]  '
    fi
}

log() {
    printf '%s %s\n' "$(tag)" "$*"
}

move_to_trash() {
    local src="$1"
    if [[ ! -e "${src}" && ! -L "${src}" ]]; then
        log "Already absent (skip): ${src}"
        return 0
    fi
    local base
    base="$(basename "${src}")"
    local dest="${TRASH_DIR}/${base}"
    if [[ -e "${dest}" || -L "${dest}" ]]; then
        dest="${TRASH_DIR}/${base}.${TIMESTAMP}"
    fi
    if [[ "${MODE}" == "dry-run" ]]; then
        log "Would move to Trash: ${src} -> ${dest}"
    else
        mkdir -p "${TRASH_DIR}"
        mv "${src}" "${dest}"
        log "Moved to Trash: ${src} -> ${dest}"
    fi
}

echo "============================================================"
echo " PinGate Legacy Migration (${MODE})"
echo "============================================================"

# Step 1: Discover, stop & unload legacy LaunchAgent(s)
log "Step 1: Check legacy LaunchAgent(s) matching *antigravity-proxy*.plist"
LEGACY_PLISTS=()
if [[ -d "${LAUNCH_AGENTS_DIR}" ]]; then
    while IFS= read -r -d '' plist; do
        LEGACY_PLISTS+=("${plist}")
    done < <(find "${LAUNCH_AGENTS_DIR}" -maxdepth 1 -name "*antigravity-proxy*.plist" -print0 2>/dev/null || true)
fi

if [[ ${#LEGACY_PLISTS[@]} -eq 0 ]]; then
    log "No legacy *antigravity-proxy*.plist found in ${LAUNCH_AGENTS_DIR}"
else
    for plist in "${LEGACY_PLISTS[@]}"; do
        label="$(/usr/libexec/PlistBuddy -c 'Print :Label' "${plist}" 2>/dev/null || basename "${plist}" .plist)"
        if launchctl print "gui/${UID_NUM}/${label}" >/dev/null 2>&1; then
            if [[ "${MODE}" == "dry-run" ]]; then
                log "Would bootout LaunchAgent: gui/${UID_NUM}/${label}"
            else
                launchctl bootout "gui/${UID_NUM}/${label}" 2>/dev/null \
                    || launchctl unload -w "${plist}" 2>/dev/null \
                    || true
                log "Stopped & unloaded LaunchAgent: ${label}"
            fi
        else
            log "LaunchAgent not currently loaded: ${label}"
        fi
        move_to_trash "${plist}"
    done
fi

# Also check for any stray legacy mihomo process running out of AntigravityProxy
LEGACY_PIDS="$(pgrep -f "${LEGACY_SUPPORT_DIR}/mihomo" 2>/dev/null || true)"
if [[ -n "${LEGACY_PIDS}" ]]; then
    if [[ "${MODE}" == "dry-run" ]]; then
        log "Would terminate legacy mihomo PID(s): ${LEGACY_PIDS//$'\n'/ }"
    else
        for pid in ${LEGACY_PIDS}; do
            kill -TERM "${pid}" 2>/dev/null || true
        done
        sleep 1
        for pid in ${LEGACY_PIDS}; do
            if kill -0 "${pid}" 2>/dev/null; then
                kill -KILL "${pid}" 2>/dev/null || true
            fi
        done
        log "Terminated legacy mihomo PID(s): ${LEGACY_PIDS//$'\n'/ }"
    fi
fi

# Step 2: Move legacy /Applications/Antigravity Proxy.app to ~/.Trash
log "Step 2: Move legacy launcher app to Trash"
move_to_trash "${LEGACY_APP}"

# Step 3: Copy & verify mihomo binary BEFORE touching legacy support directory
log "Step 3: Preserve verified mihomo binary into PinGate"
MIHOMO_READY=false
if [[ -x "${PINGATE_MIHOMO}" ]]; then
    EXISTING_SHA="$(shasum -a 256 "${PINGATE_MIHOMO}" | awk '{print $1}')"
    log "PinGate mihomo already exists (sha256: ${EXISTING_SHA}): ${PINGATE_MIHOMO}"
    if [[ "${MODE}" == "apply" ]]; then
        chmod 0700 "${PINGATE_SUPPORT_DIR}" "${PINGATE_BIN_DIR}" "${PINGATE_MIHOMO}"
    fi
    MIHOMO_READY=true
elif [[ -f "${LEGACY_MIHOMO}" ]]; then
    SRC_SHA="$(shasum -a 256 "${LEGACY_MIHOMO}" | awk '{print $1}')"
    if [[ "${MODE}" == "dry-run" ]]; then
        log "Would copy ${LEGACY_MIHOMO} -> ${PINGATE_MIHOMO} (mode 0700, sha256: ${SRC_SHA})"
        MIHOMO_READY=true
    else
        mkdir -p "${PINGATE_BIN_DIR}"
        chmod 0700 "${PINGATE_SUPPORT_DIR}" "${PINGATE_BIN_DIR}"
        TMP_BIN="${PINGATE_BIN_DIR}/.mihomo.copy.$$"
        cp "${LEGACY_MIHOMO}" "${TMP_BIN}"
        chmod 0700 "${TMP_BIN}"
        DST_SHA="$(shasum -a 256 "${TMP_BIN}" | awk '{print $1}')"
        if [[ "${SRC_SHA}" != "${DST_SHA}" ]]; then
            rm -f "${TMP_BIN}"
            echo "Error: SHA-256 mismatch while copying mihomo (${SRC_SHA} != ${DST_SHA})" >&2
            exit 1
        fi
        mv -f "${TMP_BIN}" "${PINGATE_MIHOMO}"
        log "Copied & verified mihomo (0700, sha256: ${DST_SHA}): ${PINGATE_MIHOMO}"
        MIHOMO_READY=true
    fi
else
    log "Legacy mihomo binary not found at ${LEGACY_MIHOMO} (PinGate can download it on first run)"
    MIHOMO_READY=true
fi

# Step 4: Dynamically seed PinGate config.json from local machine settings (if absent or unconfigured)
log "Step 4: Seed PinGate config.json dynamically from local settings (if absent or unconfigured)"
SHOULD_SEED=true
if [[ -f "${PINGATE_CONFIG}" ]]; then
    if command -v python3 >/dev/null 2>&1; then
        HAS_NODE="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    outlets = d.get("outlets") or []
    print("yes" if outlets and str(outlets[0].get("primaryNodeName") or "").strip() else "no")
except Exception:
    print("yes")
' "${PINGATE_CONFIG}")"
        if [[ "${HAS_NODE}" == "yes" ]]; then
            log "PinGate config.json already configured (preserve): ${PINGATE_CONFIG}"
            SHOULD_SEED=false
        else
            log "PinGate config.json exists with empty primaryNodeName; will enrich from legacy settings"
        fi
    else
        log "PinGate config.json already exists (preserve): ${PINGATE_CONFIG}"
        SHOULD_SEED=false
    fi
fi

if [[ "${SHOULD_SEED}" == false ]]; then
    :
elif command -v python3 >/dev/null 2>&1; then
    python3 - "${MODE}" "${LEGACY_CONFIG}" "${T3_SETTINGS}" "${FLCLASH_PROFILES_DIR}" "${PINGATE_CONFIG}" <<'PY'
import json
import os
import pathlib
import re
import secrets
import sys
import uuid

mode, legacy_cfg_path, t3_path, flclash_dir, dest_cfg_path = sys.argv[1:6]
prefix = "[DRY-RUN]" if mode == "dry-run" else "[APPLY]  "

# 1. Discover newest FlClash profile YAML dynamically
profile_path = ""
fl_dir = pathlib.Path(flclash_dir)
if fl_dir.is_dir():
    yamls = sorted(
        [p for p in fl_dir.iterdir() if p.is_file() and p.suffix.lower() in (".yaml", ".yml")],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    if yamls:
        profile_path = str(yamls[0])

# 2. Extract listen port, primary node name, and any DOMAIN-SUFFIX rules from legacy config.yaml
listen_port = 17899
primary_node = ""
bypass_domains = []
seen_domains = set()

def add_domain(raw: str):
    d = raw.strip()
    if not d:
        return
    low = d.lower()
    if low in ("localhost", "127.0.0.1", "::1", "*.local", ".local"):
        return
    if "/" in d or re.match(r"^[0-9.:]+$", d):
        return
    if d.startswith("*."):
        d = d[1:]
    if not d.startswith("."):
        d = "." + d
    if d.lower() not in seen_domains:
        seen_domains.add(d.lower())
        bypass_domains.append(d)

legacy_cfg = pathlib.Path(legacy_cfg_path)
if legacy_cfg.is_file():
    text = legacy_cfg.read_text(encoding="utf-8", errors="replace")
    m_port = re.search(r"^\s*mixed-port\s*:\s*(\d+)", text, re.M)
    if m_port:
        listen_port = int(m_port.group(1))

    # Prefer the target referenced by MATCH rule (if it matches a declared proxy),
    # otherwise prefer a node with dialer-proxy, otherwise the first proxy name.
    proxy_names = []
    chained_nodes = []
    current_name = None
    for line in text.splitlines():
        m_name = re.match(r"^\s*-\s*name\s*:\s*(.+?)\s*$", line)
        if m_name:
            val = m_name.group(1).strip().strip('"').strip("'")
            current_name = val
            proxy_names.append(val)
        elif current_name and re.match(r"^\s+dialer-proxy\s*:\s*\S+", line):
            chained_nodes.append(current_name)
        m_dom = re.match(r"^\s*-\s*['\"]?DOMAIN-SUFFIX,([^,'\"\s]+),DIRECT", line)
        if m_dom:
            add_domain(m_dom.group(1))

    m_match = re.search(r"^\s*-\s*['\"]?MATCH,([^,'\"\n]+)", text, re.M)
    match_target = m_match.group(1).strip().strip('"').strip("'") if m_match else ""
    if match_target and match_target in proxy_names:
        primary_node = match_target
    elif chained_nodes:
        primary_node = chained_nodes[0]
    elif proxy_names:
        primary_node = proxy_names[0]

# 3. Extract custom bypass domains from T3 Code settings.json NO_PROXY (if present)
t3_file = pathlib.Path(t3_path)
if t3_file.is_file():
    try:
        t3_data = json.loads(t3_file.read_text(encoding="utf-8"))
        instances = t3_data.get("providerInstances", {})
        if isinstance(instances, dict):
            for inst in instances.values():
                if not isinstance(inst, dict):
                    continue
                env = inst.get("environment") or inst.get("env")
                if isinstance(env, dict):
                    no_proxy = env.get("NO_PROXY") or env.get("no_proxy") or ""
                    for token in str(no_proxy).split(","):
                        add_domain(token)
                elif isinstance(env, list):
                    for item in env:
                        if isinstance(item, dict):
                            k = str(item.get("name") or item.get("key") or "")
                            if k.upper() == "NO_PROXY":
                                for token in str(item.get("value") or "").split(","):
                                    add_domain(token)
    except Exception:
        pass

outlet_id = str(uuid.uuid4()).upper()
config = {
    "schemaVersion": 1,
    "captureMode": "userSpace",
    "outlets": [
        {
            "id": outlet_id,
            "name": "Primary Outlet",
            "listenHost": "127.0.0.1",
            "listenPort": listen_port,
            "controllerPort": 17890,
            "controllerSecret": secrets.token_hex(16),
            "source": {
                "localClashProfile": {
                    "path": profile_path,
                }
            },
            "primaryNodeName": primary_node,
            "fallbackNodeNames": [],
            "enabled": True,
        }
    ],
    "targets": [
        {
            "id": str(uuid.uuid4()).upper(),
            "name": "Antigravity",
            "kind": "guiApp",
            "outletID": outlet_id,
            "enabled": True,
            "bundleID": "com.google.antigravity",
            "appPath": "/Applications/Antigravity.app",
            "processMatchNames": ["Antigravity", "language_server", "antigravity"],
            "chromiumProxyFlags": True,
            "extraEnv": {"NODE_USE_ENV_PROXY": "1"},
        },
        {
            "id": str(uuid.uuid4()).upper(),
            "name": "T3 Code",
            "kind": "t3Integration",
            "outletID": outlet_id,
            "enabled": True,
            "processMatchNames": ["T3 Code", "t3code"],
            "chromiumProxyFlags": False,
            "extraEnv": {"NODE_USE_ENV_PROXY": "1"},
            "t3SettingsPath": "~/.t3/userdata/settings.json",
            "t3ProviderKey": "antigravity",
        },
        {
            "id": str(uuid.uuid4()).upper(),
            "name": "agy",
            "kind": "cliTool",
            "outletID": outlet_id,
            "enabled": True,
            "processMatchNames": ["agy"],
            "chromiumProxyFlags": False,
            "extraEnv": {"NODE_USE_ENV_PROXY": "1"},
            "cliCommandName": "agy",
            "cliTargetBinaryPath": "/opt/homebrew/bin/agy",
        },
    ],
    "bypassRules": {
        "domains": bypass_domains,
        "cidrs": [
            "127.0.0.0/8",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "100.64.0.0/10",
        ],
        "extraNoProxyEntries": ["localhost", "127.0.0.1", "::1", "*.local"],
    },
    "auditPolicy": {
        "pollIntervalSeconds": 3.0,
        "failClosedOnPortDown": True,
        "warnOnExitIPChange": True,
        "notifyOnLeak": True,
        "suspiciousDirectIPs": [],
        "probeTimeoutSeconds": 6.0,
    },
}

print(
    f"{prefix} {'Would seed' if mode == 'dry-run' else 'Seeding'} {dest_cfg_path} "
    f"(port={listen_port}, profile={'found' if profile_path else 'none'}, "
    f"primaryNode={'detected' if primary_node else 'empty'}, bypassDomains={len(bypass_domains)})"
)

if mode == "apply":
    dest = pathlib.Path(dest_cfg_path)
    dest.parent.mkdir(parents=True, exist_ok=True)
    os.chmod(dest.parent, 0o700)
    tmp = dest.parent / f".config.json.tmp.{os.getpid()}"
    fd = os.open(str(tmp), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(config, fh, indent=2, ensure_ascii=False, sort_keys=True)
            fh.write("\n")
    except Exception:
        tmp.unlink(missing_ok=True)
        raise
    os.chmod(tmp, 0o600)
    os.replace(tmp, dest)
    os.chmod(dest, 0o600)
PY
else
    log "python3 not available; PinGate will bootstrap config.json on first launch"
fi

# Step 5: Move legacy Application Support directory to ~/.Trash
log "Step 5: Archive legacy Application Support directory to Trash"
if [[ "${MIHOMO_READY}" == true ]]; then
    move_to_trash "${LEGACY_SUPPORT_DIR}"
else
    echo "Error: Refusing to archive ${LEGACY_SUPPORT_DIR} because mihomo was not verified." >&2
    exit 1
fi

# Step 6: Remove plaintext /tmp remnants
log "Step 6: Remove plaintext temporary directories"
for p in "${TMP_CLEANUP_PATHS[@]}"; do
    if [[ -e "${p}" || -L "${p}" ]]; then
        if [[ "${MODE}" == "dry-run" ]]; then
            log "Would remove: ${p}"
        else
            rm -rf "${p}"
            log "Removed: ${p}"
        fi
    else
        log "Already absent (skip): ${p}"
    fi
done

# Post-check summary
echo "------------------------------------------------------------"
if [[ "${MODE}" == "dry-run" ]]; then
    echo "Dry-run complete. Re-run with --apply to execute these actions."
else
    echo "Migration applied successfully."
    if [[ -x "${PINGATE_MIHOMO}" ]]; then
        echo "  PinGate mihomo: ${PINGATE_MIHOMO} ($(stat -f '%Lp' "${PINGATE_MIHOMO}"))"
    fi
    if [[ -f "${PINGATE_CONFIG}" ]]; then
        echo "  PinGate config: ${PINGATE_CONFIG} ($(stat -f '%Lp' "${PINGATE_CONFIG}"))"
    fi
    echo "  Legacy files moved to ~/.Trash are recoverable if rollback is needed."
fi
