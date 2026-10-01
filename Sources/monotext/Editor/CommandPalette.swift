import AppKit

func fuzzyMatch(_ query: String, in candidate: String) -> Int? {
    let needle = query.filter { !$0.isWhitespace }.map { $0.lowercased() }
    let characters = Array(candidate)
    guard !needle.isEmpty, needle.count <= characters.count else { return nil }
    let lowered = characters.map { $0.lowercased() }
    let bonus = characters.indices.map { index -> Int in
        guard index > 0 else { return 10 }
        let previous = characters[index - 1]
        guard previous.isLetter || previous.isNumber else { return 10 }
        return previous.isLowercase && characters[index].isUppercase ? 8 : 0
    }
    var best = [[Int?]](repeating: [Int?](repeating: nil, count: characters.count), count: needle.count)
    for step in needle.indices {
        for index in characters.indices where lowered[index] == needle[step] {
            guard step > 0 else {
                best[0][index] = 1 + bonus[index]
                continue
            }
            for prior in 0..<index {
                guard let score = best[step - 1][prior] else { continue }
                let total = score + 1 + bonus[index] + (prior == index - 1 ? 6 : -min(index - prior - 1, 5))
                best[step][index] = max(total, best[step][index] ?? .min)
            }
        }
    }
    return best[needle.count - 1].compactMap { $0 }.max()
}

func shortcutGlyphs(key: String, modifiers: NSEvent.ModifierFlags) -> String {
    guard let scalar = key.unicodeScalars.first else { return "" }
    let named: [UInt32: String] = [
        0xF700: "↑", 0xF701: "↓", 0xF702: "←", 0xF703: "→", 0xF728: "⌦", 0xF729: "↖", 0xF72B: "↘",
        0xF72C: "⇞", 0xF72D: "⇟", 0x1B: "⎋", 0x0D: "↩", 0x09: "⇥", 0x08: "⌫", 0x7F: "⌫", 0x20: "Space",
    ]
    let functionKey = (0xF704...0xF726).contains(scalar.value) ? "F\(scalar.value - 0xF703)" : nil
    let printable = scalar.isASCII && scalar.value > 0x20 ? key.uppercased() : nil
    guard let glyph = named[scalar.value] ?? functionKey ?? printable else { return "" }
    let mask = key == key.lowercased() ? modifiers : modifiers.union(.shift)
    let symbols: [(NSEvent.ModifierFlags, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
    return symbols.filter { mask.contains($0.0) }.map(\.1).joined() + glyph
}

struct PaletteCommand {
    let item: NSMenuItem
    let action: Selector
    let group: String
    let label: String
    let pathLength: Int
    let shortcut: String
}

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PaletteRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
    }
}

