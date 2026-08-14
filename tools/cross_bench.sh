#!/usr/bin/env bash
# Cross-OS / cross-chip benchmark corpus runner.
#
# Runs the fixed `corpus/` (images + golden transcripts) through the benchmark
# in each mode on the current machine, and writes one JSON per mode tagged with
# the machine (hostname + model + macOS). Run this on every machine you want to
# compare, then merge the results with:
#
#   python3 tools/cross_compare.py
#
# Config (env overrides):
#   CORPUS_DIR      corpus directory            (default: <repo>/corpus)
#   RESULTS_DIR     where JSON results go       (default: <repo>/corpus/results)
#   BIN             benchmark binary            (default: release build)
#   BENCH_WARMUP    warm-up images per run      (default: 1)
#   BENCH_RUNS      measurement repetitions     (default: 3)
#   CORPUS_CONCURRENCY  fixed across machines   (default: 4)
#   CORPUS_NATIVE   1 = also run the macOS 26 native (documents) engine
#                   alongside the stable legacy baseline
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORPUS="${CORPUS_DIR:-$ROOT/corpus}"
RESULTS="${RESULTS_DIR:-$CORPUS/results}"
BIN="${BIN:-$ROOT/OCRBenchmark/.build/release/OCRBenchmark}"
CONCURRENCY="${CORPUS_CONCURRENCY:-4}"
WARMUP="${BENCH_WARMUP:-1}"
RUNS="${BENCH_RUNS:-3}"

[[ -f "$CORPUS/manifest.json" ]] || { echo "❌ no corpus at $CORPUS — run: swift tools/gen_corpus.swift" >&2; exit 1; }
mkdir -p "$RESULTS"

CORPUS_VERSION="$(python3 -c 'import json;print(json.load(open("'$CORPUS'/manifest.json"))["corpus_version"])')"

host="$(hostname | tr 'A-Z' 'a-z' | tr -c 'a-z0-9' '-')"
model="$(sysctl -n hw.model 2>/dev/null | tr -c 'a-z0-9A-Z' '-' || echo unknown)"
osv="$(sw_vers -productVersion | tr -d '.')"
TAG="${host}_${model}_macos${osv}"

if [[ ! -x "$BIN" ]]; then
  echo "🔨 building release benchmark…"
  (cd "$ROOT/OCRBenchmark" && swift build -c release)
else
  # Incremental rebuild so the binary always matches the current source
  # (a stale release build silently misses new flags/behavior).
  (cd "$ROOT/OCRBenchmark" && swift build -c release)
fi

# Engines: the stable RecognizeTextRequest baseline is available on every macOS
# and is the cross-OS comparison engine. macOS 26+ can additionally run the new
# documents engine as a machine-local signal.
ENGINE_PASSES=(legacy:--legacy-engine)
if [[ "${CORPUS_NATIVE:-0}" == "1" ]]; then
  if [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ]]; then
    ENGINE_PASSES+=(native:)
  else
    echo "⚠️  CORPUS_NATIVE=1 requires macOS 26+; skipping native pass" >&2
  fi
fi

# mode:flag-string:extra-flags — each mode accepts different options
# (sequential rejects --concurrency; adaptive rejects --warmup/--runs).
MODES=(
  "accurate::--concurrency $CONCURRENCY --warmup $WARMUP --runs $RUNS"
  "fast:--fast:--concurrency $CONCURRENCY --warmup $WARMUP --runs $RUNS"
  "sequential:--sequential:--warmup $WARMUP --runs $RUNS"
  "adaptive:--adaptive:--concurrency $CONCURRENCY"
)

for engine in "${ENGINE_PASSES[@]}"; do
  eng_name="${engine%%:*}"; eng_flags="${engine#*:}"
  for mode in "${MODES[@]}"; do
    mode_name="${mode%%:*}"; rest="${mode#*:}"
    mode_flags="${rest%%:*}"; extra="${rest#*:}"
    out="$RESULTS/${eng_name}_${mode_name}_${TAG}.json"
    # shellcheck disable=SC2086
    "$BIN" "$CORPUS/images" \
      $mode_flags $eng_flags $extra \
      --references "$CORPUS/references" \
      --corpus-version "$CORPUS_VERSION" \
      --json "$out" >/dev/null
    echo "✓ $eng_name/$mode_name → $out"
  done
done

echo
echo "📊 machine tag: $TAG  |  corpus_version: $CORPUS_VERSION  |  concurrency: $CONCURRENCY"
echo "   compare machines:  python3 tools/cross_compare.py"
