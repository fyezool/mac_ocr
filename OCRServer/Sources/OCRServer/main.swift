import Vapor
import Foundation

// MARK: - Log Entry

struct LogEntry: Content, Sendable {
    let id: UUID
    let method: String
    let path: String
    let remoteAddress: String
    let status: HTTPStatus
    let duration: Double
    let timestamp: Date
    let imageCount: Int
}

// MARK: - App Setup

@main
enum EntryPoint {
    static func main() async throws {
        var env = try Environment.detect()
        try LoggingSystem.bootstrap(from: &env)

        let app = Application(env)
        defer { app.shutdown() }

        // ── Middleware ──
        app.middleware.use(CORSMiddleware())
        app.middleware.use(ErrorMiddleware.default(environment: env))

        // ── Shared state ──
        let requestLog = RequestLog()
        app.storage[RequestLogKey.self] = requestLog

        // ── Routes ──
        app.get("health") { _ async -> Response in
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            let body = """
            {"status":"ok","server":"OCR Server","version":"1.0.0"}
            """
            return Response(status: .ok, headers: headers, body: .init(string: body))
        }

        app.get { _ async -> Response in
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "text/html; charset=utf-8")
            return Response(status: .ok, headers: headers, body: .init(string: webPageHTML))
        }

        app.post("ocr") { req async throws -> Response in
            let start = CFAbsoluteTimeGetCurrent()

            // Parse uploaded file(s)
            let file = try req.content.get(File.self, at: "image")
            let ext = (file.filename as NSString).pathExtension.lowercased()

            guard OCRService.supportedExtensions.contains(ext) else {
                throw Abort(.badRequest, reason: "Unsupported format: .\(ext). Supported: \(OCRService.supportedExtensions.sorted().joined(separator: ", "))")
            }

            // Save to temp directory
            let tempDir = FileManager.default.temporaryDirectory
            let tempFile = tempDir.appendingPathComponent("ocr_\(UUID().uuidString).\(ext)")
            try Data(file.data).write(to: tempFile)

            // Run OCR
            let results = await OCRService.recognizeText(paths: [tempFile.path])

            // Cleanup
            try? FileManager.default.removeItem(at: tempFile)

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            let resultItem = results.first ?? OCRItem(filename: file.filename, text: "", error: "No result", duration: elapsed)

            // Log
            let logEntry = LogEntry(
                id: UUID(),
                method: "POST",
                path: "/ocr",
                remoteAddress: req.remoteAddress?.description ?? "unknown",
                status: .ok,
                duration: elapsed,
                timestamp: Date(),
                imageCount: 1
            )
            await requestLog.append(logEntry)
            emitEvent(["event": "request", "method": "POST", "path": "/ocr",
                       "remote": req.remoteAddress?.description ?? "",
                       "filename": file.filename,
                       "duration": elapsed, "status": 200])

            let response = OCRResponse(
                success: resultItem.error == nil,
                filename: resultItem.filename,
                text: resultItem.text,
                error: resultItem.error,
                duration_seconds: resultItem.duration,
                server_duration_seconds: elapsed
            )
            return try await response.encodeResponse(for: req)
        }

        app.get("log") { req async throws -> [LogEntry] in
            await requestLog.recent()
        }

        // ── Find LAN address ──
        let port = env.port ?? 8080
        let address = localAddress() ?? "127.0.0.1"

        // ── Start ──
        emitEvent(["event": "started", "address": "\(address):\(port)", "port": port])

        try await app.execute()
    }
}

// MARK: - Helpers

