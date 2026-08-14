import Foundation
import Vision
import PDFKit
import ImageIO

// MARK: - OCR Result Model

struct OCRItem: Codable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval
}

// MARK: - Structured Results

struct OCRBlock: Codable {
    let text: String
    let confidence: Double
    let rect: [Double]   // normalized [x, y, width, height]
}

struct OCRStructuredItem: Codable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval
    let confidence: Double?
    let blocks: [OCRBlock]
}

// MARK: - OCR Configuration

struct OCRConfiguration {
    /// Recognition level — .accurate (quality) or .fast (speed)
    var recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate

    /// Explicit recognition languages (order = priority)
    var recognitionLanguages: [Locale.Language] = [
        Locale.Language(identifier: "en-US"),
    ]

    /// Enable language correction (dictionary-based post-processing)
    var usesLanguageCorrection = true

    /// Domain-specific words the model should prioritize
    var customWords: [String] = []

    /// Minimum text height in normalized coordinates (0.0–1.0).
    /// Filters out noise like page numbers, watermarks, tiny incidental text.
    var minimumTextHeight: Float = 0.0

    /// Maximum concurrent images processed at once.
    /// The ANE has 16 physical cores but only a 32MB on-chip SRAM working set;
    /// exceeding it spills to DRAM (~30% throughput drop) and risks Jetsam under
    /// memory pressure. 2–4 concurrent Vision requests is the empirically safe
    /// band — values above 4 are clamped to the ceiling (see `clampedConcurrency`).
    var maxConcurrency: Int = 4

    /// Whether to automatically detect the dominant language per image.
    /// When false, uses `recognitionLanguages` exclusively (faster, more consistent).
    var automaticallyDetectsLanguage = false

    /// Region-aware enhancement: small-text (or empty low-confidence) blocks are
    /// cropped from the image, upscaled, and re-recognized before results are
    /// assembled. Raises the accuracy ceiling for dense/degraded documents.
    var enhanceSmallText = false

    /// Normalized text height below which a block is treated as "small" and
    /// eligible for the crop→upscale→re-OCR path.
    var minBlockTextHeight: Float = 0.02

    /// Upscale factor applied to small-text crops before re-recognition.
    var enhanceUpscaleFactor: CGFloat = 3

    static let `default` = OCRConfiguration()
}

// MARK: - OCR Service

enum OCRService {

    /// Defensive ceiling for concurrent Vision requests (ANE "SRAM performance
    /// cliff" defense). The ANE evaluation queue accepts up to 127 requests but
    /// has only 16 physical cores and a 32MB on-chip SRAM budget; more than ~4
    /// concurrent high-resolution requests risks DRAM spill (~30% throughput
    /// drop) and Jetsam termination under memory pressure.
    private static let concurrencyCeiling = 4

    /// Stability limit for single-file memory ingestion (MAX_FILE_SIZE_INGEST).
    /// Files larger than this are skipped during collection to avoid OOM /
    /// Jetsam on high-volume ingestion.
    static let maxIngestBytes: Int64 = 250 * 1024 * 1024

    /// Cap on pages processed per PDF, bounding CPU/ANE work on hostile or
    /// degenerate files (e.g. decompression-bomb style PDFs with huge page counts).
    static let maxPDFPages = 200

    /// Clamp a requested concurrency into the safe band [1, 4].
    private static func clampedConcurrency(_ requested: Int) -> Int {
        min(max(requested, 1), concurrencyCeiling)
    }

