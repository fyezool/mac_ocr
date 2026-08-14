# OCR Server API

The OCR App includes an in-process HTTP server that exposes OCR functionality
on the detected private LAN address at `http://<server-ip>:8080`. It is intended
for local-network use only.

---

## `GET /health`

Check if the server is running.

### Response

```
Status: 200 OK
Content-Type: application/json
```

```json
{
  "status": "ok",
  "address": "192.168.2.6:8080"
}
```

---

## `GET /`

Returns the upload page (HTML form).

### Response

```
Status: 200 OK
Content-Type: text/html; charset=utf-8
```

Returns a full HTML page with:
- File drop zone (tap to select, drag & drop)
- Supported formats: PNG, JPG, GIF, BMP, TIFF, HEIC, WebP
- Camera capture (shown only over HTTPS — e.g. via the reverse proxy)
- Run OCR button
- Live elapsed timer during processing
- Selected file count with unsupported format warning

---

## `POST /ocr`

Upload one or more images for OCR processing.

### Request

```
POST /ocr[?format=txt|json] HTTP/1.1
Host: <server-ip>:8080
Content-Type: multipart/form-data; boundary=<boundary>
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `image` | File | Yes | Image file. Repeat for multiple files. |

**Supported formats:** `png`, `jpg`, `jpeg`, `gif`, `bmp`, `tiff`, `tif`, `heic`, `webp`

### Query Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `format` | `html` (default), `txt`, `json` | Response format |
| `fast` | `1` | Use `.fast` recognition level (2-3x faster, may miss small/dense text). Omit or set to `0` for `.accurate` (default). |

### Response by Format

**`format=html`** (default)
```
Status: 200 OK
Content-Type: text/html; charset=utf-8
```
Full HTML results page with dropdown, copy, save, clear.

**`format=txt`**
```
Status: 200 OK
Content-Type: text/plain; charset=utf-8
```
Plain text with `--- filename ---` separators:
```
--- photo1.png ---
recognized text line 1
recognized text line 2

--- photo2.jpg ---
recognized text line 1

```

**`format=json`**
```
Status: 200 OK
Content-Type: application/json
```
```json
{
  "results": [
    {"filename": "photo1.png", "text": "recognized text", "error": null, "duration": 0.123},
    {"filename": "photo2.jpg", "text": "more text", "error": null, "duration": 0.098}
  ],
  "server_duration_seconds": 0.345
}
```

### Examples

```bash
# HTML results page (default)
  curl -X POST -F "image=@shot.png" http://<server-ip>:8080/ocr

# Plain text output
  curl -X POST -F "image=@shot.png" http://<server-ip>:8080/ocr?format=txt

# JSON output (great for scripting)
  curl -X POST -F "image=@shot.png" http://<server-ip>:8080/ocr?format=json

# Multiple files as JSON
curl -X POST \
  -F "image=@photo1.png" \
  -F "image=@photo2.jpg" \
  "http://<server-ip>:8080/ocr?format=json"

# Fast mode (~2-3x faster, good for bulk processing)
curl -X POST -F "image=@shot.png" "http://<server-ip>:8080/ocr?fast=1"

# Fast mode + JSON output (for scripting)
curl -X POST -F "image=@shot.png" "http://<server-ip>:8080/ocr?fast=1&format=json"
```

### Example (Python)

```python
import requests

url = "http://<server-ip>:8080/ocr"
files = [
    ("image", ("shot1.png", open("shot1.png", "rb"), "image/png")),
    ("image", ("shot2.jpg", open("shot2.jpg", "rb"), "image/jpeg")),
]

# HTML results page (default)
r = requests.post(url, files=files)
print(r.text)

# JSON output
r = requests.post(url + "?format=json", files=files)
data = r.json()
for result in data["results"]:
    print(result["filename"], "-", len(result["text"]), "chars")
```

### Example (Swift)

```swift
import Foundation

let url = URL(string: "http://<server-ip>:8080/ocr")!
var req = URLRequest(url: url)
req.httpMethod = "POST"

let boundary = UUID().uuidString
req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

var body = Data()
let imageData = try Data(contentsOf: URL(fileURLWithPath: "photo.png"))

body.append("--\(boundary)\r\n".data(using: .utf8)!)
body.append("Content-Disposition: form-data; name=\"image\"; filename=\"photo.png\"\r\n".data(using: .utf8)!)
body.append("Content-Type: image/png\r\n\r\n".data(using: .utf8)!)
body.append(imageData)
body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

