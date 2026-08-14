import Foundation

// MARK: - Shared server parsing / validation (unit-testable)

/// One uploaded file from a multipart body.
public struct UploadedFile: Codable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// Result of parsing a multipart body: files plus an optional `options` JSON field.
public struct ParsedUpload: Codable, Sendable {
    public var files: [UploadedFile] = []
    public var optionsJSON: String?

    public init() {}
}

public enum ServerSupport {

    /// Split a multipart/form-data body by boundary, collecting `name="image"`
    /// file parts and a `name="options"` text part.
    public static func parseMultipart(_ body: Data, boundary: String) -> ParsedUpload {
        let bm = "--\(boundary)".data(using: .utf8)!
        var parsed = ParsedUpload()
        var pos = body.startIndex
        while pos < body.endIndex {
            guard let bs = body[pos...].range(of: bm) else { break }
            let ps = bs.upperBound
            var pe = body.endIndex
            if let n = body[ps...].range(of: bm) { pe = n.lowerBound }
            else if let e = body[ps...].range(of: "--\(boundary)--".data(using: .utf8)!) { pe = e.lowerBound }
            let part = body[ps..<pe]
            if let cr = part.range(of: "\r\n\r\n".data(using: .utf8)!),
               let h = String(data: part[part.startIndex..<cr.lowerBound], encoding: .utf8) {
                let raw = Data(part[cr.upperBound...])
                let content: Data
                if raw.count >= 2, raw[raw.count - 2] == 13, raw[raw.count - 1] == 10 {
                    content = raw.subdata(in: 0..<(raw.count - 2))
                } else {
                    content = raw
                }
                if h.contains("name=\"image\"") {
                    parsed.files.append(UploadedFile(name: extractFilename(from: h) ?? "upload", data: content))
                } else if h.contains("name=\"options\"") {
                    parsed.optionsJSON = String(data: content, encoding: .utf8)
                }
            }
            pos = pe
        }
        return parsed
    }

    public static func extractFilename(from headers: String) -> String? {
        guard let r = headers.range(of: "filename=\"") else { return nil }
        let a = headers[r.upperBound...]
        return a.firstIndex(of: "\"").map { String(a[a.startIndex..<$0]) }
    }

    /// Verify uploaded bytes against their claimed extension using magic bytes.
    public static func hasValidContent(_ data: Data, ext: String) -> Bool {
        guard data.count >= 12 else { return false }
        let prefix = [UInt8](data.prefix(16))
        switch ext {
        case "png":
            return Array(prefix.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        case "jpg", "jpeg":
            return Array(prefix.prefix(3)) == [0xFF, 0xD8, 0xFF]
        case "gif":
            return Array(prefix.prefix(4)) == Array("GIF8".utf8)
        case "bmp":
            return Array(prefix.prefix(2)) == Array("BM".utf8)
        case "tif", "tiff":
            let header = Array(prefix.prefix(4))
            return header == [0x49, 0x49, 0x2A, 0x00] || header == [0x4D, 0x4D, 0x00, 0x2A]
        case "heic":
            guard prefix.count >= 12, Array(prefix[4..<8]) == Array("ftyp".utf8) else { return false }
            let brand = String(decoding: prefix[8..<12], as: UTF8.self)
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1"].contains(brand)
        case "webp":
            return Array(prefix.prefix(4)) == Array("RIFF".utf8)
                && data.count >= 12
                && [UInt8](data[data.startIndex + 8 ..< data.startIndex + 12]) == Array("WEBP".utf8)
        case "pdf":
            return data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
        default:
            return false
        }
    }

    /// HTML-escape a string for embedding in an HTML page.
    public static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Extract the `format` query parameter from a request path (default "html").
    public static func parseFormat(from path: String) -> String {
        guard let q = path.firstIndex(of: "?") else { return "html" }
        let query = String(path[q...].dropFirst())
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2, kv[0] == "format" { return kv[1].lowercased() }
        }
        return "html"
    }

