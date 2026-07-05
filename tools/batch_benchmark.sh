#!/usr/bin/env bash
set -euo pipefail

# batch_benchmark.sh — Run OCR Benchmark multiple times and report stats.
#
# Usage:
#   ./batch_benchmark.sh <folder-path> [runs=3] [--json]
#
# Example:
#   ./batch_benchmark.sh ~/Screenshots
#   ./batch_benchmark.sh ~/Screenshots 5 --json

BENCHMARK_DIR="$(cd "$(dirname "$0")/../OCRBenchmark" && pwd)"
FOLDER="${1:?Usage: $0 <folder-path> [runs=3]}"
RUNS="${2:-3}"
JSON_FLAG="${3:-}"

if [ ! -d "$FOLDER" ]; then
    echo "❌ Error: '$FOLDER' is not a directory."
    exit 1
fi

echo "=============================================="
echo " OCR Benchmark — Batch Runner"
echo " Folder:  $FOLDER"
echo " Runs:    $RUNS"
echo "=============================================="
echo

# Build release once
echo "🔧 Building release binary…"
cd "$BENCHMARK_DIR"
swift build -c release --disable-sandbox > /dev/null 2>&1
BINARY="$(swift build -c release --show-bin-path --disable-sandbox)/OCRBenchmark"
echo "✅ Built: $BINARY"
echo

TIMES=()
RUN=1

while [ $RUN -le "$RUNS" ]; do
    echo "─── Run $RUN/$RUNS ───"
    # Capture the "Wall-clock time" line
    OUTPUT=$("$BINARY" "$FOLDER" $JSON_FLAG 2>&1)
    WALL=$(echo "$OUTPUT" | grep "Wall-clock time" | awk '{print $4}' | sed 's/s//')
    IMG_S=$(echo "$OUTPUT" | grep "Throughput" | awk '{print $3}')

    if [ -n "$WALL" ]; then
        TIMES+=("$WALL")
        echo "   Time: ${WALL}s    Throughput: ${IMG_S} img/s"
    else
        echo "   ⚠️  Could not parse timing"
        echo "$OUTPUT"
    fi
    echo
    RUN=$((RUN + 1))
done

# Stats
if [ ${#TIMES[@]} -gt 0 ]; then
    # Sort numerically
    IFS=$'\n' SORTED=($(sort -n <<< "${TIMES[*]}")); unset IFS

    SUM=0
    for t in "${SORTED[@]}"; do
        SUM=$(echo "$SUM + $t" | bc -l)
    done
    AVG=$(echo "$SUM / ${#SORTED[@]}" | bc -l)
    MIN="${SORTED[0]}"
    MAX="${SORTED[${#SORTED[@]}-1]}"

    echo "=============================================="
    echo "📊 Summary over ${#SORTED[@]} run(s):"
    printf "   Min:     %.3fs\n" "$MIN"
    printf "   Max:     %.3fs\n" "$MAX"
    printf "   Average: %.3fs\n" "$AVG"
    echo "=============================================="
fi
