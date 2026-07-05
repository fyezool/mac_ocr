import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Server Event
struct ServerLogEntry: Sendable {
    let id: UUID; let method: String; let path: String; let remote: String
    let filename: String; let duration: TimeInterval; let status: Int; let timestamp: Date
}

final class ServerManager: NSObject, @unchecked Sendable {
    private var sockfd: Int32 = -1
    private var source: DispatchSourceRead?
    private var running = false
    private let queue = DispatchQueue(label: "ocr-server", qos: .userInitiated)
    private var logEntries: [ServerLogEntry] = []
    private let logLock = NSLock()
    var onStatusChange: ((Bool, String) -> Void)?
    var onNewLogEntry: ((ServerLogEntry) -> Void)?
    var isRunning: Bool { running }
    var port: UInt16 = 8080
    private(set) var address: String = "127.0.0.1"
    var urlString: String { "http://\(address):\(port)" }
    var recentLog: [ServerLogEntry] {
        logLock.lock(); defer { logLock.unlock() }
        return Array(logEntries.suffix(20))
    }

    func start(port: UInt16 = 8080) {
        guard !running else { return }
        self.port = port
        self.address = localAddress() ?? "127.0.0.1"
        sockfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sockfd >= 0 else { notifyStatus(error: "socket() failed"); return }
        var flags = fcntl(sockfd, F_GETFL, 0); fcntl(sockfd, F_SETFL, flags | O_NONBLOCK)
        var reuse: Int32 = 1
        setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = CFSwapInt16HostToBig(port)
        addr.sin_addr.s_addr = INADDR_ANY
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard r == 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "bind() failed (port \(port) may be in use)"); return }
        guard Darwin.listen(sockfd, 5) == 0 else { Darwin.close(sockfd); sockfd = -1; notifyStatus(error: "listen() failed"); return }
        let fd = sockfd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source?.setEventHandler { [weak self] in while true {
            var ca = sockaddr_in(); var cl = socklen_t(MemoryLayout<sockaddr_in>.size)
            let cf = withUnsafeMutablePointer(to: &ca) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.accept(fd, $0, &cl) } }
            guard cf >= 0 else { if errno == EAGAIN || errno == EWOULDBLOCK { break }; break }
            var fl = fcntl(cf, F_GETFL, 0); fcntl(cf, F_SETFL, fl | O_NONBLOCK)
            let ip = String(cString: inet_ntoa(ca.sin_addr))
            self?.queue.async { self?.handle(cf, ip: ip) }
        } }
        source?.setCancelHandler { Darwin.close(fd) }
        source?.resume()
        running = true; notifyStatus()
    }

    func stop() { source?.cancel(); source = nil; if sockfd >= 0 { Darwin.close(sockfd); sockfd = -1 }; running = false; notifyStatus() }

    private func handle(_ fd: Int32, ip: String) {
        var buf = Data(); var tmp = [UInt8](repeating: 0, count: 65536)
        var attempts = 0
        while attempts < 100 {
            let n = read(fd, &tmp, tmp.count)
            if n > 0 { buf.append(tmp, count: n); attempts = 0 }
            else if n == 0 { break }
            else if errno == EAGAIN || errno == EWOULDBLOCK { attempts += 1; usleep(10000); continue }
            else { break }
        }
        guard buf.count > 0 else { Darwin.close(fd); return }
        let start = CFAbsoluteTimeGetCurrent()
        guard let req = Req(buf) else { sendAndClose(fd, 400, "Bad Request", "text/plain"); return }
        let fmt = parseFormat(from: req.path)
        let isFast = req.path.contains("?fast=1") || req.path.contains("&fast=1")

        switch (req.method, req.path.components(separatedBy: "?").first ?? req.path) {
        case ("GET", "/"):
            sendAndClose(fd, 200, webHTML, "text/html; charset=utf-8")
            log("GET", "/", ip, "", 0, 200)
        case ("GET", "/health"):
            sendAndClose(fd, 200, "{\"status\":\"ok\",\"address\":\"\(address):\(port)\"}", "application/json")
            log("GET", "/health", ip, "", 0, 200)
        case ("POST", "/ocr"):
            handleOCR(fd, req, ip, start, format: fmt, fast: isFast)
        case ("OPTIONS", _):
            sendAndClose(fd, 204, "", "text/plain")
        default:
            sendAndClose(fd, 404, "Not Found", "text/plain")
        }
    }

    private func parseFormat(from path: String) -> String {
        guard let q = path.firstIndex(of: "?") else { return "html" }
        let query = String(path[q...].dropFirst())
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "format" { return kv[1].lowercased() }
        }
        return "html"
    }

    private func sendAndClose(_ fd: Int32, _ status: Int, _ body: String, _ ct: String) {
        send(fd, status, body, ct); Darwin.close(fd)
    }

    private func handleOCR(_ fd: Int32, _ req: Req, _ ip: String, _ start: CFAbsoluteTime, format: String = "html", fast: Bool = false) {
        guard let b = req.boundary else { sendAndClose(fd, 400, "{\"success\":false,\"error\":\"Expected multipart\"}", "application/json"); return }
        let files = parseMultiAll(req.body, b)
        guard !files.isEmpty else { sendAndClose(fd, 400, "{\"success\":false,\"error\":\"No image\"}", "application/json"); return }

        var tmpFiles: [(String, URL)] = []
        for f in files {
            let ext = (f.name as NSString).pathExtension.lowercased()
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("ocr_\(UUID().uuidString).\(ext)")
            if (try? f.data.write(to: tmp)) != nil { tmpFiles.append((f.name, tmp)) }
        }
        guard !tmpFiles.isEmpty else { sendAndClose(fd, 500, "{\"success\":false,\"error\":\"Write failed\"}", "application/json"); return }

        var allResults: [OCRItem] = []
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            allResults = await OCRService.recognizeText(paths: tmpFiles.map { $0.1.path }, fast: fast)
            for (_, url) in tmpFiles { try? FileManager.default.removeItem(at: url) }
            sem.signal()
        }
        sem.wait()

        let el = CFAbsoluteTimeGetCurrent() - start
        let results = allResults.isEmpty ? files.map { OCRItem(filename: $0.name, text: "", error: "No result", duration: 0) } : allResults

        // Handle format selection
        if format == "txt" {
            var txt = ""
            for r in results {
                txt += "--- \(r.filename) ---\n\(r.text ?? "")\n\n"
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
            let txt = (r.text ?? "").isEmpty ? "(no text)" : r.text
            let safeTxt = txt.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            let fn = esc(r.filename)
            let err = r.error ?? ""
            if i == 0 { firstText = safeTxt }
            let status = err.isEmpty ? "" : " ⚠️"
            optRows += "<option value=\"" + safeTxt.replacingOccurrences(of: "\"", with: "&quot;") + "\" data-err=\"" + esc(err) + "\">\(i+1). \(fn)\(status)</option>\n"
        }

        let html = "<!DOCTYPE html><html><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1.0\"><title>OCR</title><style>*{box-sizing:border-box;margin:0;padding:0}body{font-family:-apple-system,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:40px 20px;display:flex;justify-content:center}.card{background:#fff;border-radius:18px;padding:32px;max-width:640px;width:100%}h1{font-size:22px;font-weight:600;margin-bottom:4px}.s{color:#6e6e73;font-size:14px;margin-bottom:20px}.top{display:flex;gap:8px;margin-bottom:16px}.top a,.top button{padding:10px 20px;border-radius:8px;font-size:13px;font-weight:500;text-decoration:none;text-align:center;flex:1;border:none;cursor:pointer}.top .sv{background:#007aff;color:#fff}.top .cl{background:#fff;color:#1d1d1f;border:1px solid #e5e5ea}select{width:100%;padding:10px 12px;border:1px solid #c7c7cc;border-radius:10px;font-size:14px;background:#fff;margin-bottom:12px;appearance:auto}.out{background:#f5f5f7;border:1px solid #e5e5ea;border-radius:10px;padding:16px;min-height:150px;font-family:Menlo,monospace;font-size:13px;white-space:pre-wrap;word-break:break-word;margin-bottom:12px}.e{color:#ff3b30;font-size:12px;margin-bottom:8px}#sv{background:none;border:none;font-size:13px;color:#007aff;cursor:pointer;float:right;margin-top:4px}</style></head><body><div class=\"card\"><h1>📄 OCR</h1><p class=\"s\">" + String(results.count) + " file(s)  •  ⏱ " + String(format: "%.1fs", el) + "</p><div class=\"top\"><button class=\"sv\" id=\"sv\">💾 Save All</button><button class=\"cl\" id=\"cp\">📋 Copy</button><a class=\"cl\" href=\"/\">✕ Clear</a></div><div id=\"err\"></div><select id=\"sel\" onchange=\"show()\">" + optRows + "</select><div class=\"out\" id=\"out\">" + firstText + "</div></div><script>var d=" + (try? String(data: JSONEncoder().encode(results), encoding: .utf8))! + ";function show(){var s=document.getElementById('sel');var i=s.selectedIndex;if(d&&i>=0&&i<d.length){document.getElementById('out').textContent=d[i].text||'(no text)';document.getElementById('err').textContent=d[i].error?'⚠️ '+d[i].error:''}}document.getElementById('sv').onclick=function(){var t='';for(var i=0;i<d.length;i++){t+='--- '+d[i].filename+' ---\\n'+(d[i].text||'(no text)')+'\\n\\n'}var a=document.createElement('a');a.href='data:text/plain;charset=utf-8,'+encodeURIComponent(t);a.download='ocr_results.txt';a.click()};document.getElementById('cp').onclick=function(){var s=document.getElementById('sel');var i=s.selectedIndex;if(d&&i>=0&&i<d.length){navigator.clipboard.writeText(d[i].text||'')}}</script></body></html>"

        sendAndClose(fd, 200, html, "text/html; charset=utf-8")
        log("POST", "/ocr", ip, "\(results.count) files", el, 200)
    }

    private func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Helpers

    private func send(_ fd: Int32, _ status: Int, _ body: String, _ ct: String) {
        let st = ["200":"OK","400":"Bad Request","404":"Not Found","500":"Internal Server Error"][String(status)] ?? ""
        let bd = body.data(using: .utf8)!
        let resp = "HTTP/1.1 \(status) \(st)\r\nContent-Type: \(ct)\r\nContent-Length: \(bd.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var data = resp.data(using: .utf8)!; data.append(bd)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private func log(_ m: String, _ p: String, _ r: String, _ f: String, _ d: TimeInterval, _ s: Int) {
        let e = ServerLogEntry(id: UUID(), method: m, path: p, remote: r, filename: f, duration: d, status: s, timestamp: Date())
        logLock.lock(); logEntries.append(e); if logEntries.count > 100 { logEntries.removeFirst(logEntries.count - 100) }; logLock.unlock()
        DispatchQueue.main.async { self.onNewLogEntry?(e) }
    }

    private func notifyStatus(error: String? = nil) {
        DispatchQueue.main.async { self.onStatusChange?(self.running, error ?? (self.running ? self.urlString : "")) }
    }

    // MARK: - Multipart

    struct UFile { let name: String; let data: Data }
    private func parseMultiAll(_ body: Data, _ boundary: String) -> [UFile] {
        let bm = "--\(boundary)".data(using: .utf8)!
        var files: [UFile] = []
        var pos = body.startIndex
        while pos < body.endIndex {
            guard let bs = body[pos...].range(of: bm) else { break }
            let ps = bs.upperBound
            var pe = body.endIndex
            if let n = body[ps...].range(of: bm) { pe = n.lowerBound }
            else if let e = body[ps...].range(of: "--\(boundary)--".data(using: .utf8)!) { pe = e.lowerBound }
            let part = body[ps..<pe]
            if let cr = part.range(of: "\r\n\r\n".data(using: .utf8)!),
               let h = String(data: part[part.startIndex..<cr.lowerBound], encoding: .utf8),
               h.contains("name=\"image\"") {
                files.append(UFile(name: extractFN(h) ?? "upload", data: Data(part[cr.upperBound...])))
            }
            pos = pe
        }
        return files
    }
    private func extractFN(_ d: String) -> String? {
        guard let r = d.range(of: "filename=\"") else { return nil }
        let a = d[r.upperBound...]; return a.firstIndex(of: "\"").map { String(a[a.startIndex..<$0]) }
    }
}

