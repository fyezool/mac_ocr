import XCTest
import Foundation
import AppKit
import OCRCore

/// Spins up the real socket `ServerManager` and drives it with actual HTTP
/// requests — the closest thing to a black-box server test we can run in SPM.
final class ServerIntegrationTests: XCTestCase {

    private func randomPort() -> UInt16 {
        UInt16.random(in: 20000...49000)
    }

    private func startServer() async throws -> (server: ServerManager, url: URL) {
        let srv = ServerManager()
        srv.start(port: randomPort())
        for _ in 0..<100 where !srv.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(srv.isRunning, "server failed to start")
        guard let url = URL(string: srv.urlString) else {
            srv.stop()
            XCTFail("bad url \(srv.urlString)")
            throw URLError(.badURL)
        }
        return (srv, url)
    }

    private func stopServer(_ srv: ServerManager) async {
        srv.stop()
        for _ in 0..<50 where srv.isRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makePNG() -> Data? {
        let w = 320, h = 80
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 36),
            .foregroundColor: NSColor.black,
        ]
        ("Integration Test 2026" as NSString).draw(at: CGPoint(x: 12, y: 24), withAttributes: attrs)
        guard let img = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    private func multipartBody(boundary: String, files: [(name: String, data: Data)], options: String?) -> Data {
        var body = Data()
        for f in files {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(f.name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(f.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        if let options {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"options\"\r\n\r\n".data(using: .utf8)!)
            body.append(options.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    private func post(_ baseURL: URL, files: [(name: String, data: Data)], options: String?, format: String?) async throws -> (status: Int, data: Data) {
        let boundary = "----test-\(UUID().uuidString)"
        var components = URLComponents(url: baseURL.appendingPathComponent("ocr"), resolvingAgainstBaseURL: false)!
        if let format { components.queryItems = [URLQueryItem(name: "format", value: format)] }
        var req = URLRequest(url: components.url!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = multipartBody(boundary: boundary, files: files, options: options)
        req.timeoutInterval = 60
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    func testServerPlainRoundTrip() async throws {
        guard let png = makePNG() else { return XCTFail("could not make PNG") }
        let (srv, url) = try await startServer()
        defer { srv.stop() }

        let (status, data) = try await post(url, files: [("test.png", png)], options: nil, format: "json")
        XCTAssertEqual(status, 200)
        let resp = try JSONDecoder().decode(BatchOCRResponse.self, from: data)
        XCTAssertEqual(resp.results.count, 1)
        XCTAssertEqual(resp.results[0].filename, "test.png")
    }

    func testServerStructuredRoundTrip() async throws {
        guard let png = makePNG() else { return XCTFail("could not make PNG") }
        let (srv, url) = try await startServer()
        defer { srv.stop() }

        let (status, data) = try await post(url, files: [("test.png", png)], options: "{\"mode\":\"accurate\",\"structured\":true}", format: nil)
        XCTAssertEqual(status, 200)
        let resp = try JSONDecoder().decode(StructuredBatchResponse.self, from: data)
        XCTAssertFalse(resp.results.isEmpty)
        XCTAssertEqual(resp.results[0].filename, "test.png")
        XCTAssertEqual(resp.strategy, "accurate")
        XCTAssertFalse(resp.engine_revision.isEmpty)
        XCTAssertEqual(resp.engine_api, "RecognizeTextRequest")
    }

    func testServerAdaptiveRoundTrip() async throws {
        guard let png = makePNG() else { return XCTFail("could not make PNG") }
        let (srv, url) = try await startServer()
        defer { srv.stop() }

        let (status, data) = try await post(url, files: [("test.png", png)], options: "{\"mode\":\"adaptive\"}", format: nil)
        XCTAssertEqual(status, 200)
        let resp = try JSONDecoder().decode(StructuredBatchResponse.self, from: data)
        XCTAssertEqual(resp.strategy, "adaptive")
        XCTAssertFalse(resp.results.isEmpty)
    }

    func testServerRejectsBadMagicBytes() async throws {
        let fake: Data = Data("this is not an image, just plain text bytes padding".utf8)
        let (srv, url) = try await startServer()
        defer { srv.stop() }

        let (status, data) = try await post(url, files: [("fake.png", fake)], options: nil, format: "json")
        XCTAssertEqual(status, 400)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Invalid file content") == true)
    }

    func testServerHealth() async throws {
        let (srv, url) = try await startServer()
        defer { srv.stop() }

        let (data, resp) = try await URLSession.shared.data(from: url.appendingPathComponent("health"))
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("\"status\":\"ok\"") == true)
    }
}
