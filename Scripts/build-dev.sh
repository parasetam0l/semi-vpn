#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DERIVED_DATA="$PROJECT_ROOT/.build/DerivedData"
BUILD_APP="$DERIVED_DATA/Build/Products/Debug/SemiVPN.app"
BUILD_EXTENSION="$BUILD_APP/Contents/PlugIns/TunnelProvider.appex"
INSTALL_APP="/Applications/SemiVPN.app"
# Signing identity / team configuration:
# Provide DEVELOPMENT_TEAM via environment variable, or auto-detect from local keychain.
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$DEVELOPMENT_TEAM" ]] && [[ -d "$INSTALL_APP" ]]; then
    DEVELOPMENT_TEAM="$(codesign -dv "$INSTALL_APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" { print $2; exit }' || true)"
fi
if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    DEVELOPMENT_TEAM="$(security find-identity -p codesigning -v 2>/dev/null | awk -F'(' '/Apple Development/{print $NF}' | tr -d ')"' | head -n1 || true)"
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
    printf 'Error: DEVELOPMENT_TEAM is not set and could not be auto-detected from keychain.\n' >&2
    printf 'Please set your Apple Developer Team ID:\n' >&2
    printf '  export DEVELOPMENT_TEAM=YOUR_TEAM_ID\n' >&2
    printf '  %s\n' "$0" >&2
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
xcodebuild \
    -project "$PROJECT_ROOT/semi-vpn.xcodeproj" \
    -scheme semi-vpn \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA" \
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

for debug_dylib in \
    "$BUILD_APP/Contents/MacOS/SemiVPN.debug.dylib" \
    "$BUILD_APP/Contents/PlugIns/TunnelProvider.appex/Contents/MacOS/TunnelProvider.debug.dylib"; do
    [[ -f "$debug_dylib" ]] || {
        printf 'Missing debug dylib: %s\n' "$debug_dylib" >&2
        exit 1
    }
    if otool -L "$debug_dylib" | rg -q '/opt/homebrew/opt/openssl@3'; then
        printf 'Debug dylib still links to Homebrew OpenSSL: %s\n' "$debug_dylib" >&2
        exit 1
    fi
done

printf 'Verified: %s and %s signed with team %s\n' "$actual_bundle" "$extension_bundle" "$actual_team"
printf 'Build output: %s\n' "$BUILD_APP"

if [[ "${1:-}" == "--install" ]]; then
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
