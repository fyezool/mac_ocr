import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {

    private var isBenchmarkMode: Bool {
        ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--benchmark") })
    }

    override func awakeFromNib() {
        let flutterViewController = FlutterViewController()
        let windowFrame = self.frame
        self.contentViewController = flutterViewController
        self.setFrame(windowFrame, display: true)

        RegisterGeneratedPlugins(registry: flutterViewController)

        super.awakeFromNib()
    }

    /// Prevent the window from ever becoming visible in benchmark mode.
    override func orderFront(_ sender: Any?) {
        guard !isBenchmarkMode else { return }
        super.orderFront(sender)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        guard !isBenchmarkMode else { return }
        super.makeKeyAndOrderFront(sender)
    }

    /// "Visible at launch" in a nib can call this directly.
    override func orderFrontRegardless() {
        guard !isBenchmarkMode else { return }
        super.orderFrontRegardless()
    }
}
