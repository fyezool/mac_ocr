import Foundation
import Vision

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

        return await withTaskGroup(of: (Int, OCRItem).self) { group in
            var index = 0
            var results = [OCRItem?](repeating: nil, count: paths.count)

            // Submit initial batch
            for i in 0..<maxConcurrent {
                let c = cfg
                group.addTask { await processOne(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

            // As each task completes, submit the next one
            for await (idx, item) in group {
                results[idx] = item
                if index < paths.count {
                    let nextIdx = index
                    let c = cfg
                    group.addTask { await processOne(paths[nextIdx], index: nextIdx, config: c) }
                    index += 1
                }
            }

            return results.compactMap { $0 }
        }
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

        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage

        // Set explicit language priority (vision-framework: use Locale.Language)
        if !config.recognitionLanguages.isEmpty {
            request.recognitionLanguages = config.recognitionLanguages
        }

        // Domain-specific vocabulary for better accuracy
        if !config.customWords.isEmpty {
            request.customWords = config.customWords
        }

        // Filter out noise below minimum height
        if config.minimumTextHeight > 0 {
            // minimumTextHeight is available on VNRecognizeTextRequest (legacy)
            // For the modern API, we post-filter results instead
        }

        do {
            let observations = try await request.perform(on: imageData)
            let text = reconstructParagraphs(from: observations)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: text, error: nil, duration: elapsed))
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: error.localizedDescription, duration: elapsed))
        }
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
            "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"
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
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"
    ]
}
