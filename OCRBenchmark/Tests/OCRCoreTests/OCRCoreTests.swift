import XCTest
import OCRCore

final class OCRCoreTests: XCTestCase {

    // MARK: - Text normalization / metrics

    func testNormalizeText() {
        XCTAssertEqual(OCRService.normalizeText("  Hello   WORLD\nfoo\tbar "), "hello world foo bar")
        XCTAssertEqual(OCRService.normalizeText(""), "")
    }

    func testLevenshtein() {
        XCTAssertEqual(OCRService.levenshteinDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(OCRService.levenshteinDistance(Array("abc"), Array("abc")), 0)
        XCTAssertEqual(OCRService.levenshteinDistance(Array(""), Array("abc")), 3)
        XCTAssertEqual(OCRService.levenshteinDistance(["a", "b"], ["a"]), 1)
    }

    func testCERDetail() {
        let exact = OCRService.cerDetail(reference: "RM 1,250.00", predicted: "RM 1,250.00")
        XCTAssertEqual(exact.rate, 0, accuracy: 1e-9)
        XCTAssertEqual(exact.refCount, 11)   // "rm 1,250.00"
        XCTAssertEqual(exact.dist, 0)

        let sub = OCRService.cerDetail(reference: "abc", predicted: "axc")
        XCTAssertEqual(sub.dist, 1)
        XCTAssertEqual(sub.rate, 1.0 / 3.0, accuracy: 1e-9)

        let empty = OCRService.cerDetail(reference: "", predicted: "x")
        XCTAssertEqual(empty.rate, 1)
    }

    func testWERDetail() {
        let exact = OCRService.werDetail(reference: "one two three", predicted: "one two three")
        XCTAssertEqual(exact.rate, 0, accuracy: 1e-9)
        XCTAssertEqual(exact.refCount, 3)

        let sub = OCRService.werDetail(reference: "one two three", predicted: "one five three")
        XCTAssertEqual(sub.dist, 1)
        XCTAssertEqual(sub.rate, 1.0 / 3.0, accuracy: 1e-9)
    }

    func testBaseName() {
        XCTAssertEqual(OCRService.baseName("photo.png"), "photo")
        XCTAssertEqual(OCRService.baseName("doc.pdf (page 3)"), "doc")
        XCTAssertEqual(OCRService.baseName("a.b.c.jpg"), "a.b.c")
    }

    func testPercentile() {
        XCTAssertEqual(OCRService.percentileValue([1, 2, 3, 4, 5], 0.5), 3)
        XCTAssertEqual(OCRService.percentileValue([5, 4, 3, 2, 1], 0.95), 5)
        XCTAssertNil(OCRService.percentileValue([], 0.5))
    }

    // MARK: - Adaptive routing

    func testShouldRetryEmptyText() {
        let d = OCRService.shouldRetry(textIsEmpty: true, meanConfidence: 0.99, minConfidence: 0.9, lowConfidenceRatio: 0, threshold: 0.75)
        XCTAssertTrue(d.retry)
        XCTAssertEqual(d.reason, "empty_text")
    }

    func testShouldRetryMinConfidenceHidesBehindHighMean() {
        let d = OCRService.shouldRetry(textIsEmpty: false, meanConfidence: 0.91, minConfidence: 0.20, lowConfidenceRatio: 0.1, threshold: 0.75)
        XCTAssertTrue(d.retry)
        XCTAssertEqual(d.reason, "min_confidence")
    }

    func testShouldRetryLowRatio() {
        let d = OCRService.shouldRetry(textIsEmpty: false, meanConfidence: 0.8, minConfidence: 0.6, lowConfidenceRatio: 0.3, threshold: 0.75)
        XCTAssertTrue(d.retry)
        XCTAssertEqual(d.reason, "low_ratio")
    }

    func testShouldRetryMeanBelowThreshold() {
        let d = OCRService.shouldRetry(textIsEmpty: false, meanConfidence: 0.6, minConfidence: 0.6, lowConfidenceRatio: 0, threshold: 0.75)
        XCTAssertTrue(d.retry)
        XCTAssertEqual(d.reason, "mean_confidence")
    }

    func testShouldRetryAccept() {
        let d = OCRService.shouldRetry(textIsEmpty: false, meanConfidence: 0.9, minConfidence: 0.6, lowConfidenceRatio: 0, threshold: 0.75)
        XCTAssertFalse(d.retry)
        XCTAssertNil(d.reason)
    }

    // MARK: - Coordinate conversion (Vision bottom-left → bitmap top-left)

    func testBitmapRectConversion() {
        let r = OCRService.bitmapRect(fromNormalized: [0.1, 0.1, 0.2, 0.05], imageWidth: 1000, imageHeight: 2000)
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.x, 100, accuracy: 1e-9)
        XCTAssertEqual(r!.y, 1700, accuracy: 1e-9)   // (1 - 0.1 - 0.05) * 2000
        XCTAssertEqual(r!.width, 200, accuracy: 1e-9)
        XCTAssertEqual(r!.height, 100, accuracy: 1e-9)
    }

    func testBitmapRectTopAndBottom() {
        // Top of the image: block bottom at y=0.9 with height 0.1 → bitmap y=0.
        let top = OCRService.bitmapRect(fromNormalized: [0, 0.9, 0.5, 0.1], imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(top!.y, 0, accuracy: 1e-9)
        // Bottom of the image (y=0) maps to bitmap y = H - h.
        let bottom = OCRService.bitmapRect(fromNormalized: [0, 0, 0.5, 0.1], imageWidth: 100, imageHeight: 100)
        XCTAssertEqual(bottom!.y, 90, accuracy: 1e-9)
    }

    func testBitmapRectBadInput() {
        XCTAssertNil(OCRService.bitmapRect(fromNormalized: [0.1, 0.2], imageWidth: 100, imageHeight: 100))
    }

    // MARK: - Concurrency policy

    func testConcurrencyClamp() {
        XCTAssertEqual(OCRService.clampedConcurrency(0), 1)
        XCTAssertEqual(OCRService.clampedConcurrency(4), 4)
        XCTAssertEqual(OCRService.clampedConcurrency(16), 16)
        XCTAssertEqual(OCRService.clampedConcurrency(99), 16)
        XCTAssertEqual(OCRService.clampedConcurrency(8, policy: .production(maxConcurrent: 4)), 4)
        XCTAssertEqual(OCRService.clampedConcurrency(8, policy: .benchmark(maxConcurrent: 16)), 8)
    }

    // MARK: - PDF render scale

    func testPDFRenderScaleLetter() {
        // US Letter in points (612 × 792): 200 DPI target is 200/72 ≈ 2.777…
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let scale = OCRService.renderScale(for: bounds)
        XCTAssertEqual(scale, 200.0 / 72.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(792 * scale, 4096)
    }

    func testPDFRenderScaleCapped() {
        // Huge page: 200 DPI would exceed the 4096px cap, so scale is clamped.
        let bounds = CGRect(x: 0, y: 0, width: 2000, height: 3000)
        let scale = OCRService.renderScale(for: bounds)
        XCTAssertEqual(3000 * scale, 4096, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(3000 * scale, 4096)
    }

    func testPDFRenderScaleCustomCap() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        XCTAssertEqual(OCRService.renderScale(for: bounds, maxPixelSide: 512), 0.512, accuracy: 1e-6)
    }
}
