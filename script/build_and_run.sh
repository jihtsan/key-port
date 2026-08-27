#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="KeyPort"
BUNDLE_ID="com.jihtsan.KeyPort"
CLOUDKIT_CONTAINER="iCloud.$BUNDLE_ID"
MIN_SYSTEM_VERSION="14.0"
SIGNING_IDENTITY="${KEYPORT_SIGNING_IDENTITY:--}"
TEAM_ID="${KEYPORT_TEAM_ID:-}"
APP_IDENTIFIER_PREFIX="${KEYPORT_APP_IDENTIFIER_PREFIX:-}"
CLOUDKIT_ENVIRONMENT="${KEYPORT_CLOUDKIT_ENVIRONMENT:-Development}"
PROVISIONING_PROFILE="${KEYPORT_PROVISIONING_PROFILE:-}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_HELPERS="$APP_CONTENTS/Helpers"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_TUNNEL_BROKER="$APP_HELPERS/KeyPortTunnelBroker"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_NAME="KeyPort.icns"
APP_ICON_SOURCE="$ROOT_DIR/Resources/$APP_ICON_NAME"
ENTITLEMENTS_FILE=""
PROFILE_PLIST=""
SIGNED_ENTITLEMENTS_FILE=""

cleanup() {
  if [[ -n "$ENTITLEMENTS_FILE" && -f "$ENTITLEMENTS_FILE" ]]; then
    rm -f "$ENTITLEMENTS_FILE"
  fi
  if [[ -n "$PROFILE_PLIST" && -f "$PROFILE_PLIST" ]]; then
    rm -f "$PROFILE_PLIST"
  fi
  if [[ -n "$SIGNED_ENTITLEMENTS_FILE" && -f "$SIGNED_ENTITLEMENTS_FILE" ]]; then
    rm -f "$SIGNED_ENTITLEMENTS_FILE"
  fi
}
trap cleanup EXIT

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build --product KeyPort
swift build --product KeyPortAskPass
swift build --product KeyPortTunnelBroker
BUILD_DIR="$(swift build --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_HELPERS" "$APP_RESOURCES"
cp "$BUILD_DIR/KeyPort" "$APP_BINARY"
cp "$BUILD_DIR/KeyPortAskPass" "$APP_HELPERS/KeyPortAskPass"
cp "$BUILD_DIR/KeyPortTunnelBroker" "$APP_TUNNEL_BROKER"
if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  echo "App icon is missing: $APP_ICON_SOURCE" >&2
  exit 2
fi
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"
cp "$ROOT_DIR/Sources/KeyPort/Resources/key-hub@1x.png" "$APP_RESOURCES/key-hub@1x.png"
cp "$ROOT_DIR/Sources/KeyPort/Resources/key-hub@2x.png" "$APP_RESOURCES/key-hub@2x.png"
chmod +x "$APP_BINARY" "$APP_HELPERS/KeyPortAskPass" "$APP_TUNNEL_BROKER"
if [[ ! -x "$APP_TUNNEL_BROKER" ]]; then
  echo "Tunnel broker helper is missing or not executable: $APP_TUNNEL_BROKER" >&2
  exit 2
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>SSH KeyPort</string>
  <key>CFBundleDisplayName</key>
  <string>SSH KeyPort</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" >/dev/null
DECLARED_APP_ICON="$(plutil -extract CFBundleIconFile raw -o - "$INFO_PLIST" 2>/dev/null || true)"
if [[ "$DECLARED_APP_ICON" != "$APP_ICON_NAME" || ! -f "$APP_RESOURCES/$DECLARED_APP_ICON" ]]; then
  echo "Generated app bundle does not contain its declared icon." >&2
  exit 2
fi

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  # Ad-hoc signing is useful for local UI and SSH workflow checks, but cannot
  # activate CloudKit or iCloud Keychain.
  codesign --force --sign - "$APP_HELPERS/KeyPortAskPass" >/dev/null
  codesign --force --sign - "$APP_TUNNEL_BROKER" >/dev/null
  codesign --force --sign - "$APP_BUNDLE" >/dev/null
  codesign --verify --deep --strict "$APP_BUNDLE"
  echo "Signed ad-hoc (iCloud disabled)"
