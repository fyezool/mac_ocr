import Foundation
import Vision
import PDFKit
import ImageIO

// MARK: - OCR Result Model

public struct OCRItem: Codable, Sendable {
    public let filename: String
    public let text: String
    public let error: String?
    public let duration: TimeInterval

    public init(filename: String, text: String, error: String?, duration: TimeInterval) {
        self.filename = filename
        self.text = text
        self.error = error
        self.duration = duration
    }
}

/// A result that also carries the mean recognition confidence of the text
/// observations, used to drive the adaptive fast→accurate routing.
public struct OCRDetailedItem: Codable, Sendable {
    public let filename: String
    public let text: String
    public let error: String?
    public let duration: TimeInterval
    public let meanConfidence: Double?

    public init(filename: String, text: String, error: String?, duration: TimeInterval, meanConfidence: Double?) {
        self.filename = filename
        self.text = text
        self.error = error
        self.duration = duration
        self.meanConfidence = meanConfidence
    }
}

// MARK: - OCR Configuration

public struct OCRConfiguration: Sendable {
    /// Recognition level — .accurate (quality) or .fast (speed)
    public var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate

    /// Explicit recognition languages (order = priority)
    public var recognitionLanguages: [Locale.Language] = [
        Locale.Language(identifier: "en-US"),
    ]

    /// Enable language correction (dictionary-based post-processing)
    public var usesLanguageCorrection = true

    /// Domain-specific words the model should prioritize
    public var customWords: [String] = []

    /// Maximum concurrent images processed at once.
    /// Apple Silicon ANE benefits from moderate parallelism (4–6).
    public var maxConcurrency: Int = 4

    /// Whether to automatically detect the dominant language per image.
    /// When false, uses `recognitionLanguages` exclusively (faster, more consistent).
    public var automaticallyDetectsLanguage = false

    /// Force the legacy `RecognizeTextRequest` path even on macOS 26, where the
    /// accurate path would otherwise use `RecognizeDocumentsRequest`. Lets
    /// benchmark comparisons stay on the same recognition engine across OSes.
    public var forceLegacyEngine = false

    public static let `default` = OCRConfiguration()

    public init(
        recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate,
        recognitionLanguages: [Locale.Language] = [Locale.Language(identifier: "en-US")],
        usesLanguageCorrection: Bool = true,
        customWords: [String] = [],
        maxConcurrency: Int = 4,
        automaticallyDetectsLanguage: Bool = false,
        forceLegacyEngine: Bool = false
    ) {
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.maxConcurrency = maxConcurrency
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.forceLegacyEngine = forceLegacyEngine
    }
}

// MARK: - OCR Service

public enum OCRService {

    /// Defensive ceiling for concurrent Vision requests. Kept high (16) so the
    /// benchmark can sweep concurrency and find the real optimum on the target
    /// device; the app keeps its own conservative band. The "32MB ANE SRAM"
    /// rule is an empirical safety heuristic, not an Apple hardware guarantee.
    private static let concurrencyCeiling = 16

    /// Stability limit for single-file memory ingestion (MAX_FILE_SIZE_INGEST).
    static let maxIngestBytes: Int64 = 250 * 1024 * 1024

    /// Cap on pages processed per PDF, bounding CPU/ANE work on hostile or
    /// degenerate files (e.g. decompression-bomb style PDFs with huge page counts).
    static let maxPDFPages = 200

    /// Clamp a requested concurrency into the safe band [1, 16].
    public static func clampedConcurrency(_ requested: Int) -> Int {
        min(max(requested, 1), concurrencyCeiling)
    }

    /// The current Vision text-recognition request revision (underlying
    /// implementation version), e.g. "revision3". Record it in benchmark output
    /// so results stay comparable across macOS updates.
    public static func visionRevisionLabel() -> String {
        String(describing: RecognizeTextRequest().revision)
    }