    /// Run Vision text recognition on every image at `paths`.
    /// Processes images in parallel using the ANE (Apple Neural Engine) via
    /// Core ML, which is the backend Apple's Vision framework uses internally.
    ///
    /// - Parameter paths: Image file paths
    /// - Parameter fast: Shortcut for `.fast` recognition level
    /// - Parameter config: Full configuration (takes precedence over `fast`)
    /// - Returns: Results in the same order as `paths`.
    static func recognizeText(
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

            // Submit initial batch
            for i in 0..<maxConcurrent {
                let c = cfg
                group.addTask { await processPath(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

            // As each task completes, submit the next one
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

    /// Dispatch a single path to image or PDF processing based on extension.
    private static func processPath(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, [OCRItem]) {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            return (index, await processPDF(url, config: config))
        }
        let single = await processOne(path, index: index, config: config)
        return (index, [single.1])
    }

    /// Process a single image through Vision OCR, reconstructing paragraphs
    /// from bounding-box data so output preserves the original document layout.
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
    ///
    /// - macOS 26+: `RecognizeDocumentsRequest` — native structural layout
    ///   analysis that natively identifies paragraphs, tables, and lists
    ///   (per Tahoe's Document Intelligence), giving closer-to-1:1 output.
    /// - Older macOS: `RecognizeTextRequest` + bounding-box paragraph
    ///   reconstruction.
    ///
    /// Fast mode always uses the legacy `.fast` path for speed.
    private static func recognizeText(in data: Data, config: OCRConfiguration) async throws -> String {
        if #available(macOS 26.0, *), config.recognitionLevel != .fast {
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

    /// Convert a document observation's native structure (paragraphs, tables,
    /// lists) into layout-preserving text. Paragraphs are separated by blank
    /// lines; table cells by ` | `; list items keep their markers.
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

    /// Process a PDF document: render each page to an image and run Vision OCR
    /// on it. Each page becomes its own OCRItem (named `file.pdf (page N)`),
    /// so multi-page PDFs appear as separate entries in the results dropdown.
    ///
    /// Pages are processed sequentially (never in parallel) to keep the ANE
    /// working set — and therefore the host process RSS — under the 32MB on-chip
    /// SRAM budget, avoiding the "performance cliff" and Jetsam pressure on
    /// multi-page ingestion. Each page's render artifacts are released via an
    /// `autoreleasepool` immediately after the Vision dispatch.
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

    /// Render one PDF page at the 150–200 DPI sweet spot, capped so the longest
    /// side stays <= 4096 px. Shared by the plain and structured PDF paths.
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
    /// PDF page bounds are in 72-pt-per-inch points.
    private static func renderScale(for bounds: CGRect, maxPixelSide: CGFloat = 4096) -> CGFloat {
        let dpi = CGFloat(200) / 72   // 200 DPI target
        let longestSide = max(bounds.width, bounds.height)
        let scaled = longestSide * dpi
        if scaled <= maxPixelSide { return dpi }
        return maxPixelSide / longestSide
    }

    /// Reconstruct paragraphs from Vision text observations using bounding-box
    /// positions, preserving the original document layout.
    ///
    /// Observations are sorted top-to-bottom, left-to-right. Text blocks close
    /// together vertically are merged into the same paragraph (space-separated).
    /// Significant vertical gaps produce paragraph breaks (blank line).
    ///
    /// Uses adaptive thresholds based on median line height for robustness
    /// across different font sizes and layouts.
    private static func reconstructParagraphs(from observations: [RecognizedTextObservation]) -> String {
        reconstructParagraphsWithConfidence(from: observations).text
    }

    /// Same layout reconstruction as `reconstructParagraphs`, additionally
    /// returning the mean confidence of the recognized text observations.
    private static func reconstructParagraphsWithConfidence(from observations: [RecognizedTextObservation]) -> (text: String, meanConfidence: Double?) {
        guard !observations.isEmpty else { return ("", nil) }

        // Calculate adaptive threshold from median line height
        let heights = observations.map { $0.boundingBox.height }
        let medianHeight = heights.sorted()[heights.count / 2]
        let lineThreshold = max(medianHeight * 0.6, 0.015)  // 60% of median line height
        let paragraphThreshold = max(medianHeight * 1.2, 0.03) // 120% of median

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

    // MARK: - Structured Recognition (agent API)

    /// Run recognition and return per-file structured results (text, mean
    /// confidence, and per-line blocks with confidence + normalized boxes).
    /// Uses the `RecognizeTextRequest` engine uniformly so confidence is
    /// available on every macOS version and recognition level.
    static func recognizeTextStructured(paths: [String], config: OCRConfiguration = .default) async -> [OCRStructuredItem] {
        let maxConcurrent = min(paths.count, Self.clampedConcurrency(config.maxConcurrency))
        return await withTaskGroup(of: (Int, [OCRStructuredItem]).self) { group in
            var index = 0
            var slots = [[OCRStructuredItem]?](repeating: nil, count: paths.count)

            for i in 0..<maxConcurrent {
                let c = config
                group.addTask { await processPathStructured(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

            for await (idx, items) in group {
                slots[idx] = items
                if index < paths.count {
                    let nextIdx = index
                    let c = config
                    group.addTask { await processPathStructured(paths[nextIdx], index: nextIdx, config: c) }
                    index += 1
                }
            }
            return slots.compactMap { $0 }.flatMap { $0 }
        }
    }

    private static func processPathStructured(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, [OCRStructuredItem]) {
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "pdf" {
            return (index, await processPDFStructured(url, config: config))
        }
        let single = await processOneStructured(path, index: index, config: config)
        return (index, [single.1])
    }

    private static func processOneStructured(_ path: String, index: Int, config: OCRConfiguration) async -> (Int, OCRStructuredItem) {
        let url = URL(fileURLWithPath: path)
        let start = CFAbsoluteTimeGetCurrent()

        let imageData: Data
        do {
            imageData = try autoreleasepool { try Data(contentsOf: url) }
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRStructuredItem(filename: url.lastPathComponent, text: "", error: "Could not load image", duration: elapsed, confidence: nil, blocks: []))
        }

        do {
            let result = try await recognizeStructured(in: imageData, config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRStructuredItem(filename: url.lastPathComponent, text: result.text, error: nil, duration: elapsed, confidence: result.confidence, blocks: result.blocks))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRStructuredItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed, confidence: nil, blocks: []))
        }
    }

    /// Structured recognition: always uses `RecognizeTextRequest` (both fast and
    /// accurate levels) so per-line confidence and bounding boxes are available.
    /// When `config.enhanceSmallText` is set, small/empty blocks are cropped,
    /// upscaled, and re-recognized before the final text is assembled.
    private static func recognizeStructured(in data: Data, config: OCRConfiguration) async throws -> (text: String, confidence: Double?, blocks: [OCRBlock]) {
        let core = try await recognizeStructuredCore(in: data, config: config)
        guard config.enhanceSmallText else { return core }
        let enhanced = await enhanceSmallText(blocks: core.blocks, in: data, config: config)
        return (reconstructParagraphs(fromBlocks: enhanced), meanConfidence(enhanced), enhanced)
    }

    private static func recognizeStructuredCore(in data: Data, config: OCRConfiguration) async throws -> (text: String, confidence: Double?, blocks: [OCRBlock]) {
        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage
        if !config.recognitionLanguages.isEmpty { request.recognitionLanguages = config.recognitionLanguages }
        if !config.customWords.isEmpty { request.customWords = config.customWords }
        let observations = try await request.perform(on: data)
        let reconstruction = reconstructParagraphsWithConfidence(from: observations)
        let blocks = observations.compactMap { obs -> OCRBlock? in
            guard let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let box = obs.boundingBox
            return OCRBlock(text: candidate.string,
                            confidence: Double(candidate.confidence),
                            rect: [Double(box.origin.x), Double(box.origin.y), Double(box.width), Double(box.height)])
        }
        return (reconstruction.text, reconstruction.meanConfidence, blocks)
    }

    /// Crop each eligible block (small text, or empty low-confidence) from the
    /// source image, upscale it, and re-recognize. Replaces the block when the
    /// enhanced result is better (non-empty and higher confidence).
    private static func enhanceSmallText(blocks: [OCRBlock], in data: Data, config: OCRConfiguration) async -> [OCRBlock] {
        guard !blocks.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return blocks }

        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        guard imageW > 0, imageH > 0 else { return blocks }

        var baseConfig = config
        baseConfig.enhanceSmallText = false   // avoid recursion on crops

        var result: [OCRBlock] = []
        for block in blocks {
            guard block.rect.count == 4 else { result.append(block); continue }

            let normH = CGFloat(block.rect[3])
            let isSmall = normH < CGFloat(config.minBlockTextHeight)
            let isEmpty = block.text.isEmpty && block.confidence < 0.6
            guard isSmall || isEmpty else { result.append(block); continue }

            // Vision boundingBox origin is bottom-left; CGImage is top-left.
            let x = CGFloat(block.rect[0]) * imageW
            let w = CGFloat(block.rect[2]) * imageW
            let h = normH * imageH
            let y = (1 - CGFloat(block.rect[1]) - normH) * imageH
            let pad = max(w, h) * 0.15
            let cropRect = CGRect(x: x, y: y, width: w, height: h)
                .insetBy(dx: -pad, dy: -pad)
                .intersection(CGRect(x: 0, y: 0, width: imageW, height: imageH))
            guard cropRect.width >= 4, cropRect.height >= 4,
                  let crop = image.cropping(to: cropRect)
            else { result.append(block); continue }

            // Upscale, clamped so the longest side never exceeds 4096px.
            let scale = min(config.enhanceUpscaleFactor, CGFloat(4096) / CGFloat(max(crop.width, crop.height, 1)))
            let targetW = max(Int(CGFloat(crop.width) * scale), 1)
            let targetH = max(Int(CGFloat(crop.height) * scale), 1)
            guard let ctx = CGContext(
                data: nil, width: targetW, height: targetH,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { result.append(block); continue }
            ctx.interpolationQuality = CGInterpolationQuality.high
            ctx.draw(crop, in: CGRect(origin: .zero, size: CGSize(width: targetW, height: targetH)))
            guard let scaled = ctx.makeImage(),
                  let png = NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
            else { result.append(block); continue }

            let enhanced: (text: String, confidence: Double?)
            do {
                let core = try await recognizeStructuredCore(in: png, config: baseConfig)
                enhanced = (core.text, core.confidence)
            } catch {
                result.append(block)
                continue
            }
            let newText = enhanced.text
            let newConfidence = enhanced.confidence ?? 0
            if !newText.isEmpty && (block.text.isEmpty || newConfidence > block.confidence) {
                result.append(OCRBlock(text: newText, confidence: newConfidence, rect: block.rect))
            } else {
                result.append(block)
            }
        }
        return result
    }

    private static func meanConfidence(_ blocks: [OCRBlock]) -> Double? {
        guard !blocks.isEmpty else { return nil }
        return blocks.reduce(0.0) { $0 + $1.confidence } / Double(blocks.count)
    }

    /// Paragraph reconstruction from enhanced blocks, mirroring the
    /// observation-based algorithm (same thresholds and spacing rules).
    private static func reconstructParagraphs(fromBlocks blocks: [OCRBlock]) -> String {
        guard !blocks.isEmpty else { return "" }

        let heights = blocks.map { $0.rect.count >= 4 ? $0.rect[3] : 0 }
        let median = heights.sorted()[heights.count / 2]
        let lineThreshold = max(median * 0.6, 0.015)
        let paragraphThreshold = max(median * 1.2, 0.03)

        let sorted = blocks.enumerated().sorted { a, b in
            let aRect = a.element.rect, bRect = b.element.rect
            let aY = aRect[1] + aRect[3] / 2
            let bY = bRect[1] + bRect[3] / 2
            if abs(aY - bY) > lineThreshold { return aY > bY }
            return aRect[0] < bRect[0]
        }

        var result = ""
        var lastY = -1.0
        var lastX = -1.0
        for (_, block) in sorted {
            let rect = block.rect
            let centerY = rect[1] + rect[3] / 2
            let centerX = rect[0] + rect[2] / 2

            if lastY > 0 {
                let dy = abs(centerY - lastY)
                if dy > paragraphThreshold {
                    result += "\n\n"
                } else if dy > lineThreshold {
                    result += "\n"
                } else {
                    let dx = centerX - lastX
                    if dx > rect[2] * 0.3 {
                        result += "  "
                    } else {
                        result += " "
                    }
                }
            }

            result += block.text
            lastY = centerY
            lastX = centerX
        }
        return result
    }

    private static func processPDFStructured(_ url: URL, config: OCRConfiguration) async -> [OCRStructuredItem] {
        guard let doc = PDFDocument(url: url) else {
            return [OCRStructuredItem(filename: url.lastPathComponent, text: "", error: "Could not load PDF", duration: 0, confidence: nil, blocks: [])]
        }

        var items: [OCRStructuredItem] = []
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
                items.append(OCRStructuredItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed, confidence: nil, blocks: []))
                continue
            }

            do {
                let result = try await recognizeStructured(in: pngData, config: config)
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRStructuredItem(filename: pageName, text: result.text, error: nil, duration: elapsed, confidence: result.confidence, blocks: result.blocks))
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRStructuredItem(filename: pageName, text: "", error: error.localizedDescription, duration: elapsed, confidence: nil, blocks: []))
            }
        }

        return items
    }

    // MARK: - File Helpers

    static func collectImages(from directory: URL) -> [URL] {
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

    static let supportedImageExtensions: [String] = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp", "pdf"
    ]
}
