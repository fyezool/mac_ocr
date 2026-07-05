import Cocoa
import UniformTypeIdentifiers

class DragDropView: NSView {
    weak var vc: ViewController?
    override func draggingEntered(_: NSDraggingInfo) -> NSDragOperation { vc?.drgEnter(); return .copy }
    override func draggingExited(_: NSDraggingInfo?) { vc?.drgExit() }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool { vc?.drgDrop(s) ?? false }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        vc?.updateColors()
    }
}

class ViewController: NSViewController {
    var files: [URL] = []; var ocrR: [OCRItem]?; var busy = false; var err: String?
    var t0: Date?; var elpsd: Double = 0; var swSum: Double = 0
    let srv = ServerManager(); var srvOn = false; var srvLogs: [ServerLogEntry] = []

    var scroll: NSScrollView!; var root: NSStackView!
    var pickBtn: NSButton!; var hintLbl: NSTextField!
    var infoLbl: NSTextField!; var runBtn: NSButton!
    var spnr: NSProgressIndicator!; var elapLbl: NSTextField!
    var errLbl: NSTextField!
    var tbl: NSTableView!; var emptySt: NSStackView!; var ovl: NSView!
    var srvSt: NSStackView!; var srvBtn: NSButton!; var srvAddr: NSTextField!
    var srvLogTbl: NSTableView!
    var resultsHdr: NSStackView!
    var filePicker: NSPopUpButton!
    var resultText: NSTextView!

    override func loadView() {
        let v = DragDropView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
        v.autoresizingMask = [.width, .height]; v.vc = self; view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad(); view.wantsLayer = true
        build(); refr()
    }

