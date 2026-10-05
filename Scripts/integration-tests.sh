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
    if [[ -n "${KEEP_WORK:-}" ]]; then
        echo "logs kept in $WORK"
    else
        rm -rf "$WORK"
    fi
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
cat >> ext.cnf <<'EOF'
[intermediate]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
[server_noeku]
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
EOF
# Intermediate CA and a client certificate it issued (the server only
# trusts the root, so the client must send the intermediate).
"$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout int.key -out int.csr -subj "/CN=SemiVPN Test Intermediate" 2>/dev/null
"$OPENSSL" x509 -req -in int.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out int.crt -days 30 -extfile ext.cnf -extensions intermediate 2>/dev/null
"$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout client-int.key -out client-int.csr -subj "/CN=semi-client-int" 2>/dev/null
"$OPENSSL" x509 -req -in client-int.csr -CA int.crt -CAkey int.key -CAcreateserial \
    -out client-int.crt -days 30 -extfile ext.cnf -extensions client 2>/dev/null
# A passphrase-protected copy of the client key.
"$OPENSSL" pkey -in client.key -aes256 -passout pass:open-sesame -out client-enc.key 2>/dev/null
# Server certificates without any EKU (OpenSSL accepts it for any purpose,
# remote-cert-tls must not) and with only clientAuth (OpenSSL rejects it).
"$OPENSSL" req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout server-noeku.key -out server-noeku.csr -subj "/CN=semi-server-noeku" 2>/dev/null
"$OPENSSL" x509 -req -in server-noeku.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server-noeku.crt -days 30 -extfile ext.cnf -extensions server_noeku 2>/dev/null
"$OPENSSL" x509 -req -in server-noeku.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server-clienteku.crt -days 30 -extfile ext.cnf -extensions client 2>/dev/null

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

cat > verify-once.sh <<'EOF'
#!/bin/sh
# Accepts the password exactly once: later logins must use the auth-token.
user="$(sed -n 1p "$1")"; pass="$(sed -n 2p "$1")"
[ -e once.used ] && exit 1
[ "$user" = "alice" ] && [ "$pass" = "123456" ] && touch once.used
EOF
chmod +x verify-once.sh

# Management-interface helper: `mgmt.py SOCKET after SECONDS CMD...` sends
# commands after a delay; `mgmt.py SOCKET pending` answers client-connect
# requests with AUTH_PENDING and approves them two seconds later.
cat > mgmt.py <<'EOF'
import socket, sys, time
path, mode = sys.argv[1], sys.argv[2]
for _ in range(100):
    try:
        s = socket.socket(socket.AF_UNIX); s.connect(path); break
    except OSError:
        time.sleep(0.1)
f = s.makefile("rw")
def send(cmd):
    f.write(cmd + "\n"); f.flush()
if mode == "after":
    time.sleep(float(sys.argv[3]))
    for cmd in sys.argv[4:]:
        send(cmd); time.sleep(0.3)
    time.sleep(1)
elif mode == "pending":
    for line in f:
        if line.startswith(">CLIENT:CONNECT,") or line.startswith(">CLIENT:REAUTH,"):
            cid, kid = line.strip().split(",")[1:3]
            send(f"client-pending-auth {cid} {kid} OPEN_URL:https://auth.invalid/login 30")
            time.sleep(2)
            send(f"client-auth-nt {cid} {kid}")
EOF

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

# run_case NAME EXPECT "SERVER ARGS" "CLI ARGS" ["BACKGROUND COMMAND"] < profile-directives
#   EXPECT: ready | held | fail:<regex> | timeout
#   Optional checks after `;`: clientlog:<regex> !clientlog:<regex> serverlog:<regex>
#   !serverlog:<regex> count:<regex>=<minimum client log matches>
#   The background command runs alongside the client (e.g. management actions).
run_case() {
    local name="$1" expect="$2" server_args="$3" cli_args="$4" background="${5:-}"
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
    local bg_pid=""
    if [[ -n "$background" ]]; then
        (eval "$background") > "$WORK/$name.bg.log" 2>&1 &
        bg_pid=$!
        sleep 1   # let the helper attach to the management socket first
    fi
    "$CLI" "$profile" --timeout 20 ${cargs[@]+"${cargs[@]}"} > "$clog" 2>&1
    local status=$?
    sleep 0.5
    [[ -n "$bg_pid" ]] && kill "$bg_pid" 2>/dev/null
    stop_server
    rm -f once.used

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
    IFS=';' read -r -a check_list <<< "$checks"
    for check in ${check_list[@]+"${check_list[@]}"}; do
        case "$check" in
            clientlog:*) grep -Eq "${check#clientlog:}" "$clog" || { ok=0; reason="client log lacks /${check#clientlog:}/"; } ;;
            !clientlog:*) grep -Eq "${check#!clientlog:}" "$clog" && { ok=0; reason="client log has /${check#!clientlog:}/"; } ;;
            count:*)
                local spec="${check#count:}" pattern count
                pattern="${spec%=*}"; count="${spec##*=}"
                [[ "$(grep -Ec "$pattern" "$clog")" -ge "$count" ]] || { ok=0; reason="client log has fewer than $count /$pattern/"; } ;;
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

