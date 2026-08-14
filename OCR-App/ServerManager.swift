import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Client Tracking

struct ConnectedClient: Identifiable, Sendable {
    let id: UUID
    let ip: String
    let connectedAt: Date
    let path: String
    let isActive: Bool
    let duration: TimeInterval

    var label: String { isActive ? "active" : "done" }
}

// MARK: - Server Event
struct ServerLogEntry: Sendable {
    let id: UUID; let method: String; let path: String; let remote: String
    let filename: String; let duration: TimeInterval; let status: Int; let timestamp: Date
}

final class ServerManager: NSObject, @unchecked Sendable {
    private var sockfd: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false
    private let queue = DispatchQueue(label: "ocr-server", qos: .userInitiated, attributes: .concurrent)
    private var logEntries: [ServerLogEntry] = []
    private let logLock = NSLock()
    var onStatusChange: ((Bool, String) -> Void)?
    var onNewLogEntry: ((ServerLogEntry) -> Void)?
    var onClientsChanged: (([ConnectedClient]) -> Void)?
    var isRunning: Bool { running }
    var port: UInt16 = 8080
    private(set) var address: String = "127.0.0.1"
    private let connectionLimit = DispatchSemaphore(value: 16)
    private let ocrLimit = DispatchSemaphore(value: 2)
    var urlString: String { "http://\(address):\(port)" }
    var recentLog: [ServerLogEntry] {
        logLock.lock(); defer { logLock.unlock() }
        return Array(logEntries.suffix(20))
    }

    // Client tracking
    private var activeClients: [Int32: ConnectedClient] = [:]
    private var completedClients: [ConnectedClient] = []
    private let clientLock = NSLock()
    var connectedClients: [ConnectedClient] {
        clientLock.lock(); defer { clientLock.unlock() }
        return Array(activeClients.values) + completedClients
    }

    private func trackClient(_ fd: Int32, ip: String) {
        let c = ConnectedClient(id: UUID(), ip: ip, connectedAt: Date(), path: "", isActive: true, duration: 0)
        clientLock.lock(); activeClients[fd] = c; clientLock.unlock()
        DispatchQueue.main.async { self.onClientsChanged?(self.connectedClients) }
    }

    private func updateClientPath(_ fd: Int32, path: String) {
        clientLock.lock()
        if var c = activeClients[fd] {
            c = ConnectedClient(id: c.id, ip: c.ip, connectedAt: c.connectedAt, path: path, isActive: true, duration: c.duration)
            activeClients[fd] = c
        }
        clientLock.unlock()
    }

    private func untrackClient(_ fd: Int32) {
        let elapsed: TimeInterval
        let client: ConnectedClient?
        clientLock.lock()
        client = activeClients.removeValue(forKey: fd)
        elapsed = client.map { Date().timeIntervalSince($0.connectedAt) } ?? 0
        if var c = client {
            c = ConnectedClient(id: c.id, ip: c.ip, connectedAt: c.connectedAt, path: c.path, isActive: false, duration: elapsed)
            completedClients.append(c)
            if completedClients.count > 20 { completedClients.removeFirst(completedClients.count - 20) }
        }
        clientLock.unlock()
        DispatchQueue.main.async { self.onClientsChanged?(self.connectedClients) }
    }

    func start(port: UInt16 = 8080) {
        queue.async { self._start(port: port) }
    }