// MARK: - Models

private struct OCRResp: Codable {
    let success: Bool; let filename: String; let text: String; let error: String?
    let duration_seconds: Double; let server_duration_seconds: Double
}

private struct BatchOCRResponse: Codable {
    let results: [OCRItem]
    let server_duration_seconds: Double
}

private struct Req {
    let method: String; let path: String; let body: Data; let boundary: String?
    init?(_ data: Data) {
        // Find the end of headers first (before any binary body data)
        guard let hdrEnd = data.range(of: "\r\n\r\n".data(using: .utf8)!) else { return nil }
        let hdrData = data[data.startIndex..<hdrEnd.lowerBound]
        guard let hdrStr = String(data: hdrData, encoding: .utf8) else { return nil }
        let hL = hdrStr.components(separatedBy: "\r\n"); guard hL.count >= 1 else { return nil }
        let rL = hL[0].components(separatedBy: " "); guard rL.count >= 2 else { return nil }
        method = rL[0]; path = rL[1]
        var h: [String: String] = [:]
        for line in hL.dropFirst() { if let c = line.firstIndex(of: ":") { h[String(line[line.startIndex..<c]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces) } }
        body = Data(data[hdrEnd.upperBound...])
        if let ct = h["Content-Type"], ct.hasPrefix("multipart/form-data"), let br = ct.range(of: "boundary=") { boundary = String(ct[br.upperBound...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") } else { boundary = nil }
    }
}

private func localAddress() -> String? {
    var addr: String?; var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }; defer { freeifaddrs(ifaddr) }
    var cur = first
    while true {
        let i = cur.pointee; let f = i.ifa_addr.pointee.sa_family
        if f == AF_INET {
            let name = String(cString: i.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("ap") {
                var h = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(i.ifa_addr, socklen_t(i.ifa_addr.pointee.sa_len), &h, socklen_t(h.count), nil, 0, NI_NUMERICHOST)
                let c = String(cString: h)
                if c != "127.0.0.1" && !c.hasPrefix("169.254") { addr = c; break }
            }
        }
        guard let next = i.ifa_next else { break }; cur = next
    }
    return addr ?? "127.0.0.1"
}

private let webHTML = """
<!DOCTYPE html>
<html>
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>OCR</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:40px 20px;display:flex;justify-content:center}
.card{background:#fff;border-radius:18px;padding:32px;max-width:640px;width:100%}
h1{font-size:22px;font-weight:600;margin-bottom:4px}
.sub{color:#6e6e73;font-size:14px;margin-bottom:20px}
.zone{border:2px dashed #c7c7cc;border-radius:12px;padding:30px;text-align:center;margin-bottom:16px;cursor:pointer;background:#fff}
.zone:hover,.zone.dragover{border-color:#007aff;background:#f0f7ff}
.zone p{color:#6e6e73;font-size:14px}
.go{display:block;width:100%;padding:12px;border:none;border-radius:10px;font-size:15px;font-weight:500;cursor:pointer;text-align:center;background:#007aff;color:#fff;margin-bottom:8px}
.fast{display:flex;align-items:center;justify-content:center;gap:6px;margin-bottom:12px;font-size:12px;color:#6e6e73}
.fast input{cursor:pointer}
.st{font-size:13px;text-align:center;margin-bottom:10px;color:#6e6e73;min-height:20px}
.st.e{color:#e68a00}



</style></head>
<body>
<div class="card">
<h1>📄 OCR</h1>
<p class="sub">Upload images to extract text</p>
<div class="zone" id="dz">
<p>📁 Tap to choose or drag & drop files</p>
<p style="font-size:11px;color:#999;margin-top:4px">Supports: PNG, JPG, GIF, BMP, TIFF, HEIC, WebP</p>
<div id="cnt" style="font-size:13px;font-weight:500;margin-top:6px"></div></div>
<input type="file" id="fi" name="image" accept="image/*" multiple style="display:none">

<button class="go" id="go">Run OCR</button>
<label class="fast"><input type="checkbox" id="fast"> Fast mode (~3× faster, may miss text)</label>
<div class="st" id="st"></div>
</div>
<script>
var dz=document.getElementById('dz'),fi=document.getElementById('fi'),cnt=document.getElementById('cnt'),fl=document.getElementById('fl'),go=document.getElementById('go'),st=document.getElementById('st'),fast=document.getElementById('fast');
var sel=[];var xhr;
var exts=['png','jpg','jpeg','gif','bmp','tiff','tif','heic','webp'];
dz.onclick=function(){fi.click()};
fi.onchange=function(){sel=[];for(var i=0;i<fi.files.length;i++)sel.push(fi.files[i]);listar()};
dz.ondragover=function(e){e.preventDefault();dz.classList.add('dragover')};
dz.ondragleave=function(){dz.classList.remove('dragover')};
dz.ondrop=function(e){e.preventDefault();dz.classList.remove('dragover');sel=[];for(var i=0;i<e.dataTransfer.files.length;i++)sel.push(e.dataTransfer.files[i]);listar()};
function listar(){cnt.textContent=sel.length+' file(s)';fl.innerHTML='';var bad=0;for(var i=0;i<sel.length;i++){var n=sel[i].name;var e=n.split('.').pop().toLowerCase();if(exts.indexOf(e)<0)bad++}if(bad)st.textContent='⚠️ '+bad+' of '+sel.length+' file(s) have unsupported formats';else st.textContent='';st.className=bad?'st e':'st'}
go.onclick=function(){if(!sel.length){st.className='st e';st.textContent='Select files first';return}st.className='st';st.textContent='Processing '+sel.length+' file(s)...';var t0=Date.now();var timer=setInterval(function(){var e=((Date.now()-t0)/1000).toFixed(1);st.textContent='⏱ '+e+'s  •  '+sel.length+' file(s)'},100);var fd=new FormData();for(var i=0;i<sel.length;i++)fd.append('image',sel[i]);var url='/ocr'+(fast.checked?'?fast=1':'');xhr=new XMLHttpRequest();xhr.open('POST',url,true);xhr.onload=function(){clearInterval(timer);if(xhr.status==200){document.write(xhr.responseText)}else{st.className='st e';st.textContent='Error'}};xhr.onerror=function(){clearInterval(timer);st.className='st e';st.textContent='Connection error'};xhr.send(fd)};
</script>
</body></html>
"""