@MainActor
final class CommandPalette: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CommandPalette()

    private enum Row {
        case header(String)
        case command(PaletteCommand)
        case empty
    }

    private static let rowHeight: CGFloat = 24
    private static let separatorHeight: CGFloat = 11
    private static let menuInset: CGFloat = 5
    private static let cornerRadius: CGFloat = 10
    private static let maxVisibleRows = 8

    private let panel = PalettePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    private let field = NSSearchField()
    private let separator = NSBox()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    private var commands: [PaletteCommand] = []
    private var rows: [Row] = []
    private var highlighted = -1
    private weak var host: NSWindow?

    override init() {
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self

        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.focusRingType = .none
        field.placeholderString = "Search commands"
        field.sizeToFit()
        field.delegate = self

        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.focusRingType = .none
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false

        let radius = Self.cornerRadius
        let mask = NSImage(size: NSSize(width: 2 * radius + 1, height: 2 * radius + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch

        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = mask
        [field, separator, scroll].forEach(background.addSubview)
        panel.contentView = background
    }

    func toggle(over window: NSWindow) {
        guard host == nil else {
            close()
            return
        }
        commands = NSApp.mainMenu?.items.flatMap { top in
            top.submenu.map { collect(from: $0, group: top.title, path: "") } ?? []
        } ?? []
        host = window
        field.stringValue = ""
        refilter()
        let target = panel.frame
        let animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = animates ? 0 : 1
        if animates { panel.setFrame(target.offsetBy(dx: 0, dy: 4), display: false) }
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        guard animates else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(target, display: true)
        }
    }

    func close() {
        guard let host else { return }
        self.host = nil
        host.removeChildWindow(panel)
        if panel.isKeyWindow { host.makeKey() }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard self.host == nil else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    @objc func showCommandPalette(_ sender: Any?) { close() }

    func windowDidResignKey(_ notification: Notification) { close() }

    private func collect(from menu: NSMenu, group: String, path: String) -> [PaletteCommand] {
        menu.update()
        return menu.items.flatMap { item -> [PaletteCommand] in
            guard !item.isHidden, !item.isSeparatorItem else { return [] }
            if let submenu = item.submenu {
                guard submenu !== NSApp.servicesMenu, item.title != "Open Recent" else { return [] }
                return collect(from: submenu, group: group, path: path + item.title + " › ")
            }
            guard item.isEnabled, let action = item.action, !NSStringFromSelector(action).hasPrefix("_"),
                  action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                  action != #selector(showCommandPalette(_:)) else { return [] }
            return [PaletteCommand(item: item, action: action, group: group, label: path + item.title,
                                   pathLength: (path as NSString).length,
                                   shortcut: shortcutGlyphs(key: item.keyEquivalent, modifiers: item.keyEquivalentModifierMask))]
        }
    }

    private func refilter() {
        let query = field.stringValue.trimmingCharacters(in: .whitespaces)
        rows = query.isEmpty ? groupedRows() : rankedRows(for: query)
        let first = rows.firstIndex { if case .command = $0 { true } else { false } }
        table.reloadData()
        table.selectRowIndexes(first.map { [$0] } ?? [], byExtendingSelection: false)
        highlighted = table.selectedRow
        table.scrollRowToVisible(0)
        layout()
    }

    private func groupedRows() -> [Row] {
        commands.indices.flatMap { index -> [Row] in
            let command = commands[index]
            let startsGroup = index == 0 || commands[index - 1].group != command.group
            return (startsGroup ? [.header(command.group)] : []) + [.command(command)]
        }
    }

    private func rankedRows(for query: String) -> [Row] {
        let matches = commands.compactMap { command in
            (fuzzyMatch(query, in: command.item.title) ?? fuzzyMatch(query, in: command.label)).map { (command: command, score: $0) }
        }
        guard !matches.isEmpty else { return [.empty] }
        return matches.sorted { $0.score > $1.score }.map { .command($0.command) }
    }

    private func layout() {
        guard let host else { return }
        let listHeight = CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight
        let height = Self.menuInset + Self.rowHeight + Self.separatorHeight + listHeight + Self.menuInset
        let area = host.convertToScreen(host.contentLayoutRect)
        let width = min(380, area.width - 48)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.maxY - 6 - height, width: width, height: height), display: false)
        let fieldTop = height - Self.menuInset
        field.frame = NSRect(x: 10, y: fieldTop - (Self.rowHeight + field.frame.height) / 2, width: width - 20, height: field.frame.height)
        separator.frame = NSRect(x: 10, y: fieldTop - Self.rowHeight - Self.separatorHeight / 2 - 0.5, width: width - 20, height: 1)
        scroll.frame = NSRect(x: 0, y: Self.menuInset, width: width, height: listHeight)
        table.sizeLastColumnToFit()
        panel.invalidateShadow()
    }

    private func moveSelection(by step: Int) {
        let selectable = rows.indices.filter { if case .command = rows[$0] { true } else { false } }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: table.selectedRow).map { $0 + step } ?? 0
        let next = selectable[(position + selectable.count) % selectable.count]
        table.selectRowIndexes([next], byExtendingSelection: false)
        let row = table.rect(ofRow: next)
        let target = if next > 0, case .header = rows[next - 1] { row.union(table.rect(ofRow: next - 1)) } else { row }
        let visible = scroll.documentVisibleRect
        // scrollRowToVisible animates during key events, so key repeat restarts it mid-flight and strands the list between rows.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(max(visible.minY, target.maxY - visible.height), target.minY)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func run(row: Int) {
        guard rows.indices.contains(row), case .command(let command) = rows[row] else { return }
        close()
        NSApp.sendAction(command.action, to: command.item.target, from: command.item)
    }

    @objc private func rowClicked(_ sender: Any?) { run(row: table.clickedRow) }

    func controlTextDidChange(_ notification: Notification) { refilter() }

    func searchFieldDidEndSearching(_ sender: NSSearchField) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveUp(_:)) { moveSelection(by: -1) }
        else if selector == #selector(NSResponder.moveDown(_:)) { moveSelection(by: 1) }
        else if selector == #selector(NSResponder.insertNewline(_:)) { run(row: table.selectedRow) }
        else if selector == #selector(NSResponder.cancelOperation(_:)) { close() }
        else { return false }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .command = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { PaletteRowView() }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let changed = IndexSet([highlighted, table.selectedRow].filter { rows.indices.contains($0) })
        highlighted = table.selectedRow
        table.reloadData(forRowIndexes: changed, columnIndexes: [0])
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            pin(label, in: cell, verticalOffset: 2)
        case .empty:
            let label = NSTextField(labelWithString: "No matching commands")
            label.font = .menuFont(ofSize: 0)
            label.textColor = .secondaryLabelColor
            pin(label, in: cell, verticalOffset: 0)
        case .command(let command):
            let selected = row == tableView.selectedRow
            let primary = selected ? NSColor.alternateSelectedControlTextColor : .labelColor
            let secondary = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            let title = NSMutableAttributedString(string: command.label, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: primary])
            title.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: 0, length: command.pathLength))
            let label = NSTextField(labelWithAttributedString: title)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pin(label, in: cell, verticalOffset: 0)
            let shortcut = NSTextField(labelWithString: command.shortcut)
            shortcut.font = .menuFont(ofSize: 0)
            shortcut.textColor = secondary
            shortcut.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(shortcut)
            NSLayoutConstraint.activate([
                shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -14),
                shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                label.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -12),
            ])
        }
        return cell
    }

    private func pin(_ label: NSTextField, in cell: NSView, verticalOffset: CGFloat) {
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor, constant: verticalOffset),
        ])
    }
}

extension DocumentWindowController {
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window else { return }
        CommandPalette.shared.toggle(over: window)
    }
}
