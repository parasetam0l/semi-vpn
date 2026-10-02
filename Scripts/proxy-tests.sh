#!/bin/bash
#
# Tests SemiProxy (the browser-domain proxy and its control API) in
# isolation: a separately built instance runs on scratch ports against a
# scratch config directory, so a running SemiVPN is not affected.
#
# Requirements: xcodegen, Xcode, python3.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
WORK="$(mktemp -d -t semiproxy-test)"
PROXY_PORT=59280
CONTROL_PORT=59281
UPSTREAM_PORT=58080
PIDS=()
cleanup() {
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "Building SemiProxy (unsigned)..."
(cd "$PROJECT_ROOT" && xcodegen generate >/dev/null) || exit 2
xcodebuild -project "$PROJECT_ROOT/semi-vpn.xcodeproj" -scheme semi-vpn -configuration Debug \
    -derivedDataPath "$WORK/dd" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build >/dev/null 2>&1 \
    || { echo "build failed" >&2; exit 2; }
PROXY="$WORK/dd/Build/Products/Debug/SemiProxy.app/Contents/MacOS/SemiProxy"

mkdir -p "$WORK/config" "$WORK/www"
echo "hello from upstream" > "$WORK/www/index.html"
write_config() { # block-when-disconnected forwarding-allowed
    cat > "$WORK/config/domains.json" <<EOF
{"domains":["127.0.0.1"],"subdomainDomains":[],"inactiveDomains":[],"blockWhenDisconnected":$1,"revision":1}
EOF
    echo "{\"vpnStatus\":\"disconnected\",\"forwardingAllowed\":$2,\"hasVPNIPv6\":false}" > "$WORK/config/runtime_state.json"
    sleep 1.1   # the proxy caches files by modification time
}
write_config false false

(cd "$WORK/www" && exec python3 -m http.server "$UPSTREAM_PORT" --bind 127.0.0.1) >/dev/null 2>&1 &
PIDS+=($!)
SEMIVPN_CONTAINER="$WORK/config" SEMIVPN_PROXY_PORT=$PROXY_PORT SEMIVPN_CONTROL_PORT=$CONTROL_PORT \
    "$PROXY" --parent-pid $$ >/dev/null 2>&1 &
PIDS+=($!)
sleep 2

PASSED=0
FAILED=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then
        echo "PASS  $1"; PASSED=$((PASSED + 1))
    else
        echo "FAIL  $1: expected '$2', got '$3'"; FAILED=$((FAILED + 1))
    fi
}
via_proxy() { curl -s -o /dev/null -w "%{http_code}" -x "http://127.0.0.1:$PROXY_PORT" "$1"; }
control() { curl -s -o /dev/null -w "%{http_code}" "$@"; }

check "listed domain goes direct while disconnected (fail-open)" 200 "$(via_proxy "http://127.0.0.1:$UPSTREAM_PORT/index.html")"
check "unlisted domain is refused" 403 "$(via_proxy "http://localhost:$UPSTREAM_PORT/index.html")"

reuse="$(python3 - "$PROXY_PORT" "$UPSTREAM_PORT" <<'EOF'
import socket, sys
proxy, upstream = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", proxy))
s.sendall(f"GET http://127.0.0.1:{upstream}/index.html HTTP/1.1\r\nHost: 127.0.0.1:{upstream}\r\nProxy-Connection: keep-alive\r\n\r\n".encode())
while s.recv(65536):
    pass
try:
    s.sendall(f"GET http://localhost:{upstream}/ HTTP/1.1\r\nHost: localhost:{upstream}\r\n\r\n".encode())
    print("reused" if s.recv(100) else "closed")
except OSError:
    print("closed")
EOF
)"
check "HTTP proxy connections are not reused across requests" closed "$reuse"

write_config true false
check "listed domain is blocked while disconnected (fail-closed)" 503 "$(via_proxy "http://127.0.0.1:$UPSTREAM_PORT/index.html")"
write_config true true
check "listed domain is forwarded while connected" 200 "$(via_proxy "http://127.0.0.1:$UPSTREAM_PORT/index.html")"

check "control API answers loopback callers" 200 "$(control "http://127.0.0.1:$CONTROL_PORT/v1/status")"
check "control API rejects DNS-rebinding hosts" 421 "$(control -H "Host: evil.example:$CONTROL_PORT" "http://127.0.0.1:$CONTROL_PORT/v1/status")"
check "control API rejects other extensions" 403 "$(control -H "Origin: chrome-extension://abcdefghijklmnopabcdefghijklmnop" "http://127.0.0.1:$CONTROL_PORT/v1/status")"
check "control API rejects web pages" 403 "$(control -H "Origin: https://evil.example" -X POST -d '{"domain":"x.example"}' "http://127.0.0.1:$CONTROL_PORT/v1/domains")"
check "control API accepts the SemiVPN extension" 200 "$(control -H "Origin: chrome-extension://jaiknknmjmncnocbcbneepnefhokegma" "http://127.0.0.1:$CONTROL_PORT/v1/status")"

echo
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
