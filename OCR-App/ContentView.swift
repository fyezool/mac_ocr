import SwiftUI

// MARK: - Navigation

enum AppTab: String, CaseIterable, Identifiable {
    case ocr = "OCR"
    case server = "Server"
    case history = "History"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ocr: "text.viewfinder"
        case .server: "network"
        case .history: "clock.arrow.circlepath"
        }
    }

    var label: String { rawValue }
}

// MARK: - Content View

struct ContentView: View {
    @EnvironmentObject private var app: OCRViewModel
    @EnvironmentObject private var server: ServerViewModel
    @State private var selectedTab: AppTab? = .ocr

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedTab) {
            ForEach(AppTab.allCases) { tab in
                NavigationLink(value: tab) {
                    Label(tab.label, systemImage: tab.icon)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .ocr:
            OCRTabView()
                .environmentObject(app)
        case .server:
            ServerTabView()
                .environmentObject(server)
        case .history:
            HistoryTabView()
                .environmentObject(app)
        case nil:
            Text("Select a tab")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