func localAddress() -> String? {
    var addr: String?
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var cursor = firstAddr
    while true {
        let interface = cursor.pointee
        let family = interface.ifa_addr.pointee.sa_family
        if family == AF_INET {
            let name = String(cString: interface.ifa_name)
            // Prefer en0/en1 (Wi-Fi / Ethernet)
            if name.hasPrefix("en") {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(interface.ifa_addr,
                           socklen_t(interface.ifa_addr.pointee.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0,
                           NI_NUMERICHOST)
                let candidate = String(cString: hostname)
                if candidate != "127.0.0.1" {
                    addr = candidate
                    break
                }
            }
        }
        guard let next = interface.ifa_next else { break }
        cursor = next
    }

    return addr ?? "127.0.0.1"
}

func emitEvent(_ dict: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
          let line = String(data: data, encoding: .utf8) else { return }
    print(line)
    fflush(stdout)
}

// MARK: - Actor for request log

actor RequestLog {
    private var entries: [LogEntry] = []

    func append(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > 100 { entries.removeFirst(50) }
    }

    func recent() -> [LogEntry] {
        Array(entries.suffix(20))
    }
}

struct RequestLogKey: StorageKey {
    typealias Value = RequestLog
}

// MARK: - Models

struct OCRResponse: Content {
    let success: Bool
    let filename: String
    let text: String
    let error: String?
    let duration_seconds: TimeInterval
    let server_duration_seconds: TimeInterval
}

// MARK: - CORS Middleware

struct CORSMiddleware: Middleware {
    func respond(to req: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        next.respond(to: req).map { res in
            res.headers.replaceOrAdd(name: "Access-Control-Allow-Origin", value: "*")
            res.headers.replaceOrAdd(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            res.headers.replaceOrAdd(name: "Access-Control-Allow-Headers", value: "Content-Type")
            return res
        }
    }
}

// MARK: - Environment helpers

extension Environment {
    var port: Int? {
        let args = ProcessInfo.processInfo.arguments
        for arg in args {
            if arg.hasPrefix("--port=") {
                return Int(arg.replacingOccurrences(of: "--port=", with: ""))
            }
        }
        return nil
    }
}

// MARK: - Web HTML

let webPageHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OCR Server</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, system-ui, sans-serif; background: #f5f5f7; color: #1d1d1f; padding: 40px 20px; display: flex; justify-content: center; }
  .card { background: white; border-radius: 18px; padding: 32px; max-width: 640px; width: 100%; box-shadow: 0 4px 24px rgba(0,0,0,0.08); }
  h1 { font-size: 24px; font-weight: 600; margin-bottom: 4px; }
  p.sub { color: #6e6e73; font-size: 14px; margin-bottom: 24px; }
  .upload-zone { border: 2px dashed #c7c7cc; border-radius: 12px; padding: 40px 20px; text-align: center; cursor: pointer; transition: all 0.2s; }
  .upload-zone:hover, .upload-zone.dragover { border-color: #007aff; background: #f0f7ff; }
  .upload-zone.has-file { border-color: #34c759; background: #f0fff0; }
  .upload-zone p { color: #6e6e73; font-size: 14px; }
  .upload-zone .icon { font-size: 40px; margin-bottom: 12px; }
  .upload-zone .filename { font-size: 13px; color: #1d1d1f; margin-top: 8px; word-break: break-all; }
  input[type=file] { display: none; }
  button { background: #007aff; color: white; border: none; border-radius: 10px; padding: 12px 24px; font-size: 15px; font-weight: 500; cursor: pointer; width: 100%; margin-top: 16px; transition: background 0.2s; }
  button:hover { background: #0062cc; }
  button:disabled { background: #c7c7cc; cursor: not-allowed; }
  .status { margin-top: 16px; font-size: 13px; color: #6e6e73; }
  .status.loading { color: #007aff; }
  .status.error { color: #ff3b30; }
  .status.success { color: #34c759; }
  .result { margin-top: 16px; display: none; }
  .result.show { display: block; }
  .result textarea { width: 100%; height: 200px; font-family: 'SF Mono', 'Menlo', monospace; font-size: 13px; border: 1px solid #c7c7cc; border-radius: 8px; padding: 12px; resize: vertical; }
  .result .meta { font-size: 12px; color: #6e6e73; margin-bottom: 8px; }
  .result .meta span { margin-right: 16px; }
</style>
</head>
<body>
<div class="card">
  <h1>📄 OCR Server</h1>
  <p class="sub">Upload an image to extract text via Apple Vision</p>

  <div class="upload-zone" id="dropZone" onclick="document.getElementById('fileInput').click()">
    <div class="icon">🖼️</div>
    <p>Tap to choose an image, or drag & drop</p>
    <div class="filename" id="fileName"></div>
  </div>
  <input type="file" id="fileInput" accept="image/png,image/jpeg,image/gif,image/bmp,image/tiff,image/heic,image/webp">

  <button id="submitBtn" disabled onclick="upload()">Run OCR</button>

  <div id="status" class="status"></div>

  <div class="result" id="result">
    <div class="meta"><span id="metaFile"></span><span id="metaTime"></span></div>
    <textarea id="ocrText" readonly></textarea>
  </div>
</div>

<script>
  const dropZone = document.getElementById('dropZone');
  const fileInput = document.getElementById('fileInput');
  const fileName = document.getElementById('fileName');
  const submitBtn = document.getElementById('submitBtn');
  const status = document.getElementById('status');
  const result = document.getElementById('result');
  const ocrText = document.getElementById('ocrText');
  const metaFile = document.getElementById('metaFile');
  const metaTime = document.getElementById('metaTime');

  let selectedFile = null;

  fileInput.addEventListener('change', e => {
    if (e.target.files.length) { selectFile(e.target.files[0]); }
  });

  dropZone.addEventListener('dragover', e => { e.preventDefault(); dropZone.classList.add('dragover'); });
  dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
  dropZone.addEventListener('drop', e => {
    e.preventDefault();
    dropZone.classList.remove('dragover');
    if (e.dataTransfer.files.length) { selectFile(e.dataTransfer.files[0]); }
  });

  function selectFile(file) {
    selectedFile = file;
    fileName.textContent = file.name + ' (' + (file.size / 1024).toFixed(1) + ' KB)';
    dropZone.classList.add('has-file');
    submitBtn.disabled = false;
    result.classList.remove('show');
    status.className = 'status';
    status.textContent = '';
  }

  async function upload() {
    if (!selectedFile) return;
    const form = new FormData();
    form.append('image', selectedFile);
    submitBtn.disabled = true;
    status.className = 'status loading';
    status.textContent = '⏳ Recognizing text…';
    result.classList.remove('show');

    try {
      const res = await fetch('/ocr', { method: 'POST', body: form });
      const data = await res.json();
      if (data.success) {
        status.className = 'status success';
        status.textContent = '✅ Done';
        metaFile.textContent = '📄 ' + data.filename;
        metaTime.textContent = '⏱ ' + data.duration_seconds.toFixed(3) + 's';
        ocrText.value = data.text || '(no text recognized)';
        result.classList.add('show');
      } else {
        status.className = 'status error';
        status.textContent = '❌ ' + (data.error || 'OCR failed');
      }
    } catch (e) {
      status.className = 'status error';
      status.textContent = '❌ Connection error: ' + e.message;
    }
    submitBtn.disabled = false;
  }
</script>
</body>
</html>
"""
