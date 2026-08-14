import XCTest
import Foundation
import OCRCore

final class ServerSupportTests: XCTestCase {

    private func multipartBody(boundary: String, parts: [(headers: String, content: Data)]) -> Data {
        var body = Data()
        for p in parts {
            body.append("--\(boundary)\r\n\(p.headers)\r\n\r\n".data(using: .utf8)!)
            body.append(p.content)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }

    // MARK: - Multipart parsing

    func testParseMultipartImageAndOptions() {
        let boundary = "----TEST"
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]
        let pngData = Data(png)
        let body = multipartBody(boundary: boundary, parts: [
            ("Content-Disposition: form-data; name=\"image\"; filename=\"a.png\"\r\nContent-Type: image/png", pngData),
            ("Content-Disposition: form-data; name=\"options\"", Data("{\"mode\":\"fast\",\"structured\":true}".utf8)),
        ])
        let parsed = ServerSupport.parseMultipart(body, boundary: boundary)
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files[0].name, "a.png")
        XCTAssertEqual(parsed.files[0].data, pngData)
        XCTAssertEqual(parsed.optionsJSON, "{\"mode\":\"fast\",\"structured\":true}")
    }

    func testParseMultipartTrimsCRLF() {
        let boundary = "b"
        let body = multipartBody(boundary: boundary, parts: [
            ("Content-Disposition: form-data; name=\"image\"; filename=\"x.png\"", Data("abc".utf8)),
        ])
        let parsed = ServerSupport.parseMultipart(body, boundary: boundary)
        XCTAssertEqual(parsed.files[0].data, Data("abc".utf8))
    }

    func testExtractFilename() {
        XCTAssertEqual(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"photo.png\""), "photo.png")
        XCTAssertNil(ServerSupport.extractFilename(from: "no filename here"))
    }

    // MARK: - Magic bytes

    func testMagicBytes() {
        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        png.append(Data(repeating: 1, count: 8))
        XCTAssertTrue(ServerSupport.hasValidContent(png, ext: "png"))
        XCTAssertFalse(ServerSupport.hasValidContent(png, ext: "jpg"))

        XCTAssertTrue(ServerSupport.hasValidContent(Data([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0]), ext: "jpg"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data(Array("GIF89a1234567".utf8)), ext: "gif"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data(Array("BM1234567890".utf8)), ext: "bmp"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data([0x49, 0x49, 0x2A, 0x00, 1, 2, 3, 4, 5, 6, 7, 8]), ext: "tiff"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data([0x4D, 0x4D, 0x00, 0x2A, 1, 2, 3, 4, 5, 6, 7, 8]), ext: "tif"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data(Array("RIFFxxxxWEBP yyy".utf8)), ext: "webp"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data(Array("0000ftypheicmmmmmmmm".utf8)), ext: "heic"))
        XCTAssertFalse(ServerSupport.hasValidContent(Data(Array("0000ftypavifmmmmmmmm".utf8)), ext: "heic"))
        XCTAssertTrue(ServerSupport.hasValidContent(Data("junk\n%PDF-1.7\n%...".utf8), ext: "pdf"))
        XCTAssertFalse(ServerSupport.hasValidContent(Data("not a pdf at all".utf8), ext: "pdf"))
        XCTAssertFalse(ServerSupport.hasValidContent(Data("short".utf8), ext: "png"))
    }

    // MARK: - Filename mapping / escaping / format

    func testMapFilename() {
        let map = ["ocr_ABC.png": "photo.png", "ocr_XYZ.pdf": "doc.pdf"]
        XCTAssertEqual(ServerSupport.mapFilename("ocr_ABC.png", originalByTempName: map), "photo.png")
        XCTAssertEqual(ServerSupport.mapFilename("ocr_XYZ.pdf (page 2)", originalByTempName: map), "doc.pdf (page 2)")
        XCTAssertEqual(ServerSupport.mapFilename("unknown.png", originalByTempName: map), "unknown.png")
    }

    func testEscapeHTML() {
        XCTAssertEqual(ServerSupport.escapeHTML("<script>&\"x\""), "&lt;script&gt;&amp;&quot;x&quot;")
    }

    func testParseFormat() {
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr"), "html")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format=json"), "json")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?fast=1&format=txt"), "txt")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format"), "html")
    }

    // MARK: - HTTP request parsing

    func testHTTPRequestParse() {
        let raw = "POST /ocr?format=json HTTP/1.1\r\nHost: x\r\nContent-Type: multipart/form-data; boundary=abc\r\nContent-Length: 5\r\n\r\nhello"
        let req = HTTPRequest(data: Data(raw.utf8))
        XCTAssertNotNil(req)
        XCTAssertEqual(req?.method, "POST")
        XCTAssertEqual(req?.path, "/ocr?format=json")
        XCTAssertEqual(req?.boundary, "abc")
        XCTAssertEqual(req?.contentLength, 5)
        XCTAssertEqual(req?.body, Data("hello".utf8))
    }

    func testHTTPRequestRejectsGarbage() {
        XCTAssertNil(HTTPRequest(data: Data("no-request".utf8)))
    }
}
