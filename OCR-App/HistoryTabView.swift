import SwiftUI

// MARK: - History Tab

struct HistoryTabView: View {
    @EnvironmentObject private var app: OCRViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(.title2.bold())

                if app.history.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Empty

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No OCR sessions yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Run OCR on some images and your history will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - List

    private var historyList: some View {
        LazyVStack(spacing: 8) {
            ForEach(app.history.reversed()) { entry in
                HistoryRow(entry: entry)
            }
        }
    }
}

// MARK: - History Row

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.viewfinder")
                .font(.title3)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.fileCount) image(s)")
                    .font(.subheadline.bold())

                HStack(spacing: 8) {
                    Label(entry.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("•")

                    Text(String(format: "%.1fs", entry.totalDuration))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if entry.hasErrors {
                Text("⚠️")
                    .font(.caption)
            }
        }
        .padding(12)
        .background(.fill.quinary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
    }
}
