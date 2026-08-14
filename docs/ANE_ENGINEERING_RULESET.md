# ANE & Vision Engineering Ruleset

> **Purpose:** High-density reference for coding agents working on this app.
> It separates the constraints that apply to our **public Vision/Core ML path**
> from the private `AppleNeuralEngine.framework` rules that are explicitly
> **out of scope** for a shipping App Store app.

---

## 1. Our Execution Path (the only supported one)

- We run OCR through **Vision framework** (`RecognizeTextRequest` on macOS < 26,
  `RecognizeDocumentsRequest` on macOS 26+) — the public, App Store–safe path.
- Vision internally uses **Core ML** to dispatch to the **ANE** (Apple Neural
  Engine). We get its efficiency (~12× vs CPU on M-series) for free.
- **Never** adopt the private `_ANEClient` / `_ANECompiler` route: it is
  undocumented, version-fragile, breaks App Store approval, and requires
  satisfying 20+ fragile constraints (see §4). Treat §4 as knowledge only.

## 2. Constraints That Apply to Our Code (honor these)

| Constraint | Why it matters | Implemented in this app |
|---|---|---|
| **Working-set performance cliff (empirically ~32MB-class)** | Exceeding the practical working set spills to DRAM → measured ~30% throughput drop. Empirically observed for this workload/device; the public Vision API does **not** expose the ANE's internal OCR working-set size, so treat the 32MB figure as a measured heuristic, not a hardware guarantee. | ✅ PDF pages processed **sequentially**; render artifacts freed per page via `autoreleasepool` |
| **Rasterize PDFs at retina ≥2.0 / 150–200 DPI** | 300 DPI on US Letter ≈ 33MB raw → Jetsam risk, no OCR gain | ✅ `renderScale(for:)` targets 200 DPI (≈2.78×, always ≥2.0 for normal pages), caps longest side at 4096px |
| **Amortize the ~2.3ms Core ML dispatch floor** | Every XPC round-trip costs ≥2.3ms | ✅ We send full pages/images per request, never tiny slices |
| **Bound concurrency (2–4 requests, conservative)** | Beyond ~4 concurrent requests we observed throughput/working-set pressure (cliff + Jetsam risk). Not a proven Apple hardware limit — tune empirically per device/workload with the benchmark `--sweep` (benchmark ceiling is 16). | ✅ app `clampedConcurrency(_:)` clamps to [1, 4]; `maxConcurrency` default 4 |
| **Prefer `.accurate` for quality** | `RecognizeTextRequest` accurate path is ANE-backed and near-99% (practitioner evidence) | ✅ default is `.accurate`; `.fast` exists but is user-authorized (explicit opt-in in UI/web/benchmark) |
| **Server ingest limits** | Giant requests OOM the process / trigger Jetsam on high-volume ingestion | ✅ Server `POST /ocr` is capped at 64MB total, 16MB per file, and 16 files; local ingestion remains capped at 250MB |

## 3. macOS 26 Document Intelligence (use when available)

`RecognizeDocumentsRequest` performs **structural layout analysis** natively:

- Returns `DocumentObservation.Container` with:
  - `paragraphs: [Text]` — each `Text.transcript`
  - `tables: [Table]` — `rows: [[Cell]]`, each `Cell.content.text.transcript`
  - `lists: [List]` — `items` with `markerString` + `itemString`
  - `title: Text?`, `text.transcript` (full-page), `barcodes`
- Use it on macOS 26+; fall back to `RecognizeTextRequest` + bounding-box
  paragraph reconstruction on older systems and in `.fast` mode.
- Guard with `@available(macOS 26.0, *)`; the helper types
  (`DocumentObservation`, `RecognizeDocumentsRequest`) require it.

### Coordinate translation (searchable PDF layers)
Vision uses normalized `[0,1]` coords with **top-left origin**; Core Graphics PDFs
use **bottom-left**:

```
X_pdf = X_vision × W_page
Y_pdf = (1 − Y_vision − H_vision) × H_page
```

## 4. Private-API Constraints — Knowledge Only, Never Implement

These apply **only** when writing MIL programs / bypassing Core ML. Do not act
on them for this app; record them so no agent is tempted to "optimize" by going
down this path:

| Category | Constraint | Failure mode |
|---|---|---|
| I/O | IOSurface vars bound **alphabetically** | Silent wrong-data binding |
| I/O | Multi-surface byte sizes must be **uniform** | Error 0x1d |
| I/O | Minimum ~49KB per IOSurface | Evaluation fails |
| Compiler | ~119 compilations per process | Silent failure / crash |
| Compiler | Graph depth > 8–10 attention layers | Error −14, silent fail |
| MIL | `concat` is rejected | Compile failure |
| MIL | `gelu` not valid; use tanh approx | Compile failure |
| MIL | Prefer Conv1x1 over matmul (3×) | Throughput |
| Hardware | >32,000 channels rejected | CPU fallback |
| Math | Clamp activations to ±65,504 (FP16) | NaN cascade |
| Quant | INT4 stable; INT3 incoherent (W4 cliff) | Garbage output |

## 5. Implementation Constants

| Constant | Value | Use |
|---|---|---|
| `ANE_FP16_MAX` | `65504.0` | Clamp bound if ever doing custom numerics |
| `ANE_DISPATCH_MIN_S` | `0.0023` | Amortization floor — batch full pages |
| `ANE_SRAM_BYTES` | `33_554_432` (32MB) | Empirically observed working-set cliff (not a documented hardware limit) |
| `OCR_CONCURRENCY_CEILING` | `4` (app) / `16` (benchmark) | `OCRService.clampedConcurrency` |
| `PDF_RENDER_DPI_TARGET` | `200` | `renderScale(for:)` |
| `PDF_RENDER_MAX_PIXEL_SIDE` | `4096` | `renderScale(for:)` cap |
| `MAX_FILE_SIZE_INGEST` | `262_144_000` (250MB) | `OCRService.maxIngestBytes` — skip/reject oversized files |
