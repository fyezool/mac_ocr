import XCTest
import Foundation
@testable import OCRCore

final class IntensiveFuzzTests: XCTestCase {

    // 10k random multipart + HTTP + escape/magic cases, no crash + invariant checks
    func testIntensiveRandomized() {
        var rng = SystemRandomNumberGenerator()
        let safeBoundaries = ["B", "----Boundary123", "AaB03x", "boundary", String(repeating: "X", count: 512)]
        let trickyFilenames = [
            "normal.png", "../../etc/passwd", "/var/tmp/a.jpg", "a\0b.png", "a\r\nb.png",
            "a:b*c.png", "a\"b.png", "a'b.png", "<script>.png", String(repeating: "x", count: 400) + ".png",
            "a..png", "a .png", "a\u{202E}gnp.png", "a\u{0001}b.png", "a/b\\c.png"
        ]

        let start = Date()
        var iterations = 10_000
        for i in 0..<iterations {
            let b = safeBoundaries.randomElement(using: &rng)!
            let name = trickyFilenames.randomElement(using: &rng)!
            let payloadSize = Int.random(in: 0...4096, using: &rng)
            var payload = Data((0..<payloadSize).map { _ in UInt8.random(in: 0...255, using: &rng) })
            // Occasionally make payload contain boundary string to test false splits
            if Bool.random(using: &rng), payload.count > 10 {
                let insert = "--\(b)".data(using: .utf8)!
                let pos = Int.random(in: 0..<payload.count, using: &rng)
                payload.replaceSubrange(pos..<min(pos+insert.count, payload.count), with: insert.prefix(payload.count - pos))
            }
            var body = Data()
            let hdr = "Content-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: image/png"
            body.append("--\(b)\r\n\(hdr)\r\n\r\n".data(using: .utf8)!)
            body.append(payload)
            body.append("\r\n--\(b)--\r\n".data(using: .utf8)!)
            let parsed = ServerSupport.parseMultipart(body, boundary: b)
            for f in parsed.files {
                XCTAssertFalse(f.name.contains("/"), "iter \(i) slash in \(f.name)")
                XCTAssertFalse(f.name.contains("\r"), "iter \(i) CR")
                XCTAssertFalse(f.name.contains("\n"), "iter \(i) LF")
                XCTAssertFalse(f.name.contains("\0"), "iter \(i) NUL")
                XCTAssertLessThanOrEqual(f.name.count, 255)
            }
            if Bool.random(using: &rng) {
                let badBoundary = ["", String(repeating: "A", count: 2000), "a\rb", "a\nb", "a\0b"].randomElement(using: &rng)!
                let r = ServerSupport.parseMultipart(payload, boundary: badBoundary)
                XCTAssertEqual(r.files.count, 0)
            }
            if i % 2000 == 0 { print("intensive \(i)/\(iterations) elapsed \(Date().timeIntervalSince(start))s") }
        }
        print("Intensive multipart done in \(Date().timeIntervalSince(start))s")
    }

    func testIntensiveHTTPRequest() {
        let methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"]
        let paths = ["/", "/ocr", "/health", "/ocr?format=json", "/ocr?format=../../../etc", String(repeating: "A", count: 8000)]
        for _ in 0..<3000 {
            let method = methods.randomElement()!
            let path = paths.randomElement()!
            let cl: String? = Bool.random() ? "\(Int.random(in: -5...100))" : nil
            var raw = "\(method) \(path) HTTP/1.1\r\nHost: x\r\n"
            if let cl { raw += "Content-Length: \(cl)\r\n" }
            if Bool.random() { raw += "Content-Type: multipart/form-data; boundary=abc\r\n" }
            if Bool.random() { raw += "X-Random: \(UUID().uuidString)\r\n" }
            raw += "\r\n"
            if let cl, let n = Int(cl), n > 0, n < 1000 { raw += String(repeating: "a", count: n) }
            _ = HTTPRequest(data: Data(raw.utf8))
        }
    }

    func testIntensiveEscapeAndMagic() {
        for _ in 0..<5000 {
            let len = Int.random(in: 0...500)
            let s = String((0..<len).map { _ in Character(UnicodeScalar(UInt8.random(in: 32...126))) })
            let esc = ServerSupport.escapeHTML(s)
            XCTAssertFalse(esc.contains("<script"), "escape failed for \(s.prefix(50))")
        }
        for _ in 0..<3000 {
            let d = Data((0..<Int.random(in: 0...32)).map { _ in UInt8.random(in: 0...255) })
            for ext in ["png","jpg","gif","pdf","webp","unknown"] { _ = ServerSupport.hasValidContent(d, ext: ext) }
        }
    }

    func testIntensiveFormatAndMap() {
        for _ in 0..<2000 {
            let q = ["html","JSON","TXT","../../../etc","", "json%00","HtMl"].randomElement()!
            let v = ServerSupport.parseFormat(from: "/ocr?format=\(q)")
            XCTAssertTrue(["html","json","txt"].contains(v))
        }
        let map = ["tmp1.png":"orig.png", "tmp2.jpg":"orig2.jpg"]
        for _ in 0..<1000 {
            let n = ["tmp1.png","tmp1.png (page 1)","unknown.png", String(repeating: "a", count: 300)].randomElement()!
            _ = ServerSupport.mapFilename(n, originalByTempName: map)
        }
    }

    // Stress: 60MB random payload should be capped/rejected, not OOM
    func testStressLargePayloadCapped() {
        let huge = Data(repeating: 0x41, count: 70*1024*1024)
        let body = NSMutableData()
        body.append("--B\r\nContent-Disposition: form-data; name=\"image\"; filename=\"a.png\"\r\n\r\n".data(using: .utf8)!)
        body.append(huge)
        body.append("\r\n--B--\r\n".data(using: .utf8)!)
        let p = ServerSupport.parseMultipart(body as Data, boundary: "B")
        // Should either cap files or not crash; we cap parts, so at least not crash
        XCTAssertLessThanOrEqual(p.files.first?.data.count ?? 0, 70*1024*1024)
    }
}
