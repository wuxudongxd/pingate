#!/usr/bin/env bash
set -euo pipefail

# PinGate macOS App & CLI Bundler
# Builds release PinGateApp and pingate-cli, generates AppIcon.icns,
# assembles PinGate.app, ad-hoc codesigns it, and installs ~/.local/bin/pingate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTPUT_DIR="${PINGATE_APP_DIR:-/Applications}"
CLI_INSTALL_DIR="${HOME}/.local/bin"
SKIP_CLI=false
APP_VERSION="1.0.0"
BUILD_NUMBER="1"
BUNDLE_ID="com.pingate.app"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --output-dir <dir>    Directory to install PinGate.app (default: /Applications)
  --cli-dir <dir>       Directory to install pingate CLI (default: ~/.local/bin)
  --skip-cli            Do not install the pingate CLI binary
  --version <semver>    CFBundleShortVersionString (default: 1.0.0)
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --cli-dir)
            CLI_INSTALL_DIR="$2"
            shift 2
            ;;
        --skip-cli)
            SKIP_CLI=true
            shift
            ;;
        --version)
            APP_VERSION="$2"
            shift 2
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

log() {
    printf '[PinGate Bundle] %s\n' "$*"
}

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pingate-bundle.XXXXXX")"
cleanup() {
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

log "Building release targets in ${REPO_ROOT}..."
cd "${REPO_ROOT}"
swift build -c release --product PinGateApp
swift build -c release --product pingate-cli

BIN_DIR="$(swift build -c release --show-bin-path)"
APP_BIN="${BIN_DIR}/PinGateApp"
CLI_BIN="${BIN_DIR}/pingate-cli"

if [[ ! -x "${APP_BIN}" ]]; then
    echo "Error: Built PinGateApp binary not found at ${APP_BIN}" >&2
    exit 1
fi
if [[ ! -x "${CLI_BIN}" ]]; then
    echo "Error: Built pingate-cli binary not found at ${CLI_BIN}" >&2
    exit 1
fi

# Generate a clean native macOS squircle shield/gate AppIcon.icns using Swift + AppKit/CoreGraphics
log "Generating AppIcon.icns..."
ICON_PNG="${WORK_DIR}/AppIcon-1024.png"
ICONSET_DIR="${WORK_DIR}/AppIcon.iconset"
ICON_ICNS="${WORK_DIR}/AppIcon.icns"
mkdir -p "${ICONSET_DIR}"

cat > "${WORK_DIR}/render_icon.swift" <<'SWIFT'
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: render_icon.swift <output.png>\n", stderr)
    exit(1)
}
let outPath = CommandLine.arguments[1]
let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let cg = ctx.cgContext

cg.setAllowsAntialiasing(true)
cg.setShouldAntialias(true)

// Outer macOS squircle inset
let inset: CGFloat = 86
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 196
let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Subtle drop shadow
cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor)
cg.addPath(bgPath)
cg.setFillColor(NSColor(calibratedRed: 0.07, green: 0.14, blue: 0.25, alpha: 1).cgColor)
cg.fillPath()
cg.restoreGState()

// Deep slate-to-teal gradient background
cg.saveGState()
cg.addPath(bgPath)
cg.clip()
let colors = [
    NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.26, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.44, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.09, green: 0.54, blue: 0.56, alpha: 1).cgColor
] as CFArray
let colorSpace = CGColorSpaceCreateDeviceRGB()
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0.0, 0.55, 1.0])!
cg.drawLinearGradient(
    gradient,
    start: CGPoint(x: rect.minX, y: rect.minY),
    end: CGPoint(x: rect.maxX, y: rect.maxY),
    options: []
)

// Subtle top highlight sheen
let sheenColors = [
    NSColor(calibratedWhite: 1.0, alpha: 0.20).cgColor,
    NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor
] as CFArray
let sheen = CGGradient(colorsSpace: colorSpace, colors: sheenColors, locations: [0.0, 1.0])!
cg.drawLinearGradient(
    sheen,
    start: CGPoint(x: size / 2, y: rect.maxY),
    end: CGPoint(x: size / 2, y: size * 0.48),
    options: []
)
cg.restoreGState()

// Crisp inner border
cg.addPath(bgPath)
cg.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.22).cgColor)
cg.setLineWidth(6)
cg.strokePath()

// Shield silhouette
let shieldPath = CGMutablePath()
let cx = size / 2
shieldPath.move(to: CGPoint(x: cx, y: 785))
shieldPath.addLine(to: CGPoint(x: 735, y: 695))
shieldPath.addCurve(
    to: CGPoint(x: cx, y: 235),
    control1: CGPoint(x: 735, y: 455),
    control2: CGPoint(x: 615, y: 310)
)
shieldPath.addCurve(
    to: CGPoint(x: 289, y: 695),
    control1: CGPoint(x: 409, y: 310),
    control2: CGPoint(x: 289, y: 455)
)
shieldPath.closeSubpath()

