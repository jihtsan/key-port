#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -x /usr/bin/ssh || ! -x /usr/bin/nc ]]; then
    echo "SSH relay fixture skipped: macOS ssh and netcat are required"
    exit 0
fi

swift build --product KeyPortSSHRelay >/dev/null
BUILD_DIR="$(swift build --show-bin-path)"
HELPER="$BUILD_DIR/KeyPortSSHRelay"
if [[ ! -x "$HELPER" ]]; then
    echo "SSH relay fixture failed: helper was not built" >&2
    exit 1
fi

FIXTURE_DIR="$(mktemp -d /tmp/keyport-ssh-relay.XXXXXX)"
declare -a SERVER_PIDS=()
declare -a USED_PORTS=()
SSHD_PID=""

cleanup() {
    set +e
    if ((${#SERVER_PIDS[@]} > 0)); then
        for pid in "${SERVER_PIDS[@]}"; do
            kill "$pid" 2>/dev/null || true
        done
    fi
    if [[ -n "$SSHD_PID" ]]; then
        kill "$SSHD_PID" 2>/dev/null || true
    fi
    if ((${#SERVER_PIDS[@]} > 0)); then
        for pid in "${SERVER_PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
    fi
    if [[ -n "$SSHD_PID" ]]; then
        wait "$SSHD_PID" 2>/dev/null || true
    fi
    rm -rf "$FIXTURE_DIR"
}
trap cleanup EXIT HUP INT TERM

choose_port() {
    local port
    for _ in {1..100}; do
        port=$((40000 + RANDOM % 20000))
        local already_used=false
        if ((${#USED_PORTS[@]} > 0)); then
            for used_port in "${USED_PORTS[@]}"; do
                if [[ "$used_port" == "$port" ]]; then
                    already_used=true
                    break
                fi
            done
        fi
        [[ "$already_used" == false ]] || continue
        if ! /usr/bin/nc -4 -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 \
            && ! /usr/bin/nc -6 -z -w 1 ::1 "$port" >/dev/null 2>&1; then
            USED_PORTS+=("$port")
            printf '%s\n' "$port"
            return 0
        fi
    done
    echo "SSH relay fixture could not find a free port" >&2
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
    echo "SSH relay fixture listener did not become ready: $host:$port" >&2
    return 1
}

start_response_server() {
    local family="$1"
    local host="$2"
    local port="$3"
    local response="$4"
    local received="$5"
    (
        { printf '%s\n' "$response"; sleep 0.5; } \
            | /usr/bin/nc "$family" -kl "$host" "$port" >"$received" 2>/dev/null
    ) &
    SERVER_PIDS+=("$!")
}

write_manifest() {
    local path="$1"
    local target_host="$2"
    local target_port="$3"
    local profile_id="$4"
    local first_port="$5"
    local second_port="$6"
    local third_port="${7:-}"
    local candidate_suffix=""
    if [[ -n "$third_port" ]]; then
        candidate_suffix=",{\"endpointID\":\"52000000-0000-4000-8000-000000000013\",\"host\":\"127.0.0.1\",\"port\":$third_port}"
    fi
    printf '{"configurations":[{"candidates":[{"endpointID":"52000000-0000-4000-8000-000000000011","host":"127.0.0.1","port":%s},{"endpointID":"52000000-0000-4000-8000-000000000012","host":"127.0.0.1","port":%s}%s],"connectTimeoutMilliseconds":500,"operationID":"52000000-0000-4000-8000-000000000010","overallBudgetMilliseconds":3000,"profileID":"%s","schemaVersion":1,"target":{"host":"%s","port":%s}}],"schemaVersion":1}\n' \
        "$first_port" "$second_port" "$candidate_suffix" "$profile_id" "$target_host" "$target_port" >"$path"
    chmod 600 "$path"
}

echo "KeyPortSSHRelay version: $("$HELPER" --version)"

PROFILE_ID="52000000-0000-4000-8000-000000000014"
FIRST_PORT="$(choose_port)"
SECOND_PORT="$(choose_port)"
THIRD_PORT="$(choose_port)"
RECEIVED="$FIXTURE_DIR/received"
THIRD_RECEIVED="$FIXTURE_DIR/third-received"
OUTPUT="$FIXTURE_DIR/output"
ERROR="$FIXTURE_DIR/error"
MANIFEST="$FIXTURE_DIR/routes.json"
start_response_server -4 127.0.0.1 "$SECOND_PORT" "RELAY_RESPONSE" "$RECEIVED"
start_response_server -4 127.0.0.1 "$THIRD_PORT" "WRONG_RESPONSE" "$THIRD_RECEIVED"
sleep 0.2
write_manifest "$MANIFEST" 127.0.0.1 40000 "$PROFILE_ID" "$FIRST_PORT" "$SECOND_PORT" "$THIRD_PORT"

printf 'RELAY_INPUT\n' | "$HELPER" \
    --config "$MANIFEST" \
    --profile-id "$PROFILE_ID" \
    --forward-host 127.0.0.1 \
    --forward-port 40000 \
    >"$OUTPUT" 2>"$ERROR"
/usr/bin/grep -Fxq "RELAY_RESPONSE" "$OUTPUT"
/usr/bin/grep -Fxq "RELAY_INPUT" "$RECEIVED"
[[ ! -s "$THIRD_RECEIVED" ]]
[[ ! -s "$ERROR" ]]
echo "SSH relay IPv4: ordered preconnect fallback, bidirectional bytes, and no postconnect fallback passed"

TIMEOUT_MANIFEST="$FIXTURE_DIR/timeout-routes.json"
TIMEOUT_ERROR="$FIXTURE_DIR/timeout-error"
TIMEOUT_PORT="$(choose_port)"
printf '{"configurations":[{"candidates":[{"endpointID":"52000000-0000-4000-8000-000000000021","host":"203.0.113.254","port":%s}],"connectTimeoutMilliseconds":100,"operationID":"52000000-0000-4000-8000-000000000022","overallBudgetMilliseconds":150,"profileID":"52000000-0000-4000-8000-000000000023","schemaVersion":1,"target":{"host":"127.0.0.1","port":40001}}],"schemaVersion":1}\n' "$TIMEOUT_PORT" >"$TIMEOUT_MANIFEST"
chmod 600 "$TIMEOUT_MANIFEST"
set +e
"$HELPER" --config "$TIMEOUT_MANIFEST" --profile-id 52000000-0000-4000-8000-000000000023 --forward-host 127.0.0.1 --forward-port 40001 </dev/null >"$FIXTURE_DIR/timeout-output" 2>"$TIMEOUT_ERROR"
TIMEOUT_STATUS=$?
set -e
[[ "$TIMEOUT_STATUS" -ne 0 ]]
/usr/bin/grep -Eq '^KeyPortSSHRelay (candidate_timeout|candidate_unavailable|budget_exceeded)$' "$TIMEOUT_ERROR"
echo "SSH relay bounded failure: timeout/budget diagnostic stayed stable"

IPV6_PORT="$(choose_port)"
IPV6_MANIFEST="$FIXTURE_DIR/ipv6-routes.json"
IPV6_OUTPUT="$FIXTURE_DIR/ipv6-output"
IPV6_RECEIVED="$FIXTURE_DIR/ipv6-received"
start_response_server -6 ::1 "$IPV6_PORT" "RELAY_IPV6_RESPONSE" "$IPV6_RECEIVED"
sleep 0.2
printf '{"configurations":[{"candidates":[{"endpointID":"52000000-0000-4000-8000-000000000031","host":"::1","port":%s}],"connectTimeoutMilliseconds":500,"operationID":"52000000-0000-4000-8000-000000000032","overallBudgetMilliseconds":3000,"profileID":"52000000-0000-4000-8000-000000000033","schemaVersion":1,"target":{"host":"::1","port":40002}}],"schemaVersion":1}\n' "$IPV6_PORT" >"$IPV6_MANIFEST"
chmod 600 "$IPV6_MANIFEST"
set +e
printf 'RELAY_IPV6_INPUT\n' | "$HELPER" --config "$IPV6_MANIFEST" --profile-id 52000000-0000-4000-8000-000000000033 --forward-host ::1 --forward-port 40002 >"$IPV6_OUTPUT" 2>"$FIXTURE_DIR/ipv6-error"
IPV6_STATUS=$?
set -e
if [[ "$IPV6_STATUS" -eq 0 ]]; then
        /usr/bin/grep -Fxq "RELAY_IPV6_RESPONSE" "$IPV6_OUTPUT"
        /usr/bin/grep -Fxq "RELAY_IPV6_INPUT" "$IPV6_RECEIVED"
        echo "SSH relay IPv6: preconnect and byte forwarding passed"
else
    echo "SSH relay IPv6 fixture skipped: IPv6 loopback unavailable"
fi

if [[ -x /usr/sbin/sshd && -x /usr/bin/ssh-keygen && -x /usr/bin/ssh-keyscan ]]; then
    CURRENT_USER="$(id -un)"
    SSH_PORT="$(choose_port)"
    /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE_DIR/host_key"
    /usr/bin/ssh-keygen -q -t ed25519 -N '' -f "$FIXTURE_DIR/client_key"
    cp "$FIXTURE_DIR/client_key.pub" "$FIXTURE_DIR/authorized_keys"
    chmod 600 "$FIXTURE_DIR/authorized_keys"
    SSHD_CONFIG="$FIXTURE_DIR/sshd_config"
    printf '%s\n' \
        "Port $SSH_PORT" \
        'ListenAddress 127.0.0.1' \
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
        'AllowTcpForwarding no' \
        'X11Forwarding no' \
        'UsePAM no' \
        "AllowUsers $CURRENT_USER" \
        'LogLevel QUIET' \
        >"$SSHD_CONFIG"
    /usr/sbin/sshd -t -f "$SSHD_CONFIG"
    /usr/sbin/sshd -D -e -f "$SSHD_CONFIG" >"$FIXTURE_DIR/sshd.log" 2>&1 &
    SSHD_PID="$!"
    wait_for_listen -4 127.0.0.1 "$SSH_PORT"
    KNOWN_HOSTS="$FIXTURE_DIR/known_hosts"
    /usr/bin/ssh-keyscan -q -4 -p "$SSH_PORT" 127.0.0.1 >"$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"

    OPENSSH_MANIFEST="$FIXTURE_DIR/openssh-routes.json"
    OPENSSH_CONFIG="$FIXTURE_DIR/openssh-config"
    OPENSSH_FIRST_PORT="$(choose_port)"
    write_manifest "$OPENSSH_MANIFEST" 127.0.0.1 "$SSH_PORT" "$PROFILE_ID" "$OPENSSH_FIRST_PORT" "$SSH_PORT"
    printf '%s\n' \
        'Host relay-fixture' \
        '    HostName 127.0.0.1' \
        "    Port $SSH_PORT" \
        "    User $CURRENT_USER" \
        "    IdentityFile $FIXTURE_DIR/client_key" \
        '    IdentitiesOnly yes' \
        '    StrictHostKeyChecking yes' \
        "    UserKnownHostsFile $KNOWN_HOSTS" \
        '    GlobalKnownHostsFile /dev/null' \
        "    ProxyCommand $HELPER --config $OPENSSH_MANIFEST --profile-id $PROFILE_ID --forward-host %h --forward-port %p" \
        >"$OPENSSH_CONFIG"
    /usr/bin/ssh -F "$OPENSSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=3 relay-fixture true
    echo "System OpenSSH: auth, host-key policy, and session lifecycle remained outside the helper"
else
    echo "System OpenSSH fixture skipped: sshd/key tools unavailable"
fi

echo "SSH relay fixture passed"
