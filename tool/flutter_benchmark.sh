#!/usr/bin/env bash
set -euo pipefail

# flutter_benchmark.sh — Run the Flutter OCR app in benchmark mode.
#
# Usage:
#   ./tool/flutter_benchmark.sh <folder-path> [--release]
#
# Builds the Flutter app with the benchmark entry point, then launches the
# native binary directly. Progress goes to stderr, JSON results go to stdout.
#
#   ./tool/flutter_benchmark.sh ~/Screenshots > results.json

FOLDER="${1:?Usage: $0 <folder-path> [--debug]}"
BUILD_MODE="${2:-release}"

if [ ! -d "$FOLDER" ]; then
    echo "❌ Error: '$FOLDER' is not a directory." >&2
    exit 1
fi

# Resolve to absolute path
FOLDER="$(cd "$FOLDER" && pwd)"

# Determine build mode and flags
case "$BUILD_MODE" in
    --debug|debug)
        BUILD_FLAG="--debug"
        BUILD_DIR="Debug"
        echo "📱 Flutter OCR Benchmark (debug mode)" >&2
        ;;
    --release|release|*)
        BUILD_FLAG="--release"
        BUILD_DIR="Release"
        echo "📱 Flutter OCR Benchmark (release mode)" >&2
        ;;
esac

echo "   Folder: $FOLDER" >&2
echo "   Building app…" >&2

flutter build macos $BUILD_FLAG --target lib/benchmark_main.dart >&2

# Locate the built binary
APP_DIR="build/macos/Build/Products/$BUILD_DIR"
BINARY="$APP_DIR/ocr_app.app/Contents/MacOS/ocr_app"

if [ ! -x "$BINARY" ]; then
    echo "❌ Error: built binary not found at $BINARY" >&2
    exit 1
fi

echo "   Launching benchmark…" >&2
echo "" >&2

# Launch directly — stdout gets JSON, stderr gets progress
exec "$BINARY" "--benchmark,$FOLDER"