else
  if [[ "$CLOUDKIT_ENVIRONMENT" != "Development" && "$CLOUDKIT_ENVIRONMENT" != "Production" ]]; then
    echo "KEYPORT_CLOUDKIT_ENVIRONMENT must be Development or Production." >&2
    exit 2
  fi
  if [[ -z "$PROVISIONING_PROFILE" ]]; then
    echo "This signing mode requires KEYPORT_PROVISIONING_PROFILE for iCloud entitlements." >&2
    echo "Create a macOS development/distribution profile for $BUNDLE_ID, download it, and pass its path." >&2
    exit 2
  fi
  if [[ ! -f "$PROVISIONING_PROFILE" ]]; then
    echo "Provisioning profile not found: $PROVISIONING_PROFILE" >&2
    exit 2
  fi
  for required_tool in jq openssl rg xcrun; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
      echo "Required signing validation tool is unavailable: $required_tool" >&2
      exit 2
    fi
  done

  PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/keyport-profile.XXXXXX")"
  security cms -D -i "$PROVISIONING_PROFILE" -o "$PROFILE_PLIST"
  PROFILE_TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.team-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_PLATFORM="$(/usr/libexec/PlistBuddy -c 'Print :Platform:0' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  if [[ "$PROFILE_PLATFORM" != "OSX" ]]; then
    echo "The provisioning profile is not a macOS profile (platform: ${PROFILE_PLATFORM:-unknown})." >&2
    exit 2
  fi
  if [[ -z "$PROFILE_TEAM_ID" ]]; then
    echo "The provisioning profile does not contain a Team ID." >&2
    exit 2
  fi
  case "$PROFILE_APP_ID" in
    *."$BUNDLE_ID")
      PROFILE_APP_ID_PREFIX="${PROFILE_APP_ID%.$BUNDLE_ID}"
      ;;
    *)
      echo "The provisioning profile does not target $BUNDLE_ID." >&2
      exit 2
      ;;
  esac
  PROFILE_EXPIRATION_EPOCH="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$PROFILE_EXPIRATION" '+%s' 2>/dev/null || true)"
  if [[ -z "$PROFILE_EXPIRATION_EPOCH" || "$PROFILE_EXPIRATION_EPOCH" -le "$(date '+%s')" ]]; then
    echo "The provisioning profile is expired or has an invalid expiration date." >&2
    exit 2
  fi

  PROFILE_PROVISIONED_DEVICES="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$PROFILE_PLIST" 2>/dev/null || true)"
  if [[ -n "$PROFILE_PROVISIONED_DEVICES" ]]; then
    CURRENT_MAC_DEVICE_ID="$(xcrun xcdevice list 2>/dev/null \
      | jq -r '.[] | select(.platform == "com.apple.platform.macosx" and .simulator == false and .available == true) | .identifier' \
      | head -n 1 || true)"
    if [[ -z "$CURRENT_MAC_DEVICE_ID" ]]; then
      echo "Unable to resolve this Mac's Xcode provisioning device ID with xcrun xcdevice list." >&2
      exit 2
    fi
    if ! printf '%s\n' "$PROFILE_PROVISIONED_DEVICES" | rg -Fq "$CURRENT_MAC_DEVICE_ID"; then
      echo "The provisioning profile does not include this Mac's Xcode device ID: $CURRENT_MAC_DEVICE_ID" >&2
      echo "Register that macOS device in Apple Developer, then regenerate and download the profile." >&2
      exit 2
    fi
  fi

  PROFILE_CLOUDKIT_CONTAINERS="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_CLOUDKIT_SERVICES="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_CLOUDKIT_ENVIRONMENTS="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' "$PROFILE_PLIST" 2>/dev/null || true)"
  if ! printf '%s\n' "$PROFILE_CLOUDKIT_CONTAINERS" | rg -Fq "$CLOUDKIT_CONTAINER"; then
    echo "The provisioning profile does not authorize $CLOUDKIT_CONTAINER." >&2
    echo "Associate the iCloud container with the App ID, then regenerate the profile." >&2
    exit 2
  fi
  if [[ "$PROFILE_CLOUDKIT_SERVICES" != "*" ]] \
    && ! printf '%s\n' "$PROFILE_CLOUDKIT_SERVICES" | rg -Fq 'CloudKit'; then
    echo "The provisioning profile does not authorize the CloudKit service." >&2
    exit 2
  fi
  if ! printf '%s\n' "$PROFILE_CLOUDKIT_ENVIRONMENTS" | rg -Fq "$CLOUDKIT_ENVIRONMENT"; then
    echo "The provisioning profile does not authorize the $CLOUDKIT_ENVIRONMENT CloudKit environment." >&2
    exit 2
  fi

  if [[ "$SIGNING_IDENTITY" =~ ^[[:xdigit:]]{40}$ ]]; then
    SIGNING_CERTIFICATE_SHA1="$(printf '%s' "$SIGNING_IDENTITY" | tr '[:lower:]' '[:upper:]')"
  else
    SIGNING_CERTIFICATE_SHA1="$(security find-identity -p codesigning -v \
      | awk -v identity="$SIGNING_IDENTITY" 'index($0, "\"" identity "\"") { print $2; exit }')"
  fi
  if [[ -z "$SIGNING_CERTIFICATE_SHA1" ]]; then
    echo "Unable to resolve the requested signing certificate." >&2
    exit 2
  fi
  PROFILE_CERTIFICATE_COUNT="$(plutil -extract DeveloperCertificates raw -o - "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_CERTIFICATE_SHA1S=""
  if [[ "$PROFILE_CERTIFICATE_COUNT" =~ ^[0-9]+$ ]]; then
    for ((certificate_index = 0; certificate_index < PROFILE_CERTIFICATE_COUNT; certificate_index++)); do
      PROFILE_CERTIFICATE_SHA1="$(plutil -extract "DeveloperCertificates.$certificate_index" raw -o - "$PROFILE_PLIST" \
        | base64 -D \
        | openssl x509 -inform DER -noout -fingerprint -sha1 \
        | sed 's/^.*=//; s/://g')"
      PROFILE_CERTIFICATE_SHA1S+="$PROFILE_CERTIFICATE_SHA1"$'\n'
    done
  fi
  if ! printf '%s\n' "$PROFILE_CERTIFICATE_SHA1S" | rg -Fxq "$SIGNING_CERTIFICATE_SHA1"; then
    echo "The signing certificate is not included in the provisioning profile." >&2
    exit 2
  fi
  if [[ -n "$TEAM_ID" && "$TEAM_ID" != "$PROFILE_TEAM_ID" ]]; then
    echo "KEYPORT_TEAM_ID does not match the provisioning profile." >&2
    exit 2
  fi
  TEAM_ID="$PROFILE_TEAM_ID"
  APP_IDENTIFIER_PREFIX="${APP_IDENTIFIER_PREFIX:-$PROFILE_APP_ID_PREFIX}"
  if [[ "$APP_IDENTIFIER_PREFIX" != "$PROFILE_APP_ID_PREFIX" ]]; then
    echo "KEYPORT_APP_IDENTIFIER_PREFIX does not match the provisioning profile." >&2
    exit 2
  fi
  # Do not carry Safari's quarantine metadata into the embedded profile.
  cp -X "$PROVISIONING_PROFILE" "$APP_CONTENTS/embedded.provisionprofile"

  ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/keyport-entitlements.XXXXXX")"
  cp "$ROOT_DIR/Resources/KeyPort.entitlements" "$ENTITLEMENTS_FILE"
  PROFILE_KEYCHAIN_GROUP="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$PROFILE_PLIST" 2>/dev/null || true)"
  PROFILE_KVSTORE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.ubiquity-kvstore-identifier' "$PROFILE_PLIST" 2>/dev/null || true)"
  if [[ -z "$PROFILE_KEYCHAIN_GROUP" ]]; then
    echo "The provisioning profile does not authorize a Keychain access group." >&2
    exit 2
  fi
  case "$PROFILE_KEYCHAIN_GROUP" in
    "${APP_IDENTIFIER_PREFIX}.${BUNDLE_ID}") KEYCHAIN_ACCESS_GROUP="$PROFILE_KEYCHAIN_GROUP" ;;
    "${APP_IDENTIFIER_PREFIX}.*") KEYCHAIN_ACCESS_GROUP="${APP_IDENTIFIER_PREFIX}.${BUNDLE_ID}" ;;
    *)
      echo "The provisioning profile Keychain access group does not authorize $BUNDLE_ID." >&2
      exit 2
      ;;
  esac
  case "$PROFILE_KVSTORE_IDENTIFIER" in
    "${APP_IDENTIFIER_PREFIX}.${BUNDLE_ID}") KVSTORE_IDENTIFIER="$PROFILE_KVSTORE_IDENTIFIER" ;;
    "${APP_IDENTIFIER_PREFIX}.*") KVSTORE_IDENTIFIER="${APP_IDENTIFIER_PREFIX}.${BUNDLE_ID}" ;;
    *)
      echo "The provisioning profile does not authorize the KeyPort iCloud key-value store identifier." >&2
      exit 2
      ;;
  esac
  /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 $KEYCHAIN_ACCESS_GROUP" "$ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.ubiquity-kvstore-identifier $KVSTORE_IDENTIFIER" "$ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy -c "Set :com.apple.developer.icloud-container-environment $CLOUDKIT_ENVIRONMENT" "$ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $PROFILE_APP_ID" "$ENTITLEMENTS_FILE"
  /usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS_FILE"

  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_HELPERS/KeyPortAskPass" >/dev/null
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" "$APP_TUNNEL_BROKER" >/dev/null
  codesign --force --options runtime --sign "$SIGNING_IDENTITY" \
    --entitlements "$ENTITLEMENTS_FILE" "$APP_BUNDLE" >/dev/null
  SIGNED_TEAM_ID="$(codesign -dvv "$APP_BUNDLE" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [[ "$SIGNED_TEAM_ID" != "$TEAM_ID" ]]; then
    echo "The signed Team ID ($SIGNED_TEAM_ID) does not match the entitlement Team ID ($TEAM_ID)." >&2
    exit 2
  fi
  SIGNED_ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/keyport-signed-entitlements.XXXXXX")"
  codesign -d --entitlements :- "$APP_BUNDLE" >"$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null
  if [[ "$(plutil -extract 'com\.apple\.application-identifier' raw -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)" != "$PROFILE_APP_ID" ]] \
    || [[ "$(plutil -extract 'com\.apple\.developer\.team-identifier' raw -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)" != "$TEAM_ID" ]] \
    || [[ "$(plutil -extract 'com\.apple\.developer\.icloud-container-environment' raw -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)" != "$CLOUDKIT_ENVIRONMENT" ]]; then
    echo "The final signature is missing required application, team, or CloudKit environment entitlements." >&2
    exit 2
  fi
  SIGNED_CLOUDKIT_CONTAINERS="$(plutil -extract 'com\.apple\.developer\.icloud-container-identifiers' json -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)"
  SIGNED_CLOUDKIT_SERVICES="$(plutil -extract 'com\.apple\.developer\.icloud-services' json -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)"
  SIGNED_KEYCHAIN_GROUPS="$(plutil -extract keychain-access-groups json -o - "$SIGNED_ENTITLEMENTS_FILE" 2>/dev/null || true)"
  if ! printf '%s\n' "$SIGNED_CLOUDKIT_CONTAINERS" | rg -Fq "$CLOUDKIT_CONTAINER" \
    || ! printf '%s\n' "$SIGNED_CLOUDKIT_SERVICES" | rg -Fq 'CloudKit' \
    || ! printf '%s\n' "$SIGNED_KEYCHAIN_GROUPS" | rg -Fq "$KEYCHAIN_ACCESS_GROUP"; then
    echo "The final signature is missing required CloudKit container, service, or Keychain entitlements." >&2
    exit 2
  fi
  codesign --verify --deep --strict "$APP_BUNDLE"
  echo "Signed with $SIGNING_IDENTITY (Team $SIGNED_TEAM_ID, App ID prefix $APP_IDENTIFIER_PREFIX, iCloud $CLOUDKIT_ENVIRONMENT)"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 3
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME launched successfully from $APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
