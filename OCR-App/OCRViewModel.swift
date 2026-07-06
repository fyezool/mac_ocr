import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - OCR State

@MainActor
final class OCRViewModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var results: [OCRItem]?
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var elapsed: TimeInterval = 0
    @Published var isFastMode = false
    @Published var selectedResultIndex: Int = 0
    @Published var isDragOver = false

    private var generation = 0
    private var timer: Timer?
    private var startTime: Date?

    var hasFiles: Bool { !files.isEmpty }
    var hasResults: Bool { results != nil && !results!.isEmpty }
    var hasError: Bool { errorMessage != nil }
    var fileCount: Int { files.count }
    var resultCount: Int { results?.count ?? 0 }

    var selectedResult: OCRItem? {
        guard let r = results, selectedResultIndex >= 0, selectedResultIndex < r.count else { return nil }
        return r[selectedResultIndex]
    }

    // MARK: - Actions

    func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [
            .png, .jpeg, .gif, .bmp, .tiff,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image
        ]
        guard panel.runModal() == .OK else { return }
        addURLs(panel.urls)
    }

    func addURLs(_ urls: [URL]) {
        guard !isBusy else { return }
        var all: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                all.append(contentsOf: OCRService.collectImages(from: url))
            } else {
                all.append(url)
            }
        }
        guard !all.isEmpty else { return }
        generation &+= 1
        files = all
        results = nil
        errorMessage = nil
    }

    func runOCR() {
        guard !files.isEmpty, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        elapsed = 0
        startTime = Date()
        let gen = generation

        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, self.isBusy, let start = self.startTime else { return }
            Task { @MainActor in
                self.elapsed = Date().timeIntervalSince(start)
            }
        }

        let paths = files.map(\.path)
        let fast = isFastMode

        Task {
            let r = await OCRService.recognizeText(paths: paths, fast: fast)
            await MainActor.run {
                timer?.invalidate()
                timer = nil
                guard gen == self.generation else { return }
                elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
                results = r
                isBusy = false
                selectedResultIndex = 0
            }
        }
    }

    func clearAll() {
        files = []
        results = nil
        errorMessage = nil
        elapsed = 0
        isBusy = false
        generation &+= 1
        selectedResultIndex = 0
        timer?.invalidate()
        timer = nil
    }

    func copyAll() {
        guard let r = results, !r.isEmpty else { return }
        let text = r.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copySelected() {
        guard let item = selectedResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
    }

    func saveResults() {
        guard let r = results, !r.isEmpty else { return }
        let text = r.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ocr_results_\(Int(Date().timeIntervalSince1970)).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - History persistence

    private(set) var history: [HistoryEntry] = []

    func saveToHistory() {
        guard let r = results, !r.isEmpty else { return }
        let entry = HistoryEntry(
            id: UUID(),
            date: Date(),
            fileCount: files.count,
            totalDuration: elapsed,
            hasErrors: r.contains(where: { $0.error != nil })
        )
        history.append(entry)
    }
}

// MARK: - Models

struct HistoryEntry: Identifiable {
    let id: UUID
    let date: Date
    let fileCount: Int
    let totalDuration: TimeInterval
    let hasErrors: Bool
}
