import Cocoa

// Standard macOS app entry point — main.swift allows top-level code
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
