import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vc = ViewController()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = vc
        window.title = "OCR Batch Processor"
        window.minSize = NSSize(width: 480, height: 500)

        // Compute a visible centered position
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let winW: CGFloat = 640, winH: CGFloat = 720
        let x = screenFrame.origin.x + (screenFrame.width - winW) / 2
        let y = screenFrame.origin.y + (screenFrame.height - winH) / 2
        window.setFrame(NSRect(x: x, y: y, width: winW, height: winH), display: true, animate: false)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