    /// Map a temp UUID filename back to the original uploaded name, preserving
    /// a "(page N)" suffix for multi-page PDFs.
    public static func mapFilename(_ filename: String, originalByTempName: [String: String]) -> String {
        if let range = filename.range(of: " (page ") {
            let base = String(filename[..<range.lowerBound])
            guard let orig = originalByTempName[base] else { return filename }
            return orig + String(filename[range.lowerBound...])
        }
        return originalByTempName[filename] ?? filename
    }
}

// MARK: - Server models

public struct BatchOCRResponse: Codable {
    public let results: [OCRItem]
    public let server_duration_seconds: Double

    public init(results: [OCRItem], server_duration_seconds: Double) {
        self.results = results
        self.server_duration_seconds = server_duration_seconds
    }
}

/// Agent API request options (multipart field `options`). Decoded with
/// `.convertFromSnakeCase`, so `confidence_threshold` and `custom_words` work.
public struct AgentOptions: Codable {
    public let mode: String?
    public let languages: [String]?
    public let customWords: [String]?
    public let confidenceThreshold: Double?
    public let structured: Bool?
    public let enhanceSmallText: Bool?

    public init(mode: String?, languages: [String]?, customWords: [String]?, confidenceThreshold: Double?, structured: Bool?, enhanceSmallText: Bool?) {
        self.mode = mode
        self.languages = languages
        self.customWords = customWords
        self.confidenceThreshold = confidenceThreshold
        self.structured = structured
        self.enhanceSmallText = enhanceSmallText
    }
}

/// Structured agent API response: per-file blocks + confidence.
public struct StructuredBatchResponse: Codable {
    public let results: [OCRStructuredItem]
    public let server_duration_seconds: Double
    public let processing_ms: Double
    public let strategy: String
    public let engine: String
    public let engine_revision: String
    public let engine_api: String
    public let language: String

    public init(results: [OCRStructuredItem], server_duration_seconds: Double, processing_ms: Double, strategy: String, engine: String, engine_revision: String, engine_api: String, language: String) {
        self.results = results
        self.server_duration_seconds = server_duration_seconds
        self.processing_ms = processing_ms
        self.strategy = strategy
        self.engine = engine
        self.engine_revision = engine_revision
        self.engine_api = engine_api
        self.language = language
    }
}

/// Parsed HTTP request line + headers + body.
public struct HTTPRequest {
    public let method: String
    public let path: String
    public let body: Data
    public let boundary: String?
    public let contentLength: Int?

    public init?(data: Data) {
        guard let hdrEnd = data.range(of: "\r\n\r\n".data(using: .utf8)!) else { return nil }
        let hdrData = data[data.startIndex..<hdrEnd.lowerBound]
        guard let hdrStr = String(data: hdrData, encoding: .utf8) else { return nil }
        let hL = hdrStr.components(separatedBy: "\r\n")
        guard hL.count >= 1 else { return nil }
        let rL = hL[0].components(separatedBy: " ")
        guard rL.count >= 2 else { return nil }
        method = rL[0]
        path = rL[1]
        var h: [String: String] = [:]
        for line in hL.dropFirst() {
            if let c = line.firstIndex(of: ":") {
                let key = String(line[line.startIndex..<c]).trimmingCharacters(in: .whitespaces).lowercased()
                h[key] = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        contentLength = h["content-length"].flatMap(Int.init)
        let payload = Data(data[hdrEnd.upperBound...])
        if let length = contentLength, length >= 0 {
            body = Data(payload.prefix(length))
        } else {
            body = payload
        }
        if let ct = h["content-type"], ct.lowercased().hasPrefix("multipart/form-data"), let br = ct.range(of: "boundary=", options: .caseInsensitive) {
            boundary = String(ct[br.upperBound...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "").removingPercentEncoding ?? ""
        } else {
            boundary = nil
        }
    }
}
