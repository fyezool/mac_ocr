# OCR Batch Processor

macOS desktop app for batch OCR using Apple Vision. Built-in HTTP server for
sharing OCR over the local network.

## Features

- **Batch OCR** — Pick or drag-drop multiple images, run OCR on all of them
- **Parallel processing** — Processes up to 4 images concurrently on the ANE
  (Apple Neural Engine) via `withTaskGroup`, maximizing throughput
- **Live timer** — Shows elapsed time during processing
- **Paragraph reconstruction** — Uses Vision bounding boxes to preserve original
  document layout (paragraph grouping via Y-position thresholds)
- **File dropdown** — Browse per-file results via dropdown on both native and web UI
- **Copy & Save** — Copy individual file text, copy all, save all as `.txt`
- **Clear** — Reset to initial state
- **Network Server** — Start an in-process HTTP server, upload images from any
  browser on your local network, browse results per-file
- **Dark mode** — System-adaptive colors throughout

## Performance

Measured on **Apple M3 Pro** — 467 screenshots (mixed formats):

| Mode | Wall-clock | Throughput | Per-file | Accuracy |
|------|-----------|-----------|----------|----------|
| Accurate, sequential | 159s | 2.9 img/s | 0.34s | ~98% |
| **Accurate, parallel** ⭐ | **56.9s** | **8.2 img/s** | 0.49s | ~98% |
| Fast, parallel | 9.0s | 51.7 img/s | 0.08s | ~58% |

**Accurate + parallel** is the recommended mode — 3× faster than sequential
with no accuracy loss. Parallelism exploits the ANE's ability to handle
multiple Core ML requests concurrently (research-backed: S4 MLX batch scaling,
S1 ANE architecture).

Fast mode is useful for pre-screening but misses ~40% of text on screenshots.

## Quick Start

### Build & Run (development)

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then **Cmd+R** or Product → Run.

### Build for production

```bash
xcodebuild -project OCR-App.xcodeproj -scheme "OCR App" build -configuration Release -derivedDataPath /tmp/OCR-App-Build
```

The built app is at:
```
/tmp/OCR-App-Build/Build/Products/Release/OCR App.app
```

Copy to Applications:
```bash
cp -R "/tmp/OCR-App-Build/Build/Products/Release/OCR App.app" /Applications/
```

> **Note:** The app is ad-hoc signed. On other Macs, right-click → Open to bypass
> Gatekeeper. For proper distribution without warnings, sign with an Apple
> Developer ID certificate and notarize.

## Usage

### GUI App
1. **Pick Image(s)** button or **drag & drop** files onto the window
2. Click **Run OCR** — live timer shows progress
3. Browse results via **file dropdown** — select a file to view its text
4. **Copy** individual text, **Copy All**, or **Save as .txt**
5. **Clear All** to reset

### Network Server
1. Launch the app and click **Start Server** (bottom of the window)
2. The app shows the server address (e.g. `http://192.168.2.6:8080`)
3. Open that address from any device on your network
4. Select files → tap **Run OCR** — results page shows dropdown + per-file output
5. **💾 Save All** downloads all results
6. **📋 Copy** copies the currently selected file's text
7. **✕ Clear** to go back

For JSON or plain-text output, append `?format=json` or `?format=txt` to the
OCR endpoint. For fast mode (pre-screening), use `?fast=1`.

### CLI Benchmark

```bash
cd OCRBenchmark
swift package clean 2>&1

# Accurate + parallel (default, recommended — 3× faster than sequential)
swift run -c release OCRBenchmark ~/Screenshots

# Fast + parallel (pre-screening, ~6× faster, may miss text)
swift run -c release OCRBenchmark ~/Screenshots --fast

# Accurate + sequential (baseline for comparison)
swift run -c release OCRBenchmark ~/Screenshots --sequential

# JSON output
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

For repeated runs with stats:
```bash
./tools/batch_benchmark.sh ~/Screenshots
```

## Project Structure

```
├── OCR-App/                     # macOS GUI application
│   ├── AppDelegate.swift        # Application entry point
│   ├── ViewController.swift     # Main UI (file picker, drag-drop, results)
│   ├── ServerManager.swift      # Embedded HTTP server (BSD sockets + GCD)
│   └── OCRService.swift         # Vision OCR logic with parallel processing
├── OCR-App.xcodeproj/           # Xcode project
├── OCRBenchmark/                # CLI benchmark tool (Swift Package)
│   ├── Package.swift
│   └── Sources/
└── tools/
    └── batch_benchmark.sh       # Multi-run benchmark wrapper
```

## Requirements

- macOS 15+ (required for `RecognizeTextRequest`)
- Xcode 16+
- Swift 6.0+ (for CLI tools)

## Supported Formats

PNG, JPG, JPEG, GIF, BMP, TIFF, TIF, HEIC, WebP

## Research Basis

Speed optimizations are informed by recent research into the Apple Neural
Engine and on-device OCR performance:

- **S1** (ANE architecture, arXiv 2606.22283): Confirms Vision API routes
  through Core ML → ANE. Documents ANE throughput/energy roofline on M-series
  chips including M3 Pro.
- **S2** (OCR→Core ML case study, Hugging Face 2025): Reports ANE is ~12×
  more power-efficient than CPU and ~4× more efficient than GPU for OCR.
- **S3** (practitioner report): Vision framework OCR achieves ~99% perceived
  accuracy, significantly outperforming VLM-based pipelines.
- **S4** (MLX batch scaling, arXiv 2510.18921): Apple Silicon shows sub-linear
  latency scaling with batch size, motivating parallel processing.