    func build() {
        // Scroll
        scroll = NSScrollView(frame: view.bounds); scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; view.addSubview(scroll)

        // Document view + stack with auto-layout (internal to scroll view, won't affect window)
        let cv = NSView()
        scroll.documentView = cv

        root = NSStackView()
        root.orientation = .vertical; root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        cv.translatesAutoresizingMaskIntoConstraints = false
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)
        let wc = root.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        wc.priority = .defaultHigh  // allow scroll view to constrain width
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            wc,
        ])

        // Pick button
        pickBtn = NSButton(title: "Pick Image(s)", target: self, action: #selector(pickImgs))
        pickBtn.bezelStyle = .regularSquare; pickBtn.controlSize = .large

        // Hint
        hintLbl = NSTextField(labelWithString: "… or drop images/folders anywhere on this window")
        hintLbl.font = .systemFont(ofSize: 12); hintLbl.textColor = .secondaryLabelColor; hintLbl.alignment = .center

        // Info row
        let infoRow = NSStackView()
        infoRow.orientation = .horizontal; infoRow.spacing = 8
        infoRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        infoRow.wantsLayer = true; infoRow.layer?.cornerRadius = 6
        infoRow.layer?.borderWidth = 1; infoRow.layer?.borderColor = NSColor.separatorColor.cgColor
        infoLbl = NSTextField(labelWithString: ""); infoLbl.isEditable = false; infoLbl.isBordered = false; infoLbl.backgroundColor = .clear
        infoRow.addArrangedSubview(infoLbl)

        // Run button
        runBtn = NSButton(title: "Run OCR", target: self, action: #selector(runOCR))
        runBtn.bezelStyle = .regularSquare; runBtn.controlSize = .large

        // Elapsed label
        elapLbl = NSTextField(labelWithString: "")
        elapLbl.font = .systemFont(ofSize: 12); elapLbl.textColor = .secondaryLabelColor; elapLbl.alignment = .center
        elapLbl.isHidden = true

        // Error row
        let errRow = NSStackView()
        errRow.orientation = .horizontal; errRow.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        errRow.wantsLayer = true; errRow.layer?.cornerRadius = 6
        errRow.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.9, alpha: 1).cgColor
        errLbl = NSTextField(wrappingLabelWithString: ""); errLbl.textColor = NSColor(calibratedRed: 0.6, green: 0.1, blue: 0.1, alpha: 1)
        errLbl.isEditable = false; errLbl.isBordered = false; errLbl.backgroundColor = .clear
        errRow.addArrangedSubview(errLbl)

        errRow.addArrangedSubview(errLbl)

        // Empty state
        emptySt = NSStackView()
        emptySt.orientation = .vertical; emptySt.spacing = 8; emptySt.alignment = .centerX
        emptySt.edgeInsets = NSEdgeInsets(top: 60, left: 0, bottom: 60, right: 0)
        let ei = NSTextField(labelWithString: "🖼️"); ei.font = .systemFont(ofSize: 48); ei.isEditable = false; ei.isBordered = false; ei.backgroundColor = .clear
        let et = NSTextField(wrappingLabelWithString: "Select images or folders\nto extract text")
        et.font = .systemFont(ofSize: 16); et.textColor = .secondaryLabelColor; et.alignment = .center
        et.isEditable = false; et.isBordered = false; et.backgroundColor = .clear
        let es = NSTextField(labelWithString: "or drag & drop them here")
        es.font = .systemFont(ofSize: 13); es.textColor = .tertiaryLabelColor; es.alignment = .center
        es.isEditable = false; es.isBordered = false; es.backgroundColor = .clear
        emptySt.addArrangedSubview(ei); emptySt.addArrangedSubview(et); emptySt.addArrangedSubview(es)

        // Server card
        srvSt = NSStackView()
        srvSt.orientation = .vertical; srvSt.spacing = 8
        srvSt.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        srvSt.wantsLayer = true; srvSt.layer?.cornerRadius = 8
        srvSt.layer?.borderWidth = 1; srvSt.layer?.borderColor = NSColor.separatorColor.cgColor
        // Server header row
        let si = NSImageView(); si.setFrameSize(NSSize(width: 16, height: 16))
        let sl = NSTextField(labelWithString: "Network Server"); sl.font = .boldSystemFont(ofSize: 13)
        sl.isEditable = false; sl.isBordered = false; sl.backgroundColor = .clear
        srvBtn = NSButton(title: "Start Server", target: self, action: #selector(toggleSrv))
        srvBtn.bezelStyle = .regularSquare; srvBtn.controlSize = .small
        let srvTop = NSStackView(views: [si, sl, srvBtn])
        srvTop.orientation = .horizontal; srvTop.spacing = 6; srvTop.alignment = .centerY
        // Server address
        srvAddr = NSTextField(labelWithString: "")
        srvAddr.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        srvAddr.textColor = .secondaryLabelColor; srvAddr.isSelectable = true; srvAddr.isHidden = true
        srvAddr.isEditable = false; srvAddr.isBordered = false; srvAddr.backgroundColor = .clear
        // Server log
        srvLogTbl = NSTableView(); srvLogTbl.usesAutomaticRowHeights = true
        let lc = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("L"))
        srvLogTbl.addTableColumn(lc); srvLogTbl.headerView = nil; srvLogTbl.style = .plain
        srvLogTbl.backgroundColor = .clear; srvLogTbl.dataSource = self; srvLogTbl.delegate = self
        srvLogTbl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        srvSt.addArrangedSubview(srvTop); srvSt.addArrangedSubview(srvAddr); srvSt.addArrangedSubview(srvLogTbl)

        // Results header (copy all + save)
        resultsHdr = NSStackView()
        resultsHdr.orientation = .horizontal; resultsHdr.spacing = 8
        let titleLbl = NSTextField(labelWithString: "Results:"); titleLbl.font = .boldSystemFont(ofSize: 14)
        titleLbl.isEditable = false; titleLbl.isBordered = false; titleLbl.backgroundColor = .clear
        let clearBtn = NSButton(title: "✕ Clear All", target: self, action: #selector(clearAll))
        clearBtn.bezelStyle = .inline; clearBtn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let copyBtn = NSButton(title: "📋 Copy All", target: self, action: #selector(copyAll))
        copyBtn.bezelStyle = .inline
        let saveBtn = NSButton(title: "💾 Save .txt", target: self, action: #selector(saveFile))
        saveBtn.bezelStyle = .inline
        resultsHdr.addArrangedSubview(titleLbl)
        resultsHdr.addArrangedSubview(NSView()) // spacer
        resultsHdr.addArrangedSubview(clearBtn)
        resultsHdr.addArrangedSubview(copyBtn)
        resultsHdr.addArrangedSubview(saveBtn)

        // File picker dropdown + text view (replaces the table for large batches)
        filePicker = NSPopUpButton()
        filePicker.target = self; filePicker.action = #selector(selectedFileChanged)
        filePicker.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resultText = NSTextView()
        resultText.isEditable = false; resultText.isSelectable = true
        resultText.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        resultText.backgroundColor = .textBackgroundColor
        resultText.textContainerInset = NSSize(width: 8, height: 8)
        resultText.drawsBackground = true
        resultText.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        // Assemble root
        root.addArrangedSubview(pickBtn)
        root.addArrangedSubview(hintLbl)
        root.addArrangedSubview(infoRow)
        root.addArrangedSubview(runBtn)
        root.addArrangedSubview(elapLbl)
        root.addArrangedSubview(errRow)
        root.addArrangedSubview(resultsHdr)
        root.addArrangedSubview(filePicker)
        root.addArrangedSubview(resultText)
        root.addArrangedSubview(emptySt)
        root.addArrangedSubview(srvSt)

        // Overlay
        ovl = NSView(frame: view.bounds); ovl.autoresizingMask = [.width, .height]
        ovl.wantsLayer = true; ovl.layer?.cornerRadius = 12
        ovl.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.5, blue: 1, alpha: 0.1).cgColor
        ovl.isHidden = true; view.addSubview(ovl)
        let dl = NSTextField(labelWithString: "Drop images or folders here"); dl.font = .boldSystemFont(ofSize: 20)
        dl.textColor = .systemBlue; dl.alignment = .center; dl.isEditable = false; dl.isBordered = false; dl.backgroundColor = .clear
        dl.frame = NSRect(x: 0, y: view.bounds.midY - 15, width: view.bounds.width, height: 30)
        dl.autoresizingMask = [.minXMargin, .maxXMargin]; ovl.addSubview(dl)

        // Connect server
        view.registerForDraggedTypes([.fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])
        srv.onStatusChange = { [weak self] on, info in
            guard let s = self else { return }; s.srvOn = on; s.srvAddr.stringValue = on ? info : ""
            s.srvAddr.isHidden = !on; s.srvBtn.title = on ? "Stop Server" : "Start Server"
            // Log detected address for debugging
            try? "Server address: \(info)\n".write(toFile: "/tmp/ocr_srv_log.txt", atomically: true, encoding: .utf8)
            s.refr()
        }
        srv.onNewLogEntry = { [weak self] _ in
            guard let s = self else { return }; s.srvLogs = s.srv.recentLog; s.srvLogTbl.reloadData()
        }
    }

    // MARK: - Actions
    @objc func pickImgs() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = true; p.canChooseDirectories = true
        p.allowedContentTypes = [.png, .jpeg, .gif, .bmp, .tiff,
            UTType(filenameExtension: "heic") ?? .image, UTType(filenameExtension: "webp") ?? .image]
        guard p.runModal() == .OK else { return }
        var all: [URL] = []
        for u in p.urls { var d: ObjCBool = false; FileManager.default.fileExists(atPath: u.path, isDirectory: &d)
            all.append(contentsOf: d.boolValue ? OCRService.collectImages(from: u) : [u]) }
        if !all.isEmpty { files = all; ocrR = nil; err = nil; refr() }
    }
    func drgEnter() { ovl.isHidden = false }
    func drgExit() { ovl.isHidden = true }
    func drgDrop(_ sender: NSDraggingInfo) -> Bool {
        ovl.isHidden = true; var all: [URL] = []
        if let items = sender.draggingPasteboard.pasteboardItems {
            for item in items {
                // Try .fileURL type first (file:// URL string)
                if let urlStr = item.string(forType: .fileURL),
                   let url = URL(string: urlStr) ?? URL(string: "file://\(urlStr)") {
                    var d: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &d) else { continue }
                    all.append(contentsOf: d.boolValue ? OCRService.collectImages(from: url) : [url])
                }
            }
        }
        // Fallback: try NSFilenamesPboardType
        if all.isEmpty, let paths = sender.draggingPasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for p in paths {
                let url = URL(fileURLWithPath: p)
                var d: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &d) else { continue }
                all.append(contentsOf: d.boolValue ? OCRService.collectImages(from: url) : [url])
            }
        }
        if all.isEmpty { return false }; files = all; ocrR = nil; err = nil; refr(); return true
    }
    @objc func runOCR() {
        guard !files.isEmpty, !busy else { return }
        busy = true; err = nil; elpsd = 0; swSum = 0; t0 = Date()
        runBtn.isEnabled = false; elapLbl.isHidden = false; refr()
        var timer: Timer?
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let s = self, s.busy, let st = s.t0 else { timer?.invalidate(); return }
            s.elpsd = Date().timeIntervalSince(st)
            s.elapLbl.stringValue = String(format: "⏱ %.1fs elapsed  •  %d images", s.elpsd, s.files.count)
        }
        Task {
            let r = await OCRService.recognizeText(paths: files.map(\.path))
            await MainActor.run {
                timer?.invalidate(); self.elpsd = self.t0.map { Date().timeIntervalSince($0) } ?? 0
                self.swSum = r.reduce(0) { $0 + $1.duration }; self.ocrR = r; self.busy = false
                self.runBtn.isEnabled = true; self.refr()
            }
        }
    }
    @objc func copyAll() {
        guard let r = ocrR, !r.isEmpty else { return }
        let t = r.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string); toast("Copied all")
    }
    @objc func saveFile() {
        guard let r = ocrR, !r.isEmpty else { return }
        let t = r.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")
        let p = NSSavePanel(); p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = "ocr_results_\(Int(Date().timeIntervalSince1970)).txt"
        guard p.runModal() == .OK, let u = p.url else { return }
        try? t.write(to: u, atomically: true, encoding: .utf8); toast("Saved")
    }
    @objc func cpOne(_ sender: NSButton) {
        guard let r = ocrR, sender.tag >= 0, sender.tag < r.count else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r[sender.tag].text, forType: .string); toast("Copied")
    }
    @objc func toggleSrv() { srvOn ? srv.stop() : srv.start(port: 8080) }

    @objc func clearAll() {
        files = []; ocrR = nil; err = nil; elpsd = 0; swSum = 0; busy = false
        runBtn.isEnabled = true; elapLbl.isHidden = true
        filePicker.removeAllItems(); resultText.string = ""
        refr()
    }

    func updateColors() {
        // colors update automatically with system appearance
    }

    @objc func selectedFileChanged() {
        guard let r = ocrR, filePicker.indexOfSelectedItem >= 0,
              filePicker.indexOfSelectedItem < r.count else { return }
        let item = r[filePicker.indexOfSelectedItem]
        resultText.string = item.text.isEmpty ? "(no text recognized)" : item.text
    }
    func toast(_ m: String) {
        let t = NSTextField(wrappingLabelWithString: m); t.font = .systemFont(ofSize: 13); t.textColor = .white; t.alignment = .center
        t.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 0.9); t.layer?.cornerRadius = 8; t.wantsLayer = true
        t.isEditable = false; t.isBordered = false
        t.frame = NSRect(x: (view.bounds.width - 280) / 2, y: 60, width: 280, height: 36)
        t.autoresizingMask = [.minXMargin, .maxXMargin]; view.addSubview(t)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { t.removeFromSuperview() }
    }
    func refr() {
        let hf = !files.isEmpty; let hr = ocrR != nil && !ocrR!.isEmpty; let he = err != nil
        infoLbl.superview?.isHidden = !hf; if hf { infoLbl.stringValue = "\(files.count) file(s) selected" }
        runBtn.isHidden = !hf || hr; runBtn.title = busy ? "Processing…" : "Run OCR"
        elapLbl.isHidden = !busy
        errLbl.superview?.isHidden = !he; if he { errLbl.stringValue = err! }
        resultsHdr.isHidden = !hr
        filePicker.isHidden = !hr
        resultText.isHidden = !hr
        emptySt.isHidden = hf || hr || he
        if hr, let r = ocrR {
            // Populate file dropdown
            filePicker.removeAllItems()
            let count = r.count
            filePicker.addItems(withTitles: r.enumerated().map { (i, item) in
                let err = item.error != nil ? " ⚠️" : ""
                return "\(i + 1). \(item.filename)\(err)"
            })
            filePicker.selectItem(at: 0)
            resultText.string = r.first?.text.isEmpty ?? true ? "(no text recognized)" : r.first?.text ?? ""
        }
    }
}

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in t: NSTableView) -> Int {
        t === srvLogTbl ? min(srvLogs.count, 10) : 0
    }
    func tableView(_ t: NSTableView, viewFor col: NSTableColumn?, row: Int) -> NSView? {
        guard t === srvLogTbl else { return nil }
        let id = NSUserInterfaceItemIdentifier("LC")
        var c = t.makeView(withIdentifier: id, owner: self) as? NSTextField
        if c == nil { c = NSTextField(labelWithString: ""); c?.identifier = id; c?.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        let es = Array(srvLogs.suffix(10))
        if row < es.count { c?.stringValue = "\(es[row].method)  \(es[row].filename.isEmpty ? es[row].path : es[row].filename)  \(String(format: "%.2fs", es[row].duration))" }
        return c
    }
}
