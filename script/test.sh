#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
swift run KeyPortCoreChecks
swift build --product KeyPort
swift build --product KeyPortAskPass

BUILD_DIR="$(swift build --show-bin-path)"
FIXTURE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_ROOT"' EXIT

check_askpass() {
  local executable="$1"
  local fixture_dir
  fixture_dir="$FIXTURE_ROOT/$(basename "$executable")"
  mkdir -p "$fixture_dir"
  mkfifo "$fixture_dir/password.fifo"
  chmod 600 "$fixture_dir/password.fifo"
  printf 'fixture-password' >"$fixture_dir/password.fifo" &
  KEYPORT_ASKPASS_MODE=1 KEYPORT_PASSWORD_PIPE="$fixture_dir/password.fifo" "$executable" >"$fixture_dir/actual"
  printf 'fixture-password\n' >"$fixture_dir/expected"
  cmp -s "$fixture_dir/expected" "$fixture_dir/actual"
}

check_askpass "$BUILD_DIR/KeyPortAskPass"
check_askpass "$BUILD_DIR/KeyPort"
echo "KeyPortAskPassChecks: helper and app fallback consumed a protected FIFO once"
