import AppKit
import SwiftUI

enum Prefs {
    static let windowWidth = "WindowWidth"
    static let windowHeight = "WindowHeight"
    static let fontName = "PlainTextFontName"
    static let fontSize = "PlainTextFontSize"
    static let checkSpelling = "CheckSpellingWhileTyping"
    static let checkGrammar = "CheckGrammarWithSpelling"
    static let correctSpelling = "CorrectSpellingAutomatically"
    static let smartCopyPaste = "SmartCopyPaste"
    static let smartQuotes = "SmartQuotes"
    static let smartDashes = "SmartDashes"
    static let smartLinks = "SmartLinks"
    static let textReplacement = "TextReplacement"
    static let openingEncoding = "PlainTextEncodingForRead"
    static let savingEncoding = "PlainTextEncodingForWrite"
    static let addTxtExtension = "AddExtensionToNewPlainTextFiles"

    static func register() {
        let fallback = NSFont.userFixedPitchFont(ofSize: 0) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        UserDefaults.standard.register(defaults: [
            windowWidth: 90,
            windowHeight: 30,
            fontName: fallback.fontName,
            fontSize: Double(fallback.pointSize),
            checkSpelling: true,
            checkGrammar: false,
            correctSpelling: false,
            smartCopyPaste: true,
            smartQuotes: false,
            smartDashes: false,
            smartLinks: false,
            textReplacement: false,
            openingEncoding: 0,
            savingEncoding: 0,
            addTxtExtension: true,
        ])
    }

    static var font: NSFont {
        let defaults = UserDefaults.standard
        let size = CGFloat(defaults.double(forKey: fontSize))
        let named = defaults.string(forKey: fontName).flatMap { NSFont(name: $0, size: size) }
        return named ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func setFont(_ font: NSFont) {
        UserDefaults.standard.set(font.fontName, forKey: fontName)
        UserDefaults.standard.set(Double(font.pointSize), forKey: fontSize)
    }

    static func encoding(forKey key: String) -> String.Encoding? {
        let raw = UserDefaults.standard.integer(forKey: key)
        return raw == 0 ? nil : String.Encoding(rawValue: UInt(raw))
    }
}

let availableEncodings: [(name: String, raw: Int)] = String.availableStringEncodings
    .map { (String.localizedName(of: $0), Int($0.rawValue)) }
    .filter { !$0.0.isEmpty }
    .sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

private struct SettingsView: View {
    var body: some View {
        TabView {
            NewDocumentTab().tabItem { Text("New Document") }
            OpenAndSaveTab().tabItem { Text("Open and Save") }
        }
        .padding(20)
        .frame(width: 480, height: 430)
    }
}

private struct NewDocumentTab: View {
    @AppStorage(Prefs.windowWidth) private var width = 90
    @AppStorage(Prefs.windowHeight) private var height = 30
    @AppStorage(Prefs.fontName) private var fontName = ""
    @AppStorage(Prefs.fontSize) private var fontSize = 11.0
    @AppStorage(Prefs.checkSpelling) private var checkSpelling = true
    @AppStorage(Prefs.checkGrammar) private var checkGrammar = false
    @AppStorage(Prefs.correctSpelling) private var correctSpelling = false
    @AppStorage(Prefs.smartCopyPaste) private var smartCopyPaste = true
    @AppStorage(Prefs.smartQuotes) private var smartQuotes = false
    @AppStorage(Prefs.smartDashes) private var smartDashes = false
    @AppStorage(Prefs.smartLinks) private var smartLinks = false
    @AppStorage(Prefs.textReplacement) private var textReplacement = false

    var body: some View {
        Form {
            Section("Window Size") {
                TextField("Width:", value: $width, format: .number).frame(width: 160)
                TextField("Height:", value: $height, format: .number).frame(width: 160)
            }
            Section("Font") {
                LabeledContent("Plain text font:") {
                    HStack {
                        Text("\(Prefs.font.displayName ?? fontName) \(Int(fontSize))")
                        Button("Change…") { NSApp.sendAction(#selector(AppDelegate.showFontPanel(_:)), to: nil, from: nil) }
                    }
                }
            }
            Section("Options") {
                Toggle("Check spelling as you type", isOn: $checkSpelling)
                Toggle("Check grammar with spelling", isOn: $checkGrammar)
                Toggle("Correct spelling automatically", isOn: $correctSpelling)
                Toggle("Smart copy/paste", isOn: $smartCopyPaste)
                Toggle("Smart quotes", isOn: $smartQuotes)
                Toggle("Smart dashes", isOn: $smartDashes)
                Toggle("Smart links", isOn: $smartLinks)
                Toggle("Text replacement", isOn: $textReplacement)
            }
        }
        .formStyle(.grouped)
    }
}

private struct OpenAndSaveTab: View {
    @AppStorage(Prefs.openingEncoding) private var opening = 0
    @AppStorage(Prefs.savingEncoding) private var saving = 0
    @AppStorage(Prefs.addTxtExtension) private var addTxtExtension = true

    var body: some View {
        Form {
            Section("Plain Text File Encoding") {
                encodingPicker("Opening:", selection: $opening)
                encodingPicker("Saving:", selection: $saving)
            }
            Section {
                Toggle("Add \".txt\" extension to plain text files", isOn: $addTxtExtension)
            }
        }
        .formStyle(.grouped)
    }

    private func encodingPicker(_ label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            Text("Automatic").tag(0)
            Divider()
            ForEach(availableEncodings, id: \.raw) { Text($0.name).tag($0.raw) }
        }
    }
}

func makeSettingsWindow() -> NSWindow {
    let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
    window.title = "Settings"
    window.styleMask.remove(.miniaturizable)
    window.setContentSize(NSSize(width: 480, height: 430))
    window.isReleasedWhenClosed = false
    window.center()
    return window
}
