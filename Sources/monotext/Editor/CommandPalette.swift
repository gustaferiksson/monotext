import AppKit

func fuzzyMatch(_ query: String, in candidate: String) -> (score: Int, ranges: [NSRange])? {
    let needle = query.filter { !$0.isWhitespace }.map { $0.lowercased() }
    let characters = Array(candidate)
    guard !needle.isEmpty, needle.count <= characters.count else { return nil }
    let lowered = characters.map { $0.lowercased() }
    let offsets = characters.reduce(into: [0]) { $0.append($0[$0.count - 1] + $1.utf16.count) }
    let bonus = characters.indices.map { index -> Int in
        guard index > 0 else { return 10 }
        let previous = characters[index - 1]
        guard previous.isLetter || previous.isNumber else { return 10 }
        return previous.isLowercase && characters[index].isUppercase ? 8 : 0
    }
    var best = [[Int?]](repeating: [Int?](repeating: nil, count: characters.count), count: needle.count)
    var parent = [[Int]](repeating: [Int](repeating: -1, count: characters.count), count: needle.count)
    for step in needle.indices {
        for index in characters.indices where lowered[index] == needle[step] {
            guard step > 0 else {
                best[0][index] = 1 + bonus[index]
                continue
            }
            for prior in 0..<index {
                guard let score = best[step - 1][prior] else { continue }
                let total = score + 1 + bonus[index] + (prior == index - 1 ? 6 : -min(index - prior - 1, 5))
                guard total > (best[step][index] ?? .min) else { continue }
                best[step][index] = total
                parent[step][index] = prior
            }
        }
    }
    let last = needle.count - 1
    guard let (end, score) = characters.indices.compactMap({ index in best[last][index].map { (index, $0) } })
        .max(by: { $0.1 < $1.1 }) else { return nil }
    var matched = [end]
    for step in stride(from: last, to: 0, by: -1) { matched.append(parent[step][matched[matched.count - 1]]) }
    let ranges = matched.reversed().map { NSRange(location: offsets[$0], length: offsets[$0 + 1] - offsets[$0]) }
    return (score, ranges)
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
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 7, yRadius: 7).fill()
    }
}

@MainActor
final class CommandPalette: NSObject, NSWindowDelegate, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CommandPalette()

    private enum Row {
        case header(String)
        case command(PaletteCommand, [NSRange])
        case empty
    }

    private static let fieldHeight: CGFloat = 44
    private static let rowHeight: CGFloat = 30
    private static let headerHeight: CGFloat = 28
    private static let listInset: CGFloat = 6
    private static let maxVisibleRows: CGFloat = 8

    private let panel = PalettePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    private let field = NSTextField()
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

        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .title3)
        field.placeholderString = "Type a command"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self

        separator.boxType = .separator

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
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

        let content = NSView()
        [field, separator, scroll].forEach(content.addSubview)
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        glass.contentView = content
        panel.contentView = glass
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
        panel.invalidateShadow()
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
            return (startsGroup ? [.header(command.group)] : []) + [.command(command, [])]
        }
    }

    private func rankedRows(for query: String) -> [Row] {
        let matches: [(command: PaletteCommand, score: Int, ranges: [NSRange])] = commands.compactMap { command in
            let leaf = fuzzyMatch(query, in: command.item.title).map { match in
                (score: match.score, ranges: match.ranges.map { NSRange(location: $0.location + command.pathLength, length: $0.length) })
            }
            return (leaf ?? fuzzyMatch(query, in: command.label)).map { (command, $0.score, $0.ranges) }
        }
        guard !matches.isEmpty else { return [.empty] }
        return matches.sorted { $0.score > $1.score }.map { .command($0.command, $0.ranges) }
    }

    private func height(of row: Row) -> CGFloat {
        if case .header = row { return Self.headerHeight }
        return Self.rowHeight
    }

    private func layout() {
        guard let host else { return }
        let listHeight = min(rows.map(height(of:)).reduce(0, +), Self.rowHeight * Self.maxVisibleRows)
        let height = Self.fieldHeight + 1 + listHeight + 2 * Self.listInset
        let area = host.convertToScreen(host.contentLayoutRect)
        let width = min(540, area.width - 48)
        panel.setFrame(NSRect(x: area.midX - width / 2, y: area.maxY - 12 - height, width: width, height: height), display: false)
        let fieldLine = field.intrinsicContentSize.height
        field.frame = NSRect(x: 14, y: height - (Self.fieldHeight + fieldLine) / 2, width: width - 28, height: fieldLine)
        separator.frame = NSRect(x: 0, y: height - Self.fieldHeight - 1, width: width, height: 1)
        scroll.frame = NSRect(x: 0, y: Self.listInset, width: width, height: listHeight)
        table.sizeLastColumnToFit()
        panel.displayIfNeeded()
        panel.invalidateShadow()
    }

    private func moveSelection(by step: Int) {
        let selectable = rows.indices.filter { if case .command = rows[$0] { true } else { false } }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: table.selectedRow).map { $0 + step } ?? 0
        let next = selectable[(position + selectable.count) % selectable.count]
        table.selectRowIndexes([next], byExtendingSelection: false)
        if next > 0, case .header = rows[next - 1] { table.scrollRowToVisible(next - 1) }
        table.scrollRowToVisible(next)
    }

    private func run(row: Int) {
        guard rows.indices.contains(row), case .command(let command, _) = rows[row] else { return }
        close()
        NSApp.sendAction(command.action, to: command.item.target, from: command.item)
    }

    @objc private func rowClicked(_ sender: Any?) { run(row: table.clickedRow) }

    func controlTextDidChange(_ notification: Notification) { refilter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.moveUp(_:)) { moveSelection(by: -1) }
        else if selector == #selector(NSResponder.moveDown(_:)) { moveSelection(by: 1) }
        else if selector == #selector(NSResponder.insertNewline(_:)) { run(row: table.selectedRow) }
        else if selector == #selector(NSResponder.cancelOperation(_:)) { close() }
        else { return false }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(of: rows[row]) }

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
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            label.textColor = .tertiaryLabelColor
            pin(label, in: cell, verticalOffset: 3)
        case .empty:
            let label = NSTextField(labelWithString: "No matching commands")
            label.font = .systemFont(ofSize: NSFont.systemFontSize)
            label.textColor = .secondaryLabelColor
            pin(label, in: cell, verticalOffset: 0)
        case .command(let command, let matches):
            let selected = row == tableView.selectedRow
            let primary = selected ? NSColor.alternateSelectedControlTextColor : .labelColor
            let secondary = selected ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
            let title = NSMutableAttributedString(string: command.label, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: primary])
            title.addAttribute(.foregroundColor, value: secondary, range: NSRange(location: 0, length: command.pathLength))
            matches.forEach { title.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold), range: $0) }
            let label = NSTextField(labelWithAttributedString: title)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pin(label, in: cell, verticalOffset: 0)
            let shortcut = NSTextField(labelWithString: command.shortcut)
            shortcut.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            shortcut.textColor = selected ? .alternateSelectedControlTextColor : .secondaryLabelColor
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
