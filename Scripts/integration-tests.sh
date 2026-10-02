#!/bin/bash
#
# End-to-end tests of ovpn-cli against a real OpenVPN server.
#
# The server runs unprivileged on loopback with `dev null`, so no tun device,
# root, or network configuration is needed. A throwaway PKI and all static
# keys are generated per run.
#
# Requirements: openvpn >= 2.6 and openssl in PATH (brew install openvpn).
#
# Usage: Scripts/integration-tests.sh [name-filter]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
FILTER="${1:-}"
PORT=21194

command -v openvpn >/dev/null || { echo "openvpn is required (brew install openvpn)" >&2; exit 2; }
OPENSSL="$(command -v openssl)"
[[ -x /opt/homebrew/opt/openssl@3/bin/openssl ]] && OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
[[ -x /usr/local/opt/openssl@3/bin/openssl ]] && OPENSSL=/usr/local/opt/openssl@3/bin/openssl

WORK="$(mktemp -d -t semivpn-it)"
SERVER_PID=""
cleanup() {
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Building ovpn-cli..."
(cd "$PROJECT_ROOT" && swift build --product ovpn-cli >/dev/null) || { echo "build failed" >&2; exit 2; }
CLI="$(cd "$PROJECT_ROOT" && swift build --product ovpn-cli --show-bin-path)/ovpn-cli"

# MARK: - PKI

cd "$WORK" || exit 2
cat > ext.cnf <<'EOF'
[server]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[client]
basicConstraints=CA:FALSE
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EOF
"$OPENSSL" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout ca.key -out ca.crt -days 30 -subj "/CN=SemiVPN Test CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
for name in server client; do
    "$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$name.key" -out "$name.csr" -subj "/C=TR/O=SemiVPN Test/CN=semi-$name" 2>/dev/null
    "$OPENSSL" x509 -req -in "$name.csr" -CA ca.crt -CAkey ca.key -CAcreateserial \
        -out "$name.crt" -days 30 -extfile ext.cnf -extensions "$name" 2>/dev/null
done
openvpn --genkey secret ta.key
openvpn --genkey secret tc.key
openvpn --genkey tls-crypt-v2-server v2server.key
openvpn --tls-crypt-v2 v2server.key --genkey tls-crypt-v2-client v2client.key

cat > verify-pass.sh <<'EOF'
#!/bin/sh
# via-file: line 1 username, line 2 password
user="$(sed -n 1p "$1")"; pass="$(sed -n 2p "$1")"
[ "$user" = "alice" ] && [ "$pass" = "correct horse" ]
EOF
chmod +x verify-pass.sh

cat > server.conf <<EOF
mode server
tls-server
proto udp4
port $PORT
local 127.0.0.1
dev null
topology subnet
ifconfig 10.77.0.1 255.255.255.0
ifconfig-noexec
route-noexec
ifconfig-pool 10.77.0.10 10.77.0.100 255.255.255.0
push "topology subnet"
push "route-gateway 10.77.0.1"
push "dhcp-option DNS 10.77.0.1"
ca ca.crt
cert server.crt
key server.key
dh none
keepalive 1 10
verb 4
EOF

# MARK: - Runner

start_server() {
    local log="$1"; shift
    openvpn --config server.conf "$@" > "$log" 2>&1 &
    SERVER_PID=$!
    for _ in $(seq 1 60); do
        grep -q "Initialization Sequence Completed" "$log" && return 0
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            SERVER_PID=""
            return 1
        fi
        sleep 0.1
    done
    return 1
}

stop_server() {
    if [[ -n "$SERVER_PID" ]]; then
        kill "$SERVER_PID" 2>/dev/null
        wait "$SERVER_PID" 2>/dev/null
        SERVER_PID=""
    fi
}

# Builds a client profile: the scenario's directives (stdin, with @PORT@
# substituted) plus inline ca/cert/key. A `remote` line is added unless the
# scenario lists its own; `#nocert` omits the client certificate.
make_profile() {
    local body
    body="$(sed "s/@PORT@/$PORT/g")"
    {
        echo "client"
        echo "dev tun"
        grep -q "^remote " <<< "$body" || echo "remote 127.0.0.1 $PORT"
        echo "$body"
        echo "<ca>"; cat ca.crt; echo "</ca>"
        if ! grep -q "^#nocert" <<< "$body"; then
            echo "<cert>"; cat client.crt; echo "</cert>"
            echo "<key>"; cat client.key; echo "</key>"
        fi
    }
}

PASSED=0
FAILED=0
FAILED_NAMES=()

# run_case NAME EXPECT "SERVER ARGS" "CLI ARGS" < profile-directives
#   EXPECT: ready | held | fail:<regex> | timeout
#   Optional checks after `;`: clientlog:<regex> serverlog:<regex> !serverlog:<regex>
run_case() {
    local name="$1" expect="$2" server_args="$3" cli_args="$4"
    if [[ -n "$FILTER" && "$name" != *"$FILTER"* ]]; then
        cat > /dev/null
        return
    fi
    local profile="$WORK/$name.ovpn" slog="$WORK/$name.server.log" clog="$WORK/$name.client.log"
    make_profile > "$profile"

    local -a sargs=() cargs=()
    eval "sargs=($server_args)"
    eval "cargs=($cli_args)"
    if ! start_server "$slog" ${sargs[@]+"${sargs[@]}"}; then
        echo "FAIL  $name (server did not start)"
        tail -5 "$slog" | sed 's/^/      /'
        FAILED=$((FAILED + 1)); FAILED_NAMES+=("$name")
        stop_server
        return
    fi

    local outcome_expect="${expect%%;*}" checks=""
    [[ "$expect" == *";"* ]] && checks="${expect#*;}"
    "$CLI" "$profile" --timeout 20 ${cargs[@]+"${cargs[@]}"} > "$clog" 2>&1
    local status=$?
    stop_server

    local ok=1 reason=""
    case "$outcome_expect" in
        ready) [[ $status -eq 0 ]] && grep -q "SUCCESS" "$clog" || { ok=0; reason="expected ready (exit $status)"; } ;;
        held) [[ $status -eq 0 ]] && grep -q "HOLD COMPLETE.*state: ready" "$clog" || { ok=0; reason="expected a held, ready session (exit $status)"; } ;;
        timeout) [[ $status -eq 3 ]] || { ok=0; reason="expected timeout (exit $status)"; } ;;
        fail:*)
            local pattern="${outcome_expect#fail:}"
            [[ $status -eq 1 ]] && grep -Eq "FAILED: .*($pattern)" "$clog" || { ok=0; reason="expected failure matching /$pattern/ (exit $status)"; } ;;
    esac
    local check
    IFS=' ' read -r -a check_list <<< "$checks"
    for check in ${check_list[@]+"${check_list[@]}"}; do
        case "$check" in
            clientlog:*) grep -Eq "${check#clientlog:}" "$clog" || { ok=0; reason="client log lacks /${check#clientlog:}/"; } ;;
            serverlog:*) grep -Eq "${check#serverlog:}" "$slog" || { ok=0; reason="server log lacks /${check#serverlog:}/"; } ;;
            !serverlog:*) grep -Eq "${check#!serverlog:}" "$slog" && { ok=0; reason="server log has /${check#!serverlog:}/"; } ;;
        esac
    done

    if [[ $ok -eq 1 ]]; then
        echo "PASS  $name"
        PASSED=$((PASSED + 1))
    else
        echo "FAIL  $name: $reason"
        grep -E "SUCCESS|FAILED|TIMEOUT|HOLD|error|state\]" "$clog" | tail -6 | sed 's/^/      client: /'
        grep -E "TLS Error|AUTH|HMAC|error|Error" "$slog" | tail -4 | sed 's/^/      server: /'
        FAILED=$((FAILED + 1)); FAILED_NAMES+=("$name")
    fi
}

# MARK: - Scenarios

run_case udp-baseline "ready" "" "" <<'EOF'
proto udp
remote-cert-tls server
EOF

run_case tcp-baseline "ready" "--proto tcp4-server" "" <<'EOF'
proto tcp
remote-cert-tls server
EOF

run_case udp-data-channel-pings "held;clientlog:received ping" "" "--hold 3" <<'EOF'
proto udp
EOF

echo
echo "$PASSED passed, $FAILED failed"
if [[ $FAILED -gt 0 ]]; then
    printf '  failed: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