run_case udp-data-channel-pings "held;clientlog:data channel verified" "" "--hold 3" <<'EOF'
proto udp
EOF

# tls-auth: HMAC keys are truncated to the digest size; SHA1 is the default.
for digest in SHA512 SHA256 SHA1; do
    run_case "tls-auth-$digest" "ready" "--tls-auth ta.key 0 --auth $digest" "" <<EOF
proto udp
auth $digest
key-direction 1
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF
done

run_case tls-auth-default-digest "ready" "--tls-auth ta.key 0" "" <<EOF
proto udp
key-direction 1
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF

run_case tls-auth-bidirectional "ready" "--tls-auth ta.key" "" <<EOF
proto udp
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF

run_case tls-auth-invalid-key "fail:tls-auth" "--tls-auth ta.key 0" "" <<'EOF'
proto udp
key-direction 1
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
00112233
-----END OpenVPN Static key V1-----
</tls-auth>
EOF

run_case tls-crypt-v1 "ready" "--tls-crypt tc.key" "" <<EOF
proto udp
<tls-crypt>
$(cat tc.key)
</tls-crypt>
EOF

run_case tls-crypt-v1-tcp "ready" "--proto tcp4-server --tls-crypt tc.key" "" <<EOF
proto tcp
<tls-crypt>
$(cat tc.key)
</tls-crypt>
EOF

run_case tls-crypt-v2 "ready" "--tls-crypt-v2 v2server.key" "" <<EOF
proto udp
<tls-crypt-v2>
$(cat v2client.key)
</tls-crypt-v2>
EOF

run_case tcp4-client-proto "ready" "--proto tcp4-server" "" <<'EOF'
proto tcp4-client
EOF

run_case remote-line-proto "ready" "--proto tcp4-server" "" <<'EOF'
proto udp
remote 127.0.0.1 @PORT@ tcp
EOF

run_case lowercase-cipher "ready" "--data-ciphers AES-128-GCM" "" <<'EOF'
proto udp
cipher aes-128-gcm
data-ciphers aes-128-gcm
EOF

run_case file-references "ready" "--tls-auth ta.key 0" "" <<'EOF'
proto udp
tls-auth ta.key 1
EOF

# MARK: TLS

run_case cert-chain-in-cert-block "ready" "" "" <<EOF
proto udp
#nocert
<cert>
$(cat client-int.crt int.crt)
</cert>
<key>
$(cat client-int.key)
</key>
EOF

run_case cert-chain-extra-certs "ready" "" "" <<EOF
proto udp
#nocert
<cert>
$(cat client-int.crt)
</cert>
<extra-certs>
$(cat int.crt)
</extra-certs>
<key>
$(cat client-int.key)
</key>
EOF

# The server drops the session without a TLS alert, like with any OpenVPN
# client: the hand-window expires and the client retries.
run_case cert-chain-missing-intermediate "timeout;clientlog:handshake timed out;serverlog:unable to get local issuer" "" "--timeout 8" <<EOF
proto udp
hand-window 3
#nocert
<cert>
$(cat client-int.crt)
</cert>
<key>
$(cat client-int.key)
</key>
EOF

run_case encrypted-key "ready" "" "--askpass open-sesame" <<EOF
proto udp
#nocert
<cert>
$(cat client.crt)
</cert>
<key>
$(cat client-enc.key)
</key>
EOF

run_case encrypted-key-no-passphrase "fail:passphrase" "" "" <<EOF
proto udp
#nocert
<cert>
$(cat client.crt)
</cert>
<key>
$(cat client-enc.key)
</key>
EOF