req.httpBody = body

let task = URLSession.shared.dataTask(with: req) { data, _, _ in
    if let data = data, let html = String(data: data, encoding: .utf8) {
        print(html)  // HTML results page
    }
}
task.resume()
```

---

## Agent API (structured output)

Add an `options` multipart field (JSON) to `POST /ocr` to get structured results
(per-line blocks with confidence + normalized bounding boxes) and control the
recognition pipeline.

### Request

```
POST /ocr HTTP/1.1
Content-Type: multipart/form-data; boundary=<boundary>
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `image` | File | Yes | Image file. Repeat for multiple files. |
| `options` | Text | No | JSON with the fields below. |

`options` JSON (snake_case accepted):

| Field | Default | Description |
|-------|---------|-------------|
| `mode` | `"accurate"` | `"accurate"`, `"fast"`, or `"adaptive"` (fast probe → retry accurate below the threshold) |
| `languages` | `["en-US"]` | Priority-ordered recognition languages, e.g. `["ms-MY","en-US"]` |
| `custom_words` | `[]` | Domain vocabulary to bias recognition |
| `confidence_threshold` | `0.75` | Items below this mean confidence are retried in `adaptive` mode |
| `structured` | `true` | `true` → blocks/confidence response; `false` → plain text |
| `enhance_small_text` | `false` | Crop small-text blocks and re-OCR them; also recovers uncovered text-like regions from the image |

### Example

```bash
curl -X POST \
  -F 'options={"mode":"adaptive","languages":["ms-MY","en-US"],"confidence_threshold":0.8,"custom_words":["Sdn Bhd","SST"]}' \
  -F "image=@receipt.png" \
  http://<server-ip>:8080/ocr
```

### Response (structured)

```json
{
  "results": [
    {
      "filename": "receipt.png",
      "text": "…layout-preserving transcript…",
      "error": null,
      "duration": 0.41,
      "confidence": 0.94,
      "blocks": [
        {
          "text": "Sdn Bhd",
          "confidence": 0.99,
          "rect": [0.129, 0.972, 0.22, 0.014]
        }
      ]
    }
  ],
  "server_duration_seconds": 0.42,
  "processing_ms": 420,
  "strategy": "adaptive",
  "engine": "vision",
  "engine_revision": "revision3",
  "language": "ms-MY"
}
```

`strategy` reports the mode used. `engine_revision` records the Vision
text-recognition request revision so results can be correlated with the
underlying engine version. Without an `options` field, `POST /ocr`
behaves exactly as documented above.

---

## `GET /` (after POST)

After submitting to `/ocr`, the results page includes:

### Save All

The **💾 Save All** button triggers a download of all OCR results as a `.txt`
file with the format:

```
--- filename1.png ---
recognized text line 1
recognized text line 2

--- filename2.jpg ---
recognized text line 1

```

### Copy

The **📋 Copy** button copies the currently selected file's text to the
clipboard.

---

## Error Responses

| Status | Body | Meaning |
|--------|------|---------|
| `400` | Bad Request | Missing or invalid multipart data |
| `400` | `{"error":"Expected multipart"}` | No multipart boundary found |
| `400` | `{"error":"No image"}` | No file with field name `image` |
| `400` | `{"error":"Invalid file content: <name>"}` | Uploaded bytes don't match the claimed extension (magic-byte check failed) |
| `413` | `{"error":"File too large (max 16MB)"}` | A single file exceeds 16MB |
| `413` | `{"error":"Too many files"}` | More than 16 files in one request |
| `500` | `{"error":"Write failed"}` | Could not save uploaded file to temp |
| `404` | Not Found | Unknown route |

---

## CLI Benchmark (local)

For scripted/automated OCR without network overhead, use the included CLI tool:

```bash
cd OCRBenchmark
swift run -c release OCRBenchmark ~/Screenshots --json results.json
```

Outputs JSON with per-file timing and summary stats:

```json
{
  "summary": {
    "total_images": 450,
    "successful": 438,
    "wall_clock_seconds": 45.231,
    "images_per_second": 9.9
  },
  "results": [
    {"filename": "shot1.png", "text": "...", "duration": 0.123},
    {"filename": "shot2.png", "text": "...", "duration": 0.098}
  ]
}
```
