import SwiftUI

@main
struct OCR_App: App {
    @StateObject private var appModel = OCRViewModel()
    @StateObject private var serverModel = ServerViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .environmentObject(serverModel)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
    }
}
