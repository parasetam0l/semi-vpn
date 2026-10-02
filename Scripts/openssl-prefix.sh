#!/bin/sh
# Prints the OpenSSL 3 installation prefix: $OPENSSL_ROOT, else Homebrew's
# openssl@3 (Apple Silicon or Intel location).
if [ -n "${OPENSSL_ROOT:-}" ]; then
    echo "$OPENSSL_ROOT"
    exit 0
fi
for candidate in /opt/homebrew/opt/openssl@3 /usr/local/opt/openssl@3; do
    if [ -f "$candidate/lib/libssl.3.dylib" ]; then
        echo "$candidate"
        exit 0
    fi
done
echo "error: OpenSSL 3 not found; install it with 'brew install openssl@3' or set OPENSSL_ROOT" >&2
exit 1
