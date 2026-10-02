#!/bin/sh
# Xcode pre-build phase: copies the OpenSSL dylibs into the target's temp
# directory with @rpath install names, so the product links against them.
set -e
PREFIX="$("$SRCROOT/Scripts/openssl-prefix.sh")"
SRC="$PREFIX/lib"
STAGE="$TARGET_TEMP_DIR/OpenSSL"
mkdir -p "$STAGE"
for lib in libssl.3.dylib libcrypto.3.dylib; do
    ditto "$SRC/$lib" "$STAGE/$lib"
    chmod u+w "$STAGE/$lib"
    install_name_tool -id "@rpath/$lib" "$STAGE/$lib"
done
for crypto in "$SRC/libcrypto.3.dylib" "$(realpath "$SRC")/libcrypto.3.dylib"; do
    install_name_tool -change "$crypto" "@rpath/libcrypto.3.dylib" "$STAGE/libssl.3.dylib" 2>/dev/null || true
done
