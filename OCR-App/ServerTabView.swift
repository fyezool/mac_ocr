import SwiftUI

// MARK: - Server Tab

struct ServerTabView: View {
    @EnvironmentObject private var server: ServerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // MARK: - Header
                headerSection

                // MARK: - Status card
                statusCard

                // MARK: - Logs
                if !server.logs.isEmpty {
                    logSection
                } else {
                    emptyLogState
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack {
            Label("Network Server", systemImage: "network")
                .font(.title2.bold())

            Spacer()

            Button(server.isRunning ? "Stop Server" : "Start Server") {
                server.toggle()
            }
            .buttonStyle(.borderedProminent)
            .tint(server.isRunning ? .red : .accentColor)
            .controlSize(.large)
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(server.isRunning ? Color.green : Color.red)
                    .frame(width: 10, height: 10)

                Text(server.isRunning ? "Running" : "Stopped")
                    .font(.subheadline.bold())
                    .foregroundStyle(server.isRunning ? .green : .secondary)
            }

            if server.isRunning {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Server Address")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(server.urlString)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.fill.quinary)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Text("Connect via HTTP — the OCR API is available at the address above")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Log Section

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Activity")
                    .font(.headline)
                Spacer()
                Button("Clear", systemImage: "trash") {
                    server.clearLogs()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            ForEach(Array(server.logs.reversed().prefix(20).enumerated()), id: \.element.id) { _, entry in
                LogRow(entry: entry)
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

    private var emptyLogState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No server activity yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Start the server and send requests to see logs here")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Log Row

private struct LogRow: View {
    let entry: ServerLogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.method)
                .font(.caption.bold().monospaced())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.15))
                .foregroundStyle(statusColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(entry.filename.isEmpty ? entry.path : entry.filename)
                .font(.caption.monospaced())
                .lineLimit(1)

            Spacer()

            Text(String(format: "%.2fs", entry.duration))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.fill.quaternary.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var statusColor: Color {
        switch entry.status {
        case 200..<300: .green
        case 400..<500: .orange
        default: .red
        }
    }
}