run_case verify-x509-subject "ready" "" "" <<'EOF'
proto udp
verify-x509-name "C=TR, O=SemiVPN Test, CN=semi-server"
EOF

run_case verify-x509-name "ready" "" "" <<'EOF'
proto udp
verify-x509-name semi-server name
EOF

run_case verify-x509-name-prefix "ready" "" "" <<'EOF'
proto udp
verify-x509-name semi- name-prefix
EOF

run_case verify-x509-subject-mismatch "fail:subject mismatch" "" "" <<'EOF'
proto udp
verify-x509-name "C=TR, O=Other, CN=semi-server"
EOF

run_case remote-cert-tls-requires-server-eku "fail:serverAuth EKU" "--cert server-noeku.crt --key server-noeku.key" "" <<'EOF'
proto udp
remote-cert-tls server
EOF

run_case server-cert-wrong-purpose "fail:unsuitable certificate purpose" "--cert server-clienteku.crt --key server-noeku.key" "" <<'EOF'
proto udp
EOF

run_case tls-version-min-1.3 "ready" "" "" <<'EOF'
proto udp
tls-version-min 1.3
EOF

run_case tls-version-min-1.3-vs-tls12-server "timeout;clientlog:handshake timed out;serverlog:unsupported protocol" "--tls-version-max 1.2" "--timeout 8" <<'EOF'
proto udp
hand-window 3
tls-version-min 1.3
EOF

# tls-cipher only applies up to TLS 1.2, so these servers stop there. Like
# OpenVPN, SemiVPN accepts IANA names (what openvpn-install and current
# OpenVPN docs write), OpenSSL names and lists mixing both.
run_case tls-cipher-iana-name "ready;serverlog:TLSv1.2.*ECDHE-ECDSA-AES128-GCM-SHA256" "--tls-version-max 1.2" "" <<'EOF'
proto udp
tls-cipher TLS-ECDHE-ECDSA-WITH-AES-128-GCM-SHA256
EOF

run_case tls-cipher-openssl-name "ready;serverlog:TLSv1.2.*ECDHE-ECDSA-AES256-GCM-SHA384" "--tls-version-max 1.2" "" <<'EOF'
proto udp
tls-cipher ECDHE-ECDSA-AES256-GCM-SHA384
EOF

# The server accepts only the suite named in IANA form here.
run_case tls-cipher-mixed-list "ready;serverlog:TLSv1.2.*ECDHE-ECDSA-CHACHA20-POLY1305" "--tls-version-max 1.2 --tls-cipher ECDHE-ECDSA-CHACHA20-POLY1305" "" <<'EOF'
proto udp
tls-cipher TLS-ECDHE-ECDSA-WITH-CHACHA20-POLY1305-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384
EOF

run_case tls-cipher-unknown "fail:tls-cipher" "" "" <<'EOF'
proto udp
tls-cipher TLS-NOT-A-REAL-CIPHER
EOF

# MARK: Connection state machine

AUTH_SERVER="--script-security 2 --auth-user-pass-verify verify-pass.sh via-file"

run_case auth-success "ready" "$AUTH_SERVER" "--auth-user-pass alice 'correct horse'" <<'EOF'
proto udp
auth-user-pass
EOF

run_case auth-inline-credentials "ready" "$AUTH_SERVER" "" <<'EOF'
proto udp
auth-user-pass
<auth-user-pass>
alice
correct horse
</auth-user-pass>
EOF

# AUTH_FAILED arrives in reply to PUSH_REQUEST and must end the session
# (it used to be ignored, looping forever).
run_case auth-failed-udp "fail:Authentication failed" "$AUTH_SERVER" "--auth-user-pass alice wrong" <<'EOF'
proto udp
auth-user-pass
EOF

run_case auth-failed-tcp "fail:Authentication failed" "--proto tcp4-server $AUTH_SERVER" "--auth-user-pass alice wrong" <<'EOF'
proto tcp
auth-user-pass
EOF

# A tls-auth key mismatch makes the server drop everything: the hand-window
# must expire and the client must retry instead of hanging in "connecting".
run_case handshake-timeout "timeout;clientlog:handshake timed out;clientlog:reconnecting" "--tls-auth tc.key 0" "--timeout 9" <<EOF
proto udp
hand-window 3
key-direction 1
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF

run_case remote-failover "ready;clientlog:connection refused" "" "" <<'EOF'
proto udp
remote 127.0.0.1 1
remote 127.0.0.1 @PORT@
EOF

