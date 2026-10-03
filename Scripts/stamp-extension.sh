#!/bin/sh
# Xcode post-build phase: stamps the bundled browser extension with a
# fingerprint of its files, as the manifest's version_name ("0.4.0 (1a2b3c4)").
#
# The app copies the bundled extension to the folder the browser loads it
# from, and the extension reloads itself when that copy's version_name differs
# from the one it runs. Any change to the extension therefore reaches the
# browser, even when its version number was not bumped.
set -e
SRC="$SRCROOT/ChromeExtension"
MANIFEST="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/ChromeExtension/manifest.json"
if [ ! -f "$MANIFEST" ]; then
    echo "warning: $MANIFEST not found; the extension is not stamped"
    exit 0
fi
FINGERPRINT="$(cd "$SRC" && find . -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 | shasum -a 256 | cut -c1-7)"
VERSION="$(plutil -extract version raw -o - "$SRC/manifest.json")"
STAMP="$VERSION ($FINGERPRINT)"
# Leave an already stamped file untouched: rewriting it after Xcode signed
# the app in an earlier build would invalidate that signature.
if [ "$(plutil -extract version_name raw -o - "$MANIFEST" 2>/dev/null)" != "$STAMP" ]; then
    plutil -replace version_name -string "$STAMP" "$MANIFEST"
fi
