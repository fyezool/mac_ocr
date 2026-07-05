# OCR Batch Processor — Native Swift

macOS desktop app for batch OCR using Apple Vision.

- **OCR-App** — AppKit GUI (drag-drop, file picker, results list, copy/save)
- **OCRBenchmark** — CLI benchmark tool (per-file timing, JSON output)
- **OCRServer** — Vapor HTTP server (upload via browser from any device)

## Quick Start

### GUI App

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then Build & Run.

### CLI Benchmark

```bash
cd OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

For repeated runs:
```bash
./tools/batch_benchmark.sh ~/Screenshots
```

### HTTP Server

```bash
cd OCRServer
swift build -c release
swift run -c release OCRServer
```

Then open `http://<your-ip>:8080` from any device on your network.

To run with the Flutter app's server manager, launch the GUI app and tap **Start Server**.

## Project Structure

```
├── OCR-App/                        # macOS GUI application
│   ├── AppDelegate.swift           # Application entry point
│   ├── ViewController.swift        # Main UI (file picker, drag-drop, results)
│   └── OCRService.swift            # Vision OCR logic
├── OCR-App.xcodeproj/              # Xcode project
├── OCRBenchmark/                   # CLI benchmarking tool (Swift Package)
│   ├── Package.swift
│   └── Sources/
│       ├── OCRBenchmark/main.swift
│       └── OCRCore/OCRService.swift
├── OCRServer/                      # HTTP server (Swift Package + Vapor)
│   ├── Package.swift
│   └── Sources/OCRServer/
│       ├── main.swift              # Vapor routes + web UI
│       └── OCRService.swift
└── tools/
    └── batch_benchmark.sh          # Multi-run benchmark wrapper
```

## Requirements

- macOS 15+ (required for `RecognizeTextRequest`)
- Xcode 16+ (for the GUI app)
- Swift 6.0+ (for CLI tools)