run_case exit-notify-on-disconnect "held;serverlog:Delayed exit" "" "--hold 2" <<'EOF'
proto udp
EOF

run_case server-restart "held;clientlog:Server requested a reconnect;clientlog:attempt 1" \
    "--management $WORK/mgmt.sock unix" "--hold 6" \
    "python3 mgmt.py $WORK/mgmt.sock after 2 'client-kill 0'" <<'EOF'
proto udp
EOF

run_case server-halt "fail:disconnected this client" \
    "--management $WORK/mgmt.sock unix" "--hold 6" \
    "python3 mgmt.py $WORK/mgmt.sock after 2 'client-kill 0 HALT'" <<'EOF'
proto udp
EOF

# The password is valid once; the reconnect forced by the server must
# authenticate with the pushed auth-token instead.
run_case auth-token-reconnect "held;clientlog:received auth-token;clientlog:Server requested a reconnect" \
    "--script-security 2 --auth-user-pass-verify verify-once.sh via-file --auth-gen-token 60 --management $WORK/mgmt.sock unix" \
    "--auth-user-pass alice 123456 --hold 6" \
    "python3 mgmt.py $WORK/mgmt.sock after 2 'client-kill 0'" <<'EOF'
proto udp
auth-user-pass
EOF

run_case auth-pending "ready;clientlog:authentication pending" \
    "--management $WORK/mgmt.sock unix --management-client-auth" "--auth-user-pass alice x" \
    "python3 mgmt.py $WORK/mgmt.sock pending" <<'EOF'
proto udp
auth-user-pass
EOF

ROUTES=""
for i in $(seq 1 120); do ROUTES="$ROUTES --push \"route 10.$((i / 250)).$((i % 250)).0 255.255.255.0\""; done
run_case push-continuation "ready;clientlog:continues in the next message;clientlog:routes=120" "$ROUTES" "" <<'EOF'
proto udp
EOF

# MARK: Renegotiation (soft reset on a new key-id; data keeps flowing)

RENEG_OK="held;count:renegotiation complete=2;!clientlog:ping restart;!serverlog:Authenticate/Decrypt packet error;!serverlog:TLS (Error|ERROR)"

run_case reneg-server-initiated "$RENEG_OK;clientlog:server initiated" "--reneg-sec 3" "--hold 8" <<'EOF'
proto udp
EOF

run_case reneg-client-initiated "$RENEG_OK;clientlog:client initiated" "--reneg-sec 0" "--hold 8" <<'EOF'
proto udp
reneg-sec 3
EOF

run_case reneg-tcp "$RENEG_OK" "--proto tcp4-server --reneg-sec 3" "--hold 8" <<'EOF'
proto tcp
EOF

run_case reneg-tls-auth "$RENEG_OK" "--reneg-sec 3 --tls-auth ta.key 0 --auth SHA256" "--hold 8" <<EOF
proto udp
auth SHA256
key-direction 1
<tls-auth>
$(cat ta.key)
</tls-auth>
EOF

run_case reneg-tls-crypt "$RENEG_OK" "--reneg-sec 3 --tls-crypt tc.key" "--hold 8" <<EOF
proto udp
<tls-crypt>
$(cat tc.key)
</tls-crypt>
EOF

run_case reneg-tls-crypt-v2 "$RENEG_OK" "--reneg-sec 3 --tls-crypt-v2 v2server.key" "--hold 8" <<EOF
proto udp
<tls-crypt-v2>
$(cat v2client.key)
</tls-crypt-v2>
EOF

run_case reneg-cbc-prf "$RENEG_OK;clientlog:OpenVPN PRF" "--reneg-sec 3 --data-ciphers AES-256-CBC --auth SHA256" "--hold 8 --no-ekm" <<'EOF'
proto udp
cipher AES-256-CBC
data-ciphers AES-256-CBC
auth SHA256
EOF

run_case reneg-with-credentials "$RENEG_OK" "--reneg-sec 3 $AUTH_SERVER" "--hold 8 --auth-user-pass alice 'correct horse'" <<'EOF'
proto udp
auth-user-pass
EOF

echo
echo "$PASSED passed, $FAILED failed"
if [[ $FAILED -gt 0 ]]; then
    printf '  failed: %s\n' "${FAILED_NAMES[@]}"
    exit 1
fi
