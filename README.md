# OCR Batch Processor

macOS app for batch OCR using Apple Vision, accelerated by the Apple Neural
Engine (ANE). Built-in LAN HTTP server for OCR automation on the local network.

## Features

- **Batch OCR** — Drag & drop images or folders (PNG, JPG, GIF, BMP, TIFF, HEIC,
  WebP, **PDF**) and run OCR on all of them
- **PDF support** — Each PDF page rendered at 200 DPI and OCR'd as its own result
  entry (`file.pdf (page N)`)
- **macOS 26 Document Intelligence** — Uses `RecognizeDocumentsRequest` where
  available for native paragraph / table / list structure; falls back to
  bounding-box reconstruction on older systems
- **Parallel processing** — Up to 4 concurrent Vision requests on the ANE
  (`clampedConcurrency` keeps the working set under the 32MB SRAM budget)
- **Live timer** — Elapsed time shown during processing
- **File dropdown** — Browse per-file results via dropdown on native and web UI
- **Copy & Save** — Copy individual file text, copy all, save all as `.txt`
- **Clear** — Reset to initial state
- **Network Server** — In-process LAN HTTP server for local OCR automation
- **Agent API** — `POST /ocr` with an `options` JSON field returns structured
  blocks + confidence and supports `fast`/`accurate`/`adaptive` modes, language
  selection, custom vocabulary, a retry confidence threshold, and region-aware
  small-text upscaling (`enhance_small_text`)
- **Web camera capture** — Take a photo in the web UI (requires HTTPS via your
  reverse proxy) and OCR it with the same pipeline
- **History tab** — Records past OCR runs
- **Dark mode** — System-adaptive colors throughout

## Performance

Measured on **Apple M3 Pro** — 467 screenshots (mixed formats):

| Mode | Wall-clock | Throughput | Per-file | Accuracy |
|------|-----------|-----------|----------|----------|
| Accurate, sequential | 159s | 2.9 img/s | 0.34s | ~98% |
| **Accurate, parallel** ⭐ | **56.9s** | **8.2 img/s** | 0.49s | ~98% |
| Fast, parallel | 9.0s | 51.7 img/s | 0.08s | ~58% |

**Accurate + parallel** is the recommended mode — 3× faster than sequential
with no accuracy loss. Fast mode is useful for pre-screening but misses ~40%
of text on screenshots. See `docs/ANE_ENGINEERING_RULESET.md` for the ANE
constraints behind these settings.

## Quick Start

### Build with the script (no Xcode UI needed)

```bash
./build.sh                 # release → ./dist/OCR App.app
./build.sh --debug         # debug build
./build.sh --dmg           # also package ./dist/OCR App.dmg
./build.sh --open          # build then launch
./build.sh --output ~/Desktop   # custom output dir
```

### Build in Xcode (development)

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then **Cmd+R**.

> **Note:** The app is ad-hoc signed. On other Macs, right-click → Open to
> bypass Gatekeeper the first time.

### Distribute a .dmg (no Apple Developer Program fee)

```bash
./build.sh --dmg
```

Creates `dist/OCR App.dmg`. Host it anywhere — your own server, a shared drive,
or GitHub Releases. Users mount the DMG and drag the app to **/Applications**.

Because the app isn't signed with an Apple Developer ID or notarized, Gatekeeper
shows a warning on first launch. Users bypass it once via **right-click → Open**,
or **System Settings → Privacy & Security → Open Anyway**. This is fine for
trusted users on your own network. Only distribution to unknown/public users
needs the paid **$99/year Apple Developer Program** for Developer ID signing +
notarization.

## Usage

### GUI App

1. **Drag & drop** files or folders onto the window
2. Click **Run OCR** in the "ready" card (or press ⏎) — live timer shows progress
3. Browse results via **file dropdown** — select a file to view its text
4. **Copy** individual text, **Copy All**, or **Save .txt**
5. **✕ Clear All** to reset
6. Use the **Fast mode** checkbox for quick pre-screening (~6× faster, may miss text)

### Network Server

1. Go to the **Server** tab and click **Start Server**
2. The app shows the LAN address (e.g. `http://192.168.2.6:8080`)
3. Open it from any device on your network
4. Select files or take a photo → tap **Run OCR** — results page shows dropdown + per-file output
5. **💾 Save All** / **📋 Copy** / **✕ Clear**

> **⚠️ Security:** the LAN server has **no authentication**. Anyone who can
> reach the listening interface can submit files for OCR. Use it only on
> networks you trust, and expose it externally only through your own reverse
> proxy (e.g. OPNsense) with access control.

API details in [`API.md`](API.md). Notable options:
- `?format=json` or `?format=txt` — output format
- `?fast=1` — fast recognition mode
- Uploads over **64MB**, individual files over **16MB**, or batches over 16 files are rejected (HTTP 413)

### CLI Benchmark

