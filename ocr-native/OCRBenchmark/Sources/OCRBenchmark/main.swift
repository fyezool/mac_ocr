import Foundation
import OCRCore

// MARK: - Benchmark Runner

@main
struct OCRBenchmark {

    static func main() async {
        let args = CommandLine.arguments

        // Parse arguments
        let folderPath: String
        var outputFormat = Format.table
        var saveJsonPath: String?

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        if let idx = args.firstIndex(of: "--json") {
            outputFormat = .json
            if idx + 1 < args.count, !args[idx + 1].hasPrefix("-") {
                saveJsonPath = args[idx + 1]
            }
        }

        if args.count < 2 || args[1].hasPrefix("-") {
            printUsage()
            exit(1)
        }
        folderPath = args[1]

        // Collect images
        let folderURL = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            print("❌ Error: '\(folderPath)' is not a valid directory.")
            exit(1)
        }

        print("📁 Scanning \"\(folderURL.path)\" for images…", terminator: " ")
        let images = OCRService.collectImages(from: folderURL)
        print("found \(images.count) image(s).")

        guard !images.isEmpty else {
            print("No images found. Exiting.")
            exit(0)
        }

        // Run OCR
        print("🔍 Running OCR on \(images.count) image(s)…")
        print(String(repeating: "─", count: 60))

        let startTotal = CFAbsoluteTimeGetCurrent()
        let paths = images.map(\.path)
        let results = await OCRService.recognizeText(paths: paths)
        let totalElapsed = CFAbsoluteTimeGetCurrent() - startTotal

        // Compute stats
        let successful = results.filter { $0.error == nil && !$0.text.isEmpty }
        let failed = results.filter { $0.error != nil }
        let empty = results.filter { $0.error == nil && $0.text.isEmpty }

        let totalDuration = results.reduce(0.0) { $0 + $1.duration }
        let avgDuration = totalDuration / Double(results.count)
        let imagesPerSecond: Double = totalElapsed > 0 ? Double(results.count) / totalElapsed : 0

        // ---- Output ----
        switch outputFormat {
        case .table:
            printTable(results: results, totalElapsed: totalElapsed, totalDuration: totalDuration,
                       avgDuration: avgDuration, imagesPerSecond: imagesPerSecond,
                       successful: successful.count, failed: failed.count, empty: empty.count)
        case .json:
            let jsonOutput = buildJSON(results: results, totalElapsed: totalElapsed, totalDuration: totalDuration,
                                       avgDuration: avgDuration, imagesPerSecond: imagesPerSecond,
                                       totalImages: images.count, successful: successful.count,
                                       failed: failed.count, empty: empty.count)
            if let path = saveJsonPath {
                do {
                    try jsonOutput.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                    print("📄 JSON results saved to: \(path)")
                } catch {
                    print("❌ Failed to write JSON: \(error.localizedDescription)")
                    print(jsonOutput)
                }
            } else {
                print(jsonOutput)
            }
        }
    }

    // MARK: - Helpers

    private static func printUsage() {
        print("""
        OCR Benchmark — measure Apple Vision text recognition performance

        Usage:
          swift run OCRBenchmark <folder-path> [options]

        Options:
          --json [path]    Output in JSON format (optionally save to file)
          --help, -h       Show this help

        Example:
          swift run OCRBenchmark ~/Screenshots
          swift run OCRBenchmark ~/Screenshots --json results.json
        """)
    }

    private static func printTable(
        results: [OCRItem],
        totalElapsed: TimeInterval,
        totalDuration: TimeInterval,
        avgDuration: TimeInterval,
        imagesPerSecond: Double,
        successful: Int,
        failed: Int,
        empty: Int
    ) {
        // Per-file details
        let header = "Duration     File\(String(repeating: " ", count: 36))Chars  Error"
        print(header)
        print(String(repeating: "─", count: 75))
        for r in results {
            let durationStr = String(format: "%.3fs", r.duration)
            let charCount = r.text.count
            let errorStr = r.error ?? (r.text.isEmpty ? "(no text)" : "")
            let name = r.filename.count > 38 ? String(r.filename.prefix(35)) + "…" : r.filename
            let line = "\(durationStr)  \(name.padding(toLength: 40, withPad: " ", startingAt: 0))  \(String(format: "%7d", charCount))  \(errorStr)"
            print(line)
        }

        // Summary
        print(String(repeating: "─", count: 60))
        print("📊 Summary:")
        print("   Total images:       \(results.count)")
        print("   Successful OCR:     \(successful)")
        print("   Empty results:      \(empty)")
        print("   Failed:             \(failed)")
        print(String(format: "   Wall-clock time:    %.3fs", totalElapsed))
        print(String(format: "   Sum of durations:  %.3fs", totalDuration))
        print(String(format: "   Average per image: %.3fs", avgDuration))
        print(String(format: "   Throughput:        %.1f images/s", imagesPerSecond))
    }

    private static func buildJSON(
        results: [OCRItem],
        totalElapsed: TimeInterval,
        totalDuration: TimeInterval,
        avgDuration: TimeInterval,
        imagesPerSecond: Double,
        totalImages: Int,
        successful: Int,
        failed: Int,
        empty: Int
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let summary: [String: Any] = [
            "total_images": totalImages,
            "successful": successful,
            "empty": empty,
            "failed": failed,
            "wall_clock_seconds": totalElapsed,
            "sum_duration_seconds": totalDuration,
            "avg_duration_seconds": avgDuration,
            "images_per_second": imagesPerSecond,
        ]

        let output: [String: Any] = [
            "summary": summary,
            "results": results.map { r in
                [
                    "filename": r.filename,
                    "text": r.text,
                    "error": r.error as Any,
                    "duration_seconds": r.duration,
                ]
            },
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return jsonString
    }

    enum Format {
        case table, json
    }
}