    /// Downscale an image so its longest side is at most `maxPixelSide` pixels,
    /// returning re-encoded PNG data. Returns nil for non-image files or
    /// decodable failures. Used by the resolution sweep.
    public static func resizedImageData(at url: URL, maxPixelSide: Int) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixelSide,
              ] as CFDictionary)
        else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Run Vision text recognition on every image at `paths`.
    /// Processes images in parallel using the ANE (Apple Neural Engine) via
    /// Core ML, which is the backend Apple's Vision framework uses internally.
    ///
    /// - Parameter paths: Image file paths
    /// - Parameter fast: Shortcut for `.fast` recognition level
    /// - Parameter config: Full configuration (takes precedence over `fast`)
    /// - Returns: Results in the same order as `paths`.
    public static func recognizeText(
        paths: [String],
        fast: Bool = false,
        config: OCRConfiguration = .default
    ) async -> [OCRItem] {
        var cfg = config
        if fast { cfg.recognitionLevel = .fast }
        let maxConcurrent = min(paths.count, Self.clampedConcurrency(cfg.maxConcurrency))

        return await withTaskGroup(of: (Int, [OCRItem]).self) { group in
            var index = 0
            var slots = [[OCRItem]?](repeating: nil, count: paths.count)

            for i in 0..<maxConcurrent {
                let c = cfg
                group.addTask { await processPath(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

            for await (idx, items) in group {
                slots[idx] = items
                if index < paths.count {
                    let nextIdx = index
                    let c = cfg
                    group.addTask { await processPath(paths[nextIdx], index: nextIdx, config: c) }
                    index += 1
                }
            }

            return slots.compactMap { $0 }.flatMap { $0 }
        }
    }

    /// Sequential version — processes one file at a time. Useful as a
    /// baseline for benchmarking the speedup from parallel processing.
    public static func recognizeTextSequential(paths: [String], fast: Bool = false) async -> [OCRItem] {
        let config = fast ? { var c = OCRConfiguration.default; c.recognitionLevel = .fast; return c }() : .default
        var results: [OCRItem] = []
        for (i, path) in paths.enumerated() {
            let (_, items) = await processPath(path, index: i, config: config)
            results.append(contentsOf: items)
        }
        return results
    }

    /// Detailed pass used by the adaptive benchmark: runs the configured
    /// recognition level and also reports the mean confidence of the recognized
    /// text observations. Unlike `recognizeText`, this always uses the
    /// `RecognizeTextRequest` path so per-observation confidence is available
    /// (the macOS 26 `RecognizeDocumentsRequest` path doesn't expose it).
    public static func recognizeTextDetailed(paths: [String], config: OCRConfiguration = .default) async -> [OCRDetailedItem] {
        let maxConcurrent = min(paths.count, Self.clampedConcurrency(config.maxConcurrency))
        return await withTaskGroup(of: (Int, [OCRDetailedItem]).self) { group in
            var index = 0
            var slots = [[OCRDetailedItem]?](repeating: nil, count: paths.count)

            for i in 0..<maxConcurrent {
                let c = config
                group.addTask { await processPathDetailed(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

            for await (idx, items) in group {
                slots[idx] = items
                if index < paths.count {
                    let nextIdx = index
                    let c = config
                    group.addTask { await processPathDetailed(paths[nextIdx], index: nextIdx, config: c) }
                    index += 1
                }
            }
            return slots.compactMap { $0 }.flatMap { $0 }
        }
    }

    private static func processPathDetailed(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, [OCRDetailedItem]) {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            return (index, await processPDFDetailed(url, config: config))
        }
        let single = await processOneDetailed(path, index: index, config: config)
        return (index, [single.1])
    }

    private static func processOneDetailed(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, OCRDetailedItem) {
        let url = URL(fileURLWithPath: path)
        let start = CFAbsoluteTimeGetCurrent()

        let imageData: Data
        do {
            imageData = try autoreleasepool { try Data(contentsOf: url) }
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRDetailedItem(filename: url.lastPathComponent, text: "", error: "Could not load image", duration: elapsed, meanConfidence: nil))
        }

        do {
            let (text, confidence) = try await recognizeTextWithConfidence(in: imageData, config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRDetailedItem(filename: url.lastPathComponent, text: text, error: nil, duration: elapsed, meanConfidence: confidence))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRDetailedItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed, meanConfidence: nil))
        }
    }

    /// Probe path: always uses `RecognizeTextRequest` and returns the mean
    /// confidence of non-empty observations alongside the reconstructed text.
    private static func recognizeTextWithConfidence(in data: Data, config: OCRConfiguration) async throws -> (String, Double?) {
        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage
        if !config.recognitionLanguages.isEmpty { request.recognitionLanguages = config.recognitionLanguages }
        if !config.customWords.isEmpty { request.customWords = config.customWords }
        let observations = try await request.perform(on: data)
        let result = reconstructParagraphsWithConfidence(from: observations)
        return (result.text, result.meanConfidence)
    }

    /// Dispatch a single path to image or PDF processing based on extension.
    private static func processPath(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, [OCRItem]) {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            return (index, await processPDF(url, config: config))
        }
        let single = await processOne(path, index: index, config: config)
        return (index, [single.1])
    }

    private static func processOne(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, OCRItem) {
        let url = URL(fileURLWithPath: path)
        let start = CFAbsoluteTimeGetCurrent()

        let imageData: Data
        do {
            imageData = try autoreleasepool { try Data(contentsOf: url) }
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: "Could not load image", duration: elapsed))
        }

        do {
            let text = try await recognizeText(in: imageData, config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: text, error: nil, duration: elapsed))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed))
        }
    }

    /// Recognize text from image data using the best available Vision API.
    /// macOS 26+ uses `RecognizeDocumentsRequest` (native paragraph/table/list
    /// layout); older systems use `RecognizeTextRequest` + bounding-box
    /// paragraph reconstruction. Fast mode always uses the legacy `.fast` path.
    private static func recognizeText(in data: Data, config: OCRConfiguration) async throws -> String {
        if #available(macOS 26.0, *), config.recognitionLevel != .fast, !config.forceLegacyEngine {
            do {
                let request = RecognizeDocumentsRequest()
                let observations = try await request.perform(on: data)
                if let doc = observations.first?.document, !doc.text.transcript.isEmpty {
                    return reconstructDocumentText(from: doc)
                }
            } catch {
                // Fall through to the legacy path below.
            }
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage
        if !config.recognitionLanguages.isEmpty { request.recognitionLanguages = config.recognitionLanguages }
        if !config.customWords.isEmpty { request.customWords = config.customWords }
        let observations = try await request.perform(on: data)
        return reconstructParagraphs(from: observations)
    }

    /// Convert a document observation's native structure into layout-preserving
    /// text: paragraphs separated by blank lines, table cells by ` | `, list
    /// items keep their markers.
    @available(macOS 26.0, *)
    private static func reconstructDocumentText(from doc: DocumentObservation.Container) -> String {
        var parts: [String] = []

        if let title = doc.title, !title.transcript.isEmpty {
            parts.append(title.transcript)
        }
        for paragraph in doc.paragraphs where !paragraph.transcript.isEmpty {
            parts.append(paragraph.transcript)
        }
        for table in doc.tables {
            var rows: [String] = []
            for row in table.rows {
                rows.append(row.map { $0.content.text.transcript }.joined(separator: " | "))
            }
            if !rows.isEmpty { parts.append(rows.joined(separator: "\n")) }
        }
        for list in doc.lists {
            for item in list.items {
                let marker = item.markerString.isEmpty ? "•" : item.markerString
                parts.append("\(marker) \(item.itemString)")
            }
        }

        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Reconstruct paragraphs from Vision text observations using bounding-box
    /// positions with adaptive thresholds based on median line height.
    /// Process a PDF document: render each page to an image and run Vision OCR
    /// on it. Each page becomes its own OCRItem (named `file.pdf (page N)`).
    ///
    /// Pages are processed sequentially to keep ANE working set / RSS bounded,
    /// and each page's render artifacts are released via `autoreleasepool`.
    private static func processPDF(_ url: URL, config: OCRConfiguration) async -> [OCRItem] {
        guard let doc = PDFDocument(url: url) else {
            return [OCRItem(filename: url.lastPathComponent, text: "", error: "Could not load PDF", duration: 0)]
        }

        var items: [OCRItem] = []
        items.reserveCapacity(doc.pageCount)
        let pageLimit = min(doc.pageCount, Self.maxPDFPages)

        for pageIndex in 0..<pageLimit {
            let pageStart = CFAbsoluteTimeGetCurrent()
            let pageName = "\(url.lastPathComponent) (page \(pageIndex + 1))"

            let pngData: Data
            do {
                pngData = try renderPDFPage(doc, pageIndex: pageIndex)
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed))
                continue
            }

            do {
                let text = try await recognizeText(in: pngData, config: config)
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRItem(filename: pageName, text: text, error: nil, duration: elapsed))
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed))
            }
        }

        return items
    }

    private static func processPDFDetailed(_ url: URL, config: OCRConfiguration) async -> [OCRDetailedItem] {
        guard let doc = PDFDocument(url: url) else {
            return [OCRDetailedItem(filename: url.lastPathComponent, text: "", error: "Could not load PDF", duration: 0, meanConfidence: nil)]
        }

        var items: [OCRDetailedItem] = []
        items.reserveCapacity(doc.pageCount)
        let pageLimit = min(doc.pageCount, Self.maxPDFPages)

        for pageIndex in 0..<pageLimit {
            let pageStart = CFAbsoluteTimeGetCurrent()
            let pageName = "\(url.lastPathComponent) (page \(pageIndex + 1))"

            let pngData: Data
            do {
                pngData = try renderPDFPage(doc, pageIndex: pageIndex)
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRDetailedItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed, meanConfidence: nil))
                continue
            }

            do {
                let (text, confidence) = try await recognizeTextWithConfidence(in: pngData, config: config)
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRDetailedItem(filename: pageName, text: text, error: nil, duration: elapsed, meanConfidence: confidence))
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRDetailedItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed, meanConfidence: nil))
            }
        }

        return items
    }

    /// Render one PDF page at the 150–200 DPI sweet spot, capped at 4096px on
    /// the longest side. Shared by the plain and detailed PDF paths.
    private static func renderPDFPage(_ doc: PDFDocument, pageIndex: Int) throws -> Data {
        try autoreleasepool {
            guard let page = doc.page(at: pageIndex) else {
                throw NSError(domain: "OCR", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing page \(pageIndex + 1)"])
            }
            let bounds = page.bounds(for: .mediaBox)
            let scale = renderScale(for: bounds)
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let thumbnail = page.thumbnail(of: size, for: .mediaBox)
            guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            else {
                throw NSError(domain: "OCR", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not render page \(pageIndex + 1)"])
            }
            return data
        }
    }

    /// Scale that lands in the 150–200 DPI rasterization sweet spot, capped so
    /// the longest rendered side never exceeds `maxPixelSide` (~4096px).
    private static func renderScale(for bounds: CGRect, maxPixelSide: CGFloat = 4096) -> CGFloat {
        let dpi = CGFloat(200) / 72   // 200 DPI target
        let longestSide = max(bounds.width, bounds.height)
        let scaled = longestSide * dpi
        if scaled <= maxPixelSide { return dpi }
        return maxPixelSide / longestSide
    }

    private static func reconstructParagraphs(from observations: [RecognizedTextObservation]) -> String {
        reconstructParagraphsWithConfidence(from: observations).text
    }

    /// Same layout reconstruction as `reconstructParagraphs`, additionally
    /// returning the mean confidence of the recognized text observations.
    private static func reconstructParagraphsWithConfidence(from observations: [RecognizedTextObservation]) -> (text: String, meanConfidence: Double?) {
        guard !observations.isEmpty else { return ("", nil) }

        // Adaptive threshold from median line height
        let heights = observations.map { $0.boundingBox.height }
        let medianHeight = heights.sorted()[heights.count / 2]
        let lineThreshold = max(medianHeight * 0.6, 0.015)
        let paragraphThreshold = max(medianHeight * 1.2, 0.03)

        let sorted = observations.sorted { a, b in
            let aY = a.boundingBox.origin.y + a.boundingBox.height / 2
            let bY = b.boundingBox.origin.y + b.boundingBox.height / 2
            if abs(aY - bY) > lineThreshold { return aY > bY }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        }

        var result = ""
        var lastY: CGFloat = -1
        var lastX: CGFloat = -1
        var confidences: [Float] = []

        for obs in sorted {
            guard let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let text = candidate.string
            confidences.append(candidate.confidence)

            let box = obs.boundingBox
            let centerY = box.origin.y + box.height / 2
            let centerX = box.origin.x + box.width / 2

            if lastY > 0 {
                let dy = abs(centerY - lastY)
                if dy > paragraphThreshold {
                    result += "\n\n"
                } else if dy > lineThreshold {
                    result += "\n"
                } else {
                    let dx = centerX - lastX
                    if dx > box.width * 0.3 {
                        result += "  "
                    } else {
                        result += " "
                    }
                }
            }

            result += text
            lastY = centerY
            lastX = centerX
        }

        let meanConfidence = confidences.isEmpty ? nil : Double(confidences.reduce(0.0) { $0 + Double($1) } / Double(confidences.count))
        return (result, meanConfidence)
    }

    public static func collectImages(from directory: URL) -> [URL] {
        let imageExtensions: Set<String> = [
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "pdf"
        ]
        var images: [URL] = []

        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return images }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true
            else { continue }

            // Skip files over the 250MB ingest stability limit.
            if let size = values.fileSize, Int64(size) > maxIngestBytes { continue }

            if imageExtensions.contains(fileURL.pathExtension.lowercased()) {
                images.append(fileURL)
            }
        }

        return images
    }
}