```bash
cd OCRBenchmark
swift package clean 2>&1   # once, after moving directories

# Accurate + parallel (default, recommended)
swift run -c release OCRBenchmark ~/Screenshots

# Fast + parallel (pre-screening)
swift run -c release OCRBenchmark ~/Screenshots --fast

# Accurate + sequential (baseline)
swift run -c release OCRBenchmark ~/Screenshots --sequential

# Set concurrency explicitly (max 16)
swift run -c release OCRBenchmark ~/Screenshots --concurrency 6

# Sweep concurrency 1,2,3,4,5,6,8 → find the real optimum
swift run -c release OCRBenchmark ~/Screenshots --sweep --json sweep.json

# Resolution sweep 512…4096 (+native) vs CER/WER/latency/throughput
swift run -c release OCRBenchmark ~/Screenshots --resize-sweep --references ~/gt --json resize.json

# Adaptive cascade: fast probe → retry accurate on low-confidence items,
# benchmarked against always-accurate (throughput, p95, CER/WER)
swift run -c release OCRBenchmark ~/Screenshots --adaptive --json adaptive.json

# Sweep the adaptive threshold (0.50–0.95) to find the accuracy/latency frontier
swift run -c release OCRBenchmark ~/Screenshots --adaptive-sweep --references ~/gt --json adapt_sweep.json

# Languages / engine pinning / downscaling
swift run -c release OCRBenchmark ~/Screenshots --lang ms-MY,en-US --json results.json
swift run -c release OCRBenchmark ~/Screenshots --legacy-engine --json results.json
swift run -c release OCRBenchmark ~/Screenshots --resize-to 1024 --json results.json

# Accuracy: CER/WER/exact-match against <basename>.txt ground truth
swift run -c release OCRBenchmark ~/Screenshots --references ~/gt --json results.json

# JSON output (also records OS, SoC, RAM, Vision revision, p50/p95/p99)
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

Benchmark JSON now records the environment (OS, device model, SoC, RAM), the OCR
configuration (recognition level, languages, concurrency with requested vs
effective values and safety ceiling, Vision revision, engine pinning), per-file
latency percentiles (p50/p95/p99), and — with `--references` — both **macro**
and **micro** (corpus-level) CER/WER plus exact match. `--sweep`,
`--resize-sweep`, and `--adaptive-sweep` expose concurrency, input resolution,
and the adaptive retry threshold as measured dimensions instead of assuming the
hard-coded defaults are optimal. `--legacy-engine` forces the
`RecognizeTextRequest` path even on macOS 26 so engine-dependent comparisons
stay apples-to-apples.

Repeated runs with stats:
```bash
./tools/batch_benchmark.sh ~/Screenshots
```

## Project Structure

```
├── build.sh                     # Build .app from the terminal
├── OCR-App/                     # macOS GUI application (SwiftUI)
│   ├── OCR_App.swift            # App entry point
│   ├── ContentView.swift        # Tab container (OCR / Server / History)
│   ├── OCRTabView.swift         # OCR tab UI (drop, run, results)
│   ├── OCRViewModel.swift       # OCR state + actions
│   ├── ServerTabView.swift      # Server tab UI
│   ├── ServerViewModel.swift    # Server state
│   ├── HistoryTabView.swift     # History tab
│   ├── ServerManager.swift      # Embedded HTTP server (BSD sockets + GCD)
│   └── OCRService.swift         # Vision OCR + PDF rendering + ANE tuning
├── OCR-App.xcodeproj/           # Xcode project
├── OCRBenchmark/                # CLI benchmark tool (Swift Package)
├── docs/
│   └── ANE_ENGINEERING_RULESET.md  # ANE/Vision constraints for agents
├── API.md                       # HTTP API documentation
└── tools/
    └── batch_benchmark.sh       # Multi-run benchmark wrapper
```

## Requirements

- macOS 15+ (macOS 26 recommended for Document Intelligence)
- Xcode 16+
- Swift 6.0+ (for CLI tools)

## Supported Formats

PNG, JPG, JPEG, GIF, BMP, TIFF, TIF, HEIC, WebP, PDF

## Research Basis

Speed optimizations are informed by research into the Apple Neural Engine and
on-device OCR:

- **S1** (ANE architecture, arXiv 2606.22283): Vision routes through Core ML →
  ANE; documents ANE roofline on M-series including M3 Pro.
- **S2** (OCR→Core ML case study, Hugging Face 2025): ANE is ~12× more
  power-efficient than CPU and ~4× more efficient than GPU for OCR.
- **S3** (practitioner report): Vision OCR achieves ~99% perceived accuracy.
- **S4** (MLX batch scaling, arXiv 2510.18921): Apple Silicon shows sub-linear
  latency scaling with batch size, motivating parallel processing.
- **ANE ruleset**: 32MB SRAM working-set budget, 2–4 concurrency band,
  200 DPI PDF rendering, 250MB ingest limit — implemented and documented in
  `docs/ANE_ENGINEERING_RULESET.md`.
