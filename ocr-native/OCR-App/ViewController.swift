import Cocoa
import UniformTypeIdentifiers

// MARK: - View Controller

class ViewController: NSViewController {

    // MARK: Data

    private var selectedFiles: [URL] = []
    private var results: [OCRItem]?
    private var isProcessing = false
    private var errorMessage: String?

    // MARK: UI Outlets

    private let scrollView = NSScrollView()
    private let contentView = NSView()
    private let stackView: NSStackView = {
        let s = NSStackView()
        s.orientation = .vertical
        s.spacing = 12
        s.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        return s
    }()

    private let pickButton = NSButton()
    private let dropHintLabel = NSTextField(labelWithString: "… or drop images/folders anywhere on this window")
    private let infoCard = NSView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let runButton = NSButton()
    private let errorCard = NSView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let resultsHeaderView = NSView()
    private let resultsTitleLabel = NSTextField(labelWithString: "")
    private let copyAllButton = NSButton()
    private let saveButton = NSButton()
    private let tableView = NSTableView()
    private let emptyStateView = NSView()
    private let dropOverlay = NSView()
    private let progressSpinner = NSProgressIndicator()

    // MARK: Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 720))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.wantsLayer = true
        setupUI()
        layoutUI()
        registerForDragDrop()
        updateUI()
    }

    // MARK: - Setup

    private func setupUI() {
        // --- Pick Button ---
        pickButton.title = "Pick Image(s)"
        pickButton.bezelStyle = .regularSquare
        pickButton.controlSize = .large
        pickButton.action = #selector(pickImages)
        pickButton.target = self

        // --- Drop Hint ---
        dropHintLabel.font = NSFont.systemFont(ofSize: 12)
        dropHintLabel.textColor = .secondaryLabelColor
        dropHintLabel.alignment = .center

        // --- Info Card ---
        infoCard.wantsLayer = true
        infoCard.layer?.cornerRadius = 6
        infoCard.layer?.borderWidth = 1
        infoCard.layer?.borderColor = NSColor.separatorColor.cgColor
        infoCard.addSubview(infoLabel)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            infoLabel.centerYAnchor.constraint(equalTo: infoCard.centerYAnchor),
            infoLabel.leadingAnchor.constraint(equalTo: infoCard.leadingAnchor, constant: 12),
            infoCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])

        // --- Run Button ---
        runButton.title = "Run OCR"
        runButton.bezelStyle = .regularSquare
        runButton.controlSize = .large
        runButton.isHighlighted = true
        runButton.action = #selector(runOCR)
        runButton.target = self
        runButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // --- Progress Spinner ---
        progressSpinner.style = .spinning
        progressSpinner.controlSize = .small
        progressSpinner.isHidden = true

        // --- Error Card ---
        errorCard.wantsLayer = true
        errorCard.layer?.cornerRadius = 6
        errorCard.layer?.backgroundColor = NSColor(calibratedRed: 1, green: 0.9, blue: 0.9, alpha: 1).cgColor
        errorCard.addSubview(errorLabel)
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = NSColor(calibratedRed: 0.6, green: 0.1, blue: 0.1, alpha: 1)
        NSLayoutConstraint.activate([
            errorLabel.topAnchor.constraint(equalTo: errorCard.topAnchor, constant: 12),
            errorLabel.leadingAnchor.constraint(equalTo: errorCard.leadingAnchor, constant: 12),
            errorLabel.trailingAnchor.constraint(equalTo: errorCard.trailingAnchor, constant: -12),
            errorLabel.bottomAnchor.constraint(equalTo: errorCard.bottomAnchor, constant: -12),
        ])

        // --- Results Header ---
        resultsTitleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        copyAllButton.title = "📋"
        copyAllButton.bezelStyle = .inline
        copyAllButton.action = #selector(copyAll)
        copyAllButton.target = self
        copyAllButton.toolTip = "Copy all text"
        saveButton.title = "💾"
        saveButton.bezelStyle = .inline
        saveButton.action = #selector(saveToFile)
        saveButton.target = self
        saveButton.toolTip = "Save as .txt"

        // --- Table View ---
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ResultCell"))
        column.title = "Results"
        column.isEditable = false
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.usesAutomaticRowHeights = true
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self

        // --- Drop Overlay ---
        dropOverlay.wantsLayer = true
        dropOverlay.layer?.cornerRadius = 12
        dropOverlay.layer?.backgroundColor = NSColor(calibratedRed: 0, green: 0.5, blue: 1, alpha: 0.1).cgColor
        dropOverlay.isHidden = true

        let dropLabel = NSTextField(labelWithString: "Drop images or folders here")
        dropLabel.font = NSFont.boldSystemFont(ofSize: 20)
        dropLabel.textColor = NSColor.systemBlue
        dropLabel.alignment = .center
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.addSubview(dropLabel)
        NSLayoutConstraint.activate([
            dropLabel.centerXAnchor.constraint(equalTo: dropOverlay.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: dropOverlay.centerYAnchor),
        ])

        // --- Empty State ---
        let emptyIcon = NSTextField(labelWithString: "🖼️")
        emptyIcon.font = NSFont.systemFont(ofSize: 48)
        emptyIcon.alignment = .center
        let emptyTitle = NSTextField(wrappingLabelWithString: "Select images or folders\nto extract text")
        emptyTitle.font = NSFont.systemFont(ofSize: 16)
        emptyTitle.textColor = .secondaryLabelColor
        emptyTitle.alignment = .center
        let emptySubtitle = NSTextField(labelWithString: "or drag & drop them here")
        emptySubtitle.font = NSFont.systemFont(ofSize: 13)
        emptySubtitle.textColor = .tertiaryLabelColor
        emptySubtitle.alignment = .center

        let emptyStack = NSStackView(views: [emptyIcon, emptyTitle, emptySubtitle])
        emptyStack.orientation = .vertical
        emptyStack.spacing = 8
        emptyStack.alignment = .centerX
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.addSubview(emptyStack)
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
        ])
    }

    private func layoutUI() {
        // MARK: Scroll View
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Content view hosts stack
        contentView.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])

        // --- Assemble stack ---
        stackView.addArrangedSubview(pickButton)
        stackView.addArrangedSubview(dropHintLabel)
        stackView.addArrangedSubview(infoCard)
        stackView.addArrangedSubview(runButton)
        stackView.addArrangedSubview(errorCard)
        stackView.addArrangedSubview(resultsHeaderView)
        stackView.addArrangedSubview(tableView)
        stackView.addArrangedSubview(emptyStateView)

        // Results header: title + buttons
        resultsHeaderView.addSubview(resultsTitleLabel)
        resultsHeaderView.addSubview(copyAllButton)
        resultsHeaderView.addSubview(saveButton)
        resultsTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        copyAllButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resultsTitleLabel.leadingAnchor.constraint(equalTo: resultsHeaderView.leadingAnchor),
            resultsTitleLabel.centerYAnchor.constraint(equalTo: resultsHeaderView.centerYAnchor),
            copyAllButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
            copyAllButton.centerYAnchor.constraint(equalTo: resultsHeaderView.centerYAnchor),
            saveButton.trailingAnchor.constraint(equalTo: resultsHeaderView.trailingAnchor),
            saveButton.centerYAnchor.constraint(equalTo: resultsHeaderView.centerYAnchor),
            resultsHeaderView.heightAnchor.constraint(equalToConstant: 32),
        ])

        // Drop overlay (on top of everything)
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            dropOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Drag & Drop

    private func registerForDragDrop() {
        view.registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dropOverlay.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        var files: [URL] = []
        let paths = sender.draggingPasteboard.propertyList(forType: .fileURL) as? [String] ?? []

        for pathString in paths {
            let url = URL(fileURLWithPath: pathString)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                files.append(contentsOf: OCRService.collectImages(from: url))
            } else {
                let ext = url.pathExtension.lowercased()
                if OCRService.supportedImageExtensions.contains(ext) {
                    files.append(url)
                }
            }
        }

        if files.isEmpty { return false }
        addFiles(files)
        return true
    }

    // MARK: - Actions

    @objc private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .png, .jpeg, .gif, .bmp, .tiff,
            UTType(filenameExtension: "heic") ?? .image,
            UTType(filenameExtension: "webp") ?? .image,
        ]

        guard panel.runModal() == .OK else { return }

        var files: [URL] = []
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                files.append(contentsOf: OCRService.collectImages(from: url))
            } else {
                files.append(url)
            }
        }

        if files.isEmpty { return }
        addFiles(files)
    }

    private func addFiles(_ files: [URL]) {
        selectedFiles = files
        results = nil
        errorMessage = nil
        updateUI()
    }

    @objc private func runOCR() {
        guard !selectedFiles.isEmpty, !isProcessing else { return }

        isProcessing = true
        errorMessage = nil
        results = nil
        updateUI()

        let paths = selectedFiles.map(\.path)
        runButton.isEnabled = false

        Task {
            let ocrResults = await OCRService.recognizeText(paths: paths)

            await MainActor.run {
                self.results = ocrResults
                self.isProcessing = false
                self.runButton.isEnabled = true
                self.updateUI()
            }
        }
    }

    @objc private func copyAll() {
        guard let results, !results.isEmpty else { return }
        let text = results.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast("Copied all text to clipboard")
    }

    @objc private func copySingle(_ sender: NSButton) {
        let row = sender.tag
        guard let results, row >= 0, row < results.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(results[row].text, forType: .string)
        showToast("Copied to clipboard")
    }

    @objc private func saveToFile() {
        guard let results, !results.isEmpty else { return }
        let text = results.map { "--- \($0.filename) ---\n\($0.text)" }.joined(separator: "\n\n")

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ocr_results_\(Date().timeIntervalSince1970).txt"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            showToast("Saved to \(url.lastPathComponent)")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - UI Update

    private func updateUI() {
        let hasFiles = !selectedFiles.isEmpty
        let hasResults = results != nil && !results!.isEmpty
        let hasError = errorMessage != nil

        // Info card
        infoCard.isHidden = !hasFiles
        if hasFiles {
            infoLabel.stringValue = "\(selectedFiles.count) file(s) selected"
        }

        // Run button
        runButton.isHidden = !hasFiles || hasResults
        if isProcessing {
            runButton.title = "Processing…"
            runButton.isEnabled = false
        } else {
            runButton.title = "Run OCR"
            runButton.isEnabled = true
        }

        // Progress spinner next to run button
        progressSpinner.isHidden = !isProcessing
        if isProcessing {
            progressSpinner.startAnimation(nil)
        } else {
            progressSpinner.stopAnimation(nil)
        }

        // Error card
        errorCard.isHidden = !hasError
        if hasError {
            errorLabel.stringValue = errorMessage!
        }

        // Results header
        resultsHeaderView.isHidden = !hasResults
        if hasResults {
            resultsTitleLabel.stringValue = "Results (\(results!.count) file(s)):"
        }

        // Table
        tableView.isHidden = !hasResults
        if hasResults {
            tableView.reloadData()
            // Invalidate row heights after reload
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<results!.count))
        }

        // Empty state
        emptyStateView.isHidden = hasFiles || hasResults || hasError

        // Resize table
        if hasResults {
            let totalHeight = (0..<results!.count).reduce(0) { $0 + tableView.rowHeight(forRow: $1) }
            tableView.setFrameSize(NSSize(width: tableView.frame.width, height: totalHeight))
        }
    }

    private func showToast(_ message: String) {
        let toast = NSTextField(wrappingLabelWithString: message)
        toast.font = NSFont.systemFont(ofSize: 13)
        toast.textColor = .white
        toast.alignment = .center
        toast.backgroundColor = NSColor(calibratedWhite: 0.2, alpha: 0.9)
        toast.layer?.cornerRadius = 8
        toast.wantsLayer = true
        toast.isEditable = false
        toast.isBordered = false

        toast.frame = NSRect(x: 0, y: 0, width: 280, height: 36)
        toast.center = CGPoint(x: view.bounds.midX, y: 60)
        toast.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        view.addSubview(toast)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            toast.removeFromSuperview()
        }
    }
}

