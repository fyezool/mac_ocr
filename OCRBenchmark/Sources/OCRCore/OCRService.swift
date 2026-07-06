import Foundation
import Vision

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

    public static let `default` = OCRConfiguration()

    public init(
        recognitionLevel: RecognizeTextRequest.RecognitionLevel = .accurate,
        recognitionLanguages: [Locale.Language] = [Locale.Language(identifier: "en-US")],
        usesLanguageCorrection: Bool = true,
        customWords: [String] = [],
        maxConcurrency: Int = 4,
        automaticallyDetectsLanguage: Bool = false
    ) {
        self.recognitionLevel = recognitionLevel
        self.recognitionLanguages = recognitionLanguages
        self.usesLanguageCorrection = usesLanguageCorrection
        self.customWords = customWords
        self.maxConcurrency = maxConcurrency
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
    }
}

// MARK: - OCR Service

public enum OCRService {

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
        let maxConcurrent = min(paths.count, cfg.maxConcurrency)

        return await withTaskGroup(of: (Int, OCRItem).self) { group in
            var index = 0
            var results = [OCRItem?](repeating: nil, count: paths.count)

            for i in 0..<maxConcurrent {
                let c = cfg
                group.addTask { await processOne(paths[i], index: i, config: c) }
            }
            index = maxConcurrent

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

    /// Sequential version — processes one image at a time. Useful as a
    /// baseline for benchmarking the speedup from parallel processing.
    public static func recognizeTextSequential(paths: [String], fast: Bool = false) async -> [OCRItem] {
        let config = fast ? { var c = OCRConfiguration.default; c.recognitionLevel = .fast; return c }() : .default
        var results: [OCRItem] = []
        for (i, path) in paths.enumerated() {
            let (_, item) = await processOne(path, index: i, config: config)
            results.append(item)
        }
        return results
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

        var request = RecognizeTextRequest()
        request.recognitionLevel = config.recognitionLevel
        request.usesLanguageCorrection = config.usesLanguageCorrection
        request.automaticallyDetectsLanguage = config.automaticallyDetectsLanguage

        if !config.recognitionLanguages.isEmpty {
            request.recognitionLanguages = config.recognitionLanguages
        }

        if !config.customWords.isEmpty {
            request.customWords = config.customWords
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
    /// positions with adaptive thresholds based on median line height.
    private static func reconstructParagraphs(from observations: [RecognizedTextObservation]) -> String {
        guard !observations.isEmpty else { return "" }

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

        for obs in sorted {
            let text = obs.topCandidates(1).first?.string ?? ""
            guard !text.isEmpty else { continue }

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

        return result
    }

    public static func collectImages(from directory: URL) -> [URL] {
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
}
