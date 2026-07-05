import Foundation
import Vision

// MARK: - OCR Result Model

public struct OCRItem: Codable, Sendable {
    let filename: String
    let text: String
    let error: String?
    let duration: TimeInterval
}

// MARK: - OCR Service

public enum OCRService {

    public static func recognizeText(paths: [String]) async -> [OCRItem] {
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

    public static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "tif", "heic", "webp"
    ]
}
