import Foundation
import Darwin
import OCRCore

// MARK: - Benchmark Runner

@main
struct OCRBenchmark {

    struct RunOptions {
        var folder = ""
        var outputFormat = Format.table
        var jsonPath: String?
        var useFast = false
        var useSequential = false
        var useAutoLang = false
        var concurrency: Int?
        var sweep = false
        var adaptive = false
        var adaptiveSweep = false
        var adaptiveThreshold = 0.75
        var languages: [String]?
        var legacyEngine = false
        var resizeTo: Int?
        var resizeSweep = false
        var referencesDir: String?
        var warmup = 0
        var runs = 1
        var help = false
    }

    struct AccuracySummary {
        var compared = 0
        var cerSum = 0.0
        var cerDistSum = 0
        var cerRefSum = 0
        var werSum = 0.0
        var werDistSum = 0
        var werRefSum = 0
        var exactSum = 0.0
        var perFile: [[String: Any]] = []
    }

    // MARK: - Entry

    static func main() async {
        let opts = parseOptions()
        if opts.help { printUsage(); exit(0) }

        if opts.sweep && opts.concurrency != nil {
            print("❌ --sweep and --concurrency are mutually exclusive.")
            exit(1)
        }
        if opts.useSequential && (opts.sweep || opts.concurrency != nil) {
            print("❌ --sequential cannot be combined with --sweep/--concurrency.")
            exit(1)
        }
        if opts.useFast && opts.useSequential {
            print("❌ Can't use --fast and --sequential together.")
            exit(1)
        }
        if opts.adaptive && opts.useSequential {
            print("❌ --adaptive cannot be combined with --sequential.")
            exit(1)
        }
        if opts.adaptive && opts.sweep {
            print("❌ --adaptive cannot be combined with --sweep.")
            exit(1)
        }
        if opts.adaptive && opts.useFast {
            print("❌ --adaptive cannot be combined with --fast (adaptive already uses fast as its cheap pass).")
            exit(1)
        }
        if opts.resizeSweep && (opts.sweep || opts.adaptive || opts.useSequential) {
            print("❌ --resize-sweep cannot be combined with --sweep/--adaptive/--sequential.")
            exit(1)
        }
        if opts.adaptiveSweep && (opts.adaptive || opts.sweep || opts.resizeSweep || opts.useSequential) {
            print("❌ --adaptive-sweep cannot be combined with --adaptive/--sweep/--resize-sweep/--sequential.")
            exit(1)
        }
        if opts.resizeSweep && opts.resizeTo != nil {
            print("❌ --resize-sweep and --resize-to are mutually exclusive.")
            exit(1)
        }
        if (opts.warmup > 0 || opts.runs > 1) && (opts.sweep || opts.adaptive || opts.adaptiveSweep || opts.resizeSweep) {
            print("❌ --warmup/--runs apply to single-run mode only.")
            exit(1)
        }
        guard !opts.folder.isEmpty else { printUsage(); exit(1) }

        let folderURL = URL(fileURLWithPath: (opts.folder as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir), isDir.boolValue else {
            print("❌ Error: '\(opts.folder)' is not a valid directory.")
            exit(1)
        }

        print("📁 Scanning \"\(folderURL.path)\" for images…", terminator: " ")
        let images = OCRService.collectImages(from: folderURL)
        print("found \(images.count) image(s).")
        guard !images.isEmpty else { print("No images found. Exiting."); exit(0) }

        let levelLabel = opts.useFast ? "fast" : "accurate"
        if opts.resizeSweep {
            await runResizeSweep(images: images, options: opts)
        } else if opts.adaptiveSweep {
            await runAdaptiveSweep(images: images, options: opts)
        } else if opts.adaptive {
            await runAdaptive(images: images, options: opts)
        } else if opts.sweep {
            await runSweep(images: images, options: opts, levelLabel: levelLabel)
        } else {
            await runSingle(images: images, options: opts, levelLabel: levelLabel)
        }
    }

    // MARK: - Shared config / path helpers

    private static func applyCommonConfig(_ config: inout OCRConfiguration, options: RunOptions) {
        config.maxConcurrency = options.concurrency ?? config.maxConcurrency
        config.automaticallyDetectsLanguage = options.useAutoLang
        config.customWords = ["OCR", "Apple", "Vision", "Neural Engine"]
        config.forceLegacyEngine = options.legacyEngine
        if let languages = options.languages, !languages.isEmpty {
            config.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }
        }
    }

    /// Returns OCR paths for the given images, optionally downscaling to
    /// `maxPixelSide` (0/absent = native). Resized files keep the original
    /// basename so `--references` still matches. Caller must run `cleanup()`.
    private static func preparePaths(images: [URL], maxPixelSide: Int?) -> (paths: [String], cleanup: () -> Void) {
        guard let maxPixelSide else { return (images.map(\.path), {}) }
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ocr_resize_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        var paths: [String] = []
        for img in images {
            if img.pathExtension.lowercased() == "pdf" {
                paths.append(img.path)
                continue
            }
            guard let data = OCRService.resizedImageData(at: img, maxPixelSide: maxPixelSide) else { continue }
            let name = (img.lastPathComponent as NSString).deletingPathExtension + ".png"
            let out = tmpDir.appendingPathComponent(name)
            if (try? data.write(to: out)) != nil { paths.append(out.path) }
        }
        return (paths, { try? FileManager.default.removeItem(at: tmpDir) })
    }

    // MARK: - Single run

    private static func runSingle(images: [URL], options: RunOptions, levelLabel: String) async {
        // Warm-up: discard one pass over the first N images so Vision/Core ML
        // initialization doesn't pollute the measurement.
        if options.warmup > 0 {
            let n = min(options.warmup, images.count)
            _ = await runSinglePass(images: Array(images.prefix(n)), options: options)
            print("🌡 Warm-up pass over \(n) image(s) discarded.")
        }
        if options.runs > 1 {
            await runSingleRepeated(images: images, options: options, levelLabel: levelLabel)
        } else {
            await runSingleOnce(images: images, options: options, levelLabel: levelLabel)
        }
    }