// MARK: - NSTableView DataSource / Delegate

extension ViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        results?.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let result = results?[row] else { return nil }

        let identifier = NSUserInterfaceItemIdentifier("ResultCellView")
        var cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ResultCellView
        if cell == nil {
            cell = ResultCellView()
            cell?.identifier = identifier
        }

        cell?.configure(with: result, row: row, target: self, action: #selector(copySingle))
        return cell
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let result = results?[row] else { return 100 }

        // Estimate height based on text length
        let text = result.text.isEmpty ? "(no text recognized)" : result.text
        let width = tableView.frame.width - 32  // padding
        let textHeight = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)],
            context: nil
        ).height

        return max(80, textHeight + 80)  // header + padding
    }
}

// MARK: - Custom Table Cell

class ResultCellView: NSTableRowView {

    private let filenameLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let copyButton = NSButton()
    private let container = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Container box (card-like)
        container.boxType = .custom
        container.borderType = .lineBorder
        container.borderWidth = 1
        container.borderColor = NSColor.separatorColor
        container.cornerRadius = 6
        container.fillColor = NSColor.controlBackgroundColor
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)

        // Filename
        filenameLabel.font = NSFont.boldSystemFont(ofSize: 13)
        filenameLabel.lineBreakMode = .byTruncatingTail

        // Copy button
        copyButton.title = "📋"
        copyButton.bezelStyle = .inline
        copyButton.toolTip = "Copy text"

        // Text view
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.layer?.cornerRadius = 6
        textView.wantsLayer = true

        // Layout inside container
        let headerRow = NSStackView(views: [filenameLabel, copyButton])
        headerRow.orientation = .horizontal
        headerRow.spacing = 8
        headerRow.alignment = .centerY

        let innerStack = NSStackView(views: [headerRow, textView])
        innerStack.orientation = .vertical
        innerStack.spacing = 8
        innerStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(innerStack)
        NSLayoutConstraint.activate([
            innerStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            innerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            innerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            innerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        // Container fills the cell
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            container.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            container.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            container.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    func configure(with result: OCRItem, row: Int, target: AnyObject, action: Selector) {
        filenameLabel.stringValue = result.filename
        textView.string = result.text.isEmpty ? "(no text recognized)" : result.text
        textView.textColor = result.text.isEmpty ? .secondaryLabelColor : .labelColor
        copyButton.tag = row
        copyButton.target = target
        copyButton.action = action
    }
}
