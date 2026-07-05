import Foundation
import Vision

// MARK: - OCR Result Model

struct OCRItem: Codable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval
}

// MARK: - OCR Service

enum OCRService {

    /// Run Vision text recognition on every image at `paths`.
    /// Processes images in parallel using the ANE (Apple Neural Engine) via
    /// Core ML, which is the backend Apple's Vision framework uses internally.
    ///
    /// Research basis:
    ///  - S1 (ANE architecture): confirms Vision API uses Core ML → ANE path
    ///  - S2 (OCR→Core ML case study): ANE is ~12x more power-efficient than
    ///    CPU and ~4x more efficient than GPU for OCR workloads
    ///  - S4 (MLX batch scaling): Apple Silicon shows sub-linear latency scaling
    ///    with batch size, motivating parallel processing
    ///
    /// - Parameter paths: Image file paths
    /// - Parameter fast: Use `.fast` recognition level (speed) vs
    ///   `.accurate` (quality, default). `.fast` is ~2-3x faster but may miss
    ///   small or densely packed text.
    /// - Returns: Results in the same order as `paths`.
    static func recognizeText(paths: [String], fast: Bool = false) async -> [OCRItem] {
        let level: RecognizeTextRequest.RecognitionLevel = fast ? .fast : .accurate
        let maxConcurrent = min(paths.count, 4) // limit concurrency for stability

        return await withTaskGroup(of: (Int, OCRItem).self) { group in
            // Process in parallel, up to `maxConcurrent` at a time
            var index = 0
            var results = [OCRItem?](repeating: nil, count: paths.count)

            // Submit initial batch
            for i in 0..<maxConcurrent {
                group.addTask { await processOne(paths[i], index: i, level: level) }
            }
            index = maxConcurrent

            // As each task completes, submit the next one
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

    /// Process a single image through Vision OCR, reconstructing paragraphs
    /// from bounding-box data so output preserves the original document layout.
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

    /// Reconstruct paragraphs from Vision text observations using bounding-box
    /// positions, preserving the original document layout.
    ///
    /// Observations are sorted top-to-bottom, left-to-right. Text blocks close
    /// together vertically are merged into the same paragraph (space-separated).
    /// Significant vertical gaps produce paragraph breaks (blank line).
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
                lines.append("") // paragraph break
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