    private static func runSinglePass(images: [URL], options: RunOptions) async -> (results: [OCRItem], wall: TimeInterval) {
        let (paths, cleanup) = preparePaths(images: images, maxPixelSide: options.resizeTo)
        defer { cleanup() }
        let startTotal = CFAbsoluteTimeGetCurrent()
        let results: [OCRItem]
        if options.useSequential {
            results = await OCRService.recognizeTextSequential(paths: paths, fast: options.useFast)
        } else {
            var config = OCRConfiguration.default
            if options.useFast { config.recognitionLevel = .fast }
            applyCommonConfig(&config, options: options)
            results = await OCRService.recognizeText(paths: paths, config: config)
        }
        return (results, CFAbsoluteTimeGetCurrent() - startTotal)
    }

    private static func runSingleOnce(images: [URL], options: RunOptions, levelLabel: String) async {
        let concurrency = options.concurrency ?? (options.useSequential ? 1 : 4)
        let modeLabel = options.useFast ? "fast + parallel" : (options.useSequential ? "accurate + sequential" : "accurate + parallel (\(concurrency))")
        print("🔍 Running OCR on \(images.count) image(s) (\(modeLabel))…")
        print(String(repeating: "─", count: 60))

        let (results, totalElapsed) = await runSinglePass(images: images, options: options)

        let successful = results.filter { $0.error == nil && !$0.text.isEmpty }.count
        let failed = results.filter { $0.error != nil }.count
        let empty = results.filter { $0.error == nil && $0.text.isEmpty }.count
        let totalDuration = results.reduce(0.0) { $0 + $1.duration }
        let avgDuration = totalDuration / Double(max(results.count, 1))
        let imagesPerSecond = totalElapsed > 0 ? Double(results.count) / totalElapsed : 0
        let (p50, p95, p99) = percentiles(results.map(\.duration))
        let accuracy = options.referencesDir.map { computeAccuracy(results: results, referencesDir: $0) }

        switch options.outputFormat {
        case .table:
            printSingleTable(results: results, totalElapsed: totalElapsed, totalDuration: totalDuration,
                             avgDuration: avgDuration, imagesPerSecond: imagesPerSecond,
                             successful: successful, failed: failed, empty: empty,
                             p50: p50, p95: p95, p99: p99, accuracy: accuracy, concurrency: concurrency)
        case .json:
            let json = buildSingleJSON(results: results, options: options, levelLabel: levelLabel, concurrency: concurrency,
                                       totalElapsed: totalElapsed, totalDuration: totalDuration, avgDuration: avgDuration,
                                       imagesPerSecond: imagesPerSecond, totalImages: images.count,
                                       successful: successful, failed: failed, empty: empty,
                                       p50: p50, p95: p95, p99: p99, accuracy: accuracy)
            emitJSON(json, path: options.jsonPath)
        }
    }

    /// Repeated runs with median/min/max/stddev to separate real signal from
    /// thermal or scheduling noise.
    private static func runSingleRepeated(images: [URL], options: RunOptions, levelLabel: String) async {
        let n = options.runs
        print("🔍 Running OCR \(n)× on \(images.count) image(s) (\(levelLabel))…")
        print(String(repeating: "─", count: 60))

        var walls: [Double] = []
        var throughputs: [Double] = []
        var p95s: [Double] = []
        var runsJSON: [[String: Any]] = []
        for i in 1...n {
            let (results, wall) = await runSinglePass(images: images, options: options)
            let (_, p95, _) = percentiles(results.map(\.duration))
            let t = wall > 0 ? Double(results.count) / wall : 0
            walls.append(wall)
            throughputs.append(t)
            p95s.append(p95 * 1000)
            runsJSON.append(["run": i, "wall_clock_seconds": wall, "throughput_img_s": t, "p95_latency_ms": p95 * 1000])
        }

        func stats(_ a: [Double]) -> (median: Double, min: Double, max: Double, stddev: Double) {
            let s = a.sorted()
            let mean = a.reduce(0, +) / Double(max(a.count, 1))
            let variance = a.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(a.count, 1))
            return (s[s.count / 2], s.first ?? 0, s.last ?? 0, variance.squareRoot())
        }

        let w = stats(walls), th = stats(throughputs), p = stats(p95s)
        print(pad("metric", 14) + pad("median", 12) + pad("min", 12) + pad("max", 12) + "stddev")
        print(pad("wall (s)", 14) + pad(String(format: "%.2f", w.median), 12) + pad(String(format: "%.2f", w.min), 12) + pad(String(format: "%.2f", w.max), 12) + String(format: "%.2f", w.stddev))
        print(pad("img/s", 14) + pad(String(format: "%.1f", th.median), 12) + pad(String(format: "%.1f", th.min), 12) + pad(String(format: "%.1f", th.max), 12) + String(format: "%.1f", th.stddev))
        print(pad("p95 (ms)", 14) + pad(String(format: "%.0f", p.median), 12) + pad(String(format: "%.0f", p.min), 12) + pad(String(format: "%.0f", p.max), 12) + String(format: "%.0f", p.stddev))

        if options.outputFormat == .json {
            let output: [String: Any] = [
                "schema_version": "1.0",
                "mode": "single_repeated",
                "runs": n,
                "environment": environmentInfo(),
                "ocr": ocrInfo(level: levelLabel, concurrency: options.concurrency ?? 4, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
                "median": [
                    "wall_clock_seconds": w.median,
                    "throughput_img_s": th.median,
                    "p95_latency_ms": p.median,
                    "min_wall_seconds": w.min,
                    "max_wall_seconds": w.max,
                    "wall_stddev_seconds": w.stddev,
                ],
                "passes": runsJSON,
            ]
            emitJSON(output, path: options.jsonPath)
        }
    }

