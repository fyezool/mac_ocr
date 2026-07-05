import Cocoa
import FlutterMacOS
import Vision

// MARK: - OCR Plugin (native Vision text recognition)

@available(macOS 15.0, *)
private class OCRPlugin: NSObject, FlutterPlugin {
    static func register(with registrar: any FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.ocr.app/ocr", binaryMessenger: registrar.messenger)
        let instance = OCRPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "recognizeText":
            guard let args = call.arguments as? [String: Any],
                  let paths = args["paths"] as? [String] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected 'paths' array", details: nil))
                return
            }
            Task { await processImages(paths: paths, result: result) }
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func processImages(paths: [String], result: @escaping FlutterResult) async {
        var results: [[String: Any]] = []
        
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let start = CFAbsoluteTimeGetCurrent()
            
            guard let imageData = try? Data(contentsOf: url) else {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                results.append([
                    "filename": url.lastPathComponent,
                    "text": "",
                    "error": "Could not load image",
                    "duration": elapsed,
                ])
                continue
            }
            
            var recognizedText = ""
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            
            do {
                let observations = try await request.perform(on: imageData)
                recognizedText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                results.append([
                    "filename": url.lastPathComponent,
                    "text": "",
                    "error": error.localizedDescription,
                    "duration": elapsed,
                ])
                continue
            }
            
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            results.append([
                "filename": url.lastPathComponent,
                "text": recognizedText,
                "duration": elapsed,
            ])
        }
        
        let finalResults = results
        await MainActor.run {
            result(finalResults)
        }
    }
}

// MARK: - App Delegate

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    guard let controller = mainFlutterWindow?.contentViewController as? FlutterViewController else { return }
    if #available(macOS 15.0, *) {
        OCRPlugin.register(with: controller.registrar(forPlugin: "OCRPlugin"))
    }

    // In benchmark mode, hide the window — the Dart side handles everything.
    if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--benchmark") }) {
        mainFlutterWindow?.orderOut(nil)
    }
  }
}
