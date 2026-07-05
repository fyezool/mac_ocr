# OCR Server API

The OCR App includes an in-process HTTP server that exposes OCR functionality
over the local network. All endpoints run on `http://<server-ip>:8080`.

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
curl -X POST -F "image=@shot.png" http://192.168.2.6:8080/ocr

# Plain text output
curl -X POST -F "image=@shot.png" http://192.168.2.6:8080/ocr?format=txt

# JSON output (great for scripting)
curl -X POST -F "image=@shot.png" http://192.168.2.6:8080/ocr?format=json

# Multiple files as JSON
curl -X POST \
  -F "image=@photo1.png" \
  -F "image=@photo2.jpg" \
  "http://192.168.2.6:8080/ocr?format=json"
```

### Example (Python)

```python
import requests

url = "http://192.168.2.6:8080/ocr"
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

let url = URL(string: "http://192.168.2.6:8080/ocr")!
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
