#!/bin/sh
# Xcode post-compile phase: embeds the staged OpenSSL dylibs in the product's
# Frameworks folder, points the binaries at them and re-signs.
set -e
PREFIX="$("$SRCROOT/Scripts/openssl-prefix.sh")"
SRC="$PREFIX/lib"
STAGE="$TARGET_TEMP_DIR/OpenSSL"
DEST="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$DEST"
for lib in libssl.3.dylib libcrypto.3.dylib; do
    ditto "$STAGE/$lib" "$DEST/$lib"
done
for bin in "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" "$TARGET_BUILD_DIR/${EXECUTABLE_PATH}.debug.dylib"; do
    [ -f "$bin" ] || continue
    for lib in libssl.3.dylib libcrypto.3.dylib; do
        for path in "$SRC/$lib" "$(realpath "$SRC")/$lib"; do
            install_name_tool -change "$path" "@rpath/$lib" "$bin" 2>/dev/null || true
        done
    done
done

if [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
    # Xcode's processed entitlements for this target: build settings such as
    # $(AppIdentifierPrefix) expanded, plus the identifiers the provisioning
    # profile requires. Not the CODE_SIGN_ENTITLEMENTS source file: an
    # incremental build can skip Xcode's own signing of the product and keep
    # the signature made here, which macOS then refuses to launch.
    ENTITLEMENTS="$TARGET_TEMP_DIR/$FULL_PRODUCT_NAME.xcent"
    if [ ! -f "$ENTITLEMENTS" ]; then
        echo "warning: $ENTITLEMENTS not found; signing $FULL_PRODUCT_NAME without entitlements"
        ENTITLEMENTS=""
    fi
    # The debug dylib first: the stub executable cannot be signed while a
    # subcomponent is unsigned.
    for bin in "$TARGET_BUILD_DIR/${EXECUTABLE_PATH}.debug.dylib" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH"; do
        [ -f "$bin" ] || continue
        codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
            ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} "$bin" \
            || echo "warning: could not re-sign $bin"
    done
    for lib in "$DEST/libssl.3.dylib" "$DEST/libcrypto.3.dylib"; do
        codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$lib" \
            || echo "warning: could not sign $lib"
    done
    # Re-seal the product after modifying its nested dylibs, so the bundle
    # signature matches its contents.
    codesign --force --options runtime --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        ${ENTITLEMENTS:+--entitlements "$ENTITLEMENTS"} "$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME" \
        || echo "warning: could not re-seal $FULL_PRODUCT_NAME"
fi
