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

// MARK: - OCR Service

public enum OCRService {

    /// Run Vision text recognition on every image at `paths`.
    /// Processes images in parallel, up to 4 at a time, using the ANE
    /// (Apple Neural Engine) via Core ML.
    ///
    /// - Parameter paths: Image file paths
    /// - Parameter fast: Use `.fast` recognition level (speed) vs
    ///   `.accurate` (quality, default).
    /// - Returns: Results in the same order as `paths`.
    public static func recognizeText(paths: [String], fast: Bool = false) async -> [OCRItem] {
        let level: RecognizeTextRequest.RecognitionLevel = fast ? .fast : .accurate
        let maxConcurrent = min(paths.count, 4)

        return await withTaskGroup(of: (Int, OCRItem).self) { group in
            var index = 0
            var results = [OCRItem?](repeating: nil, count: paths.count)

            for i in 0..<maxConcurrent {
                group.addTask { await processOne(paths[i], index: i, level: level) }
            }
            index = maxConcurrent

            for await (idx, item) in group {
                results[idx] = item
                if index < paths.count {
                    let nextIdx = index
                    group.addTask { await processOne(paths[nextIdx], index: nextIdx, level: level) }
                    index += 1
                }
            }

            return results.compactMap { $0 }
        }
    }

    /// Sequential version — processes one image at a time. Useful as a
    /// baseline for benchmarking the speedup from parallel processing.
    public static func recognizeTextSequential(paths: [String], fast: Bool = false) async -> [OCRItem] {
        let level: RecognizeTextRequest.RecognitionLevel = fast ? .fast : .accurate
        var results: [OCRItem] = []
        for (i, path) in paths.enumerated() {
            let (_, item) = await processOne(path, index: i, level: level)
            results.append(item)
        }
        return results
    }

    private static func processOne(_ path: String, index: Int, level: RecognizeTextRequest.RecognitionLevel) async -> (Int, OCRItem) {
        let url = URL(fileURLWithPath: path)
        let start = CFAbsoluteTimeGetCurrent()

        guard let imageData = try? Data(contentsOf: url) else {
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            return (index, OCRItem(filename: url.lastPathComponent, text: "", error: "Could not load image", duration: elapsed))
        }

        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

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

    private static func reconstructParagraphs(from observations: [RecognizedTextObservation]) -> String {
        let sorted = observations.sorted(by: { a, b in
            let aY = a.boundingBox.origin.y + a.boundingBox.height / 2
            let bY = b.boundingBox.origin.y + b.boundingBox.height / 2
            if abs(aY - bY) > 0.02 { return aY > bY }
            return a.boundingBox.origin.x < b.boundingBox.origin.x
        })

        var lines: [String] = []
        var lastY: CGFloat = -1

        for obs in sorted {
            let text = obs.topCandidates(1).first?.string ?? ""
            let centerY = obs.boundingBox.origin.y + obs.boundingBox.height / 2

            if lastY > 0, abs(centerY - lastY) > 0.03 {
                lines.append("")
            }
            if lines.isEmpty || abs(centerY - lastY) > 0.02 {
                lines.append(text)
            } else {
                lines[lines.count - 1] += " " + text
            }
            lastY = centerY
        }

        return lines.joined(separator: "\n")
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
