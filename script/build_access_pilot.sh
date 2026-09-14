#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build --product KeyPort
swift build --product KeyPortAskPass
BUILD_DIR="$(swift build --show-bin-path)"
APP="$ROOT_DIR/dist/KeyPortAccessPilot.app"
while IFS= read -r pilot_pid; do
  [[ -z "$pilot_pid" ]] || kill "$pilot_pid"
done < <(pgrep -f "^$APP/Contents/MacOS/KeyPort$" || true)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BUILD_DIR/KeyPort" "$APP/Contents/MacOS/KeyPort"
cp "$BUILD_DIR/KeyPortAskPass" "$APP/Contents/Helpers/KeyPortAskPass"
cp -R "$BUILD_DIR/KeyPort_KeyPortInterface.bundle" "$APP/Contents/Resources/"
cp -R "$BUILD_DIR/KeyPort_KeyPort.bundle" "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>KeyPort</string><key>CFBundleIdentifier</key><string>com.jihtsan.KeyPort.AccessPilot</string><key>CFBundleName</key><string>KeyPort 真实连接验收</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/Helpers/KeyPortAskPass"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
