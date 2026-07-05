# OCR Batch Processor

A macOS desktop OCR application built with **Flutter** and **Apple Vision**
framework. Drag-and-drop or pick images to extract text with batch processing
support and **built-in benchmark timing**.

---

## Features

- **🖼️ Batch OCR** — Process multiple images in one go
- **📥 Drag & Drop** — Drop images or folders anywhere on the window
- **📂 File Picker** — Multi-select via native file dialog
- **📋 Export** — Copy individual results, copy all, or save as `.txt`
- **⏱ Built-in Benchmark** — Live elapsed timer while processing, then a summary card with wall-clock time, per-image average, and throughput (images/s)
- **⚡ Fast** — Uses Apple's Neural Engine for on-device text recognition
- **🔒 Private** — All processing stays on your machine; no data sent to any server

## Requirements

### Hardware

| Component | Minimum | Recommended |
|---|---|---|
| **CPU** | Apple Silicon (M1+) or Intel | Apple Silicon (M1+) |
| **RAM** | 8 GB | 16 GB+ |
| **Neural Engine** | Any Apple Silicon | M1 or later |
| **Storage** | 200 MB free | 500 MB free |

### Software

| Requirement | Version |
|---|---|
| **macOS** | 15.0 (Sequoia) or later |
| **Xcode** | 16+ (for development) |
| **Flutter** | 3.35+ (for development) |

> **Note:** Requires macOS 15+ because the app uses the latest `Vision` framework
> (`RecognizeTextRequest` with async `perform(on:)` API). The framework leverages
> Apple Silicon's Neural Engine for accelerated text recognition.

## Installation

### From Source

```bash
# Clone the repository
git clone <repo-url>
cd ocr_app

# Get dependencies
flutter pub get

# Run (debug mode — supports hot reload)
flutter run -d macos

# Build release binary
flutter build macos --release
```

The release build will be at `build/macos/Build/Products/Release/ocr_app.app`.

## Usage

1. **Launch the app** — you'll see an empty state with a **Pick Image(s)** button
2. **Add images** — click the button or **drag & drop** images/folders anywhere on the window (supports PNG, JPG, JPEG, GIF, BMP, TIFF, HEIC, WebP)
3. **Run OCR** — click **Run OCR** to process all selected images
4. **Live timer** — while processing, you'll see elapsed time update in real-time
5. **Benchmark card** — after processing completes, a blue summary card shows:
   - Wall-clock time, average per image, throughput (images/s)
   - Successful / empty / failed counts
6. **View results** — each image's recognized text appears in a scrollable card list
7. **Export** — click the copy icon on any card, or use the header toolbar to **copy all** or **save as `.txt`**

### Example

```
1. Drop 450 screenshots into the window
2. Click "Run OCR"
3. Watch elapsed time tick up:  ⏱ 12.3s elapsed  •  450 images
4. Benchmark card appears:
   ┌──────────────────────────────────┐
   │ ⚡ Benchmark                      │
   │ Wall-clock time      45.231s     │
   │ Average per image    0.101s      │
   │ Throughput           9.9 img/s   │
   │ Successful           438         │
   │ Empty                12          │
   └──────────────────────────────────┘
5. Results list below — copy or save
```

## Architecture

```
┌─────────────────────────────────────────────┐
│               Flutter (Dart)                 │
│  ┌──────────────┐  ┌──────────────────────┐ │
│  │  ocr_page.dart │  │  ocr_service.dart    │ │
│  │  (UI + state + │  │  (platform channel)  │ │
│  │   benchmark)   │  │                      │ │
│  └──────┬───────┘  └──────────┬───────────┘ │
│         │                     │              │
└─────────┼─────────────────────┼──────────────┘
          │                     │  MethodChannel
          │                     │  "com.ocr.app/ocr"
          ▼                     ▼
┌─────────────────────────────────────────────┐
│           Native (Swift / macOS)             │
│  ┌─────────────────────────────────────────┐ │
│  │         AppDelegate.swift                │ │
│  │  └─ OCRPlugin (FlutterPlugin)            │ │
│  │     └─ processImages()                   │ │
│  │        └─ RecognizeTextRequest            │ │
│  │           └─ Vision.perform(on:)          │ │
│  └─────────────────────────────────────────┘ │
└─────────────────────────────────────────────┘
```

## Benchmark Results

After processing completes, the app shows:

| Metric | What it measures |
|--------|-----------------|
| **Wall-clock time** | Total real time from Dart side (includes MethodChannel round-trip) |
| **Sum of durations** | Sum of per-file timestamps from the Swift/Vision side |
| **Average per image** | `Sum of durations ÷ image count` |
| **Throughput** | `Image count ÷ wall-clock time` |

The gap between wall-clock time and sum of durations is the **Flutter bridge
overhead** (MethodChannel serialization + event loop).

### Native Swift Comparison

For a direct comparison, there's a native Swift (AppKit) port in the
[`ocr-native/`](ocr-native/) directory with its own benchmark CLI:

```bash
cd ocr-native/OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots
```

See [`ocr-native/README.md`](ocr-native/README.md) for details.

## Supported Image Formats

| Format | Extension |
|---|---|
| PNG | `.png` |
| JPEG | `.jpg`, `.jpeg` |
| GIF | `.gif` |
| BMP | `.bmp` |
| TIFF | `.tiff`, `.tif` |
| HEIC | `.heic` |
| WebP | `.webp` |

## OCR Capabilities

- **Recognition Level:** Accurate (uses full neural network, not fast path)
- **Language Correction:** Enabled (automatic spelling correction)
- **Language Detection:** Automatic (supports multiple languages)
- **Text Types:** Printed text, handwritten text (limited), documents, signs, screenshots

## Development

### Project Structure

```
ocr_app/
├── lib/
│   ├── main.dart              # App entry point
│   ├── pages/
│   │   └── ocr_page.dart      # Single-page UI + benchmark tracking
│   └── services/
│       └── ocr_service.dart   # Platform channel wrapper + OCRResult model
├── macos/
│   └── Runner/
│       ├── AppDelegate.swift  # OCR plugin (with per-file timing)
│       ├── MainFlutterWindow.swift
│       └── *.entitlements     # Sandbox permissions
├── ocr-native/                # Native Swift port + benchmark CLI
│   ├── OCR-App/               # AppKit GUI app
│   ├── OCRBenchmark/          # CLI benchmark tool
│   └── README.md
├── pubspec.yaml
└── README.md
```

### Adding Features

All UI changes are in `lib/pages/ocr_page.dart` and support hot reload
(`r` in terminal). Native OCR changes go in `macos/Runner/AppDelegate.swift`
— these need a full rebuild (`flutter run`).

## License

MIT License — see `LICENSE` for details.

---

*Built with [Flutter](https://flutter.dev) + [Apple Vision](https://developer.apple.com/documentation/vision/)*
