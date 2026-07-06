import Foundation
import SwiftUI

// MARK: - Server ViewModel

@MainActor
final class ServerViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var address: String = ""
    @Published var logs: [ServerLogEntry] = []
    @Published var errorMessage: String?

    private let server = ServerManager()

    var urlString: String { "http://\(address):8080" }

    func toggle() {
        if isRunning {
            stop()
        } else {
            start()
        }
    }

    func start() {
        server.onStatusChange = { [weak self] on, info in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = on
                self.address = info
                if !on, info.hasPrefix("Error:") {
                    self.errorMessage = info
                }
            }
        }
        server.onNewLogEntry = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.logs = Array(self.server.recentLog)
            }
        }
        server.start(port: 8080)
    }

    func stop() {
        server.stop()
        isRunning = false
    }

    func clearLogs() {
        logs = []
    }
}
