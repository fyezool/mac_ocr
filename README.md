# OCR Batch Processor

macOS desktop app for batch OCR using Apple Vision. Built-in HTTP server for
sharing OCR over the local network.

## Features

- **Batch OCR** — Pick or drag-drop multiple images, run OCR on all of them
- **Live timer** — Shows elapsed time during processing
- **Paragraph reconstruction** — Uses Vision bounding boxes to preserve original layout
- **File dropdown** — Browse per-file results via dropdown on both native and web UI
- **Copy & Save** — Copy individual file text, copy all, save all as `.txt`
- **Clear** — Reset to initial state
- **Network Server** — Start an in-process HTTP server, upload images from any
  browser on your local network, browse results per-file
- **Dark mode** — System-adaptive colors throughout

## Quick Start

Open `OCR-App.xcodeproj` in Xcode (macOS 15+), then Build & Run.

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

### CLI Benchmark

```bash
cd OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots
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
│   └── OCRService.swift         # Vision OCR logic with paragraph reconstruction
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
