import AppKit
import UniformTypeIdentifiers

final class Document: NSDocument {
    private var text = ""
    private var encoding = String.Encoding.utf8
    private lazy var writeEncoding = Prefs.encoding(forKey: Prefs.savingEncoding)

    private var textView: EditorTextView? {
        (windowControllers.first as? DocumentWindowController)?.textView
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        let scrollView = EditorTextView.makeScrollView()
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        configure(textView)
        textView.string = text

        let font = Prefs.font
        let defaults = UserDefaults.standard
        let columns = CGFloat(defaults.integer(forKey: Prefs.windowWidth))
        let lines = CGFloat(defaults.integer(forKey: Prefs.windowHeight))
        let size = NSSize(width: columns * font.maximumAdvancement.width + 40,
                          height: lines * NSLayoutManager().defaultLineHeight(for: font) + 20 + statusBarHeight)

        addWindowController(DocumentWindowController(scrollView: scrollView, contentSize: size))
    }

    private func configure(_ textView: EditorTextView) {
        let defaults = UserDefaults.standard
        textView.font = Prefs.font
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isContinuousSpellCheckingEnabled = defaults.bool(forKey: Prefs.checkSpelling)
        textView.isGrammarCheckingEnabled = defaults.bool(forKey: Prefs.checkGrammar)
        textView.isAutomaticSpellingCorrectionEnabled = defaults.bool(forKey: Prefs.correctSpelling)
        textView.smartInsertDeleteEnabled = defaults.bool(forKey: Prefs.smartCopyPaste)
        textView.isAutomaticQuoteSubstitutionEnabled = defaults.bool(forKey: Prefs.smartQuotes)
        textView.isAutomaticDashSubstitutionEnabled = defaults.bool(forKey: Prefs.smartDashes)
        textView.isAutomaticLinkDetectionEnabled = defaults.bool(forKey: Prefs.smartLinks)
        textView.isAutomaticTextReplacementEnabled = defaults.bool(forKey: Prefs.textReplacement)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        var decoded: NSString?
        let suggestions = [(Prefs.encoding(forKey: Prefs.openingEncoding) ?? .utf8).rawValue]
        let detected = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: suggestions],
                                               convertedString: &decoded, usedLossyConversion: nil)
        guard detected != 0, let decoded else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownStringEncodingError)
        }
        encoding = String.Encoding(rawValue: detected)
        text = decoded as String
        textView?.string = text
        undoManager?.removeAllActions()
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["public.plain-text"]
    }

    override func data(ofType typeName: String) throws -> Data {
        let contents = textView?.string ?? text
        text = contents
        guard let data = contents.data(using: savingEncoding) else {
            throw unencodableError()
        }
        return data
    }

    private var savingEncoding: String.Encoding {
        writeEncoding ?? encoding
    }

    private func unencodableError() -> NSError {
        let name = String.localizedName(of: savingEncoding)
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInapplicableStringEncodingError, userInfo: [
            NSLocalizedDescriptionKey: String(format: "This document can no longer be saved using its original %@ encoding.", name),
            NSLocalizedRecoverySuggestionErrorKey: "Please choose another encoding (such as UTF-8).",
            NSLocalizedRecoveryOptionsErrorKey: ["Cancel", "Overwrite"],
            NSRecoveryAttempterErrorKey: self,
        ])
    }

    override func checkAutosavingSafety() throws {
        try super.checkAutosavingSafety()
        let contents = textView?.string ?? text
        guard contents.data(using: savingEncoding) == nil else { return }
        throw unencodableError()
    }

    override func attemptRecovery(fromError error: Error, optionIndex recoveryOptionIndex: Int) -> Bool {
        guard recoveryOptionIndex == 1 else { return false }
        encoding = .utf8
        writeEncoding = .utf8
        return true
    }

    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? {
        guard UserDefaults.standard.bool(forKey: Prefs.addTxtExtension) else { return nil }
        return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        guard let textView else { throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError) }
        return NSPrintOperation(view: textView, printInfo: printInfo)
    }
}

let statusBarHeight: CGFloat = 22

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let textView: EditorTextView
    private let summaryLabel = NSTextField(labelWithString: "")

    init(scrollView: NSScrollView, contentSize: NSSize) {
        textView = scrollView.documentView as! EditorTextView
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)

        let content = NSView(frame: NSRect(origin: .zero, size: contentSize))
        scrollView.frame = NSRect(x: 0, y: statusBarHeight, width: contentSize.width,
                                  height: contentSize.height - statusBarHeight)
        scrollView.autoresizingMask = [.width, .height]
        content.addSubview(scrollView)
        content.addSubview(makeStatusBar(width: contentSize.width))

        window.contentView = content
        window.setContentSize(contentSize)
        window.center()
        window.delegate = self

        summaryLabel.stringValue = textView.selectionSummary
        textView.selectionSummaryChanged = { [weak self] summary in
            self?.summaryLabel.stringValue = summary
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func makeStatusBar(width: CGFloat) -> NSView {
        let bar = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: statusBarHeight))
        bar.boxType = .custom
        bar.borderWidth = 0
        bar.cornerRadius = 0
        bar.fillColor = .windowBackgroundColor
        bar.contentViewMargins = .zero
        bar.autoresizingMask = [.width, .maxYMargin]

        let separator = NSBox(frame: NSRect(x: 0, y: statusBarHeight - 1, width: width, height: 1))
        separator.boxType = .separator
        separator.autoresizingMask = [.width, .minYMargin]

        let margin: CGFloat = 12
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.alignment = .right
        summaryLabel.frame = NSRect(x: margin, y: 3, width: width - 2 * margin, height: 15)
        summaryLabel.autoresizingMask = [.width, .minYMargin]

        bar.addSubview(separator)
        bar.addSubview(summaryLabel)
        return bar
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        (document as? NSDocument)?.undoManager
    }

    @IBAction func toggleWrap(_ sender: Any?) {
        textView.wrapsToWindow.toggle()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(toggleWrap(_:)) else { return true }
        item.title = textView.wrapsToWindow ? "Wrap to Page" : "Wrap to Window"
        return true
    }
}
