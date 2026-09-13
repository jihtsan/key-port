#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift build --product KeyPortDesignPreview
BUILD_DIR="$(swift build --show-bin-path)"
APP="$ROOT_DIR/dist/KeyPortDesignPreview.app"
mkdir -p "$APP/Contents/MacOS"
while IFS= read -r preview_pid; do
  [[ -z "$preview_pid" ]] || kill "$preview_pid"
done < <(pgrep -f "^$APP/Contents/MacOS/KeyPortDesignPreview$" || true)
mkdir -p "$APP/Contents/Resources"
cp -R "$BUILD_DIR/KeyPort_KeyPortInterface.bundle" "$APP/Contents/Resources/"
cp "$BUILD_DIR/KeyPortDesignPreview" "$APP/Contents/MacOS/KeyPortDesignPreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>KeyPortDesignPreview</string><key>CFBundleIdentifier</key><string>com.jihtsan.KeyPort.DesignPreview</string><key>CFBundleName</key><string>KeyPort Design Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
open -n "$APP"
echo "$APP"
