#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -x /usr/sbin/sshd || ! -x /usr/bin/ssh || ! -x /usr/bin/ssh-keygen || ! -x /usr/bin/nc ]]; then
    echo "C4 fixture skipped: macOS OpenSSH and netcat are required"
    exit 0
fi

SSH_VERSION="$(/usr/bin/ssh -V 2>&1 || true)"
case "$SSH_VERSION" in
    OpenSSH_9.7*|OpenSSH_10.2*) ;;
    *)
        echo "C4 fixture skipped: unsupported OpenSSH version (${SSH_VERSION%%,*})"
        exit 0
        ;;
esac

swift build --product KeyPortTunnelBroker >/dev/null
BUILD_DIR="$(swift build --show-bin-path)"
BROKER="$BUILD_DIR/KeyPortTunnelBroker"

# OpenSSH limits Unix control paths to 103 bytes; keep the fixture root short.
FIXTURE_DIR="$(mktemp -d /tmp/keyport-c4.XXXXXX)"
SSHD_PID=""
BROKER_PID=""
declare -a TARGET_PIDS=()
declare -a CLEANUP_PORTS=()

cleanup() {
    set +e
    if [[ -n "$BROKER_PID" ]] && kill -0 "$BROKER_PID" 2>/dev/null; then
        kill "$BROKER_PID" 2>/dev/null
    fi
    for pid in "${TARGET_PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    if [[ -n "$SSHD_PID" ]] && kill -0 "$SSHD_PID" 2>/dev/null; then
        kill "$SSHD_PID" 2>/dev/null
    fi
    for port in "${CLEANUP_PORTS[@]}"; do
        for pid in $(/usr/sbin/lsof -nP -t -a -iTCP:"$port" -sTCP:LISTEN 2>/dev/null); do
            kill "$pid" 2>/dev/null
        done
    done
    [[ -z "$BROKER_PID" ]] || wait "$BROKER_PID" 2>/dev/null
    for pid in "${TARGET_PIDS[@]}"; do
        wait "$pid" 2>/dev/null
    done
    [[ -z "$SSHD_PID" ]] || wait "$SSHD_PID" 2>/dev/null
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

choose_port() {
    local port
    for _ in {1..100}; do
        port=$((40000 + RANDOM % 20000))
        if ! /usr/bin/nc -4 -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 \
            && ! /usr/bin/nc -6 -z -w 1 ::1 "$port" >/dev/null 2>&1; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    echo "C4 fixture could not find a free port" >&2
    return 1
}

wait_for_listen() {
    local family="$1"
    local host="$2"
    local port="$3"
    for _ in {1..100}; do
        if /usr/bin/nc "$family" -z -w 1 "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
    done
    echo "C4 fixture listener did not become ready: $host:$port" >&2
    return 1
}

wait_for_port_closed() {
    local port="$1"
    for _ in {1..40}; do
        if ! /usr/bin/nc -4 -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.05
    done
    echo "C4 fixture local port remained open: $port" >&2
    return 1
}

wait_for_absent() {
    local path="$1"
    for _ in {1..40}; do
        if [[ ! -e "$path" ]]; then
            return 0
        fi
        sleep 0.05
    done
    echo "C4 fixture resource remained: $path" >&2
    return 1
}

wait_for_output() {
    local output="$1"
    local expected="$2"
    local pid="$3"
    for _ in {1..240}; do
        if [[ -f "$output" ]] && /usr/bin/grep -Fq "$expected" "$output"; then
            return 0
        fi
        if ! kill -0 "$pid" 2>/dev/null; then
            return 1
        fi
        sleep 0.05
    done
    return 1
}

start_target_server() {
    local family="$1"
    local host="$2"
    local port="$3"
    (
        while true; do
            printf 'C4_TARGET_RESPONSE\n' | /usr/bin/nc "$family" -l "$host" "$port" >/dev/null 2>&1 || true
        done
    ) &
    TARGET_PIDS+=("$!")
    CLEANUP_PORTS+=("$port")
}

stop_broker_writer() {
    exec 9>&- || true
}

run_success_case() {
    local name="$1"
    local family="$2"
    local target_host="$3"
    local target_port
    local local_port
    local runtime_directory
    local token
    local control_path
    local lease_path
    local input_path
    local output_path
    local error_path
    local response
    local status

    target_port="$(choose_port)"
    local_port="$(choose_port)"
    start_target_server "$family" "$target_host" "$target_port"
    wait_for_listen "$family" "$target_host" "$target_port"

    runtime_directory="$FIXTURE_DIR/r-$name"
    mkdir -m 700 "$runtime_directory"
    token="c4$(printf '%020d' "$RANDOM")"
    control_path="$runtime_directory/control-$token.sock"
    lease_path="$runtime_directory/lease-$token.json"
    input_path="$FIXTURE_DIR/broker-$name.in"
    output_path="$FIXTURE_DIR/broker-$name.out"
    error_path="$FIXTURE_DIR/broker-$name.err"
    mkfifo "$input_path"

    "$BROKER" start \
        --local-port "$local_port" \
        --remote-host "$target_host" \
        --remote-port "$target_port" \
        --ssh-host 127.0.0.1 \
        --ssh-port "$SSH_PORT" \
        --username "$CURRENT_USER" \
        --identity-path "$FIXTURE_DIR/client_key" \
        --known-hosts-path "$KNOWN_HOSTS" \
        --control-path "$control_path" \
        --lease-path "$lease_path" \
        <"$input_path" >"$output_path" 2>"$error_path" &
    BROKER_PID="$!"
    exec 9>"$input_path"

    if ! wait_for_output "$output_path" "FORWARD_ESTABLISHED" "$BROKER_PID"; then
        echo "C4 $name broker output:" >&2
        sed -n '1,80p' "$output_path" "$error_path" >&2 || true
        return 1
    fi

    response="$(/usr/bin/nc -4 -w 2 127.0.0.1 "$local_port" </dev/null || true)"
    if [[ "$response" != *C4_TARGET_RESPONSE* ]]; then
        echo "C4 $name did not receive the target response" >&2
        return 1
    fi

    stop_broker_writer
    if wait "$BROKER_PID"; then
        status=0
    else
        status=$?
    fi
    BROKER_PID=""
    if [[ "$status" -ne 0 ]]; then
        echo "C4 $name broker exited with status $status" >&2
        return 1
    fi
    wait_for_port_closed "$local_port"
    wait_for_absent "$control_path"
    wait_for_absent "$lease_path"
    echo "C4 $name: open-confirm, target response, stdin EOF, and port cleanup passed"
}

run_refused_case() {
    local target_port
    local local_port
    local runtime_directory
    local token
    local control_path
    local lease_path
    local input_path
    local output_path
    local error_path
    local status

    target_port="$(choose_port)"
    local_port="$(choose_port)"
    CLEANUP_PORTS+=("$local_port")
    runtime_directory="$FIXTURE_DIR/r-refused"
    mkdir -m 700 "$runtime_directory"
    token="c4$(printf '%020d' "$RANDOM")"
    control_path="$runtime_directory/control-$token.sock"
    lease_path="$runtime_directory/lease-$token.json"
    input_path="$FIXTURE_DIR/broker-refused.in"
    output_path="$FIXTURE_DIR/broker-refused.out"
    error_path="$FIXTURE_DIR/broker-refused.err"
    mkfifo "$input_path"

    "$BROKER" start \
        --local-port "$local_port" \
        --remote-host 127.0.0.1 \
        --remote-port "$target_port" \
        --ssh-host 127.0.0.1 \
        --ssh-port "$SSH_PORT" \
        --username "$CURRENT_USER" \
        --identity-path "$FIXTURE_DIR/client_key" \
        --known-hosts-path "$KNOWN_HOSTS" \
        --control-path "$control_path" \
        --lease-path "$lease_path" \
        <"$input_path" >"$output_path" 2>"$error_path" &
    BROKER_PID="$!"
    exec 9>"$input_path"

    if ! wait_for_output "$output_path" "FORWARD_FAILED target_refused" "$BROKER_PID"; then
        echo "C4 refused broker output:" >&2
        sed -n '1,80p' "$output_path" "$error_path" >&2 || true
        return 1
    fi
    stop_broker_writer
    if wait "$BROKER_PID"; then
        status=0
    else
        status=$?
    fi
    BROKER_PID=""
    if [[ "$status" -eq 0 ]]; then
        echo "C4 refused broker unexpectedly succeeded" >&2
        return 1
    fi
    wait_for_port_closed "$local_port"
    wait_for_absent "$control_path"
    wait_for_absent "$lease_path"
    echo "C4 refused: open-failed and cleanup passed"
}

CURRENT_USER="$(id -un)"
SSH_PORT="$(choose_port)"
KNOWN_HOSTS="$FIXTURE_DIR/known_hosts"

/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE_DIR/host_key"
/usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE_DIR/client_key"
cp "$FIXTURE_DIR/client_key.pub" "$FIXTURE_DIR/authorized_keys"
chmod 600 "$FIXTURE_DIR/authorized_keys"

SSHD_CONFIG="$FIXTURE_DIR/sshd_config"
printf '%s\n' \
    "Port $SSH_PORT" \
    'ListenAddress 127.0.0.1' \
    'ListenAddress ::1' \
    "HostKey \"$FIXTURE_DIR/host_key\"" \
    "PidFile \"$FIXTURE_DIR/sshd.pid\"" \
    "AuthorizedKeysFile \"$FIXTURE_DIR/authorized_keys\"" \
    'StrictModes no' \
    'PasswordAuthentication no' \
    'KbdInteractiveAuthentication no' \
    'ChallengeResponseAuthentication no' \
    'PubkeyAuthentication yes' \
    'PermitRootLogin no' \
    'PermitTTY no' \
    'AllowTcpForwarding local' \
    'X11Forwarding no' \
    'UsePAM no' \
    "AllowUsers $CURRENT_USER" \
    'LogLevel QUIET' \
    'Subsystem sftp internal-sftp' \
    >"$SSHD_CONFIG"
/usr/sbin/sshd -t -f "$SSHD_CONFIG"
/usr/sbin/sshd -D -e -f "$SSHD_CONFIG" >"$FIXTURE_DIR/sshd.log" 2>&1 &
SSHD_PID="$!"
wait_for_listen -4 127.0.0.1 "$SSH_PORT"
wait_for_listen -6 ::1 "$SSH_PORT"

/usr/bin/ssh-keyscan -q -4 -p "$SSH_PORT" 127.0.0.1 >"$KNOWN_HOSTS"
chmod 600 "$KNOWN_HOSTS"
/usr/bin/ssh -4 \
    -i "$FIXTURE_DIR/client_key" \
    -o BatchMode=yes \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$KNOWN_HOSTS" \
    -o GlobalKnownHostsFile=/dev/null \
    -o ConnectTimeout=3 \
    -p "$SSH_PORT" \
    "$CURRENT_USER@127.0.0.1" true

run_success_case ipv4 -4 127.0.0.1
run_success_case ipv6 -6 ::1
run_refused_case

echo "C4 fixture passed: ${SSH_VERSION%%,*}"
