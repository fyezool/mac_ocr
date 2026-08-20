import XCTest
import Foundation
@testable import OCRCore

final class SecurityHardeningTests: XCTestCase {

    private func multipart(boundary: String, parts: [(String, Data)]) -> Data {
        var d = Data()
        for (hdr, content) in parts {
            d.append("--\(boundary)\r\n\(hdr)\r\n\r\n".data(using: .utf8)!)
            d.append(content)
            d.append("\r\n".data(using: .utf8)!)
        }
        d.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return d
    }

    // MARK: - Escape

    func testEscapeHTMLCoversSingleQuote() {
        XCTAssertEqual(ServerSupport.escapeHTML("'"), "&#39;")
        XCTAssertEqual(ServerSupport.escapeHTML("<'&\">"), "&lt;&#39;&amp;&quot;&gt;")
    }

    // MARK: - Filename sanitization

    func testExtractFilenameStripsTraversal() {
        XCTAssertEqual(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"../../etc/passwd.png\""), "passwd.png")
        XCTAssertEqual(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"/var/tmp/a.jpg\""), "a.jpg")
    }

    func testExtractFilenameStripsCRLFAndNull() {
        XCTAssertEqual(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"a.png\r\nInjected: evil\""), "a.pngInjected_ evil")
        XCTAssertNil(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"\r\n\""))
        XCTAssertEqual(ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"a\0b.png\""), "ab.png")
    }

    func testExtractFilenameWhitelistsChars() {
        // Colon and other non-whitelisted become _
        let name = ServerSupport.extractFilename(from: "Content-Disposition: form-data; name=\"image\"; filename=\"a:b*c.png\"")
        XCTAssertEqual(name, "a_b_c.png")
    }

    // MARK: - Multipart boundaries

    func testParseMultipartRejectsBadBoundary() {
        XCTAssertEqual(ServerSupport.parseMultipart(Data("hi".utf8), boundary: "").files.count, 0)
        XCTAssertEqual(ServerSupport.parseMultipart(Data("hi".utf8), boundary: String(repeating: "A", count: 1025)).files.count, 0)
        XCTAssertEqual(ServerSupport.parseMultipart(Data("hi".utf8), boundary: "a\rb").files.count, 0)
        XCTAssertEqual(ServerSupport.parseMultipart(Data("hi".utf8), boundary: "a\nb").files.count, 0)
        XCTAssertEqual(ServerSupport.parseMultipart(Data("hi".utf8), boundary: "a\0b").files.count, 0)
    }

    func testParseMultipartCapsPartsAndOptions() {
        var many: [(String, Data)] = []
        for i in 0..<40 {
            many.append(("Content-Disposition: form-data; name=\"image\"; filename=\"f\(i).png\"\r\nContent-Type: image/png", Data([0x89,0x50,0x4E,0x47,0x0D,0x0A,0x1A,0x0A] + Array(repeating: 0, count:20))))
        }
        let parsed = ServerSupport.parseMultipart(multipart(boundary: "B", parts: many), boundary: "B")
        XCTAssertEqual(parsed.files.count, 32, "should cap at 32 parts")

        let huge = String(repeating: "a", count: 32*1024)
        let body = multipart(boundary: "B", parts: [("Content-Disposition: form-data; name=\"options\"", Data(huge.utf8))])
        let p2 = ServerSupport.parseMultipart(body, boundary: "B")
        XCTAssertLessThanOrEqual(p2.optionsJSON?.count ?? 0, 16*1024)
    }

    // MARK: - hasValidContent edge

    func testHasValidContentPDFShort() {
        XCTAssertTrue(ServerSupport.hasValidContent(Data("%PDF-".utf8), ext: "pdf"))
        XCTAssertFalse(ServerSupport.hasValidContent(Data("%PD".utf8), ext: "pdf"))
        XCTAssertFalse(ServerSupport.hasValidContent(Data("short".utf8), ext: "png"))
    }

    // MARK: - parseFormat whitelist

    func testParseFormatWhitelist() {
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format=../../../etc"), "html")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format=JSON"), "json")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format=txt"), "txt")
        XCTAssertEqual(ServerSupport.parseFormat(from: "/ocr?format=HTML"), "html")
    }

    // MARK: - HTTPRequest duplicate / negative CL

    func testHTTPRequestRejectsDuplicateContentLength() {
        let raw = "POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nContent-Length: 999\r\n\r\nhello"
        XCTAssertNil(HTTPRequest(data: Data(raw.utf8)))
    }

    func testHTTPRequestRejectsNegativeContentLength() {
        let raw = "POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: -5\r\n\r\nhello"
        XCTAssertNil(HTTPRequest(data: Data(raw.utf8)))
    }

    func testHTTPRequestTruncatesBodyToCL() {
        let raw = "POST /ocr HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello world"
        let req = HTTPRequest(data: Data(raw.utf8))
        XCTAssertEqual(req?.body, Data("hello".utf8))
        XCTAssertEqual(req?.contentLength, 5)
    }
}
