import Foundation
import os
import Vision
import PDFKit
import ImageIO

// MARK: - OCR Result Model

public struct OCRItem: Codable, Sendable {
    public let filename: String
    public let text: String
    public let error: String?
    public let duration: TimeInterval
    public let loadMs: Double?
    public let visionMs: Double?

    public init(filename: String, text: String, error: String?, duration: TimeInterval, loadMs: Double? = nil, visionMs: Double? = nil) {
        self.filename = filename
        self.text = text
        self.error = error
        self.duration = duration
        self.loadMs = loadMs
        self.visionMs = visionMs
    }
}

/// Per-item confidence statistics used to drive adaptive routing. Mean alone
/// can hide a few catastrophic blocks, so min + low-ratio are also reported.
public struct ConfidenceStats: Codable, Sendable {
    public let mean: Double?
    public let min: Double?
    public let p10: Double?
    public let lowRatio: Double?
}

/// A result that also carries recognition confidence statistics, used to drive
/// the adaptive fast→accurate routing.
public struct OCRDetailedItem: Codable, Sendable {
    public let filename: String
    public let text: String
    public let error: String?
    public let duration: TimeInterval
    public let meanConfidence: Double?
    public let minConfidence: Double?
    public let p10Confidence: Double?
    public let lowConfidenceRatio: Double?

    public init(filename: String, text: String, error: String?, duration: TimeInterval, meanConfidence: Double?, minConfidence: Double? = nil, p10Confidence: Double? = nil, lowConfidenceRatio: Double? = nil) {
        self.filename = filename
        self.text = text
        self.error = error
        self.duration = duration
        self.meanConfidence = meanConfidence
        self.minConfidence = minConfidence
        self.p10Confidence = p10Confidence
        self.lowConfidenceRatio = lowConfidenceRatio
    }
}

// MARK: - Structured results (agent API)

/// A recognized line/block with its confidence and normalized bounding box.
public struct OCRBlock: Codable, Sendable {
    public let text: String
    public let confidence: Double
    public let rect: [Double]   // normalized [x, y, width, height] (bottom-left)

    public init(text: String, confidence: Double, rect: [Double]) {
        self.text = text
        self.confidence = confidence
        self.rect = rect
    }
}

/// Structured per-file result: text, mean confidence, and per-line blocks.
public struct OCRStructuredItem: Codable, Sendable {
    public let filename: String
    public let text: String
    public let error: String?
    public let duration: TimeInterval
    public let confidence: Double?
    public let blocks: [OCRBlock]

    public init(filename: String, text: String, error: String?, duration: TimeInterval, confidence: Double?, blocks: [OCRBlock]) {
        self.filename = filename
        self.text = text
        self.error = error
        self.duration = duration
        self.confidence = confidence
        self.blocks = blocks
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

    /// Minimum text height in normalized coordinates (0.0–1.0), mapped to the
    /// document request's `minimumTextHeightFraction` when > 0.
    public var minimumTextHeight: Float = 0.0

    /// Region-aware enhancement: small-text blocks are cropped/upscaled/re-OCR'd,
    /// and uncovered text-like regions are recovered from the source image.
    public var enhanceSmallText = false

    /// Normalized text height below which a block is treated as "small".
    public var minBlockTextHeight: Float = 0.02

    /// Upscale factor applied to small-text crops before re-recognition.
    public var enhanceUpscaleFactor: CGFloat = 3

    /// Cap on missing-region recovery OCR calls per image (bounds the grid
    /// scan cost on large images).
    public var maxRecoveryRegions: Int = 8

    public static let `default` = OCRConfiguration()

    public init(
        recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate,
        recognitionLanguages: [Locale.Language] = [Locale.Language(identifier: "en-US")],
        usesLanguageCorrection: Bool = true,
        customWords: [String] = [],
        maxConcurrency: Int = 4,
        automaticallyDetectsLanguage: Bool = false,
        forceLegacyEngine: Bool = false,
        minimumTextHeight: Float = 0.0,
        enhanceSmallText: Bool = false,
        minBlockTextHeight: Float = 0.02,
        enhanceUpscaleFactor: CGFloat = 3,
        maxRecoveryRegions: Int = 8
    ) {
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.maxConcurrency = maxConcurrency
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.forceLegacyEngine = forceLegacyEngine
        self.minimumTextHeight = minimumTextHeight
        self.enhanceSmallText = enhanceSmallText
        self.minBlockTextHeight = minBlockTextHeight
        self.enhanceUpscaleFactor = enhanceUpscaleFactor
        self.maxRecoveryRegions = maxRecoveryRegions
    }
}

// MARK: - OCR Service

/// How aggressively to parallelize Vision requests. The benchmark must be able
/// to sweep beyond the production-safe ceiling to find the real optimum;
/// production keeps a conservative cap.
public enum ConcurrencyPolicy: Sendable {
    case production(maxConcurrent: Int)
    case benchmark(maxConcurrent: Int)