    // MARK: - Concurrency sweep

    private static func runSweep(images: [URL], options: RunOptions, levelLabel: String) async {
        let levels = [1, 2, 3, 4, 5, 6, 8]
        print("🔍 Sweeping concurrency (\(levelLabel)) over [\(levels.map(String.init).joined(separator: ", "))]…")
        print(String(repeating: "─", count: 60))
        print(pad("Concurrency", 13) + pad("Wall(s)", 12) + pad("img/s", 9) + pad("p50(ms)", 11) + pad("p95(ms)", 11) + "p99(ms)")
        print(String(repeating: "─", count: 60))

        var runs: [[String: Any]] = []
        for level in levels {
            var config = OCRConfiguration.default
            if options.useFast { config.recognitionLevel = .fast }
            applyCommonConfig(&config, options: options)
            config.maxConcurrency = level

            let start = CFAbsoluteTimeGetCurrent()
            let results = await OCRService.recognizeText(paths: images.map(\.path), config: config)
            let elapsed = CFAbsoluteTimeGetCurrent() - start

            let successful = results.filter { $0.error == nil && !$0.text.isEmpty }.count
            let failed = results.filter { $0.error != nil }.count
            let empty = results.filter { $0.error == nil && $0.text.isEmpty }.count
            let throughput = elapsed > 0 ? Double(results.count) / elapsed : 0
            let (p50, p95, p99) = percentiles(results.map(\.duration))
            let accuracy = options.referencesDir.map { computeAccuracy(results: results, referencesDir: $0) }

            print(pad(String(level), 13) + pad(String(format: "%.2f", elapsed), 12) + pad(String(format: "%.1f", throughput), 9)
                + pad(String(format: "%.0f", p50 * 1000), 11) + pad(String(format: "%.0f", p95 * 1000), 11) + String(format: "%.0f", p99 * 1000))

            var run: [String: Any] = [
                "concurrency": concurrencyInfo(requested: level),
                "wall_clock_seconds": elapsed,
                "throughput_img_s": throughput,
                "p50_latency_ms": p50 * 1000,
                "p95_latency_ms": p95 * 1000,
                "p99_latency_ms": p99 * 1000,
                "successful": successful,
                "failed": failed,
                "empty": empty,
            ]
            if let accuracy { run["accuracy"] = accuracyJSON(accuracy) }
            runs.append(run)
        }

        if options.outputFormat == .json {
            let output: [String: Any] = [
                "schema_version": "1.0",
                "mode": "sweep",
                "environment": environmentInfo(),
                "ocr": ocrInfo(level: levelLabel, concurrency: 0, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
                "concurrency_levels": levels,
                "runs": runs,
            ]
            emitJSON(output, path: options.jsonPath)
        }
    }

    // MARK: - Adaptive cascade

    private struct AdaptiveRunResult {
        var finalItems: [OCRItem] = []
        var wall: TimeInterval = 0
        var retriedFiles = 0
        var accuracy: AccuracySummary?
        var stats: [String: Any] = [:]
        var perFile: [[String: Any]] = []
    }

    /// fast probe → retry accurate on low-confidence items, compared against an
    /// always-accurate baseline on throughput, p95, and accuracy.
    private static func runAdaptive(images: [URL], options: RunOptions) async {
        let concurrency = options.concurrency ?? 4
        let threshold = options.adaptiveThreshold
        print("🔍 Adaptive OCR (fast probe → retry accurate when confidence < \(threshold)) on \(images.count) image(s)…")
        print(String(repeating: "─", count: 60))

        // Baseline: always-accurate
        var accurateConfig = OCRConfiguration.default
        applyCommonConfig(&accurateConfig, options: options)
        accurateConfig.maxConcurrency = concurrency
        let baseStart = CFAbsoluteTimeGetCurrent()
        let baseItems = await OCRService.recognizeText(paths: images.map(\.path), config: accurateConfig)
        let baseWall = CFAbsoluteTimeGetCurrent() - baseStart
        let baselineStats = runStats(baseItems, wall: baseWall)
        let accuracyBaseline = options.referencesDir.map { computeAccuracy(results: baseItems, referencesDir: $0) }

        let result = await adaptiveRun(images: images, options: options, threshold: threshold)
        let wall = result.wall
        let adaptiveStats = result.stats
        let accuracyAdaptive = result.accuracy

        if options.outputFormat == .table {
            print(String(repeating: "─", count: 60))
            print("📊 Adaptive vs baseline:")
            print("   " + pad("", 16) + pad("Adaptive", 18) + "Baseline")
            print("   " + pad("Wall (s)", 16) + pad(String(format: "%.2f", wall), 18) + String(format: "%.2f", baseWall))
            print("   " + pad("Items/s", 16) + pad(String(format: "%.2f", adaptiveStats["throughput_items_s"] as? Double ?? 0), 18) + String(format: "%.2f", baselineStats["throughput_items_s"] as? Double ?? 0))
            print("   " + pad("p50 (ms)", 16) + pad(String(format: "%.0f", adaptiveStats["p50_latency_ms"] as? Double ?? 0), 18) + String(format: "%.0f", baselineStats["p50_latency_ms"] as? Double ?? 0))
            print("   " + pad("p95 (ms)", 16) + pad(String(format: "%.0f", adaptiveStats["p95_latency_ms"] as? Double ?? 0), 18) + String(format: "%.0f", baselineStats["p95_latency_ms"] as? Double ?? 0))
            if let a = accuracyAdaptive, let b = accuracyBaseline, a.compared > 0, b.compared > 0 {
                print("   " + pad("CER macro (%)", 16) + pad(String(format: "%.2f", a.cerSum / Double(a.compared) * 100), 18) + String(format: "%.2f", b.cerSum / Double(b.compared) * 100))
                print("   " + pad("CER micro (%)", 16) + pad(String(format: "%.2f", a.cerRefSum > 0 ? Double(a.cerDistSum) / Double(a.cerRefSum) * 100 : 0), 18) + String(format: "%.2f", b.cerRefSum > 0 ? Double(b.cerDistSum) / Double(b.cerRefSum) * 100 : 0))
            }
            let speedup = wall > 0 ? baseWall / wall : 0
            let verdict = speedup >= 1 ? "adaptive wins" : "baseline wins"
            print("   Wall speedup: \(String(format: "%.2f", speedup))× → \(verdict)")
        } else {
            var adaptive = adaptiveStats
            if let accuracyAdaptive { adaptive["accuracy"] = accuracyJSON(accuracyAdaptive) }
            adaptive["per_file"] = result.perFile
            var baseline = baselineStats
            if let accuracyBaseline { baseline["accuracy"] = accuracyJSON(accuracyBaseline) }
            let output: [String: Any] = [
                "schema_version": "1.0",
                "mode": "adaptive",
                "environment": environmentInfo(),
                "ocr": ocrInfo(level: "fast+accurate", concurrency: concurrency, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
                "adaptive_threshold": threshold,
                "retried_files": result.retriedFiles,
                "total_files": images.count,
                "adaptive": adaptive,
                "baseline_accurate": baseline,
                "speedup_wall_x": wall > 0 ? baseWall / wall : 0,
            ]
            emitJSON(output, path: options.jsonPath)
        }
    }

    /// One adaptive run at a given retry threshold. Retry rule: empty text,
    /// mean confidence below the threshold, any block below 0.4 confidence, or
    /// more than 25% of blocks below 0.5 confidence.
    private static func adaptiveRun(images: [URL], options: RunOptions, threshold: Double) async -> AdaptiveRunResult {
        let paths = images.map(\.path)
        let concurrency = options.concurrency ?? 4

        var fastConfig = OCRConfiguration.default
        fastConfig.recognitionLevel = .fast
        applyCommonConfig(&fastConfig, options: options)
        fastConfig.maxConcurrency = concurrency

        var accurateConfig = OCRConfiguration.default
        applyCommonConfig(&accurateConfig, options: options)
        accurateConfig.maxConcurrency = concurrency

        let totalStart = CFAbsoluteTimeGetCurrent()
        let fastItems = await OCRService.recognizeTextDetailed(paths: paths, config: fastConfig)

        let pathByKey = Dictionary(images.map { (ownerKey($0.lastPathComponent), $0.path) }, uniquingKeysWith: { a, _ in a })
        var retryPaths = Set<String>()
        var retryReason: [String: String] = [:]
        for item in fastItems {
            guard let path = pathByKey[ownerKey(item.filename)] else { continue }
            let decision = OCRService.shouldRetry(
                textIsEmpty: item.text.isEmpty,
                meanConfidence: item.meanConfidence,
                minConfidence: item.minConfidence,
                lowConfidenceRatio: item.lowConfidenceRatio,
                threshold: threshold
            )
            if decision.retry {
                retryPaths.insert(path)
                retryReason[item.filename] = decision.reason ?? "confidence"
            }
        }
        let retryList = paths.filter { retryPaths.contains($0) }

        var accurateByFilename: [String: OCRItem] = [:]
        var accurateItems: [OCRItem] = []
        if !retryList.isEmpty {
            accurateItems = await OCRService.recognizeText(paths: retryList, config: accurateConfig)
            for r in accurateItems { accurateByFilename[r.filename] = r }
        }

        var finalItems: [OCRItem] = []
        for item in fastItems {
            if let accurate = accurateByFilename[item.filename] {
                // End-to-end per-file latency = fast probe + accurate retry.
                finalItems.append(OCRItem(filename: accurate.filename, text: accurate.text, error: accurate.error, duration: item.duration + accurate.duration))
            } else {
                finalItems.append(OCRItem(filename: item.filename, text: item.text, error: item.error, duration: item.duration))
            }
        }
        let wall = CFAbsoluteTimeGetCurrent() - totalStart

        // Per-phase latency so adaptive p95 can be attributed to fast vs retry.
        var stats = runStats(finalItems, wall: wall)
        let (_, fastP95, _) = percentiles(fastItems.map(\.duration))
        stats["fast_pass_p95_ms"] = fastP95 * 1000
        if !accurateItems.isEmpty {
            let (_, retryP95, _) = percentiles(accurateItems.map(\.duration))
            stats["retry_pass_p95_ms"] = retryP95 * 1000
        }

        var perFile: [[String: Any]] = []
        for item in fastItems {
            let retried = accurateByFilename[item.filename] != nil
            var entry: [String: Any] = [
                "filename": item.filename,
                "engine_used": retried ? "fast+accurate" : "fast",
                "mean_confidence": item.meanConfidence ?? NSNull(),
                "min_confidence": item.minConfidence ?? NSNull(),
                "p10_confidence": item.p10Confidence ?? NSNull(),
                "low_conf_ratio": item.lowConfidenceRatio ?? NSNull(),
            ]
            if retried { entry["retry_reason"] = retryReason[item.filename] ?? "confidence" }
            perFile.append(entry)
        }

        var result = AdaptiveRunResult()
        result.finalItems = finalItems
        result.wall = wall
        result.retriedFiles = retryPaths.count
        result.accuracy = options.referencesDir.map { computeAccuracy(results: finalItems, referencesDir: $0) }
        result.stats = stats
        result.perFile = perFile
        return result
    }

    /// Sweep the adaptive retry threshold to find the accuracy/latency Pareto
    /// frontier instead of assuming a single value.
    private static func runAdaptiveSweep(images: [URL], options: RunOptions) async {
        let thresholds = [0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90, 0.95]
        let concurrency = options.concurrency ?? 4
        print("🔍 Adaptive threshold sweep (fast probe → retry accurate below T) on \(images.count) image(s)…")
        print(String(repeating: "─", count: 60))

        var accurateConfig = OCRConfiguration.default
        applyCommonConfig(&accurateConfig, options: options)
        accurateConfig.maxConcurrency = concurrency
        let baseStart = CFAbsoluteTimeGetCurrent()
        let baseItems = await OCRService.recognizeText(paths: images.map(\.path), config: accurateConfig)
        let baseWall = CFAbsoluteTimeGetCurrent() - baseStart
        let baselineStats = runStats(baseItems, wall: baseWall)
        let accuracyBaseline = options.referencesDir.map { computeAccuracy(results: baseItems, referencesDir: $0) }

        print(pad("Thresh", 10) + pad("Retry%", 9) + pad("Wall(s)", 12) + pad("img/s", 9) + pad("p50(ms)", 11) + pad("p95(ms)", 11) + pad("CER%", 9) + "WER%")
        print(String(repeating: "─", count: 60))

        var runs: [[String: Any]] = []
        for t in thresholds {
            let r = await adaptiveRun(images: images, options: options, threshold: t)
            let retryPct = Double(r.retriedFiles) / Double(max(images.count, 1)) * 100
            let cer = r.accuracy.map { $0.compared > 0 ? $0.cerSum / Double($0.compared) * 100 : 0 } ?? 0
            let wer = r.accuracy.map { $0.compared > 0 ? $0.werSum / Double($0.compared) * 100 : 0 } ?? 0
            print(pad(String(format: "%.2f", t), 10) + pad(String(format: "%.0f", retryPct), 9)
                + pad(String(format: "%.2f", r.wall), 12) + pad(String(format: "%.1f", r.stats["throughput_items_s"] as? Double ?? 0), 9)
                + pad(String(format: "%.0f", r.stats["p50_latency_ms"] as? Double ?? 0), 11) + pad(String(format: "%.0f", r.stats["p95_latency_ms"] as? Double ?? 0), 11)
                + pad(String(format: "%.2f", cer), 9) + String(format: "%.2f", wer))

            var run: [String: Any] = r.stats
            run["threshold"] = t
            run["retried_files"] = r.retriedFiles
            run["retried_ratio"] = retryPct / 100
            if let accuracy = r.accuracy { run["accuracy"] = accuracyJSON(accuracy) }
            runs.append(run)
        }

        var baseline = baselineStats
        if let accuracyBaseline { baseline["accuracy"] = accuracyJSON(accuracyBaseline) }

        if options.outputFormat == .json {
            let output: [String: Any] = [
                "schema_version": "1.0",
                "mode": "adaptive_sweep",
                "environment": environmentInfo(),
                "ocr": ocrInfo(level: "fast+accurate", concurrency: concurrency, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
                "thresholds": thresholds,
                "baseline_wall_seconds": baseWall,
                "runs": runs,
                "baseline_accurate": baseline,
            ]
            emitJSON(output, path: options.jsonPath)
        }
    }

    private static func ownerKey(_ filename: String) -> String {
        if let range = filename.range(of: " (page ") {
            return String(filename[..<range.lowerBound])
        }
        return filename
    }

    private static func runStats(_ items: [OCRItem], wall: TimeInterval) -> [String: Any] {
        let successful = items.filter { $0.error == nil && !$0.text.isEmpty }.count
        let failed = items.filter { $0.error != nil }.count
        let empty = items.filter { $0.error == nil && $0.text.isEmpty }.count
        let (p50, p95, p99) = percentiles(items.map(\.duration))
        let throughput = wall > 0 ? Double(items.count) / wall : 0
        return [
            "items": items.count,
            "successful": successful,
            "failed": failed,
            "empty": empty,
            "wall_clock_seconds": wall,
            "throughput_items_s": throughput,
            "p50_latency_ms": p50 * 1000,
            "p95_latency_ms": p95 * 1000,
            "p99_latency_ms": p99 * 1000,
        ]
    }

    // MARK: - Resolution sweep

    private static func runResizeSweep(images: [URL], options: RunOptions) async {
        let sizes = [512, 1024, 1536, 2048, 3072, 4096, 0]   // 0 = native
        print("🔍 Resolution sweep (accurate) over [\(sizes.map { $0 == 0 ? "native" : String($0) }.joined(separator: ", "))]…")
        print(String(repeating: "─", count: 60))
        print(pad("MaxSide", 12) + pad("Wall(s)", 12) + pad("img/s", 9) + pad("p50(ms)", 11) + pad("p95(ms)", 11) + pad("CER(%)", 10) + "WER(%)")
        print(String(repeating: "─", count: 60))

        var runs: [[String: Any]] = []
        for size in sizes {
            var config = OCRConfiguration.default
            applyCommonConfig(&config, options: options)

            let start = CFAbsoluteTimeGetCurrent()
            let (paths, cleanup) = preparePaths(images: images, maxPixelSide: size == 0 ? nil : size)
            let results = await OCRService.recognizeText(paths: paths, config: config)
            let wall = CFAbsoluteTimeGetCurrent() - start
            cleanup()

            let (p50, p95, _) = percentiles(results.map(\.duration))
            let throughput = wall > 0 ? Double(results.count) / wall : 0
            let accuracy = options.referencesDir.map { computeAccuracy(results: results, referencesDir: $0) }
            let cerPct = accuracy.map { $0.compared > 0 ? $0.cerSum / Double($0.compared) * 100 : 0 } ?? 0
            let werPct = accuracy.map { $0.compared > 0 ? $0.werSum / Double($0.compared) * 100 : 0 } ?? 0

            let label = size == 0 ? "native" : String(size)
            print(pad(label, 12) + pad(String(format: "%.2f", wall), 12) + pad(String(format: "%.1f", throughput), 9)
                + pad(String(format: "%.0f", p50 * 1000), 11) + pad(String(format: "%.0f", p95 * 1000), 11)
                + pad(String(format: "%.2f", cerPct), 10) + String(format: "%.2f", werPct))

            var run: [String: Any] = [
                "max_pixel_side": size,
                "wall_clock_seconds": wall,
                "throughput_img_s": throughput,
                "p50_latency_ms": p50 * 1000,
                "p95_latency_ms": p95 * 1000,
                "items": results.count,
            ]
            if let accuracy { run["accuracy"] = accuracyJSON(accuracy) }
            runs.append(run)
        }

        if options.outputFormat == .json {
            let output: [String: Any] = [
                "schema_version": "1.0",
                "mode": "resize_sweep",
                "environment": environmentInfo(),
                "ocr": ocrInfo(level: "accurate", concurrency: options.concurrency ?? 4, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
                "sizes": sizes,
                "runs": runs,
            ]
            emitJSON(output, path: options.jsonPath)
        }
    }

    // MARK: - Accuracy (CER / WER)

    private static func computeAccuracy(results: [OCRItem], referencesDir: String) -> AccuracySummary {
        var summary = AccuracySummary()
        for r in results {
            let base = baseName(r.filename)
            let refPath = (referencesDir as NSString).appendingPathComponent("\(base).txt")
            guard let reference = try? String(contentsOfFile: refPath, encoding: .utf8) else { continue }

            let c = cerDetail(reference: reference, predicted: r.text)
            let w = werDetail(reference: reference, predicted: r.text)
            let exact = normalize(reference) == normalize(r.text) ? 1.0 : 0.0
            summary.compared += 1
            summary.cerSum += c.rate
            summary.cerDistSum += c.dist
            summary.cerRefSum += c.refCount
            summary.werSum += w.rate
            summary.werDistSum += w.dist
            summary.werRefSum += w.refCount
            summary.exactSum += exact
            summary.perFile.append(["filename": r.filename, "cer": c.rate, "wer": w.rate, "exact": exact == 1.0])
        }
        return summary
    }

    private static func accuracyJSON(_ a: AccuracySummary) -> [String: Any] {
        guard a.compared > 0 else {
            return ["compared": 0, "cer_macro": 0, "cer_micro": 0, "wer_macro": 0, "wer_micro": 0, "exact_match": 0, "per_file": []]
        }
        return [
            "compared": a.compared,
            "cer_macro": a.cerSum / Double(a.compared),
            "cer_micro": a.cerRefSum > 0 ? Double(a.cerDistSum) / Double(a.cerRefSum) : 0,
            "wer_macro": a.werSum / Double(a.compared),
            "wer_micro": a.werRefSum > 0 ? Double(a.werDistSum) / Double(a.werRefSum) : 0,
            "exact_match": a.exactSum / Double(a.compared),
            "per_file": a.perFile,
        ]
    }

    private static func baseName(_ filename: String) -> String { OCRService.baseName(filename) }

    private static func normalize(_ s: String) -> String { OCRService.normalizeText(s) }

    private static func levenshtein<Element: Equatable>(_ a: [Element], _ b: [Element]) -> Int { OCRService.levenshteinDistance(a, b) }

    private static func cerDetail(reference: String, predicted: String) -> (rate: Double, dist: Int, refCount: Int) { OCRService.cerDetail(reference: reference, predicted: predicted) }

    private static func werDetail(reference: String, predicted: String) -> (rate: Double, dist: Int, refCount: Int) { OCRService.werDetail(reference: reference, predicted: predicted) }

    // MARK: - Environment / config metadata

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func environmentInfo() -> [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return [
            "os": "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "device_model": sysctlString("hw.model") ?? "unknown",
            "soc": sysctlString("machdep.cpu.brand_string") ?? "unknown",
            "memory_gb": Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0,
        ]
    }

    private static func ocrInfo(level: String, concurrency: Int, autoLang: Bool, languages: [String] = ["en-US"], legacyEngine: Bool = false) -> [String: Any] {
        return [
            "recognition_level": level,
            "recognition_languages": languages,
            "language_correction": true,
            "automatically_detects_language": autoLang,
            "concurrency": concurrencyInfo(requested: concurrency),
            "force_legacy_engine": legacyEngine,
            "engine_api": visionEngineAPI(level: level, legacyEngine: legacyEngine),
            "engine_revision": visionEngineRevision(level: level, legacyEngine: legacyEngine),
        ]
    }

    /// Which Vision request type is used for a given recognition level. The
    /// adaptive ("fast+accurate") path mixes engines on macOS 26, which matters
    /// when interpreting benchmark results.
    private static func visionEngineAPI(level: String, legacyEngine: Bool) -> String {
        if level.contains("fast") && level.contains("accurate") {
            return "fast=RecognizeTextRequest,accurate=\(accurateAPI(legacy: legacyEngine))"
        }
        if level == "fast" { return "RecognizeTextRequest" }
        return accurateAPI(legacy: legacyEngine)
    }

    private static func accurateAPI(legacy: Bool) -> String {
        if #available(macOS 26.0, *), !legacy { return "RecognizeDocumentsRequest" }
        return "RecognizeTextRequest"
    }

    /// Per-engine revision so the reported revision matches the API actually
    /// used (documents vs text requests differ on macOS 26).
    private static func visionEngineRevision(level: String, legacyEngine: Bool) -> String {
        if level.contains("fast") && level.contains("accurate") {
            return "fast=\(OCRService.visionRevisionLabel()),accurate=\(accurateRevision(legacy: legacyEngine))"
        }
        if level == "fast" { return OCRService.visionRevisionLabel() }
        return accurateRevision(legacy: legacyEngine)
    }

    private static func accurateRevision(legacy: Bool) -> String {
        if #available(macOS 26.0, *), !legacy { return OCRService.documentsRevisionLabel() }
        return OCRService.visionRevisionLabel()
    }

    /// Report requested vs effective concurrency so published sweep graphs are
    /// unambiguous about how many requests actually ran concurrently.
    private static func concurrencyInfo(requested: Int) -> [String: Any] {
        let policy = ConcurrencyPolicy.benchmark(maxConcurrent: 16)
        let effective = OCRService.clampedConcurrency(requested, policy: policy)
        return [
            "requested_concurrency": requested,
            "effective_concurrency": effective,
            "safety_ceiling": policy.ceiling,
            "policy": "benchmark",
            "benchmark_mode": true,
        ]
    }

    // MARK: - Output

    private static func printSingleTable(
        results: [OCRItem], totalElapsed: TimeInterval, totalDuration: TimeInterval,
        avgDuration: TimeInterval, imagesPerSecond: Double, successful: Int, failed: Int, empty: Int,
        p50: Double, p95: Double, p99: Double, accuracy: AccuracySummary?, concurrency: Int
    ) {
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

        print(String(repeating: "─", count: 60))
        print("📊 Summary:")
        print("   Concurrency:        \(concurrency)")
        print("   Total images:       \(results.count)")
        print("   Successful OCR:     \(successful)")
        print("   Empty results:      \(empty)")
        print("   Failed:             \(failed)")
        print(String(format: "   Wall-clock time:    %.3fs", totalElapsed))
        print(String(format: "   Sum of durations:  %.3fs", totalDuration))
        print(String(format: "   Average per image: %.3fs", avgDuration))
        print(String(format: "   Throughput:        %.1f images/s", imagesPerSecond))
        print(String(format: "   p50 latency:       %.0f ms", p50 * 1000))
        print(String(format: "   p95 latency:       %.0f ms", p95 * 1000))
        print(String(format: "   p99 latency:       %.0f ms", p99 * 1000))
        if let accuracy, accuracy.compared > 0 {
            let cerMicro = accuracy.cerRefSum > 0 ? Double(accuracy.cerDistSum) / Double(accuracy.cerRefSum) * 100 : 0
            let werMicro = accuracy.werRefSum > 0 ? Double(accuracy.werDistSum) / Double(accuracy.werRefSum) * 100 : 0
            print(String(format: "   CER macro (chars): %.3f%%", accuracy.cerSum / Double(accuracy.compared) * 100))
            print(String(format: "   CER micro (chars): %.3f%%", cerMicro))
            print(String(format: "   WER macro (words): %.3f%%", accuracy.werSum / Double(accuracy.compared) * 100))
            print(String(format: "   WER micro (words): %.3f%%", werMicro))
            print(String(format: "   Exact match:       %.1f%% (%d references)", accuracy.exactSum / Double(accuracy.compared) * 100, accuracy.compared))
        }
    }

    private static func buildSingleJSON(
        results: [OCRItem], options: RunOptions, levelLabel: String, concurrency: Int,
        totalElapsed: TimeInterval, totalDuration: TimeInterval, avgDuration: TimeInterval,
        imagesPerSecond: Double, totalImages: Int, successful: Int, failed: Int, empty: Int,
        p50: Double, p95: Double, p99: Double, accuracy: AccuracySummary?
    ) -> [String: Any] {
        let loadMs = results.compactMap(\.loadMs)
        let visionMs = results.compactMap(\.visionMs)
        let avg = { (a: [Double]) in a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
        let summary: [String: Any] = [
            "total_images": totalImages,
            "successful": successful,
            "empty": empty,
            "failed": failed,
            "wall_clock_seconds": totalElapsed,
            "sum_duration_seconds": totalDuration,
            "avg_duration_seconds": avgDuration,
            "images_per_second": imagesPerSecond,
            "p50_latency_ms": p50 * 1000,
            "p95_latency_ms": p95 * 1000,
            "p99_latency_ms": p99 * 1000,
            "avg_load_ms": avg(loadMs),
            "avg_vision_ms": avg(visionMs),
        ]

        var output: [String: Any] = [
            "schema_version": "1.0",
            "mode": "single",
            "environment": environmentInfo(),
            "ocr": ocrInfo(level: levelLabel, concurrency: concurrency, autoLang: options.useAutoLang, languages: options.languages ?? ["en-US"], legacyEngine: options.legacyEngine),
            "summary": summary,
            "results": results.map { r in
                [
                    "filename": r.filename,
                    "text": r.text,
                    "error": r.error as Any? ?? NSNull(),
                    "duration_seconds": r.duration,
                    "load_ms": r.loadMs ?? NSNull(),
                    "vision_ms": r.visionMs ?? NSNull(),
                ]
            },
        ]
        if let accuracy { output["accuracy"] = accuracyJSON(accuracy) }
        return output
    }

    private static func emitJSON(_ object: [String: Any], path: String?) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            print("{}")
            return
        }
        if let path {
            do {
                try string.write(toFile: path, atomically: true, encoding: .utf8)
                print("📄 JSON results saved to: \(path)")
            } catch {
                print("❌ Failed to write JSON: \(error.localizedDescription)")
                print(string)
            }
        } else {
            print(string)
        }
    }

    private static func percentiles(_ durations: [Double]) -> (p50: Double, p95: Double, p99: Double) {
        let sorted = durations.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[Int((Double(sorted.count - 1) * p).rounded())]
        }
        return (pct(0.50), pct(0.95), pct(0.99))
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Argument parsing

    private static func parseOptions() -> RunOptions {
        var o = RunOptions()
        let args = CommandLine.arguments
        if args.contains("--help") || args.contains("-h") { o.help = true; return o }

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--json":
                o.outputFormat = .json
                if i + 1 < args.count, !args[i + 1].hasPrefix("-") {
                    o.jsonPath = args[i + 1]; i += 1
                }
            case "--fast":
                o.useFast = true
            case "--sequential":
                o.useSequential = true
            case "--auto-lang":
                o.useAutoLang = true
            case "--lang":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                    print("❌ --lang requires a value (e.g. ms-MY,en-US).")
                    exit(1)
                }
                o.languages = args[i + 1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                i += 1
            case "--legacy-engine":
                o.legacyEngine = true
            case "--resize-to":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
                    print("❌ --resize-to requires a positive pixel value.")
                    exit(1)
                }
                o.resizeTo = n; i += 1
            case "--resize-sweep":
                o.resizeSweep = true
            case "--sweep":
                o.sweep = true
            case "--adaptive":
                o.adaptive = true
            case "--adaptive-sweep":
                o.adaptiveSweep = true
            case "--adaptive-threshold":
                guard i + 1 < args.count, let t = Double(args[i + 1]), t >= 0, t <= 1 else {
                    print("❌ --adaptive-threshold requires a value between 0 and 1.")
                    exit(1)
                }
                o.adaptiveThreshold = t; i += 1
            case "--concurrency":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 else {
                    print("❌ --concurrency requires a positive integer value.")
                    exit(1)
                }
                o.concurrency = n; i += 1
            case "--references":
                guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                    print("❌ --references requires a directory path.")
                    exit(1)
                }
                o.referencesDir = args[i + 1]; i += 1
            case "--warmup":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 0 else {
                    print("❌ --warmup requires a non-negative integer (images to discard before measuring).")
                    exit(1)
                }
                o.warmup = n; i += 1
            case "--runs":
                guard i + 1 < args.count, let n = Int(args[i + 1]), n >= 1 else {
                    print("❌ --runs requires a positive integer (measurement passes).")
                    exit(1)
                }
                o.runs = n; i += 1
            default:
                if a.hasPrefix("-") {
                    print("Unknown option: \(a) (see --help)")
                    exit(1)
                }
                if o.folder.isEmpty { o.folder = a }
                else { print("Unexpected argument: \(a)"); exit(1) }
            }
            i += 1
        }
        return o
    }

    private static func printUsage() {
        print("""
        OCR Benchmark — measure Apple Vision text recognition performance

        Usage:
          swift run OCRBenchmark <folder-path> [options]

        Options:
          --json [path]       Output in JSON format (optionally save to file)
          --fast              Use .fast recognition level (parallel, 2-3x faster, may miss text)
          --sequential        Process images one at a time (baseline comparison)
          --concurrency N     Set parallel OCR concurrency (default 4; max 16)
          --sweep             Sweep concurrency over 1,2,3,4,5,6,8 and print a table
          --adaptive          Fast probe → retry accurate on low-confidence items; compares vs always-accurate
          --adaptive-threshold T  Retry when mean confidence < T (default 0.75; range 0-1)
          --adaptive-sweep    Sweep the adaptive threshold (0.50-0.95) to find the accuracy/latency frontier
          --auto-lang         Enable automatic language detection per image
          --lang LIST         Comma-separated recognition languages, e.g. ms-MY,en-US (priority order)
          --legacy-engine     Force the legacy RecognizeTextRequest engine even on macOS 26
          --resize-to N       Downscale images to longest side N px before OCR
          --resize-sweep      Sweep resolutions 512…4096 (+native) vs CER/WER/latency/throughput
          --references DIR    Compute CER/WER/exact-match against <basename>.txt files in DIR
          --warmup N          Discard a warm-up pass over the first N images before measuring
          --runs N            Repeat the measurement N times and report median/min/max/stddev
          --help, -h          Show this help

        Modes (default: accurate + parallel):
          (no flags)          Accurate + parallel
          --fast              Fast + parallel
          --sequential        Accurate + sequential (baseline)
          --concurrency 8     Accurate + parallel with 8 concurrent requests
          --adaptive          Fast + retry-accurate cascade (benchmarked vs always-accurate)
          --adaptive-sweep    Adaptive cascade across thresholds
          --resize-sweep      Accuracy/latency vs input resolution

        Accuracy:
          For each image `<name>.<ext>`, the reference file `<name>.txt` is loaded from
          the --references directory and used to compute Character Error Rate (CER),
          Word Error Rate (WER), and exact-match ratio.

        Examples:
          swift run OCRBenchmark ~/Screenshots
          swift run OCRBenchmark ~/Screenshots --fast
          swift run OCRBenchmark ~/Screenshots --sequential
          swift run OCRBenchmark ~/Screenshots --concurrency 6 --json results.json
          swift run OCRBenchmark ~/Screenshots --sweep --json sweep.json
          swift run OCRBenchmark ~/Screenshots --adaptive --json adaptive.json
          swift run OCRBenchmark ~/Screenshots --adaptive --adaptive-threshold 0.8
          swift run OCRBenchmark ~/Screenshots --adaptive-sweep --references ~/gt --json adapt_sweep.json
          swift run OCRBenchmark ~/Screenshots --resize-sweep --references ~/gt --json resize.json
          swift run OCRBenchmark ~/Screenshots --lang ms-MY,en-US --json results.json
          swift run OCRBenchmark ~/Screenshots --legacy-engine --json results.json
          swift run OCRBenchmark ~/Screenshots --references ~/gt --json results.json
          swift run OCRBenchmark ~/Screenshots --warmup 10 --runs 5 --json repeated.json
        """)
    }

    enum Format {
        case table, json
    }
}
