#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/SemiVPN.app"
BUILD_EXTENSION="$BUILD_APP/Contents/PlugIns/TunnelProvider.appex"
INSTALL_APP="/Applications/SemiVPN.app"
# Signing team: DEVELOPMENT_TEAM from the environment, else the one in
# project.yml. The team is never guessed from the keychain or the installed
# app, which may belong to a different account.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-$(awk '$1 == "DEVELOPMENT_TEAM:" { print $2; exit }' "$PROJECT_ROOT/project.yml")}"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    printf 'Error: no signing team. Set DEVELOPMENT_TEAM in project.yml or the environment:\n' >&2
    printf '  DEVELOPMENT_TEAM=YOUR_TEAM_ID %s\n' "$0" >&2
    exit 1
fi

EXPECTED_TEAM_ID="$DEVELOPMENT_TEAM"
EXPECTED_BUNDLE_ID="com.semivpn.app"
EXPECTED_EXTENSION_BUNDLE_ID="com.semivpn.app.TunnelProvider"

if [[ "${1:-}" != "" && "${1:-}" != "--install" ]]; then
    printf 'Usage: %s [--install]\n' "$0" >&2
    exit 2
fi

command -v xcodegen >/dev/null 2>&1 || {
    printf 'xcodegen is required. Install it with: brew install xcodegen\n' >&2
    exit 1
}
command -v xcodebuild >/dev/null 2>&1 || {
    printf 'xcodebuild is required. Install Xcode and select it with xcode-select.\n' >&2
    exit 1
}

cd "$PROJECT_ROOT"

printf '%s\n' 'Generating the Xcode project...'
xcodegen generate

printf 'Building a signed Debug app with team %s...\n' "$EXPECTED_TEAM_ID"
# Let Xcode register the bundle IDs and this Mac, and create the development
# profiles (as building in Xcode does); the team's Apple ID must be signed in
# to Xcode.
xcodebuild \
    -project "$PROJECT_ROOT/semi-vpn.xcodeproj" \
    -scheme semi-vpn \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    DEVELOPMENT_TEAM="$EXPECTED_TEAM_ID" \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    build

[[ -d "$BUILD_APP" ]] || {
    printf 'Build succeeded but the app was not found at:\n%s\n' "$BUILD_APP" >&2
    exit 1
}

signature_info="$(codesign -dv --verbose=4 "$BUILD_APP" 2>&1 || true)"
actual_team="$(printf '%s\n' "$signature_info" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
actual_bundle="$(plutil -extract CFBundleIdentifier raw -o - "$BUILD_APP/Contents/Info.plist")"
extension_signature_info="$(codesign -dv --verbose=4 "$BUILD_EXTENSION" 2>&1 || true)"
extension_team="$(printf '%s\n' "$extension_signature_info" | awk -F= '$1 == "TeamIdentifier" { print $2; exit }')"
extension_bundle="$(plutil -extract CFBundleIdentifier raw -o - "$BUILD_EXTENSION/Contents/Info.plist")"

if [[ "$actual_team" != "$EXPECTED_TEAM_ID" ]]; then
    printf 'Unexpected signing team: %s (expected %s)\n' "$actual_team" "$EXPECTED_TEAM_ID" >&2
    printf '%s\n' "$signature_info" >&2
    exit 1
fi
if [[ "$actual_bundle" != "$EXPECTED_BUNDLE_ID" ]]; then
    printf 'Unexpected bundle identifier: %s (expected %s)\n' "$actual_bundle" "$EXPECTED_BUNDLE_ID" >&2
    exit 1
fi
if [[ "$extension_team" != "$EXPECTED_TEAM_ID" ]]; then
    printf 'Unexpected TunnelProvider signing team: %s (expected %s)\n' "$extension_team" "$EXPECTED_TEAM_ID" >&2
    printf '%s\n' "$extension_signature_info" >&2
    exit 1
fi
if [[ "$extension_bundle" != "$EXPECTED_EXTENSION_BUNDLE_ID" ]]; then
    printf 'Unexpected TunnelProvider bundle identifier: %s (expected %s)\n' "$extension_bundle" "$EXPECTED_EXTENSION_BUNDLE_ID" >&2
    exit 1
fi

codesign --verify --deep --strict "$BUILD_APP"

# macOS refuses to launch a product whose entitlements its provisioning
# profile does not grant, e.g. an unexpanded $(AppIdentifierPrefix).
for product in "$BUILD_APP" "$BUILD_EXTENSION"; do
    entitlements="$(codesign -d --entitlements - --xml "$product" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null || true)"
    if [[ "$entitlements" == *'$('* || "$entitlements" != *"<string>$EXPECTED_TEAM_ID.com.semivpn.shared</string>"* ]]; then
        printf 'Unexpected entitlements in %s:\n%s\n' "$product" "$entitlements" >&2
        exit 1
    fi
done

for debug_dylib in \
    "$BUILD_APP/Contents/MacOS/SemiVPN.debug.dylib" \
    "$BUILD_APP/Contents/PlugIns/TunnelProvider.appex/Contents/MacOS/TunnelProvider.debug.dylib"; do
    [[ -f "$debug_dylib" ]] || {
        printf 'Missing debug dylib: %s\n' "$debug_dylib" >&2
        exit 1
    }
    if otool -L "$debug_dylib" | grep -Eq '/(opt/homebrew|usr/local)/(opt|Cellar)/openssl'; then
        printf 'Debug dylib still links to Homebrew OpenSSL: %s\n' "$debug_dylib" >&2
        exit 1
    fi
done

printf 'Verified: %s and %s signed with team %s\n' "$actual_bundle" "$extension_bundle" "$actual_team"
printf 'Build output: %s\n' "$BUILD_APP"

if [[ "${1:-}" == "--install" ]]; then
    installed_team="$(codesign -dv "$INSTALL_APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2; exit }' || true)"
    if [[ -n "$installed_team" && "$installed_team" != "$EXPECTED_TEAM_ID" ]]; then
        printf 'Note: the installed SemiVPN was signed by team %s, this build by %s.\n' "$installed_team" "$EXPECTED_TEAM_ID"
        printf 'Profiles and saved passwords are keychain items of the old team: re-import the profiles after installing.\n'
        printf 'On the first connection macOS asks whether TunnelProvider may use the old build'"'"'s data; the tunnel waits until you allow it.\n'
    fi

    running_target="$INSTALL_APP/Contents/MacOS/SemiVPN"
    running_pids="$(ps -axo pid=,command= | awk -v target="$running_target" '$2 == target { print $1 }')"
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$running_pids"

    running_proxy="$INSTALL_APP/Contents/Resources/SemiProxy.app/Contents/MacOS/SemiProxy"
    running_proxy_pids="$(ps -axo pid=,command= | awk -v target="$running_proxy" '$2 == target { print $1 }')"
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        kill -TERM "$pid" 2>/dev/null || true
    done <<< "$running_proxy_pids"

    for _ in {1..10}; do
        if ! ps -axo pid=,command= | awk -v target="$running_target" '$2 == target { found=1 } END { exit found ? 0 : 1 }'; then
            break
        fi
        sleep 0.2
    done

    ditto "$BUILD_APP" "$INSTALL_APP"
    codesign --verify --deep --strict "$INSTALL_APP"
    /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$INSTALL_APP/Contents/Resources/SemiProxy.app"
    open -n "$INSTALL_APP"
    printf 'Installed and relaunched: %s\n' "$INSTALL_APP"
fi
