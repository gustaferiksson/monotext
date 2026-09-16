import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        withExtendedLifetime(delegate) {}
    }

    private lazy var settingsWindow = makeSettingsWindow()

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.register()
        NSApp.mainMenu = buildMainMenu()
        NSFontManager.shared.target = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.makeKeyAndOrderFront(nil)
    }

    @objc func showFontPanel(_ sender: Any?) {
        NSFontManager.shared.setSelectedFont(Prefs.font, isMultiple: false)
        NSFontManager.shared.orderFrontFontPanel(nil)
    }

    @objc func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let font = sender.convert(Prefs.font)
        Prefs.setFont(font)
        for document in NSDocumentController.shared.documents {
            for controller in document.windowControllers {
                let scrollView = controller.window?.contentView as? NSScrollView
                (scrollView?.documentView as? NSTextView)?.font = font
            }
        }
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs {
            let item = menu.addItem(withTitle: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
        }
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
    }
}

private func item(_ title: String, _ action: Selector?, _ key: String = "",
                  _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
    item.tag = tag
    return item
}

private func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    parent.submenu = menu
    return parent
}

private func buildMainMenu() -> NSMenu {
    let main = NSMenu()

    let servicesMenu = NSMenu(title: "Services")
    NSApp.servicesMenu = servicesMenu
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = servicesMenu

    main.addItem(submenu("MonoText", [
        item("About MonoText", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
        .separator(),
        item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
        .separator(),
        services,
        .separator(),
        item("Hide MonoText", #selector(NSApplication.hide(_:)), "h"),
        item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
        item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
        .separator(),
        item("Quit MonoText", #selector(NSApplication.terminate(_:)), "q"),
    ]))

    let openRecent = submenu("Open Recent", [])
    openRecent.submenu?.delegate = NSApp.delegate as? NSMenuDelegate

    main.addItem(submenu("File", [
        item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
        item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
        openRecent,
        .separator(),
        item("Close", #selector(NSWindow.performClose(_:)), "w"),
        item("Save", #selector(NSDocument.save(_:)), "s"),
        item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
        item("Rename…", #selector(NSDocument.rename(_:))),
        item("Move To…", #selector(NSDocument.move(_:))),
        submenu("Revert To", [item("Browse All Versions…", #selector(NSDocument.browseVersions(_:)))]),
        .separator(),
        item("Page Setup…", #selector(NSApplication.runPageLayout(_:)), "p", [.command, .shift]),
        item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
    ]))

    main.addItem(submenu("Edit", [
        item("Undo", Selector(("undo:")), "z"),
        item("Redo", Selector(("redo:")), "z", [.command, .shift]),
        .separator(),
        item("Cut", #selector(NSText.cut(_:)), "x"),
        item("Copy", #selector(NSText.copy(_:)), "c"),
        item("Paste", #selector(NSText.paste(_:)), "v"),
        item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]),
        item("Delete", #selector(NSText.delete(_:))),
        item("Select All", #selector(NSText.selectAll(_:)), "a"),
        .separator(),
        submenu("Find", [
            item("Find…", #selector(NSTextView.performFindPanelAction(_:)), "f", tag: 1),
            item("Find and Replace…", #selector(NSTextView.performFindPanelAction(_:)), "f", [.command, .option], tag: 12),
            item("Find Next", #selector(NSTextView.performFindPanelAction(_:)), "g", tag: 2),
            item("Find Previous", #selector(NSTextView.performFindPanelAction(_:)), "g", [.command, .shift], tag: 3),
            item("Use Selection for Find", #selector(NSTextView.performFindPanelAction(_:)), "e", tag: 7),
            item("Jump to Selection", #selector(NSResponder.centerSelectionInVisibleArea(_:)), "j"),
        ]),
        submenu("Spelling and Grammar", [
            item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"),
            item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"),
            .separator(),
            item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))),
            item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))),
            item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))),
        ]),
        submenu("Substitutions", [
            item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))),
            .separator(),
            item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))),
            item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))),
            item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))),
            item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
            item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))),
        ]),
        submenu("Transformations", [
            item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))),
            item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))),
            item("Capitalize", #selector(NSResponder.capitalizeWord(_:))),
        ]),
        submenu("Speech", [
            item("Start Speaking", #selector(NSTextView.startSpeaking(_:))),
            item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))),
        ]),
        .separator(),
        submenu("Selection", [
            item("Add Cursor Above", Selector(("addCursorAbove:")), "\u{F700}", [.command, .option]),
            item("Add Cursor Below", Selector(("addCursorBelow:")), "\u{F701}", [.command, .option]),
            item("Add Next Occurrence", Selector(("addSelectionToNextFindMatch:")), "d"),
            item("Move Last Selection to Next Occurrence", Selector(("moveLastSelectionToNextFindMatch:"))),
            item("Select All Occurrences", Selector(("selectAllOccurrences:")), "l", [.command, .shift]),
            item("Select All Occurrences of Word", Selector(("selectAllOccurrencesOfWord:")), "\u{F705}"),
            item("Add Cursors to Line Ends", Selector(("addCursorsToLineEnds:")), "i", [.option, .shift]),
            item("Undo Last Cursor Operation", Selector(("undoCursor:")), "u"),
            .separator(),
            item("Collapse to One Cursor", Selector(("collapseCursors:")), "\u{1b}", []),
        ]),
    ]))

    let showFonts = item("Show Fonts", #selector(NSFontManager.orderFrontFontPanel(_:)), "t")
    showFonts.target = NSApp.delegate
    showFonts.action = #selector(AppDelegate.showFontPanel(_:))

    main.addItem(submenu("Format", [
        submenu("Font", [showFonts]),
        .separator(),
        item("Wrap to Page", #selector(DocumentWindowController.toggleWrap(_:))),
    ]))

    let windowMenu = NSMenu(title: "Window")
    NSApp.windowsMenu = windowMenu
    let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
    window.submenu = windowMenu
    windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    windowMenu.addItem(.separator())
    windowMenu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
    main.addItem(window)

    return main
}
