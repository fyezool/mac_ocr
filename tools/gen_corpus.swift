#!/usr/bin/env swift
// Deterministic benchmark-corpus generator.
//
// Renders each image from its own ground-truth string, so `references/<base>.txt`
// is exact by construction and the whole set is reproducible on any macOS host
// (only system fonts are used). Usage:
//
//   swift tools/gen_corpus.swift [outDir]     # default: ./corpus
//
// Outputs:
//   corpus/images/<id>.<png|pdf>
//   corpus/references/<base>.txt
//   corpus/manifest.json   (corpus_version, schema_version, per-file metadata)

import AppKit
import CoreGraphics
import Foundation

let corpusVersion = "1.1"
let schemaVersion = "1.0"

// MARK: - Rendering helpers (NSBitmapImageRep-backed; AppKit sets up the whole
// text-drawing environment correctly, which a hand-rolled flipped CGContext
// does not.)

func newRep(w: Int, h: Int) -> NSBitmapImageRep? {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                     isPlanar: false, colorSpaceName: .deviceRGB,
                     bytesPerRow: 0, bitsPerPixel: 0)
}

func renderRep(text: String, font: NSFont, w: Int, h: Int,
               rotationDegrees: Double = 0, noiseSeed: UInt32? = nil,
               pad: CGFloat = 28) -> NSBitmapImageRep? {
    guard let rep = newRep(w: w, h: h) else { return nil }
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()

    if rotationDegrees != 0 {
        let t = NSAffineTransform()
        t.translateX(by: CGFloat(w) / 2, yBy: CGFloat(h) / 2)
        t.rotate(byDegrees: CGFloat(rotationDegrees))
        t.translateX(by: -CGFloat(w) / 2, yBy: -CGFloat(h) / 2)
        t.concat()
    }

    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    let lineHeight = font.ascender - font.descender + font.leading
    var y = CGFloat(h) - pad - lineHeight          // non-flipped rep: draw top-down
    for line in text.components(separatedBy: "\n") {
        (line as NSString).draw(at: CGPoint(x: pad, y: y), withAttributes: attrs)
        y -= lineHeight
    }

    if let seed = noiseSeed {
        srand48(Int(seed))
        let noise = NSColor.black.withAlphaComponent(0.09)
        noise.setFill()
        for _ in 0..<220 {
            let x = drand48() * Double(w)
            let yv = drand48() * Double(h)
            NSBezierPath(ovalIn: NSRect(x: x, y: yv, width: 1.5, height: 1.5)).fill()
        }
        NSColor.black.withAlphaComponent(0.05).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: Double(h) * 0.38, width: Double(w), height: 4)).fill()
        NSBezierPath(rect: NSRect(x: 0, y: Double(h) * 0.62, width: Double(w), height: 4)).fill()
    }

    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func renderColumnsRep(texts: [String], font: NSFont, w: Int, h: Int, gap: CGFloat = 48) -> NSBitmapImageRep? {
    guard let rep = newRep(w: w, h: h) else { return nil }
    let ns = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns

    NSColor.white.setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: w, height: h)).fill()

    let colW = (CGFloat(w) - gap) / 2
    let lineHeight = font.ascender - font.descender + font.leading
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
    for (ci, colText) in texts.enumerated() {
        var y = CGFloat(h) - 28 - lineHeight
        let x = 28 + CGFloat(ci) * (colW + gap)
        for line in colText.components(separatedBy: "\n") {
            (line as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
            y -= lineHeight
        }
    }

    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func downscaledRep(_ rep: NSBitmapImageRep, to w: Int, h: Int) -> NSBitmapImageRep? {
    guard let target = newRep(w: w, h: h) else { return nil }
    let ns = NSGraphicsContext(bitmapImageRep: target)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    ns.imageInterpolation = .high
    let img = NSImage(size: NSSize(width: rep.pixelsWide, height: rep.pixelsHigh))
    img.addRepresentation(rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.current = nil
    NSGraphicsContext.restoreGraphicsState()
    return target
}

func pngData(from rep: NSBitmapImageRep) -> Data? {
    rep.representation(using: .png, properties: [:])
}

func writePDF(pages: [String], to url: URL) {
    // Render each page's text to a bitmap and embed it in the PDF — avoids any
    // text-into-CG-PDF-context fragility, and PDFKit re-renders it to an image.
    var media = CGRect(x: 0, y: 0, width: 612, height: 792)
    guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { return }
    for text in pages {
        guard let rep = renderRep(text: text, font: NSFont.systemFont(ofSize: 18), w: 1000, h: 620),
              let cg = rep.cgImage else { continue }
        ctx.beginPDFPage(nil)
        ctx.draw(cg, in: CGRect(x: 56, y: 120, width: 500, height: 310))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

// MARK: - Corpus definitions

struct File {
    let id: String
    let reference: String
    let language: String
    let layout: String
    let ext: String
    let notes: String
    /// Multi-page PDF convention: page-indexed reference files
    /// `<base>.page-NNN.txt` (one per page). When set, `reference` is unused.
    let pageReferences: [(page: Int, text: String)]?
    let render: (URL) -> Bool   // returns true on success

    init(id: String, reference: String, language: String, layout: String, ext: String, notes: String,
         pageReferences: [(page: Int, text: String)]? = nil, render: @escaping (URL) -> Bool) {
        self.id = id
        self.reference = reference
        self.language = language
        self.layout = layout
        self.ext = ext
        self.notes = notes
        self.pageReferences = pageReferences
        self.render = render
    }
}

func imageFile(id: String, reference: String, language: String, layout: String, notes: String,
               text: String, font: NSFont, w: Int, h: Int,
               rotation: Double = 0, noise: UInt32? = nil, scaleTo: (w: Int, h: Int)? = nil) -> File {
    File(id: id, reference: reference, language: language, layout: layout, ext: "png", notes: notes) { url in
        guard var rep = renderRep(text: text, font: font, w: w, h: h, rotationDegrees: rotation, noiseSeed: noise) else { return false }
        if let scaleTo {
            guard let s = downscaledRep(rep, to: scaleTo.w, h: scaleTo.h) else { return false }
            rep = s
        }
        guard let data = pngData(from: rep) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

var files: [File] = []
let bodyFont = NSFont.systemFont(ofSize: 26)

// 1. Printed paragraph
files.append(imageFile(
    id: "printed", reference: "The quick brown fox jumps over the lazy dog. This sentence contains every letter of the English alphabet and is a classic test of type rendering.\nAlthough short, the pangram exercises ascenders, descenders, and the fine strokes of a font.\nFor OCR benchmarking, a known reference string makes character error rates exact and reproducible across machines and operating systems.\nThe neural engine processes each image in parallel, bounded by a global concurrency gate so the chip is never oversubscribed.",
    language: "en-US", layout: "paragraph", notes: "Plain printed English paragraph, standard size",
    text: "The quick brown fox jumps over the lazy dog. This sentence contains every letter of the English alphabet and is a classic test of type rendering.\nAlthough short, the pangram exercises ascenders, descenders, and the fine strokes of a font.\nFor OCR benchmarking, a known reference string makes character error rates exact and reproducible across machines and operating systems.\nThe neural engine processes each image in parallel, bounded by a global concurrency gate so the chip is never oversubscribed.",
    font: bodyFont, w: 1400, h: 460))

// 2. Monospaced receipt with numbers
files.append(imageFile(
    id: "receipt", reference: "WARUNG SEDAP SDN BHD\nNo. 12 Jalan Ampang, Kuala Lumpur\nTel: 03-1234 5678\n----------------------------------------\nItem              Qty      Amount\nNasi Lemak         2      RM 12.00\nMee Goreng         1       RM 8.50\nTeh Tarik          2       RM 4.00\nKopi O             1       RM 2.50\nRoti Canai         2       RM 5.00\n----------------------------------------\nSUBTOTAL                   RM 32.00\nSST 6%                     RM 1.92\nTOTAL                      RM 33.92",
    language: "en-MS", layout: "table", notes: "Monospaced receipt, dense digits and currency",
    text: "WARUNG SEDAP SDN BHD\nNo. 12 Jalan Ampang, Kuala Lumpur\nTel: 03-1234 5678\n----------------------------------------\nItem              Qty      Amount\nNasi Lemak         2      RM 12.00\nMee Goreng         1       RM 8.50\nTeh Tarik          2       RM 4.00\nKopi O             1       RM 2.50\nRoti Canai         2       RM 5.00\n----------------------------------------\nSUBTOTAL                   RM 32.00\nSST 6%                     RM 1.92\nTOTAL                      RM 33.92",
    font: NSFont.monospacedSystemFont(ofSize: 24, weight: .regular), w: 1200, h: 560))

// 3. Small text (stresses the enhance/recovery path)
files.append(imageFile(
    id: "small_text", reference: "Minimum viable text size on a phone screen.\nTwelve point type is still legible to the ANE.\nSmall text stresses the recovery pipeline.",
    language: "en-US", layout: "small-text", notes: "Small font, tests enhanceSmallText",
    text: "Minimum viable text size on a phone screen.\nTwelve point type is still legible to the ANE.\nSmall text stresses the recovery pipeline.",
    font: NSFont.systemFont(ofSize: 14), w: 900, h: 200))

// 4. Two-column layout (order-sensitive — compare across machines, not absolute)
files.append(File(
    id: "multicolumn", reference: "Column one: the first paragraph about layout.\nColumns are read left to right by humans.\nThis sample stresses structural fidelity.\nColumn two: the second paragraph.\nVision may reorder columns across engines.\nCompare this row across machines, not in isolation.",
    language: "en-US", layout: "multicolumn", ext: "png", notes: "Order-sensitive: measures layout reconstruction, compare relative across machines") { url in
    guard let rep = renderColumnsRep(
        texts: ["Column one: the first paragraph about layout.\nColumns are read left to right by humans.\nThis sample stresses structural fidelity.",
                "Column two: the second paragraph.\nVision may reorder columns across engines.\nCompare this row across machines, not in isolation."],
        font: bodyFont, w: 1200, h: 320),
        let data = pngData(from: rep) else { return false }
    return (try? data.write(to: url)) != nil
})

// 5. Slightly rotated text
files.append(imageFile(
    id: "rotated", reference: "This line is rotated three degrees about the image centre.\nDetection must still locate and read it correctly.",
    language: "en-US", layout: "rotated", notes: "~3 degree rotation",
    text: "This line is rotated three degrees about the image centre.\nDetection must still locate and read it correctly.",
    font: bodyFont, w: 1100, h: 340, rotation: 3))

// 6. Script font (handwriting-LIKE — a cursive system font, NOT real
//    handwriting; rename and treat accordingly)
files.append(imageFile(
    id: "script_font", reference: "A quick brown fox jumps over the lazy dog\nwritten in a cursive hand for handwriting-like OCR.",
    language: "en-US", layout: "script_font", notes: "Cursive SCRIPT FONT (Apple Chancery) — font recognition, not handwriting recognition",
    text: "A quick brown fox jumps over the lazy dog\nwritten in a cursive hand for handwriting-like OCR.",
    font: NSFont(name: "Apple Chancery", size: 30) ?? bodyFont, w: 1100, h: 260))

// 7. Malay text (ms-MY)
files.append(imageFile(
    id: "malay", reference: "Selamat pagi. Kualiti hidup rakyat semakin baik setiap tahun.\nBina insan seimbang dengan pendidikan dan kesihatan yang sempurna.",
    language: "ms-MY", layout: "paragraph", notes: "Malay-language paragraph (Latin script)",
    text: "Selamat pagi. Kualiti hidup rakyat semakin baik setiap tahun.\nBina insan seimbang dengan pendidikan dan kesihatan yang sempurna.",
    font: bodyFont, w: 1200, h: 240))

// 8. Low resolution (rendered 2x then downsampled)
files.append(imageFile(
    id: "lowres", reference: "Large type rendered at low resolution.\nThe enhancement path upscales before re-recognising.",
    language: "en-US", layout: "lowres", notes: "Downsampled 2x — stresses upscaling/recovery",
    text: "Large type rendered at low resolution.\nThe enhancement path upscales before re-recognising.",
    font: NSFont.systemFont(ofSize: 44), w: 1100, h: 260, scaleTo: (550, 130)))

// 9. Noisy background
files.append(imageFile(
    id: "noisy", reference: "Text on a lightly textured background.\nSalt and pepper noise should not hide the words.",
    language: "en-US", layout: "noisy", notes: "Seeded salt-and-pepper noise + faint bands",
    text: "Text on a lightly textured background.\nSalt and pepper noise should not hide the words.",
    font: bodyFont, w: 1100, h: 260, noise: 42))

// 10. Dense numbers / currency
files.append(imageFile(
    id: "numbers", reference: "RM 1,250.00\nRM 48,320.75\nRM 99,999.99\nRM 0.05\nRM 12,345,678.90",
    language: "en-US", layout: "numeric", notes: "Dense currency figures, digit accuracy",
    text: "RM 1,250.00\nRM 48,320.75\nRM 99,999.99\nRM 0.05\nRM 12,345,678.90",
    font: NSFont.monospacedSystemFont(ofSize: 34, weight: .medium), w: 900, h: 320))

// 11. Longer document
files.append(imageFile(
    id: "long_doc", reference: "The corpus exists to make OCR results comparable across operating systems and chips.\nEvery machine runs the same images and the same reference transcripts, so a\ndifference in CER or latency can be attributed to the hardware or the Vision\nrevision rather than to a different test set.\nThe generator renders each image from its own ground-truth string, so the\nreference text is exact by construction and the whole set is reproducible.",
    language: "en-US", layout: "paragraph", notes: "Longer text — larger CER sample",
    text: "The corpus exists to make OCR results comparable across operating systems and chips.\nEvery machine runs the same images and the same reference transcripts, so a\ndifference in CER or latency can be attributed to the hardware or the Vision\nrevision rather than to a different test set.\nThe generator renders each image from its own ground-truth string, so the\nreference text is exact by construction and the whole set is reproducible.",
    font: bodyFont, w: 1400, h: 460))

// 12. One-page PDF
let statementPDF = "Monthly Statement of Account\nAccount number: 1234-5678-9012\nOpening balance: RM 2,150.00\nPayments received: RM 800.00\nInterest: RM 12.30\nClosing balance: RM 1,362.30\nThis statement was generated for benchmarking purposes."
files.append(File(
    id: "statement", reference: statementPDF, language: "en-US", layout: "pdf", ext: "pdf",
    notes: "Single-page PDF — exercises the (page N) path") { url in
    writePDF(pages: [statementPDF], to: url)
    return FileManager.default.fileExists(atPath: url.path)
})

// 13. Two-page PDF — exercises the page-indexed reference convention
//     (`statement2.page-001.txt` / `statement2.page-002.txt`).
let statement2Page1 = "Quotation No. Q-2026-0142\nClient: Fyezool Technologies Sdn Bhd\nItem              Qty      Amount\nOCR integration      3     RM 9,000.00\nAPI development       2     RM 12,500.00\nSubtotal                   RM 21,500.00\nSST 6%                     RM 1,290.00\nTotal                      RM 22,790.00"
let statement2Page2 = "Terms: 30 days net from invoice date.\nPayment: bank transfer to MAYBANK 5123-4567-8901.\nThis quotation is valid for 90 days from the date of issue."
files.append(File(
    id: "statement2", reference: statement2Page1, language: "en-MS", layout: "pdf", ext: "pdf",
    notes: "Two-page PDF — validates page-indexed reference lookup",
    pageReferences: [(1, statement2Page1), (2, statement2Page2)]) { url in
    writePDF(pages: [statement2Page1, statement2Page2], to: url)
    return FileManager.default.fileExists(atPath: url.path)
})

// MARK: - Emit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "corpus"
let imagesDir = (outDir as NSString).appendingPathComponent("images")
let refsDir = (outDir as NSString).appendingPathComponent("references")
try? FileManager.default.createDirectory(atPath: imagesDir, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(atPath: refsDir, withIntermediateDirectories: true)

var manifestFiles: [[String: Any]] = []
for f in files {
    let imagePath = (imagesDir as NSString).appendingPathComponent("\(f.id).\(f.ext)")
    let refPath = (refsDir as NSString).appendingPathComponent("\(f.id).txt")
    guard f.render(URL(fileURLWithPath: imagePath)) else {
        print("❌ failed to render \(f.id).\(f.ext)")
        continue
    }
    if let pageRefs = f.pageReferences {
        for (page, text) in pageRefs {
            let pr = (refsDir as NSString).appendingPathComponent("\(f.id).page-\(String(format: "%03d", page)).txt")
            try? text.write(toFile: pr, atomically: true, encoding: .utf8)
        }
    } else {
        try? f.reference.write(toFile: refPath, atomically: true, encoding: .utf8)
    }
    var entry: [String: Any] = [
        "id": f.id,
        "filename": "\(f.id).\(f.ext)",
        "language": f.language,
        "layout": f.layout,
        "notes": f.notes,
    ]
    if let pageRefs = f.pageReferences {
        entry["reference"] = pageRefs.map { "\(f.id).page-\(String(format: "%03d", $0.page)).txt" }
    } else {
        entry["reference"] = "\(f.id).txt"
    }
    manifestFiles.append(entry)
    print("✓ \(f.id).\(f.ext)  (\(f.layout), \(f.language))")
}

let manifest: [String: Any] = [
    "corpus_version": corpusVersion,
    "schema_version": schemaVersion,
    "generator": "tools/gen_corpus.swift",
    "generated_at": ISO8601DateFormatter().string(from: Date()),
    "files": manifestFiles,
]
let manifestPath = (outDir as NSString).appendingPathComponent("manifest.json")
if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: URL(fileURLWithPath: manifestPath))
}
print("📦 corpus_version \(corpusVersion) — \(files.count) files → \(outDir)/")
