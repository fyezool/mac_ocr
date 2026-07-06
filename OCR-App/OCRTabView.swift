import SwiftUI
import UniformTypeIdentifiers

// MARK: - OCR Tab

struct OCRTabView: View {
    @EnvironmentObject private var app: OCRViewModel
    @State private var isHovering = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if app.isBusy {
                    progressSection
                }

                if app.hasError, let err = app.errorMessage {
                    errorSection(err)
                }

                if app.hasResults {
                    resultsSection
                }

                if !app.hasFiles && !app.hasResults && !app.hasError {
                    emptyState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .url, UTType("public.file-url") ?? .fileURL], isTargeted: $isHovering) { providers in
            handleDrop(providers: providers)
            return true
        }
        .background {
            dropTargetOverlay
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: isHovering)
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                Text("⏱ \(String(format: "%.1f", app.elapsed))s  •  \(app.fileCount) images")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - Error

    private func errorSection(_ msg: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.red)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Results")
                    .font(.headline)
                Spacer()

                Button("✕ Clear All") { app.clearAll() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)

                Button("📋 Copy All") { app.copyAll() }
                    .buttonStyle(.borderless)

                Button("💾 Save .txt") { app.saveResults() }
                    .buttonStyle(.borderless)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                Text("\(app.resultCount) file(s)  •  \(String(format: "%.1f", app.elapsed))s total")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let r = app.results {
                    let totalSw = r.reduce(0) { $0 + $1.duration }
                    Text("  •  \(String(format: "%.1f", totalSw))s processing")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.bottom, 4)

            if let r = app.results, r.count > 1 {
                Picker("File:", selection: $app.selectedResultIndex) {
                    ForEach(Array(r.enumerated()), id: \.offset) { i, item in
                        let suffix = item.error != nil ? " ⚠️" : ""
                        Text("\(i + 1). \(item.filename)\(suffix)").tag(i)
                    }
                }
                .pickerStyle(.menu)
            }

            if let item = app.selectedResult {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.filename)
                            .font(.subheadline.bold())
                        Spacer()
                        Button("Copy") { app.copySelected() }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.tint)
                        if let error = item.error, !error.isEmpty {
                            Text("⚠️ \(error)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Text(item.text.isEmpty ? "(no text recognized)" : item.text)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.separator, lineWidth: 1)
                        )
                }
            }
        }
        .padding(16)
        .background(.fill.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.separator, lineWidth: 1)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Drag images or folders here\nto extract text")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("drop anywhere on this window")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - Drop overlay

    private var dropTargetOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 16)
                .stroke(style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                .foregroundStyle(.tint)
                .padding(20)
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 40))
                Text("Drop images or folders")
                    .font(.title2.bold())
            }
            .foregroundStyle(.tint)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(providers: [NSItemProvider]) {
        var pending = providers.count
        guard pending > 0 else { return }
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            provider.loadObject(ofClass: NSURL.self) { item, _ in
                let url = (item as? NSURL) as? URL
                lock.lock()
                if let url { urls.append(url) }
                pending -= 1
                let done = (pending == 0)
                lock.unlock()

                if done {
                    var all: [URL] = []
                    for u in urls {
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                        if isDir.boolValue {
                            all.append(contentsOf: OCRService.collectImages(from: u))
                        } else {
                            all.append(u)
                        }
                    }
                    DispatchQueue.main.async {
                        self.app.addURLs(all)
                    }
                }
            }
        }
    }
}
