# Bug Report 3 — big-pickle

Third-pass deep scan. The previous two passes covered UI races, null derefs, and
force-unwraps. This pass found bugs in the **server I/O path** and the **CLI JSON
output**. 5 major bugs confirmed against the actual files in this repo.

> Note: the automated scan agent hallucinated several files that do not exist in
> this repo (`OCRViewModel.swift`, `ServerViewModel.swift`, `OCRTabView.swift`,
> `ContentView.swift`). Those findings are excluded. Only bugs reproduced against
> the real files are documented below.

---

## Major Bugs

### 1. `OCRBenchmark/Sources/OCRBenchmark/main.swift:213` — `--json` always emits `"{}"`

```swift
"results": results.map { r in
    [
        "filename": r.filename,
        "text": r.text,
        "error": r.error as Any,        // r.error is String?
        "duration_seconds": r.duration,
    ]
}
guard let data = try? JSONSerialization.data(withJSONObject: output, ...)
else { return "{}" }
```

`r.error as Any` boxes a Swift `Optional`. When `error == nil`, the value is
`Optional<String>.none`. `JSONSerialization` does **not** accept Swift optionals
and throws — `try?` yields `nil`, so the function **always returns `"{}"`** for any
successful run (every item has `error == nil`). The entire `--json` feature is
silently broken.

**Fix:** replace `r.error as Any` with `r.error as Any? ?? NSNull()` (or build
`[String: Any?]` and map nils to `NSNull()`).

---

### 2. `OCR-App/ServerManager.swift` `parseMultiAll` — trailing CRLF corrupts uploaded image

```swift
let part = body[ps..<pe]
if let cr = part.range(of: "\r\n\r\n".data(using: .utf8)!), ... {
    files.append(UFile(name: extractFN(h) ?? "upload", data: Data(part[cr.upperBound...])))
}
```

In multipart, each part body is terminated by `\r\n` immediately **before** the
next `--boundary`. `pe` is the *start* of the next boundary, so
`part[cr.upperBound...]` includes that trailing `\r\n`. The CR/LF bytes are written
into the temp image file. PNG/JPEG decoders often tolerate trailing bytes, but
strict formats (WebP, TIFF, BMP, GIF, HEIC) can fail to load → "Could not load
image" / empty OCR.

**Fix:** strip the trailing `\r\n` (2 bytes) before the boundary: `part[cr.upperBound..<pe].dropLast(2)` guarded by a check that those bytes are CRLF.

---

### 3. `OCR-App/ServerManager.swift` `handle()` — guaranteed ~1s latency per request

```swift
var attempts = 0
while attempts < 100 {
    let n = read(fd, &tmp, tmp.count)
    if n > 0 { buf.append(tmp, count: n); attempts = 0 }
    else if n == 0 { break }
    else if errno == EAGAIN || errno == EWOULDBLOCK { attempts += 1; usleep(10000); continue }
    else { break }
}
```

The connection fd is non-blocking (set `O_NONBLOCK` in the accept loop). After the
browser's full body arrives, `read()` returns `EAGAIN` immediately and the loop
busy-waits `100 × 10ms = 1s` before giving up. The code never inspects
`Content-Length`, so it cannot know when the body is complete — it relies purely on
a fixed timeout. Every OCR POST pays a guaranteed ~1 second of dead time.

**Fix:** parse `Content-Length` from the headers and stop reading once that many
body bytes are received; only fall back to the timeout for malformed requests.

---

### 4. `OCR-App/ServerManager.swift` `send()` — response truncated on non-blocking `write()`

```swift
data.withUnsafeBytes { buf in
    guard let base = buf.baseAddress else { return }
    var written = 0
    while written < data.count {
        let n = write(fd, base + written, data.count - written)
        if n <= 0 { break }          // EAGAIN → stop, response cut short
        written += n
    }
}
```

The connection fd is `O_NONBLOCK`. When the kernel send buffer is full, `write()`
returns `-1`/`EAGAIN`; the loop breaks on `n <= 0` and the response is **silently
truncated**. The client then receives a partial page because `Connection: close`
ends the stream mid-body. Large HTML results are most affected.

**Fix:** on `EAGAIN`, register the fd for write readiness (or block the fd before
writing) and retry; only give up on a hard error.

---

### 5. `OCR-App/ServerManager.swift` `handleOCR()` — `sem.wait()` blocks the server queue

```swift
var allResults: [OCRItem] = []
let sem = DispatchSemaphore(value: 0)
Task.detached {
    allResults = await OCRService.recognizeText(paths: tmpFiles.map { $0.1.path }, fast: fast)
    for (_, url) in tmpFiles { try? FileManager.default.removeItem(at: url) }
    sem.signal()
}
sem.wait()   // blocks the serial server queue for the whole OCR run
```

`sem.wait()` blocks the serial `DispatchQueue` the server runs on. While OCR runs
(potentially seconds), the server cannot `accept()` or service any other
connection. A single slow upload makes the entire server unresponsive. There is
also a Swift-concurrency data race: a `var` captured by `Task.detached` is mutated
inside the task (works only by accident of the semaphore).

**Fix:** don't block — make `handleOCR` itself `async`, or continue the response
assembly inside `Task.detached` and `sendAndClose` from there. Move read/parse off
the serial queue.

---

## Summary

| # | File:Line | Bug | Severity |
|---|-----------|-----|----------|
| 1 | `OCRBenchmark/.../main.swift:213` | `--json` always returns `"{}"` | Major |
| 2 | `ServerManager.swift` `parseMultiAll` | Trailing CRLF corrupts image binary | Major |
| 3 | `ServerManager.swift` `handle` | ~1s fixed busy-wait per request | Major |
| 4 | `ServerManager.swift` `send` | Non-blocking `write()` truncates response | Major |
| 5 | `ServerManager.swift` `handleOCR` | `sem.wait()` blocks server queue | Major |

No further functional bugs found in `ViewController.swift`, `OCRService.swift`,
`AppDelegate.swift`, or `main.swift` beyond those already fixed in prior passes.
