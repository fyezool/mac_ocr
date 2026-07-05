import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = ViewController()
        window = NSWindow(
            contentViewController: vc,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OCR Batch Processor"
        window.setContentSize(NSSize(width: 640, height: 720))
        window.minSize = NSSize(width: 480, height: 500)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
