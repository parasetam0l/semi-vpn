#!/bin/zsh
#
# Renders SemiVPN's screens with sample data into PNG files, in light and
# dark mode, for reviewing the design. Builds the Debug app first (with
# build-dev.sh, which does not install it) unless --no-build is given. The
# running SemiVPN is not touched, and no window appears.
#
# Usage: Scripts/ui-snapshots.sh [--no-build] [output folder]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/SemiVPN.app"

build=1
if [[ "${1:-}" == "--no-build" ]]; then
    build=0
    shift
fi
OUTPUT="${1:-$PROJECT_ROOT/.build/ui-snapshots}"

if (( build )); then
    "$SCRIPT_DIR/build-dev.sh" | tail -3
fi

rm -rf "$OUTPUT"
"$BUILD_APP/Contents/MacOS/SemiVPN" --render-ui "$OUTPUT"
