#!/bin/zsh
#
# Opens the main window of a Debug build with sample data, for trying a
# design before a release: real Liquid Glass and animations, but nothing
# connects (the power button simulates it) and nothing is installed. The
# running SemiVPN is not touched; settings go to a scratch folder.
#
# Usage: Scripts/preview-window.sh [--no-build]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_APP="$PROJECT_ROOT/.build/DerivedData/Build/Products/Debug/SemiVPN.app"

if [[ "${1:-}" != "--no-build" ]]; then
    "$SCRIPT_DIR/build-dev.sh" | tail -3
fi

SCRATCH="$(mktemp -d -t semivpn-preview)"
trap 'rm -rf "$SCRATCH"' EXIT
SEMIVPN_CONTAINER="$SCRATCH" "$BUILD_APP/Contents/MacOS/SemiVPN" --preview-window
