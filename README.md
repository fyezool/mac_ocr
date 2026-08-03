# OCR Batch Processor

macOS app for batch OCR using Apple Vision, accelerated by the Apple Neural
Engine (ANE). Built-in HTTP server for sharing OCR over the local network.

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
- **Network Server** — In-process HTTP server; upload from any browser on your
  local network, browse per-file results
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
./build.sh --open          # build then launch
./build.sh --output ~/Desktop   # custom output dir
```

### Build in Xcode (development)

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then **Cmd+R**.

> **Note:** The app is ad-hoc signed. On other Macs, right-click → Open to
> bypass Gatekeeper. For proper distribution, sign with an Apple Developer ID
> certificate and notarize.

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
2. The app shows the address (e.g. `http://192.168.2.6:8080`)
3. Open it from any device on your network
4. Select files → tap **Run OCR** — results page shows dropdown + per-file output
5. **💾 Save All** / **📋 Copy** / **✕ Clear**

API details in [`API.md`](API.md). Notable options:
- `?format=json` or `?format=txt` — output format
- `?fast=1` — fast recognition mode
- Uploads over **250MB** are rejected (HTTP 413)

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

# JSON output
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

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