    public var ceiling: Int {
        switch self {
        case .production(let n), .benchmark(let n): return n
        }
    }
}

/// FIFO async semaphore bounding process-wide in-flight Vision `perform` calls.
/// Uses `OSAllocatedUnfairLock` (not an actor) so the limit can be raised
/// synchronously from a non-async `main` and released via `defer`.
private final class VisionGate: @unchecked Sendable {
    private struct State {
        var limit: Int
        var active = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State(limit: 4))

    init(limit: Int) {
        lock.withLock { $0.limit = max(1, limit) }
    }

    /// Async-acquire; returns immediately while under the budget, otherwise
    /// suspends until a slot frees up (FIFO).
    func acquire() async {
        let granted = lock.withLock { state -> Bool in
            if state.active < state.limit {
                state.active += 1
                return true
            }
            return false
        }
        if granted { return }
        await withCheckedContinuation { cont in
            lock.withLock { state in state.waiters.append(cont) }
        }
    }

    /// Sync release — safe to call from `defer` in an async context.
    func release() {
        let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            if state.active > 0 { state.active -= 1 }
            var admitted: [CheckedContinuation<Void, Never>] = []
            while state.active < state.limit, !state.waiters.isEmpty {
                state.active += 1
                admitted.append(state.waiters.removeFirst())
            }
            return admitted
        }
        for cont in toResume { cont.resume() }
    }

    /// Raise the budget, admitting any waiters that now fit.
    func setLimit(_ newLimit: Int) {
        let toResume = lock.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.limit = max(1, newLimit)
            var admitted: [CheckedContinuation<Void, Never>] = []
            while state.active < state.limit, !state.waiters.isEmpty {
                state.active += 1
                admitted.append(state.waiters.removeFirst())
            }
            return admitted
        }
        for cont in toResume { cont.resume() }
    }

    /// Current budget (for reporting).
    func currentLimit() -> Int {
        lock.withLock { $0.limit }
    }
}

public enum OCRService {

    /// Stability limit for single-file memory ingestion (MAX_FILE_SIZE_INGEST).
    public static let maxIngestBytes: Int64 = 250 * 1024 * 1024

    /// Cap on pages processed per PDF, bounding CPU/ANE work on hostile or
    /// degenerate files (e.g. decompression-bomb style PDFs with huge page counts).
    public static let maxPDFPages = 200

    /// Cap on decoded pixels per image. Compressed bytes ≠ decoded memory, so
    /// oversized images are downscaled before Vision sees them.
    public static let maxDecodedPixels = 25_000_000

    // MARK: - Global Vision request budget

    /// Conservative process-wide cap on in-flight Vision `perform` calls.
    /// Vision's Core ML/ANE backend degrades past ~4 concurrent requests
    /// (working-set cliff + Jetsam risk — see docs/ANE_ENGINEERING_RULESET.md).
    /// The per-invocation `maxConcurrency` clamp only bounds a single call; this
    /// gate bounds the *sum* across the app UI, the HTTP server, and the
    /// benchmark running in the same process.
    public static let defaultVisionConcurrency = 4

    private static let visionGate = VisionGate(limit: OCRService.defaultVisionConcurrency)