cg.saveGState()
cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor(calibratedWhite: 0, alpha: 0.28).cgColor)
cg.addPath(shieldPath)
cg.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.96).cgColor)
cg.fillPath()
cg.restoreGState()

// Inner pin/gate keyhole emblem
let pinCenter = CGPoint(x: cx, y: 545)
let pinRadius: CGFloat = 78
cg.setFillColor(NSColor(calibratedRed: 0.06, green: 0.24, blue: 0.37, alpha: 1).cgColor)
cg.fillEllipse(in: CGRect(x: pinCenter.x - pinRadius, y: pinCenter.y - pinRadius, width: pinRadius * 2, height: pinRadius * 2))

// Pin stem
let stemPath = CGMutablePath()
stemPath.move(to: CGPoint(x: cx - 34, y: 515))
stemPath.addLine(to: CGPoint(x: cx + 34, y: 515))
stemPath.addLine(to: CGPoint(x: cx + 16, y: 365))
stemPath.addLine(to: CGPoint(x: cx - 16, y: 365))
stemPath.closeSubpath()
cg.addPath(stemPath)
cg.fillPath()

// Emerald protected dot inside pin head
let dotRadius: CGFloat = 34
cg.setFillColor(NSColor(calibratedRed: 0.16, green: 0.82, blue: 0.56, alpha: 1).cgColor)
cg.fillEllipse(in: CGRect(x: pinCenter.x - dotRadius, y: pinCenter.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2))

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outPath))
SWIFT

swift "${WORK_DIR}/render_icon.swift" "${ICON_PNG}"

for px in 16 32 128 256 512; do
    double_px=$((px * 2))
    sips -z "${px}" "${px}" "${ICON_PNG}" --out "${ICONSET_DIR}/icon_${px}x${px}.png" >/dev/null
    sips -z "${double_px}" "${double_px}" "${ICON_PNG}" --out "${ICONSET_DIR}/icon_${px}x${px}@2x.png" >/dev/null
done

iconutil -c icns "${ICONSET_DIR}" -o "${ICON_ICNS}"

# Assemble PinGate.app in staging directory
STAGED_APP="${WORK_DIR}/PinGate.app"
mkdir -p "${STAGED_APP}/Contents/MacOS"
mkdir -p "${STAGED_APP}/Contents/Resources"

cp "${APP_BIN}" "${STAGED_APP}/Contents/MacOS/PinGateApp"
chmod 0755 "${STAGED_APP}/Contents/MacOS/PinGateApp"

cp "${CLI_BIN}" "${STAGED_APP}/Contents/Resources/pingate"
chmod 0755 "${STAGED_APP}/Contents/Resources/pingate"

cp "${ICON_ICNS}" "${STAGED_APP}/Contents/Resources/AppIcon.icns"

cat > "${STAGED_APP}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>PinGate</string>
    <key>CFBundleExecutable</key>
    <string>PinGateApp</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>PinGate</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

log "Ad-hoc signing staged PinGate.app..."
codesign --force --deep --sign - "${STAGED_APP}"
codesign --verify --deep --strict "${STAGED_APP}"

mkdir -p "${OUTPUT_DIR}"
DEST_APP="${OUTPUT_DIR}/PinGate.app"
BACKUP_APP="${OUTPUT_DIR}/.PinGate.app.prev.$$"

log "Installing ${DEST_APP}..."
if [[ -e "${DEST_APP}" ]]; then
    mv "${DEST_APP}" "${BACKUP_APP}"
fi
if mv "${STAGED_APP}" "${DEST_APP}"; then
    rm -rf "${BACKUP_APP}"
else
    if [[ -e "${BACKUP_APP}" ]]; then
        mv "${BACKUP_APP}" "${DEST_APP}"
    fi
    echo "Error: Failed to install ${DEST_APP}" >&2
    exit 1
fi

if [[ "${SKIP_CLI}" == false ]]; then
    mkdir -p "${CLI_INSTALL_DIR}"
    CLI_DEST="${CLI_INSTALL_DIR}/pingate"
    CLI_TMP="${CLI_INSTALL_DIR}/.pingate.tmp.$$"
    cp "${CLI_BIN}" "${CLI_TMP}"
    chmod 0755 "${CLI_TMP}"
    codesign --force --sign - "${CLI_TMP}" >/dev/null 2>&1 || true
    mv -f "${CLI_TMP}" "${CLI_DEST}"
    log "Installed CLI to ${CLI_DEST}"
fi

log "Done! Bundle verified at ${DEST_APP}"
