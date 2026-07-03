# OCR Batch Processor

A cross-platform desktop OCR application built with **Flutter** and **Apple Vision** framework. Drag-and-drop or pick images to extract text with batch processing support.

---

## Features

- **🖼️ Batch OCR** — Process multiple images in one go
- **📥 Drag & Drop** — Drop images anywhere on the window
- **📂 File Picker** — Multi-select via native file dialog
- **📋 Export** — Copy individual results, copy all, or save as `.txt`
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

> **Note:** Requires macOS 15+ because the app uses the latest `Vision` framework (`RecognizeTextRequest` with async `perform(on:)` API). The framework leverages Apple Silicon's Neural Engine for accelerated text recognition.

## Installation

### Pre-built

Download the latest `.app` bundle from the [Releases](https://github.com/your-org/ocr-app/releases) page.

### From Source

```bash
# Clone the repository
git clone <repo-url>
cd ocr_app

# Get dependencies
flutter pub get

# Run (debug mode)
flutter run -d macos

# Build release
flutter build macos
```

The release build will be at `build/macos/Build/Products/Release/ocr_app.app`.

## Usage

1. **Launch the app** — you'll see an empty state with a **Pick Image(s)** button
2. **Add images** — click the button or **drag & drop** images anywhere on the window (supports PNG, JPG, JPEG, GIF, BMP, TIFF, HEIC, WebP)
3. **Run OCR** — click **Run OCR** to process all selected images
4. **View results** — each image's recognized text appears in a scrollable card list
5. **Export** — click the copy icon on any card, or use the header toolbar to **copy all** or **save as `.txt`**

### Example

```
1. Pick 3 photos of signs/documents
2. Click "Run OCR"
3. Results appear:
   ┌─ sign_01.jpg ───────────────────┐
   │  Welcome to the Grand Hotel     │
   │  Established 1927               │
   └─────────────────────────────────┘
   ┌─ receipt.png ───────────────────┐
   │  Total: $42.50                  │
   │  Thank you for your business    │
   └─────────────────────────────────┘
4. Click 📋 "Copy All" → paste anywhere
```

## Architecture

```
┌─────────────────────────────────────────────┐
│               Flutter (Dart)                 │
│  ┌──────────────┐  ┌──────────────────────┐ │
│  │  ocr_page.dart │  │  ocr_service.dart    │ │
│  │  (UI + state)  │  │  (platform channel)  │ │
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
│   │   └── ocr_page.dart      # Single-page UI
│   └── services/
│       └── ocr_service.dart   # Platform channel wrapper
├── macos/
│   └── Runner/
│       ├── AppDelegate.swift  # OCR plugin + app delegate
│       └── *.entitlements     # Sandbox permissions
├── pubspec.yaml
└── README.md
```

### Adding Features

All UI changes are in `lib/pages/ocr_page.dart` and support hot reload (`r` in terminal).

Native OCR changes go in `macos/Runner/AppDelegate.swift` — these need a full rebuild (`flutter run`).

## License

MIT License — see `LICENSE` for details.

---

*Built with [Flutter](https://flutter.dev) + [Apple Vision](https://developer.apple.com/documentation/vision/)*
