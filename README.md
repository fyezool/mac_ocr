# OCR Batch Processor

macOS desktop app for batch OCR using Apple Vision. Built-in HTTP server for
sharing OCR over the local network.

## Features

- **Batch OCR** — Drag-and-drop or pick multiple images, run OCR on all of them
- **Results list** — Per-file text with selectable output, copy individual or all
- **Save to file** — Export all results as a `.txt` file
- **Network Server** — Start a local HTTP server from the app, then upload
  images from any browser on your network

## Quick Start

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then Build & Run.

## Network Server

1. Launch the app
2. Click **Start Server** (bottom of the window)
3. The app shows the server address (e.g. `http://192.168.1.5:8080`)
4. Open that address from any device on your network
5. Upload an image → OCR result appears in the browser

The request log in the app shows recent uploads with timing.

## CLI Benchmark

```bash
cd OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

## Project Structure

```
├── OCR-App/                     # macOS GUI application
│   ├── AppDelegate.swift        # Application entry point
│   ├── ViewController.swift     # Main UI (file picker, drag-drop, results)
│   ├── ServerManager.swift      # Embedded HTTP server (NWListener)
│   ├── ServerViewController.swift # Server UI integration
│   └── OCRService.swift         # Vision OCR logic
├── OCR-App.xcodeproj/           # Xcode project
├── OCRBenchmark/                # CLI benchmark tool
│   ├── Package.swift
│   └── Sources/
└── tools/
    └── batch_benchmark.sh       # Multi-run benchmark wrapper
```

## Requirements

- macOS 15+ (required for `RecognizeTextRequest`)
- Xcode 16+
