import Foundation
import Vision

// MARK: - OCR Result Model

struct OCRItem: Codable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval  // seconds spent on this file
}

// MARK: - OCR Service

enum OCRService {

    /// Run Vision text recognition on every image at `paths`.
    /// Returns results in the same order as `paths`, one per file.
    static func recognizeText(paths: [String]) async -> [OCRItem] {
        var results: [OCRItem] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            let start = CFAbsoluteTimeGetCurrent()

            guard let imageData = try? Data(contentsOf: url) else {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                results.append(OCRItem(
                    filename: url.lastPathComponent,
                    text: "",
                    error: "Could not load image",
                    duration: elapsed
                ))
                continue
            }

            var recognizedText = ""
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true

            do {
                let observations = try await request.perform(on: imageData)
                recognizedText = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                results.append(OCRItem(
                    filename: url.lastPathComponent,
                    text: "",
                    error: error.localizedDescription,
                    duration: elapsed
                ))
                continue
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - start
            results.append(OCRItem(
                filename: url.lastPathComponent,
                text: recognizedText,
                error: nil,
                duration: elapsed
            ))
        }

        return results
    }

    /// Scan a directory recursively for supported image files.
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

    /// Supported image file extensions (for NSOpenPanel filter).
    static let supportedImageExtensions: [String] = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"
    ]
}
