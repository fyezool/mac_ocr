# OCR Batch Processor — Native Swift Edition

Native macOS AppKit port of the Flutter OCR Batch Processor. Uses Apple Vision
framework (`RecognizeTextRequest`) for on-device text recognition.

Includes a **CLI benchmarking tool** for automated performance measurement.

## Project Structure

```
ocr-native/
├── OCR-App/                        # macOS GUI application (native Swift)
│   ├── AppDelegate.swift           # Application entry point
│   ├── ViewController.swift        # Main UI (file picker, drag-drop, results)
│   └── OCRService.swift            # Vision OCR logic
│
├── OCR-App.xcodeproj/              # Xcode project
│
├── OCRBenchmark/                   # CLI benchmarking tool (Swift Package)
│   ├── Package.swift
│   └── Sources/
│       ├── OCRBenchmark/main.swift  # CLI entry point
│       └── OCRCore/OCRService.swift # Shared OCR logic
│
└── tools/
    └── batch_benchmark.sh          # Multi-run convenience wrapper
```

## Quick Start — CLI Benchmark

```bash
cd OCRBenchmark

# Run against a folder of images
swift run -c release OCRBenchmark ~/path/to/450-screenshots

# Save JSON results
swift run -c release OCRBenchmark ~/path/to/450-screenshots --json results.json
```

### Benchmark output

```
📁 Scanning "/Users/me/Screenshots" for images… found 450 image(s).
🔍 Running OCR on 450 image(s)…
────────────────────────────────────────────────────────────
0.123s  screenshot_001.png                         1 234
0.098s  screenshot_002.png                           892
…
────────────────────────────────────────────────────────────
📊 Summary:
   Total images:       450
   Successful OCR:     438
   Empty results:       12
   Failed:               0
   Wall-clock time:    45.231s
   Sum of durations:   45.231s
   Average per image:  0.101s
   Throughput:          9.9 images/s
```

### Options

| Option | Description |
|--------|-------------|
| `--json [path]` | Output JSON (optionally save to file) |
| `--help` / `-h` | Show help |

For repeated runs (min/max/avg over multiple trials):

```bash
./tools/batch_benchmark.sh ~/Screenshots
```

## GUI App

Open `OCR-App.xcodeproj` in Xcode (requires macOS 15+ SDK), then Build & Run.

The GUI features:
- **Pick Image(s)** button (native `NSOpenPanel`)
- **Drag & drop** images or folders
- **Run OCR** button with progress indicator
- **Results list** with per-item copy and selectable text
- **Copy All** and **Save as .txt** export

## Requirements

- macOS 15+ (required for `RecognizeTextRequest`)
- Xcode 16+ (for the GUI app)
- Swift 6.0+ (for the CLI benchmark)

## Flutter vs Native Swift

The original Flutter app is at the project root (`../`). The Flutter app now
includes a **built-in benchmark card** that shows wall-clock time, average
per-image latency, and throughput right in the GUI after each OCR run — no
separate build needed.

### Comparison

| Metric | Flutter | Native Swift |
|--------|---------|-------------|
| App bundle size | ~35 MB (includes Dart VM + engine) | ~1 MB |
| Launch time | ~0.5–1s (Dart VM warm-up) | Near-instant |
| OCR latency | MethodChannel serialization overhead | Direct Vision calls |
| Dependencies | Flutter SDK + 3 plugins | Zero (AppKit + Vision) |
| Codebase | ~550 lines (Dart + Swift) | ~400 lines (Swift only) |
| Benchmark | Built-in card in GUI | CLI tool (`--json` output) |

### Running the same benchmark on both

```bash
# Native Swift
cd ocr-native/OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots --json swift.json

# Flutter — open the app, drop the folder, click "Run OCR"
# Benchmark card appears automatically after processing
```

The per-file `duration_seconds` (from `--json` output or the `OCRResult`
model) should be nearly identical on both sides — the same Vision API does the
actual work. The wall-clock time difference shows the Flutter bridge overhead.
