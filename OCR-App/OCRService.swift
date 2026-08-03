import Foundation
import Vision
import PDFKit

// MARK: - OCR Result Model

struct OCRItem: Codable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval
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
    /// Apple Silicon ANE benefits from moderate parallelism (4–6).
    var maxConcurrency: Int = 4

    /// Whether to automatically detect the dominant language per image.
    /// When false, uses `recognitionLanguages` exclusively (faster, more consistent).
    var automaticallyDetectsLanguage = false

    static let `default` = OCRConfiguration()
}

// MARK: - OCR Service

enum OCRService {

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
        let maxConcurrent = min(paths.count, cfg.maxConcurrency)

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

        for pageIndex in 0..<doc.pageCount {
            let pageStart = CFAbsoluteTimeGetCurrent()
            let pageName = "\(url.lastPathComponent) (page \(pageIndex + 1))"

            // Render at the 150–200 DPI sweet spot, capped so the longest side
            // stays <= 4096 px. 300 DPI on US Letter is ~33MB raw — past the
            // point of diminishing OCR returns and a real RSS hazard.
            let pngData: Data
            do {
                pngData = try autoreleasepool { () throws -> Data in
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
        guard !observations.isEmpty else { return "" }

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

        for obs in sorted {
            let text = obs.topCandidates(1).first?.string ?? ""
            guard !text.isEmpty else { continue }

            let box = obs.boundingBox
            let centerY = box.origin.y + box.height / 2
            let centerX = box.origin.x + box.width / 2

            if lastY > 0 {
                let dy = abs(centerY - lastY)
                if dy > paragraphThreshold {
                    // Large vertical gap → new paragraph (blank line)
                    result += "\n\n"
                } else if dy > lineThreshold {
                    // Small vertical gap → new line
                    result += "\n"
                } else {
                    // Same line → space (but not if already adjacent)
                    let dx = centerX - lastX
                    if dx > box.width * 0.3 {
                        result += "  "  // significant horizontal gap → double space
                    } else {
                        result += " "
                    }
                }
            }

            result += text
            lastY = centerY
            lastX = centerX
        }

        return result
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
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true
            else { continue }

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
