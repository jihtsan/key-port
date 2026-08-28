#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift test
swift run KeyPortCoreChecks
swift build --product KeyPortAskPass

BUILD_DIR="$(swift build --show-bin-path)"
FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
mkfifo "$FIXTURE_DIR/password.fifo"
chmod 600 "$FIXTURE_DIR/password.fifo"
printf 'fixture-password' >"$FIXTURE_DIR/password.fifo" &
KEYPORT_PASSWORD_PIPE="$FIXTURE_DIR/password.fifo" "$BUILD_DIR/KeyPortAskPass" >"$FIXTURE_DIR/actual"
printf 'fixture-password\n' >"$FIXTURE_DIR/expected"
cmp -s "$FIXTURE_DIR/expected" "$FIXTURE_DIR/actual"
echo "KeyPortAskPassChecks: protected FIFO consumed once"