    /// Raise the process-wide Vision request budget. The benchmark opts into a
    /// higher budget (its safety ceiling is 16) so the concurrency sweep stays
    /// meaningful; the app keeps the conservative default.
    public static func setVisionConcurrencyLimit(_ limit: Int) {
        visionGate.setLimit(limit)
    }

    /// Current process-wide Vision request budget (for reporting).
    public static func visionConcurrencyLimit() -> Int {
        visionGate.currentLimit()
    }

    /// Clamp a requested concurrency into the safe band [1, ceiling] for the
    /// given policy. The benchmark needs to sweep beyond the production-safe
    /// ceiling to find the real optimum; production keeps a conservative cap.
    public static func clampedConcurrency(_ requested: Int, policy: ConcurrencyPolicy = .benchmark(maxConcurrent: 16)) -> Int {
        min(max(requested, 1), policy.ceiling)
    }

    /// The current Vision text-recognition request revision (underlying
    /// implementation version), e.g. "revision3". Record it in benchmark output
    /// so results stay comparable across macOS updates.
    public static func visionRevisionLabel() -> String {
        String(describing: RecognizeTextRequest().revision)
    }

    /// The macOS 26 document-intelligence request revision (a different engine
    /// from `RecognizeTextRequest`), e.g. "revision1".
    @available(macOS 26.0, *)
    public static func documentsRevisionLabel() -> String {
        String(describing: RecognizeDocumentsRequest().revision)
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

    // MARK: - Pure helpers (unit-testable)

    /// Lowercase + collapse whitespace, used for CER/WER comparison.
    public static func normalizeText(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public static func levenshteinDistance<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var prev = Array(0...b.count)
        var curr = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            curr[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return prev[b.count]
    }

    public static func cerDetail(reference: String, predicted: String) -> (rate: Double, dist: Int, refCount: Int) {
        let r = Array(normalizeText(reference))
        let p = Array(normalizeText(predicted))
        guard !r.isEmpty else { return (p.isEmpty ? 0 : 1, p.count, 0) }
        let dist = levenshteinDistance(r, p)
        return (Double(dist) / Double(r.count), dist, r.count)
    }

    public static func werDetail(reference: String, predicted: String) -> (rate: Double, dist: Int, refCount: Int) {
        let r = normalizeText(reference).split(separator: " ").map(String.init)
        let p = normalizeText(predicted).split(separator: " ").map(String.init)
        guard !r.isEmpty else { return (p.isEmpty ? 0 : 1, p.count, 0) }
        let dist = levenshteinDistance(r, p)
        return (Double(dist) / Double(r.count), dist, r.count)
    }

    /// Strip the "(page N)" suffix and extension from an OCR item filename.
    public static func baseName(_ filename: String) -> String {
        if let range = filename.range(of: " (page ") {
            return (String(filename[..<range.lowerBound]) as NSString).deletingPathExtension
        }
        return (filename as NSString).deletingPathExtension
    }

    public static func percentileValue(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    /// Adaptive retry decision. Mean confidence alone can hide a catastrophic
    /// block, so min/low-ratio also force a retry.
    public static func shouldRetry(textIsEmpty: Bool, meanConfidence: Double?, minConfidence: Double?, lowConfidenceRatio: Double?, threshold: Double) -> (retry: Bool, reason: String?) {
        if textIsEmpty { return (true, "empty_text") }
        if let min = minConfidence, min < 0.4 { return (true, "min_confidence") }
        if let low = lowConfidenceRatio, low > 0.25 { return (true, "low_ratio") }
        if let mean = meanConfidence, mean < threshold { return (true, "mean_confidence") }
        return (false, nil)
    }

    /// Convert a Vision normalized rect (bottom-left origin) to a top-left
    /// bitmap pixel rect for cropping.
    public static func bitmapRect(fromNormalized rect: [Double], imageWidth: Int, imageHeight: Int) -> (x: Double, y: Double, width: Double, height: Double)? {
        guard rect.count == 4 else { return nil }
        let x = rect[0] * Double(imageWidth)
        let w = rect[2] * Double(imageWidth)
        let h = rect[3] * Double(imageHeight)
        let y = (1 - rect[1] - rect[3]) * Double(imageHeight)
        return (x, y, w, h)
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
    public static func recognizeTextSequential(paths: [String], fast: Bool = false, config: OCRConfiguration = .default) async -> [OCRItem] {
        var cfg = config
        if fast { cfg.recognitionLevel = .fast }
        var results: [OCRItem] = []
        for (i, path) in paths.enumerated() {
            let (_, items) = await processPath(path, index: i, config: cfg)
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
            let (text, stats) = try await recognizeTextWithConfidence(in: imageData, config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRDetailedItem(filename: url.lastPathComponent, text: text, error: nil, duration: elapsed, meanConfidence: stats.mean, minConfidence: stats.min, p10Confidence: stats.p10, lowConfidenceRatio: stats.lowRatio))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRDetailedItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed, meanConfidence: nil))
        }
    }

    /// Probe path: always uses `RecognizeTextRequest` and returns the
    /// reconstructed text plus confidence statistics of the non-empty
    /// observations.
    private static func recognizeTextWithConfidence(in data: Data, config: OCRConfiguration) async throws -> (String, ConfidenceStats) {
        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage
        if !config.recognitionLanguages.isEmpty { request.recognitionLanguages = config.recognitionLanguages }
        if !config.customWords.isEmpty { request.customWords = config.customWords }
        await visionGate.acquire()
        defer { visionGate.release() }
        let observations = try await request.perform(on: data)
        let result = reconstructParagraphsWithConfidence(from: observations)
        return (result.text, result.stats)
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

        let loadStart = CFAbsoluteTimeGetCurrent()
        let imageData: Data
        do {
            imageData = try autoreleasepool { try Data(contentsOf: url) }
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: "Could not load image", duration: elapsed))
        }
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        do {
            let visionStart = CFAbsoluteTimeGetCurrent()
            let text = try await recognizeText(in: imageData, config: config)
            let visionMs = (CFAbsoluteTimeGetCurrent() - visionStart) * 1000
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: text, error: nil, duration: elapsed, loadMs: loadMs, visionMs: visionMs))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed, loadMs: loadMs))
        }
    }

    /// Recognize text from image data using the best available Vision API.
    /// macOS 26+ uses `RecognizeDocumentsRequest` (native paragraph/table/list
    /// layout); older systems use `RecognizeTextRequest` + bounding-box
    /// paragraph reconstruction. Fast mode always uses the legacy `.fast` path.
    private static func recognizeText(in data: Data, config: OCRConfiguration) async throws -> String {
        if #available(macOS 26.0, *), config.recognitionLevel != .fast, !config.forceLegacyEngine {
            do {
                var request = RecognizeDocumentsRequest()
                var opts = request.textRecognitionOptions
                if !config.recognitionLanguages.isEmpty { opts.recognitionLanguages = config.recognitionLanguages }
                opts.automaticallyDetectLanguage = config.automaticallyDetectsLanguage
                opts.useLanguageCorrection = config.usesLanguageCorrection
                if !config.customWords.isEmpty { opts.customWords = config.customWords }
                if config.minimumTextHeight > 0 { opts.minimumTextHeightFraction = config.minimumTextHeight }
                request.textRecognitionOptions = opts
                await visionGate.acquire()
                defer { visionGate.release() }
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
        await visionGate.acquire()
        defer { visionGate.release() }
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
                let (text, stats) = try await recognizeTextWithConfidence(in: pngData, config: config)
                let elapsed = CFAbsoluteTimeGetCurrent() - pageStart
                items.append(OCRDetailedItem(filename: pageName, text: text, error: nil, duration: elapsed, meanConfidence: stats.mean, minConfidence: stats.min, p10Confidence: stats.p10, lowConfidenceRatio: stats.lowRatio))
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
    /// Scale that lands in the 150–200 DPI rasterization sweet spot, capped so
    /// the longest rendered side never exceeds `maxPixelSide` (~4096px).
    /// PDF page bounds are in 72-pt-per-inch points.
    public static func renderScale(for bounds: CGRect, maxPixelSide: CGFloat = 4096) -> CGFloat {
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
    private static func reconstructParagraphsWithConfidence(from observations: [RecognizedTextObservation]) -> (text: String, stats: ConfidenceStats) {
        guard !observations.isEmpty else { return ("", ConfidenceStats(mean: nil, min: nil, p10: nil, lowRatio: nil)) }

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

        let stats = ConfidenceStats(
            mean: confidences.isEmpty ? nil : Double(confidences.reduce(0.0) { $0 + Double($1) } / Double(confidences.count)),
            min: confidences.min().map(Double.init),
            p10: percentile(confidences.map(Double.init), 0.10),
            lowRatio: confidences.isEmpty ? nil : Double(confidences.filter { $0 < 0.5 }.count) / Double(confidences.count)
        )
        return (result, stats)
    }

    private static func percentile(_ sortedSource: [Double], _ p: Double) -> Double? {
        let sorted = sortedSource.sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    // MARK: - Structured recognition (agent API)

    public static func recognizeTextStructured(paths: [String], config: OCRConfiguration = .default) async -> [OCRStructuredItem] {
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
        let bounded = boundedImageData(imageData)
        do {
            let result = try await recognizeStructured(in: bounded, config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRStructuredItem(filename: url.lastPathComponent, text: result.text, error: nil, duration: elapsed, confidence: result.confidence, blocks: result.blocks))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRStructuredItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed, confidence: nil, blocks: []))
        }
    }

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
        await visionGate.acquire()
        defer { visionGate.release() }
        let observations = try await request.perform(on: data)
        let reconstruction = reconstructParagraphsWithConfidence(from: observations)
        let blocks = observations.compactMap { obs -> OCRBlock? in
            guard let candidate = obs.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
            let box = obs.boundingBox
            return OCRBlock(text: candidate.string,
                            confidence: Double(candidate.confidence),
                            rect: [Double(box.origin.x), Double(box.origin.y), Double(box.width), Double(box.height)])
        }
        return (reconstruction.text, reconstruction.stats.mean, blocks)
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

    // MARK: - Region-aware enhancement

    /// Re-OCR small-text blocks and recover uncovered text-like regions.
    private static func enhanceSmallText(blocks: [OCRBlock], in data: Data, config: OCRConfiguration) async -> [OCRBlock] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
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
            guard normH < CGFloat(config.minBlockTextHeight) else { result.append(block); continue }

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

            guard let png = upscalePNG(crop, factor: config.enhanceUpscaleFactor) else { result.append(block); continue }

            do {
                let core = try await recognizeStructuredCore(in: png, config: baseConfig)
                if let newConfidence = core.confidence, newConfidence > block.confidence, !core.text.isEmpty {
                    result.append(OCRBlock(text: core.text, confidence: newConfidence, rect: block.rect))
                } else {
                    result.append(block)
                }
            } catch {
                result.append(block)
            }
        }

        result.append(contentsOf: await recoverSuspiciousRegions(image: image, imageW: imageW, imageH: imageH, blocks: result, config: config, baseConfig: baseConfig))
        return result
    }

    private static func upscalePNG(_ crop: CGImage, factor: CGFloat) -> Data? {
        let scale = min(factor, CGFloat(4096) / CGFloat(max(crop.width, crop.height, 1)))
        let targetW = max(Int(CGFloat(crop.width) * scale), 1)
        let targetH = max(Int(CGFloat(crop.height) * scale), 1)
        guard let ctx = CGContext(
            data: nil, width: targetW, height: targetH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.draw(crop, in: CGRect(origin: .zero, size: CGSize(width: targetW, height: targetH)))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    /// Rank grid cells by text-likeness, OCR only the top `maxRecoveryRegions`,
    /// and return accepted blocks in global normalized coordinates.
    private static func recoverSuspiciousRegions(image: CGImage, imageW: CGFloat, imageH: CGFloat, blocks: [OCRBlock], config: OCRConfiguration, baseConfig: OCRConfiguration) async -> [OCRBlock] {
        let cellSize: CGFloat = 256
        var candidates: [(rect: CGRect, ratio: Double)] = []
        let cols = Int(ceil(imageW / cellSize))
        let rows = Int(ceil(imageH / cellSize))

        for row in 0..<rows {
            for col in 0..<cols {
                let cellRect = CGRect(x: CGFloat(col) * cellSize, y: CGFloat(row) * cellSize, width: cellSize, height: cellSize)
                    .intersection(CGRect(x: 0, y: 0, width: imageW, height: imageH))
                guard cellRect.width >= 64, cellRect.height >= 64 else { continue }
                if blocks.contains(where: { blockRectIntersects($0.rect, cellRect, imageW: imageW, imageH: imageH) }) { continue }

                let ratio = darkPixelRatio(image, in: cellRect)
                guard ratio >= 0.03, ratio <= 0.6 else { continue }
                candidates.append((cellRect, ratio))
            }
        }

        let ranked = candidates.sorted { abs($0.ratio - 0.2) < abs($1.ratio - 0.2) }
        var recovered: [OCRBlock] = []
        for (cellRect, _) in ranked.prefix(max(config.maxRecoveryRegions, 1)) {
            let padded = cellRect.insetBy(dx: -16, dy: -16).intersection(CGRect(x: 0, y: 0, width: imageW, height: imageH))
            guard let crop = image.cropping(to: padded),
                  let png = upscalePNG(crop, factor: config.enhanceUpscaleFactor)
            else { continue }

            let core: (text: String, confidence: Double?, blocks: [OCRBlock])
            do {
                core = try await recognizeStructuredCore(in: png, config: baseConfig)
            } catch { continue }
            guard !core.text.isEmpty, !core.blocks.isEmpty,
                  let conf = core.confidence, conf >= 0.5
            else { continue }

            for local in core.blocks where local.rect.count == 4 {
                let nX = (padded.origin.x + CGFloat(local.rect[0]) * padded.width) / imageW
                let nY = (padded.origin.y + CGFloat(local.rect[1]) * padded.height) / imageH
                let nW = CGFloat(local.rect[2]) * padded.width / imageW
                let nH = CGFloat(local.rect[3]) * padded.height / imageH
                recovered.append(OCRBlock(text: local.text, confidence: local.confidence, rect: [Double(nX), Double(nY), Double(nW), Double(nH)]))
            }
        }
        return recovered
    }

    private static func blockRectIntersects(_ rect: [Double], _ cell: CGRect, imageW: CGFloat, imageH: CGFloat) -> Bool {
        guard rect.count == 4 else { return false }
        let bx = CGFloat(rect[0]) * imageW
        let by = (1 - CGFloat(rect[1]) - CGFloat(rect[3])) * imageH
        let bw = CGFloat(rect[2]) * imageW
        let bh = CGFloat(rect[3]) * imageH
        return CGRect(x: bx, y: by, width: bw, height: bh).intersects(cell)
    }

    /// Fraction of pixels darker than mid-gray in a region.
    private static func darkPixelRatio(_ image: CGImage, in rect: CGRect) -> Double {
        guard let crop = image.cropping(to: rect) else { return 0 }
        let w = crop.width, h = crop.height
        guard w > 0, h > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        let dark = data.lazy.filter { $0 < 128 }.count
        return Double(dark) / Double(w * h)
    }

    private static func meanConfidence(_ blocks: [OCRBlock]) -> Double? {
        guard !blocks.isEmpty else { return nil }
        return blocks.reduce(0.0) { $0 + $1.confidence } / Double(blocks.count)
    }

    /// Paragraph reconstruction from enhanced blocks (mirrors the observation-
    /// based algorithm: same thresholds and spacing rules).
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

    /// Downscale an image whose decoded pixel count exceeds the budget.
    private static func boundedImageData(_ data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w * h > maxDecodedPixels
        else { return data }
        let maxSide = Int(sqrt(Double(maxDecodedPixels)))
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ] as CFDictionary),
        let png = NSBitmapImageRep(cgImage: thumb).representation(using: .png, properties: [:])
        else { return data }
        return png
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
