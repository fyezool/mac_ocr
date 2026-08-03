#!/bin/bash
# Build OCR App into a .app bundle without opening Xcode.
#
# Usage:
#   ./build.sh                 # release build, copies to ./dist/OCR App.app
#   ./build.sh --debug         # debug build
#   ./build.sh --output PATH   # custom output directory
#   ./build.sh --open          # build then launch the app
#
# Requires: Xcode command line tools (xcodebuild)

set -euo pipefail

CONFIG="Release"
OUTPUT_DIR="$(pwd)/dist"
OPEN_AFTER="no"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) CONFIG="Debug"; shift ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --open) OPEN_AFTER="yes"; shift ;;
        --help|-h)
            grep '^#' "$0" | sed 's/^# //'; exit 0 ;;
        *) echo "Unknown option: $1 (see ./build.sh --help)"; exit 1 ;;
    esac
done

PROJECT="OCR-App.xcodeproj"
SCHEME="OCR App"
DERIVED="/tmp/OCR-App-Build"

echo "▸ Building '$SCHEME' ($CONFIG)..."
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIG" \
    -derivedDataPath "$DERIVED" \
    build \
    -quiet

APP_SRC="$DERIVED/Build/Products/$CONFIG/OCR App.app"
if [[ ! -d "$APP_SRC" ]]; then
    echo "❌ Build product not found at $APP_SRC" >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
APP_DST="$OUTPUT_DIR/OCR App.app"
rm -rf "$APP_DST"
cp -R "$APP_SRC" "$APP_DST"

echo "✅ App bundle: $APP_DST"
echo "   $(du -sh "$APP_DST" | cut -f1)"

if [[ "$OPEN_AFTER" == "yes" ]]; then
    echo "▸ Launching…"
    open "$APP_DST"
fi