    private func _start(port: UInt16) {
        guard !running else { return }
        self.port = port
        self.address = localAddress() ?? "127.0.0.1"
        sockfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sockfd >= 0 else { notifyStatus(error: "socket() failed"); return }
        let flags = fcntl(sockfd, F_GETFL, 0)
        guard flags >= 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "fcntl F_GETFL failed"); return }
        guard fcntl(sockfd, F_SETFL, flags | O_NONBLOCK) >= 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "fcntl F_SETFL failed"); return }
        var reuse: Int32 = 1
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = inet_addr(self.address)
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "bind() failed (port \(port) may be in use)"); return }
        guard Darwin.listen(sockfd, 5) == 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "listen() failed"); return }
        let fd = sockfd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source?.setEventHandler { [weak self] in while true {
            var ca = sockaddr_in(); var cl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cf = withUnsafeMutablePointer(to: &ca) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &cl) } }
            guard cf >= 0 else { if errno == EAGAIN || errno == EWOULDBLOCK { break }; break }
            guard let srv = self else { Darwin.close(cf); break }
            guard srv.connectionLimit.wait(timeout: .now()) == .success else {
                srv.sendAndClose(cf, 503, "Too many connections", "text/plain")
                continue
            }
            var noSigPipe: Int32 = 1
            setsockopt(cf, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let fl = fcntl(cf, F_GETFL, 0); _ = fcntl(cf, F_SETFL, fl | O_NONBLOCK)
            let ip = String(cString: inet_ntoa(ca.sin_addr))
            srv.trackClient(cf, ip: ip)
            srv.queue.async {
                defer { srv.connectionLimit.signal() }
                srv.handle(cf, ip: ip)
                srv.untrackClient(cf)
            }
        } }
        source?.setCancelHandler { Darwin.close(fd) }
        source?.resume()
        running = true; notifyStatus()
    }

    func stop() { queue.async { self._stop() } }

    private func _stop() { source?.cancel(); source = nil; sockfd = -1; running = false; DispatchQueue.main.async { self.notifyStatus() } }

    private func handle(_ fd: Int32, ip: String) {
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536)
        var attempts = 0
        var hdrEndPos = -1
        var contentLength = -1
        let maxHeaderBytes = 32 * 1024
        let maxRequestBytes = 64 * 1024 * 1024
        var tooLarge = false
        var timedOut = false
        let deadline = Date().addingTimeInterval(30)
        while attempts < 100 {
            if Date() >= deadline { timedOut = true; break }
            let n = read(fd, &tmp, tmp.count)
            if n > 0 {
                buf.append(tmp, count: n); attempts = 0
                if hdrEndPos < 0, buf.count > maxHeaderBytes { tooLarge = true; break }
                if buf.count > maxRequestBytes { tooLarge = true; break }
            }
            else if n == 0 { break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { attempts += 1; usleep(10000); continue }
            else { break }
            if hdrEndPos < 0, let r = buf.range(of: "\r\n\r\n".data(using: .utf8)!) {
                hdrEndPos = r.upperBound
                if let hdrStr = String(data: buf[buf.startIndex..<r.lowerBound], encoding: .utf8) {
                    for line in hdrStr.components(separatedBy: "\r\n") {
                        if let c = line.firstIndex(of: ":"), line.lowercased().hasPrefix("content-length") {
                            contentLength = Int(line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)) ?? -1
                            // Reject immediately if the declared length exceeds the cap —
                            // don't buffer up to 1GB from a slow stream.
                            if contentLength > maxRequestBytes { tooLarge = true }
                        }
                    }
                }
            }
            if hdrEndPos >= 0, contentLength >= 0, buf.count - hdrEndPos >= contentLength { break }
            if hdrEndPos >= 0, contentLength < 0 { break }
        }
        guard buf.count > 0 else { Darwin.close(fd); return }
        if timedOut { sendAndClose(fd, 408, "Request timeout", "text/plain"); return }
        if tooLarge { sendAndClose(fd, 413, "Request too large", "text/plain"); return }
        let start = CFAbsoluteTimeGetCurrent()
        guard let req = HTTPRequest(data: buf) else { sendAndClose(fd, 400, "Bad Request", "text/plain"); return }
        updateClientPath(fd, path: req.path)
        let fmt = ServerSupport.parseFormat(from: req.path)
        let isFast = req.path.contains("?fast=1") || req.path.contains("&fast=1")

        switch (req.method, req.path.components(separatedBy: "?").first ?? req.path) {
        case ("GET", "/"):
            sendAndClose(fd, 200, webHTML, "text/html; charset=utf-8")
            log("GET", "/", ip, "", 0, 200)
        case ("GET", "/health"):
            sendAndClose(fd, 200, "{\"status\":\"ok\",\"address\":\"\(address):\(port)\"}", "application/json")
            log("GET", "/health", ip, "", 0, 200)
        case ("POST", "/ocr"):
            guard let length = req.contentLength, req.body.count == length else {
                sendAndClose(fd, 400, "Invalid Content-Length", "text/plain")
                return
            }
            handleOCR(fd, req, ip, start, format: fmt, fast: isFast)
        case ("OPTIONS", _):
            sendAndClose(fd, 204, "", "text/plain")
        default:
            sendAndClose(fd, 404, "Not Found", "text/plain")
        }
    }

    private func sendAndClose(_ fd: Int32, _ status: Int, _ body: String, _ ct: String) {
        send(fd, status, body, ct); Darwin.close(fd)
    }

    private func handleOCR(_ fd: Int32, _ req: HTTPRequest, _ ip: String, _ start: CFAbsoluteTime, format: String = "html", fast: Bool = false) {
        guard ocrLimit.wait(timeout: .now()) == .success else {
            sendAndClose(fd, 429, "OCR capacity reached", "text/plain")
            return
        }
        defer { ocrLimit.signal() }
        guard let b = req.boundary else { sendAndClose(fd, 400, "{\"success\":false,\"error\":\"Expected multipart\"}", "application/json"); return }
        let parsed = ServerSupport.parseMultipart(req.body, boundary: b)
        let files = parsed.files
        guard !files.isEmpty else { sendAndClose(fd, 400, "{\"success\":false,\"error\":\"No image\"}", "application/json"); return }
        guard files.count <= 16 else {
            sendAndClose(fd, 413, "{\"success\":false,\"error\":\"Too many files\"}", "application/json")
            return
        }

        let maxServerFileBytes = 16 * 1024 * 1024
        let oversized = files.filter { $0.data.count > maxServerFileBytes }
        if !oversized.isEmpty {
            sendAndClose(fd, 413, "{\"success\":false,\"error\":\"File too large (max 16MB)\"}", "application/json")
            return
        }

        // Content validation: reject files whose magic bytes don't match the
        // claimed extension before anything is written to disk.
        if let invalid = files.first(where: { !ServerSupport.hasValidContent($0.data, ext: ($0.name as NSString).pathExtension.lowercased()) }) {
            let safeName = invalid.name
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            sendAndClose(fd, 400, "{\"success\":false,\"error\":\"Invalid file content: \(safeName)\"}", "application/json")
            return
        }

        var tmpFiles: [(String, URL)] = []
        for f in files {
            let ext = (f.name as NSString).pathExtension.lowercased()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ocr_\(UUID().uuidString).\(ext)")
            if (try? f.data.write(to: tmp)) != nil { tmpFiles.append((f.name, tmp)) }
        }
        guard !tmpFiles.isEmpty else { sendAndClose(fd, 500, "{\"success\":false,\"error\":\"Write failed\"}", "application/json"); return }

        // Agent API: an optional `options` multipart field switches to structured
        // (blocks + confidence) output with mode/language/threshold control.
        if let optionsJSON = parsed.optionsJSON {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let agent = try? decoder.decode(AgentOptions.self, from: Data(optionsJSON.utf8)) {
                handleAgentOCR(fd, ip, start, tmpFiles: tmpFiles, agent: agent, format: format)
                return
            }
        }

        var allResults: [OCRItem] = []
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            allResults = await OCRService.recognizeText(paths: tmpFiles.map { $0.1.path }, fast: fast)
            for (_, url) in tmpFiles { try? FileManager.default.removeItem(at: url) }
            sem.signal()
        }
        sem.wait()

        let el = CFAbsoluteTimeGetCurrent() - start
        // OCRService reports the temp UUID filenames; remap them back to the
        // original uploaded names (preserving " (page N)" suffixes for PDFs).
        let nameMap = Dictionary(uniqueKeysWithValues: tmpFiles.map { ($0.1.lastPathComponent, $0.0) })
        let results = (allResults.isEmpty ? files.map { OCRItem(filename: $0.name, text: "", error: "No result", duration: 0) } : allResults)
            .map { r in OCRItem(filename: ServerSupport.mapFilename(r.filename, originalByTempName: nameMap), text: r.text, error: r.error, duration: r.duration) }
        let totalDuration = results.reduce(0.0) { $0 + $1.duration }

        // Handle format selection
        if format == "txt" {
            var txt = ""
            for r in results {
                txt += "--- \(r.filename) ---\n\(r.text)\n\n"
            }
            sendAndClose(fd, 200, txt, "text/plain; charset=utf-8")
            log("POST", "/ocr", ip, "\(results.count) files", el, 200)
            return
        }
        if format == "json" {
            let resp = BatchOCRResponse(results: results, server_duration_seconds: el)
            let json = ((try? JSONEncoder().encode(resp)).flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
            sendAndClose(fd, 200, json, "application/json")
            log("POST", "/ocr", ip, "\(results.count) files", el, 200)
            return
        }

        // Build HTML results page (default)
        var optRows = ""
        var firstText = ""
        for (i, r) in results.enumerated() {
            let txt = r.text.isEmpty ? "(no text)" : r.text
            let safeTxt = txt.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let fn = ServerSupport.escapeHTML(r.filename)
            let err = r.error ?? ""
            if i == 0 { firstText = safeTxt }
            let status = err.isEmpty ? "" : " ⚠️"
            optRows += "<option value=\"" + safeTxt.replacingOccurrences(of: "\"", with: "&quot;") + "\" data-err=\"" + ServerSupport.escapeHTML(err) + "\">\(i+1). \(fn)\(status)</option>\n"
        }

        // Escape `<` as \u003C so OCR text containing "</script>" cannot break
        // out of the inlined <script> block (JSON does not escape < by default).
        let jsonData = ((((try? JSONEncoder().encode(results)).flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"))
            .replacingOccurrences(of: "<", with: "\\u003C")
        let html = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\"><title>OCR Results</title><style>:root{--bg:#f5f5f7;--card:#fff;--text:#1d1d1f;--secondary:#6e6e73;--tertiary:#aeaeb2;--border:#c7c7cc;--accent:#007aff;--accent-hover:#0066d6;--shadow:rgba(0,0,0,0.08);--out-bg:#f5f5f7;--out-border:#e5e5ea}@media(prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--text:#f5f5f7;--secondary:#98989d;--tertiary:#636366;--border:#38383a;--accent:#0a84ff;--accent-hover:#409cff;--shadow:rgba(0,0,0,0.3);--out-bg:#3a3a3c;--out-border:#48484a}}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:0.01ms!important;transition-duration:0.01ms!important}}*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,BlinkMacSystemFont,\"SF Pro Display\",\"SF Pro Text\",\"Helvetica Neue\",sans-serif;background:var(--bg);color:var(--text);padding:40px 20px;display:flex;justify-content:center;align-items:flex-start;min-height:100vh;-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;-webkit-tap-highlight-color:transparent}.card{background:var(--card);border-radius:20px;padding:32px;max-width:620px;width:100%;box-shadow:0 4px 24px var(--shadow)}h1{font-size:24px;font-weight:700;letter-spacing:-0.02em;margin-bottom:2px}.meta{color:var(--secondary);font-size:13px;margin-bottom:20px;display:flex;align-items:center;gap:6px;flex-wrap:wrap}.actions{display:flex;gap:8px;margin-bottom:16px}.actions button,.actions a{padding:10px 20px;border-radius:10px;font-size:13px;font-weight:500;text-decoration:none;text-align:center;flex:1;border:none;cursor:pointer;transition:all 0.2s ease;font-family:inherit}.actions button:focus-visible,.actions a:focus-visible{box-shadow:0 0 0 3px rgba(0,122,255,0.4)}.actions .primary{background:var(--accent);color:#fff}.actions .primary:hover{background:var(--accent-hover)}.actions .secondary{background:transparent;color:var(--text);border:1px solid var(--border)}.actions .secondary:hover{background:var(--out-bg)}select{width:100%;padding:10px 14px;border:1px solid var(--border);border-radius:10px;font-size:14px;background:var(--card);color:var(--text);margin-bottom:14px;appearance:auto}select:focus-visible{box-shadow:0 0 0 3px rgba(0,122,255,0.4)}.out{background:var(--out-bg);border:1px solid var(--out-border);border-radius:12px;padding:18px;min-height:160px;font-family:Menlo,Consolas,monospace;font-size:13px;line-height:1.6;white-space:pre-wrap;word-break:break-word}.err{color:#ff9500;font-size:12px;margin-top:6px;min-height:18px}.t{color:var(--tertiary);font-size:12px}.footer{margin-top:20px;padding-top:16px;border-top:1px solid var(--border);font-size:12px;color:var(--tertiary);text-align:center}</style></head><body><main><div class=\"card\"><h1>📄 Results</h1><p class=\"meta\"><span>" + String(results.count) + " file(s)</span><span>•</span><span>⏱ " + String(format: "%.1f", el) + "s wall</span><span class=\"t\">• " + String(format: "%.1f", totalDuration) + "s processing</span></p><div class=\"actions\"><button class=\"primary\" id=\"sv\">💾 Save All</button><button class=\"secondary\" id=\"cp\">📋 Copy</button><a class=\"secondary\" href=\"/\">✕ Clear</a></div><div class=\"err\" id=\"err\" aria-live=\"polite\" role=\"status\"></div><label for=\"sel\" class=\"sr-only\" style=\"position:absolute;width:1px;height:1px;overflow:hidden\">Select a file</label><select id=\"sel\" onchange=\"show()\">" + optRows + "</select><div class=\"out\" id=\"out\">" + firstText + "</div><div class=\"footer\">OCR Batch Processor</div></div></main><script>(function(){const d=" + jsonData + ";const sel=document.getElementById('sel'),out=document.getElementById('out'),err=document.getElementById('err');function show(){const i=sel.selectedIndex;if(d&&i>=0&&i<d.length){out.textContent=d[i].text||'(no text)';err.textContent=d[i].error?'⚠️ '+d[i].error:''}}window.show=show;document.getElementById('sv').onclick=function(){let t='';for(const r of d){t+='--- '+r.filename+' ---\\n'+(r.text||'(no text)')+'\\n\\n'}const a=document.createElement('a');a.href='data:text/plain;charset=utf-8,'+encodeURIComponent(t);a.download='ocr_results.txt';a.click()};document.getElementById('cp').onclick=function(){const i=sel.selectedIndex;if(d&&i>=0&&i<d.length){navigator.clipboard.writeText(d[i].text||'')}};if(d&&d.length)show()})();</script></body></html>"

        sendAndClose(fd, 200, html, "text/html; charset=utf-8")
        log("POST", "/ocr", ip, "\(results.count) files", el, 200)
    }

    /// Agent API: structured OCR honoring mode / languages / custom_words /
    /// confidence_threshold / structured. mode "adaptive" runs a fast probe and
    /// retries low-confidence items with accurate recognition.
    private func handleAgentOCR(_ fd: Int32, _ ip: String, _ start: CFAbsoluteTime, tmpFiles: [(String, URL)], agent: AgentOptions, format: String) {
        var config = OCRConfiguration.default
        if agent.mode == "fast" { config.recognitionLevel = .fast }
        if let langs = agent.languages, !langs.isEmpty { config.recognitionLanguages = langs.map { Locale.Language(identifier: $0) } }
        if let words = agent.customWords, !words.isEmpty { config.customWords = words }
        if agent.enhanceSmallText == true { config.enhanceSmallText = true }
        config.maxConcurrency = 2
        let threshold = agent.confidenceThreshold ?? 0.75

        let paths = tmpFiles.map { $0.1.path }
        let nameMap = Dictionary(uniqueKeysWithValues: tmpFiles.map { ($0.1.lastPathComponent, $0.0) })

        var finalItems: [OCRStructuredItem] = []
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            if agent.mode == "adaptive" {
                var fastCfg = config
                fastCfg.recognitionLevel = .fast
                let fastItems = await OCRService.recognizeTextStructured(paths: paths, config: fastCfg)
                let pathByKey = Dictionary(uniqueKeysWithValues: tmpFiles.map { ($0.1.lastPathComponent, $0.1.path) })
                var retryPaths: [String] = []
                for item in fastItems {
                    let base: String
                    if let r = item.filename.range(of: " (page ") { base = String(item.filename[..<r.lowerBound]) }
                    else { base = item.filename }
                    guard let p = pathByKey[base] else { continue }
                    let blockMin = item.blocks.map(\.confidence).min() ?? 1
                    let lowRatio = item.blocks.isEmpty ? 0 : Double(item.blocks.filter { $0.confidence < 0.5 }.count) / Double(item.blocks.count)
                    if item.text.isEmpty || (item.confidence ?? 0) < threshold || blockMin < 0.4 || lowRatio > 0.25 {
                        retryPaths.append(p)
                    }
                }
                let accurateItems = retryPaths.isEmpty ? [] : await OCRService.recognizeTextStructured(paths: retryPaths, config: config)
                var accurateByFilename: [String: OCRStructuredItem] = [:]
                for it in accurateItems { accurateByFilename[it.filename] = it }
                finalItems = fastItems.map { accurateByFilename[$0.filename] ?? $0 }
            } else {
                finalItems = await OCRService.recognizeTextStructured(paths: paths, config: config)
            }
            for (_, url) in tmpFiles { try? FileManager.default.removeItem(at: url) }
            sem.signal()
        }
        sem.wait()

        let el = CFAbsoluteTimeGetCurrent() - start
        let mapped = finalItems.map { it in
            OCRStructuredItem(filename: ServerSupport.mapFilename(it.filename, originalByTempName: nameMap), text: it.text, error: it.error, duration: it.duration, confidence: it.confidence, blocks: it.blocks)
        }

        if format == "txt" {
            var txt = ""
            for r in mapped { txt += "--- \(r.filename) ---\n\(r.text)\n\n" }
            sendAndClose(fd, 200, txt, "text/plain; charset=utf-8")
            log("POST", "/ocr", ip, "\(mapped.count) files", el, 200)
            return
        }
        if format == "html" && agent.structured == false {
            var body = ""
            for r in mapped {
                body += "<h2>" + ServerSupport.escapeHTML(r.filename) + "</h2><pre>" + ServerSupport.escapeHTML(r.text.isEmpty ? "(no text)" : r.text) + "</pre>"
            }
            let html = "<!DOCTYPE html><html lang=\"en\"><head><meta charset=\"UTF-8\"><title>OCR Results</title></head><body>" + body + "</body></html>"
            sendAndClose(fd, 200, html, "text/html; charset=utf-8")
            log("POST", "/ocr", ip, "\(mapped.count) files", el, 200)
            return
        }
        let resp = StructuredBatchResponse(
            results: mapped,
            server_duration_seconds: el,
            processing_ms: el * 1000,
            strategy: agent.mode ?? "accurate",
            engine: "vision",
            engine_revision: OCRService.visionRevisionLabel(),
            // The structured pipeline always uses RecognizeTextRequest so that
            // per-line confidence and bounding boxes are available on every OS.
            engine_api: "RecognizeTextRequest",
            language: agent.languages?.first ?? "en-US"
        )
        let json = ((try? JSONEncoder().encode(resp)).flatMap { String(data: $0, encoding: .utf8) }) ?? "[]"
        sendAndClose(fd, 200, json, "application/json")
        log("POST", "/ocr", ip, "\(mapped.count) files", el, 200)
    }

    // MARK: - Helpers

    private func send(_ fd: Int32, _ status: Int, _ body: String, _ ct: String) {
        let st = ["200":"OK","204":"No Content","400":"Bad Request","404":"Not Found","408":"Request Timeout","413":"Payload Too Large","429":"Too Many Requests","500":"Internal Server Error","503":"Service Unavailable"][String(status)] ?? ""
        let bd = body.data(using: .utf8) ?? Data()
        let resp = "HTTP/1.1 \(status) \(st)\r\nContent-Type: \(ct)\r\nCache-Control: no-store\r\nContent-Length: \(bd.count)\r\nConnection: close\r\n\r\n"
        guard var data = resp.data(using: .utf8) else { return }; data.append(bd)
        // Make fd blocking so write() completes — the response is small and the socket closes after
        let fl = fcntl(fd, F_GETFL, 0)
        if fl >= 0 { _ = fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = write(fd, base + written, data.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }

    private func log(_ m: String, _ p: String, _ r: String, _ f: String, _ d: TimeInterval, _ s: Int) {
        let e = ServerLogEntry(id: UUID(), method: m, path: p, remote: r, filename: f, duration: d, status: s, timestamp: Date())
        logLock.lock(); logEntries.append(e); if logEntries.count > 100 { logEntries.removeFirst(logEntries.count - 100) }; logLock.unlock()
        DispatchQueue.main.async { self.onNewLogEntry?(e) }
    }

    private func notifyStatus(error: String? = nil) {
        DispatchQueue.main.async { self.onStatusChange?(self.running, error ?? (self.running ? self.urlString : "")) }
    }
}

private func localAddress() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }

    var current = first
    while true {
        let interface = current.pointee
        if let address = interface.ifa_addr,
           address.pointee.sa_family == AF_INET {
            let name = String(cString: interface.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("ap") {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                let value = String(cString: host)
                if isPrivateIPv4(value) {
                    return value
                }
            }
        }
        guard let next = interface.ifa_next else { break }
        current = next
    }
    return nil
}

private func isPrivateIPv4(_ value: String) -> Bool {
    let octets = value.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    return octets[0] == 10
        || (octets[0] == 172 && (16...31).contains(octets[1]))
        || (octets[0] == 192 && octets[1] == 168)
}

private let webHTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,viewport-fit=cover">
<title>OCR</title>
<style>
  :root {
    --bg: #f5f5f7;
    --card: #ffffff;
    --text: #1d1d1f;
    --secondary: #6e6e73;
    --tertiary: #aeaeb2;
    --border: #c7c7cc;
    --accent: #007aff;
    --accent-hover: #0066d6;
    --shadow: rgba(0,0,0,0.08);
    --drop-border: #c7c7cc;
    --drop-bg: #ffffff;
    --drop-hover-bg: #f0f7ff;
    --drop-hover-border: #007aff;
    --warning: #ff9500;
    --error: #ff3b30;
    --focus-ring: rgba(0,122,255,0.4);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #1c1c1e;
      --card: #2c2c2e;
      --text: #f5f5f7;
      --secondary: #98989d;
      --tertiary: #636366;
      --border: #38383a;
      --accent: #0a84ff;
      --accent-hover: #409cff;
      --shadow: rgba(0,0,0,0.3);
      --drop-border: #48484a;
      --drop-bg: #2c2c2e;
      --drop-hover-bg: #1a2f44;
      --drop-hover-border: #0a84ff;
      --focus-ring: rgba(10,132,255,0.4);
    }
  }
  @media (prefers-reduced-motion: reduce) {
    *,*::before,*::after{animation-duration:0.01ms!important;transition-duration:0.01ms!important}
  }
  *{box-sizing:border-box;margin:0;padding:0}
  body{
    font-family:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text","Helvetica Neue",sans-serif;
    background:var(--bg);color:var(--text);padding:40px 20px;
    display:flex;justify-content:center;align-items:flex-start;min-height:100vh;
    -webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;
    -webkit-tap-highlight-color:transparent;
  }
  .card{
    background:var(--card);border-radius:20px;padding:32px;
    max-width:560px;width:100%;
    box-shadow:0 4px 24px var(--shadow);
  }
  h1{font-size:24px;font-weight:700;letter-spacing:-0.02em;margin-bottom:4px}
  .sub{color:var(--secondary);font-size:14px;margin-bottom:24px;line-height:1.4}

  /* Drop Zone — drag only, no click picker */
  .zone{
    border:2px dashed var(--drop-border);border-radius:16px;
    padding:36px 24px;text-align:center;margin-bottom:20px;
    background:var(--drop-bg);
    transition:all 0.25s ease;position:relative;
  }
  .zone.dragover{
    border-color:var(--drop-hover-border);
    background:var(--drop-hover-bg);
    transform:scale(1.01);
  }
  .zone-icon{font-size:40px;display:block;margin-bottom:12px;opacity:0.7;pointer-events:none}
  .zone p{color:var(--secondary);font-size:14px;line-height:1.5;pointer-events:none}
  .zone .hint{font-size:12px;color:var(--tertiary);margin-top:6px;pointer-events:none}

  /* Button */
  .btn{
    display:block;width:100%;padding:14px;border:none;
    border-radius:12px;font-size:15px;font-weight:600;
    cursor:pointer;text-align:center;
    background:var(--accent);color:#fff;
    transition:all 0.2s ease;
  }
  .btn:hover{background:var(--accent-hover);transform:translateY(-1px)}
  .btn:active{transform:translateY(0);opacity:0.9}
  .btn:disabled{opacity:0.5;cursor:not-allowed;transform:none}
  .btn:focus-visible{box-shadow:0 0 0 3px var(--focus-ring)}

  /* Fast toggle */
  .fast-row{
    display:flex;align-items:center;justify-content:center;gap:8px;
    margin-top:12px;font-size:13px;color:var(--secondary);
  }
  .fast-row input[type="checkbox"]{
    width:16px;height:16px;accent-color:var(--accent);cursor:pointer;
  }
  .fast-row label{cursor:pointer;user-select:none}

  /* Status & Spinner */
  .st{
    font-size:13px;text-align:center;margin-top:14px;
    color:var(--secondary);min-height:22px;
    transition:color 0.2s ease;
  }
  .st.e{color:var(--warning);font-weight:500}
  .spinner{display:none;width:20px;height:20px;margin:0 auto 8px;
    border:2.5px solid var(--border);border-top-color:var(--accent);
    border-radius:50%;animation:spin 0.8s linear infinite}
  @keyframes spin{to{transform:rotate(360deg)}}
  .loading .spinner{display:block}

  /* Screen-reader only */
  .sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
</style></head>
<body>
<main>
<div class="card">
  <h1>📄 OCR</h1>
  <p class="sub">Upload images to extract text</p>

  <form method="POST" action="/ocr" enctype="multipart/form-data" id="ocr-form">
    <div class="zone" id="dz">
      <span class="zone-icon" aria-hidden="true">📁</span>
      <p>Drag &amp; drop images here</p>
      <p class="hint">PNG, JPG, GIF, BMP, TIFF, HEIC, WebP, PDF</p>
      <div id="cnt" aria-live="polite" style="font-size:13px;font-weight:600;margin-top:10px;color:var(--accent)"></div>
    </div>

    <div id="cam-ui" class="cam-row" style="display:none">
      <button class="btn" id="cam" type="button">📷 Take a Picture</button>
      <video id="cam-preview" autoplay playsinline style="display:none;width:100%;border-radius:12px;margin-bottom:12px"></video>
      <button class="btn" id="cam-cap" type="button" style="display:none">📸 Capture Photo</button>
    </div>

    <button class="btn" id="go" type="submit">Run OCR</button>
    <div class="fast-row">
      <input type="checkbox" id="fast" name="fast" value="1">
      <label for="fast">Fast mode (~3× faster, may miss text)</label>
    </div>
    <div class="st" id="st" role="status" aria-live="polite"></div>
    <div class="spinner" id="spinner" aria-hidden="true"></div>
  </form>
</div>
</main>
<script>
(function(){
  const dz=document.getElementById('dz'),
        cnt=document.getElementById('cnt'),go=document.getElementById('go'),
        st=document.getElementById('st'),fast=document.getElementById('fast'),
        sp=document.getElementById('spinner'),form=document.getElementById('ocr-form');
  let sel=[];
  const exts=new Set(['png','jpg','jpeg','gif','bmp','tiff','tif','heic','webp','pdf']);

  // Drag only — no click picker
  dz.addEventListener('dragover',e=>{e.preventDefault();dz.classList.add('dragover')},{passive:false});
  dz.addEventListener('dragleave',()=>dz.classList.remove('dragover'));
  dz.addEventListener('drop',e=>{
    e.preventDefault();
    dz.classList.remove('dragover');
    if(e.dataTransfer?.files.length){sel=[...e.dataTransfer.files];updateCounter()}
  });

  function updateCounter(){
    if(!sel.length){cnt.textContent='';st.textContent='';st.className='st';return}
    cnt.textContent=sel.length+' file(s) selected';
    const bad=sel.filter(f=>!exts.has(f.name.split('.').pop().toLowerCase())).length;
    if(bad){st.textContent='⚠️ '+bad+' of '+sel.length+' file(s) have unsupported formats';st.className='st e'}
    else{st.textContent='';st.className='st'}
  }

  // Camera capture — requires a secure context (HTTPS via the reverse proxy)
  const camUI=document.getElementById('cam-ui'),cam=document.getElementById('cam'),
        camPreview=document.getElementById('cam-preview'),camCap=document.getElementById('cam-cap');
  if(window.isSecureContext&&navigator.mediaDevices&&navigator.mediaDevices.getUserMedia){
    camUI.style.display='block';
    let stream=null;
    cam.addEventListener('click',async()=>{
      try{
        stream=await navigator.mediaDevices.getUserMedia({video:{facingMode:'environment'},audio:false});
        camPreview.srcObject=stream;camPreview.style.display='block';
        cam.style.display='none';camCap.style.display='block';
        st.className='st';st.textContent='Camera live — capture the document';
      }catch(err){
        st.className='st e';st.textContent='Camera unavailable: '+err.message;
      }
    });
    camCap.addEventListener('click',()=>{
      const w=camPreview.videoWidth,h=camPreview.videoHeight;
      if(!w||!h)return;
      const cnv=document.createElement('canvas');cnv.width=w;cnv.height=h;
      cnv.getContext('2d').drawImage(camPreview,0,0,w,h);
      cnv.toBlob(blob=>{
        if(!blob)return;
        const file=new File([blob],'camera-'+Date.now()+'.jpg',{type:'image/jpeg'});
        sel.push(file);updateCounter();
        if(stream){stream.getTracks().forEach(t=>t.stop());stream=null}
        camPreview.srcObject=null;camPreview.style.display='none';
        camCap.style.display='none';cam.style.display='block';
        st.className='st';st.textContent='Photo added — ready to run OCR';
      },'image/jpeg',0.9);
    });
  }

  // Intercept form submit for AJAX with live timer
  form.addEventListener('submit',function(e){
    e.preventDefault();
    if(!sel.length){st.className='st e';st.textContent='Select files first';return}

    st.className='st';
    const t0=Date.now();
    sp.style.display='block';
    go.disabled=true;

    const timer=setInterval(()=>{
      st.textContent='⏱ '+((Date.now()-t0)/1000).toFixed(1)+'s  •  '+sel.length+' file(s)'
    },100);

    const fd=new FormData();
    for(const f of sel)fd.append('image',f);
    const url='/ocr'+(fast.checked?'?fast=1':'');

    fetch(url,{method:'POST',body:fd})
      .then(r=>{
        if(!r.ok)throw new Error('Server returned '+r.status);
        return r.text()
      })
      .then(html=>{
        clearInterval(timer);sp.style.display='none';go.disabled=false;
        document.open();document.write(html);document.close()
      })
      .catch(err=>{
        clearInterval(timer);sp.style.display='none';go.disabled=false;
        st.className='st e';st.textContent='Error: '+err.message
      })
  });
})();
</script>
</body>
</html>
"""
