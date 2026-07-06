import SwiftUI

// MARK: - Server Tab

struct ServerTabView: View {
    @EnvironmentObject private var server: ServerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    statusCard

                    if let err = server.errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(err)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    if server.isRunning {
                        clientsSection
                    }

                    if !server.logs.isEmpty {
                        logSection
                    } else {
                        emptyLogState
                    }

            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .top)
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

    // MARK: - Connected Clients

    private var clientsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Connected Clients", systemImage: "person.2")
                    .font(.headline)

                Spacer()

                Text("\(server.clients.filter(\.isActive).count) active")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.fill.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if server.clients.isEmpty {
                HStack {
                    Image(systemName: "person.fill.questionmark")
                        .foregroundStyle(.tertiary)
                    Text("Waiting for connections…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(server.clients) { client in
                    ClientRow(client: client)
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

// MARK: - Client Row

private struct ClientRow: View {
    let client: ConnectedClient

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(client.isActive ? Color.green : Color.gray.opacity(0.4))
                .frame(width: 8, height: 8)

            Image(systemName: client.isActive ? "desktopcomputer" : "desktopcomputer")
                .font(.caption)
                .foregroundStyle(client.isActive ? .secondary : .tertiary)

            Text(client.ip)
                .font(.caption.monospaced())
                .foregroundStyle(client.isActive ? .primary : .secondary)

            Text(client.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Text(client.isActive ? "connected \(Text(client.connectedAt, style: .relative))" : "\(Text(String(format: "%.1fs", client.duration)))")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(.fill.quaternary.opacity(client.isActive ? 0.3 : 0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
