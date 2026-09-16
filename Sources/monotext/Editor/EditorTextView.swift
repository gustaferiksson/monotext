import AppKit

private final class CaretUndoRecord {
    let before: [NSRange]
    let primary: Int
    var after: [NSRange] = []

    init(before: [NSRange], primary: Int) {
        self.before = before
        self.primary = primary
    }
}

final class EditorTextView: NSTextView {
    static func makeScrollView() -> NSScrollView {
        let scroll = EditorTextView.scrollablePlainDocumentContentTextView()
        guard let view = scroll.documentView as? EditorTextView else { return scroll }
        view.allowsUndo = true
        view.insertionPointColor = .clear
        view.applyWrapMode()
        return scroll
    }

    var wrapsToWindow = true { didSet { applyWrapMode() } }

    var selectionSummaryChanged: ((String) -> Void)?

    var selectionSummary: String { summaryText(for: caretStorage, in: text) }

    var carets: [NSRange] {
        get { caretStorage }
        set { apply(newValue, primaryHint: newValue.last?.location) }
    }

    private var caretStorage = [NSRange(location: 0, length: 0)]
    private var primaryIndex = 0
    private var mirroring = false
    private var fanningOut = false
    private var caretHistory: [[NSRange]] = []
    private var caretIndicators: [NSTextInsertionIndicator] = []
    private var pendingChord = false
    private var columnAnchor: Int?
    private var columnFocus: Int?
    private var focusObservers: [NSObjectProtocol] = []
    private var publishedSummary: String?
    private var headAtStart = false
    private var isFocused = false
    private var addCursorGoalX: CGFloat?
    private var textRevision = 0
    private var occurrenceCache: (key: String, matches: [NSRange])?

    var primaryCaret: NSRange { caretStorage[min(primaryIndex, caretStorage.count - 1)] }
    private var text: NSString { textStorage?.mutableString ?? NSMutableString() }

    // MARK: - Caret store

    private func apply(_ ranges: [NSRange], primaryHint: Int?, recordHistory: Bool = true, headAtStart: Bool = false) {
        self.headAtStart = headAtStart
        addCursorGoalX = nil
        let normalized = normalizeCarets(ranges, length: text.length)
        let hint = primaryHint ?? primaryCaret.location
        if recordHistory, normalized != caretStorage { pushHistory() }
        columnAnchor = nil
        caretStorage = normalized
        primaryIndex = normalized.firstIndex { NSLocationInRange(hint, $0) || $0.location == hint }
            ?? normalized.count - 1
        mirrorPrimary(stillSelecting: false)
        refreshDecorations()
    }

    private func mirrorPrimary(stillSelecting: Bool) {
        mirroring = true
        super.setSelectedRanges([NSValue(range: primaryCaret)], affinity: .downstream, stillSelecting: stillSelecting)
        mirroring = false
    }

    private func pushHistory() {
        caretHistory.append(caretStorage)
        if caretHistory.count > 32 { caretHistory.removeFirst() }
    }

    private func refreshDecorations() {
        needsDisplay = true
        updateCaretIndicators()
        publishSelectionSummary()
    }

    private func publishSelectionSummary() {
        let summary = selectionSummary
        guard summary != publishedSummary else { return }
        publishedSummary = summary
        selectionSummaryChanged?(summary)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        defer { publishSelectionSummary() }
        guard !mirroring, !fanningOut else { return }
        let incoming = ranges.map(\.rangeValue)
        guard incoming != caretStorage else { return }
        if caretStorage.count > 1, !stillSelecting { pushHistory() }
        headAtStart = incoming[0].length > 0 && incoming[0].location != caretStorage[0].location
        addCursorGoalX = nil
        caretStorage = normalizeCarets(incoming, length: text.length)
        primaryIndex = caretStorage.count - 1
        refreshDecorations()
    }

    // MARK: - Fan-out

    private func setPrimaryForFanOut(_ range: NSRange) {
        super.setSelectedRanges([NSValue(range: range)], affinity: .downstream, stillSelecting: true)
    }

    private func fanOutMovement(_ body: (NSRange) -> Void) {
        let caretsBefore = caretStorage
        fanningOut = true
        let results = caretStorage.map { caret -> NSRange in
            setPrimaryForFanOut(caret)
            body(caret)
            return selectedRange()
        }
        fanningOut = false
        let anchor = min(primaryIndex, results.count - 1)
        let hint = results[anchor].location
        apply(results, primaryHint: hint, headAtStart: results[anchor].location != caretsBefore[anchor].location)
        scrollRangeToVisible(primaryCaret)
    }

    private func fanOutEdit(over ranges: [NSRange]? = nil, _ body: (Int, NSRange) -> Void) {
        let targets = ranges ?? caretStorage
        let saved = caretStorage
        let savedPrimary = min(primaryIndex, saved.count - 1)
        let record = CaretUndoRecord(before: saved, primary: savedPrimary)
        undoManager?.beginUndoGrouping()
        registerCaretUndo(record, restoringBefore: true)
        fanningOut = true
        var results = targets
        for index in stride(from: targets.count - 1, through: 0, by: -1) {
            let lengthBefore = text.length
            setPrimaryForFanOut(targets[index])
            body(index, targets[index])
            results[index] = selectedRange()
            let delta = text.length - lengthBefore
            guard delta != 0, index + 1 < results.count else { continue }
            for later in (index + 1)..<results.count { results[later].location += delta }
        }
        fanningOut = false
        undoManager?.endUndoGrouping()
        record.after = results
        apply(results, primaryHint: results[min(savedPrimary, results.count - 1)].location)
        scrollRangeToVisible(primaryCaret)
    }

    private func registerCaretUndo(_ record: CaretUndoRecord, restoringBefore: Bool) {
        undoManager?.registerUndo(withTarget: self) { view in
            view.registerCaretUndo(record, restoringBefore: !restoringBefore)
            let target = restoringBefore ? record.before : record.after
            guard !target.isEmpty else { return }
            DispatchQueue.main.async { view.apply(target, primaryHint: target[min(record.primary, target.count - 1)].location, recordHistory: false) }
        }
    }

    override func scrollRangeToVisible(_ range: NSRange) {
        guard !fanningOut else { return }
        super.scrollRangeToVisible(range)
    }

    // MARK: - Input

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard caretStorage.count > 1, !fanningOut else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        guard !hasMarkedText() else {
            commitComposition(string)
            return
        }
        fanOutEdit { _, _ in super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    private func commitComposition(_ string: Any) {
        let marked = markedRange()
        let saved = caretStorage
        let savedPrimary = primaryIndex
        let record = CaretUndoRecord(before: saved, primary: savedPrimary)
        undoManager?.beginUndoGrouping()
        registerCaretUndo(record, restoringBefore: true)
        let lengthBefore = text.length
        fanningOut = true
        super.insertText(string, replacementRange: marked)
        let delta = text.length - lengthBefore
        var results = saved
        results[savedPrimary] = selectedRange()
        for index in stride(from: saved.count - 1, through: 0, by: -1) where index != savedPrimary {
            var target = saved[index]
            if target.location > marked.location { target.location += delta }
            let before = text.length
            setPrimaryForFanOut(target)
            super.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
            results[index] = selectedRange()
            let step = text.length - before
            guard step != 0 else { continue }
            for later in (index + 1)..<results.count where later != savedPrimary { results[later].location += step }
            if savedPrimary > index { results[savedPrimary].location += step }
        }
        fanningOut = false
        undoManager?.endUndoGrouping()
        record.after = results
        apply(results, primaryHint: results[savedPrimary].location)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let lengthBefore = text.length
        let anchor = markedRange().location != NSNotFound ? markedRange().location : self.selectedRange().location
        mirroring = true
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        mirroring = false
        let delta = text.length - lengthBefore
        guard delta != 0, caretStorage.count > 1 else { return }
        caretStorage = caretStorage.enumerated().map { index, caret in
            guard index != primaryIndex, caret.location > anchor else { return caret }
            return NSRange(location: caret.location + delta, length: caret.length)
        }
        caretStorage[primaryIndex] = self.selectedRange()
        needsDisplay = true
    }

    override func doCommand(by selector: Selector) {
        guard caretStorage.count > 1, !fanningOut, !hasMarkedText() else {
            super.doCommand(by: selector)
            return
        }
        let name = NSStringFromSelector(selector)
        if name == "cancelOperation:" {
            collapseCursors(nil)
            return
        }
        if name.hasPrefix("delete") || name.hasPrefix("insert") || name.hasPrefix("transpose") || name.hasPrefix("yank") {
            fanOutEdit { _, _ in super.doCommand(by: selector) }
            return
        }
        if name.hasPrefix("move") || name.hasPrefix("select") || name.hasPrefix("scroll") || name.hasPrefix("page") {
            fanOutMovement { _ in super.doCommand(by: selector) }
            return
        }
        super.doCommand(by: selector)
    }

    override func cancelOperation(_ sender: Any?) {
        guard caretStorage.count > 1 else {
            super.cancelOperation(sender)
            return
        }
        collapseCursors(sender)
    }

    // MARK: - Clipboard

    override func copy(_ sender: Any?) {
        guard caretStorage.count > 1 else {
            super.copy(sender)
            return
        }
        let joined = caretStorage.map { text.substring(with: $0) }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(joined, forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard caretStorage.count > 1 else {
            super.cut(sender)
            return
        }
        copy(sender)
        fanOutEdit { _, _ in super.delete(nil) }
    }

    override func paste(_ sender: Any?) { pasteMultiCursor(sender) { super.paste(sender) } }

    override func pasteAsPlainText(_ sender: Any?) { pasteMultiCursor(sender) { super.pasteAsPlainText(sender) } }

    private func pasteMultiCursor(_ sender: Any?, fallback: () -> Void) {
        guard caretStorage.count > 1, let clipboard = NSPasteboard.general.string(forType: .string) else {
            fallback()
            return
        }
        var lines = clipboard.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        guard lines.count == caretStorage.count else {
            fanOutEdit { _, _ in super.insertText(clipboard, replacementRange: NSRange(location: NSNotFound, length: 0)) }
            return
        }
        fanOutEdit { index, _ in super.insertText(lines[index], replacementRange: NSRange(location: NSNotFound, length: 0)) }
    }

    // MARK: - Multi-cursor commands

    private func wordRange(at location: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let probe = NSRange(location: min(location, text.length - 1), length: 0)
        return selectionRange(forProposedRange: probe, granularity: .selectByWord)
    }

    private func currentNeedle() -> (String, Bool)? {
        let primary = primaryCaret
        guard primary.length > 0 else {
            let word = wordRange(at: primary.location)
            guard word.length > 0 else { return nil }
            return (text.substring(with: word), true)
        }
        return (text.substring(with: primary), NSEqualRanges(primary, wordRange(at: primary.location)))
    }

    @objc func addSelectionToNextFindMatch(_ sender: Any?) {
        guard primaryCaret.length > 0 else {
            expandCaretsToWords()
            return
        }
        guard let (word, wordBoundaries) = currentNeedle() else { return }
        let after = NSMaxRange(caretStorage.last ?? primaryCaret)
        guard let match = nextOccurrence(after: after, of: word, in: text, wordBoundaries: wordBoundaries, excluding: caretStorage) else { return }
        apply(caretStorage + [match], primaryHint: match.location)
        scrollRangeToVisible(match)
    }

    @objc func moveLastSelectionToNextFindMatch(_ sender: Any?) {
        guard primaryCaret.length > 0 else {
            expandCaretsToWords()
            return
        }
        guard let (word, wordBoundaries) = currentNeedle() else { return }
        let after = NSMaxRange(primaryCaret)
        guard let match = nextOccurrence(after: after, of: word, in: text, wordBoundaries: wordBoundaries, excluding: caretStorage) else { return }
        var updated = caretStorage
        updated[min(primaryIndex, updated.count - 1)] = match
        apply(updated, primaryHint: match.location)
        scrollRangeToVisible(match)
    }

    private func expandCaretsToWords() {
        let words = caretStorage.map { $0.length > 0 ? $0 : wordRange(at: $0.location) }
        apply(words, primaryHint: words[min(primaryIndex, words.count - 1)].location)
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        guard let (word, wordBoundaries) = currentNeedle() else { return }
        selectEvery(word, wordBoundaries: wordBoundaries)
    }

    @objc func selectAllOccurrencesOfWord(_ sender: Any?) {
        let word = wordRange(at: primaryCaret.location)
        guard word.length > 0 else { return }
        selectEvery(text.substring(with: word), wordBoundaries: true)
    }

    private func selectEvery(_ word: String, wordBoundaries: Bool) {
        let matches = occurrences(of: word, in: text, wordBoundaries: wordBoundaries)
        guard !matches.isEmpty else { return }
        apply(matches, primaryHint: matches.last?.location)
    }

    @objc func addCursorsToLineEnds(_ sender: Any?) {
        var ends: [NSRange] = []
        for caret in caretStorage {
            var location = caret.location
            repeat {
                let line = text.lineRange(for: NSRange(location: min(location, max(text.length - 1, 0)), length: 0))
                var end = NSMaxRange(line)
                while end > line.location, isNewline(text.character(at: end - 1)) { end -= 1 }
                ends.append(NSRange(location: end, length: 0))
                location = NSMaxRange(line)
            } while location < NSMaxRange(caret) && location < text.length
        }
        guard !ends.isEmpty else { return }
        apply(ends, primaryHint: ends.last?.location)
    }

    private func isNewline(_ unit: unichar) -> Bool { unit == 10 || unit == 13 }

    @objc func addCursorAbove(_ sender: Any?) { addCursor(lineOffset: -1) }

    @objc func addCursorBelow(_ sender: Any?) { addCursor(lineOffset: 1) }

    private func addCursor(lineOffset: Int) {
        let anchor = lineOffset < 0 ? caretStorage.first! : caretStorage.last!
        let probe = lineOffset < 0 ? anchor.location : NSMaxRange(anchor)
        guard let rect = segmentRects(for: NSRange(location: probe, length: 0)).first else { return }
        // The goal x is kept for the whole run so a short or empty line clamps this caret
        // without dragging the ones after it to its column.
        let goalX = addCursorGoalX ?? rect.midX
        let index = characterIndexForInsertion(at: NSPoint(x: goalX, y: rect.midY + CGFloat(lineOffset) * rect.height))
        guard lineOffset < 0 ? index < probe : index > probe else { return }
        guard text.lineRange(for: NSRange(location: min(index, max(text.length - 1, 0)), length: 0))
            != text.lineRange(for: NSRange(location: min(probe, max(text.length - 1, 0)), length: 0)) else { return }
        let added = NSRange(location: index, length: 0)
        apply(caretStorage + [added], primaryHint: added.location)
        addCursorGoalX = goalX
        scrollRangeToVisible(added)
    }

    @objc func undoCursor(_ sender: Any?) {
        guard let previous = caretHistory.popLast() else { return }
        apply(previous, primaryHint: previous.last?.location, recordHistory: false)
    }

    @objc func collapseCursors(_ sender: Any?) {
        apply([primaryCaret], primaryHint: primaryCaret.location)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(collapseCursors(_:)):
            return caretStorage.count > 1
        case #selector(undoCursor(_:)):
            return !caretHistory.isEmpty
        case #selector(addCursorAbove(_:)), #selector(addCursorBelow(_:)),
             #selector(addSelectionToNextFindMatch(_:)), #selector(moveLastSelectionToNextFindMatch(_:)),
             #selector(selectAllOccurrences(_:)), #selector(selectAllOccurrencesOfWord(_:)),
             #selector(addCursorsToLineEnds(_:)):
            return isEditable || isSelectable
        default:
            return super.validateUserInterfaceItem(menuItem)
        }
    }

    // MARK: - Keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if flags == [.command, .option], let key = event.charactersIgnoringModifiers?.unicodeScalars.first {
            if Int(key.value) == NSUpArrowFunctionKey {
                addCursorAbove(nil)
                return true
            }
            if Int(key.value) == NSDownArrowFunctionKey {
                addCursorBelow(nil)
                return true
            }
        }
        let command = flags == .command
        if command, event.charactersIgnoringModifiers == "k" {
            pendingChord = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.pendingChord = false }
            return true
        }
        if pendingChord {
            pendingChord = false
            guard command, event.charactersIgnoringModifiers == "d" else { return super.performKeyEquivalent(with: event) }
            moveLastSelectionToNextFindMatch(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == [.shift, .option, .command], let key = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            super.keyDown(with: event)
            return
        }
        switch Int(key.value) {
        case NSUpArrowFunctionKey: growColumnSelection(lines: -1, columns: 0)
        case NSDownArrowFunctionKey: growColumnSelection(lines: 1, columns: 0)
        case NSLeftArrowFunctionKey: growColumnSelection(lines: 0, columns: -1)
        case NSRightArrowFunctionKey: growColumnSelection(lines: 0, columns: 1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        if flags == [.option, .shift] {
            columnSelect(anchor: index, focus: index)
            return
        }
        guard flags == .option else {
            columnAnchor = nil
            super.mouseDown(with: event)
            return
        }
        let existing = caretStorage.firstIndex { $0.length == 0 && $0.location == index }
        guard let existing, caretStorage.count > 1 else {
            apply(caretStorage + [NSRange(location: index, length: 0)], primaryHint: index)
            return
        }
        var remaining = caretStorage
        remaining.remove(at: existing)
        apply(remaining, primaryHint: remaining.last?.location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard columnAnchor != nil else {
            super.mouseDragged(with: event)
            return
        }
        guard let anchor = columnAnchor else { return }
        columnSelect(anchor: anchor, focus: characterIndexForInsertion(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard columnAnchor != nil else {
            super.mouseUp(with: event)
            return
        }
    }

    // MARK: - Column selection

    private func lineAndColumn(_ location: Int) -> (line: NSRange, column: Int) {
        let clamped = min(location, text.length)
        let line = text.lineRange(for: NSRange(location: min(clamped, max(text.length - 1, 0)), length: 0))
        return (line, clamped - line.location)
    }

    func columnSelect(anchor: Int, focus: Int) {
        let start = lineAndColumn(anchor)
        let end = lineAndColumn(focus)
        let lower = min(start.column, end.column)
        let upper = max(start.column, end.column)
        var ranges: [NSRange] = []
        var cursor = min(start.line.location, end.line.location)
        let last = max(start.line.location, end.line.location)
        while cursor <= last {
            let line = text.lineRange(for: NSRange(location: min(cursor, max(text.length - 1, 0)), length: 0))
            var content = NSMaxRange(line)
            while content > line.location, isNewline(text.character(at: content - 1)) { content -= 1 }
            let width = content - line.location
            let from = line.location + min(lower, width)
            let to = line.location + min(upper, width)
            ranges.append(NSRange(location: from, length: to - from))
            guard NSMaxRange(line) > cursor else { break }
            cursor = NSMaxRange(line)
        }
        guard !ranges.isEmpty else { return }
        apply(ranges, primaryHint: focus, headAtStart: focus < anchor)
        columnAnchor = anchor
        columnFocus = focus
    }

    private func growColumnSelection(lines: Int, columns: Int) {
        if columnAnchor == nil {
            columnAnchor = primaryCaret.location
            columnFocus = NSMaxRange(primaryCaret)
        }
        guard let focus = columnFocus else { return }
        guard let anchor = columnAnchor else { return }
        if columns != 0 {
            columnSelect(anchor: anchor, focus: min(max(focus + columns, 0), text.length))
            return
        }
        guard let rect = segmentRects(for: NSRange(location: focus, length: 0)).first else { return }
        let point = NSPoint(x: rect.midX, y: rect.midY + CGFloat(lines) * rect.height)
        guard point.y >= 0 else { return }
        columnSelect(anchor: anchor, focus: characterIndexForInsertion(at: point))
    }

    // MARK: - Geometry and drawing

    private func segmentRects(for range: NSRange) -> [CGRect] {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        layout.ensureLayout(for: textRange)
        let origin = textContainerOrigin
        var rects: [CGRect] = []
        layout.enumerateTextSegments(in: textRange, type: .selection, options: []) { _, rect, _, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            return true
        }
        return rects
    }

    private func visibleCharacterRange() -> NSRange {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let viewport = layout.textViewportLayoutController.viewportRange else {
            return NSRange(location: 0, length: text.length)
        }
        let start = content.offset(from: content.documentRange.location, to: viewport.location)
        let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
        let margin = 4096
        let lower = max(0, start - margin)
        return NSRange(location: lower, length: min(text.length, end + margin) - lower)
    }

    func occurrenceMatches() -> [NSRange] {
        guard caretsAreVisible, let needle = occurrenceNeedle(for: caretStorage, primary: primaryIndex, in: text) else { return [] }
        let scope = visibleCharacterRange()
        let key = "\(textRevision)|\(scope)|\(needle)"
        // Only the search is cached; the caret exclusion is a cheap filter over the visible
        // matches and must follow a caret set that moves without changing the needle.
        let cached = occurrenceCache?.key == key ? occurrenceCache?.matches : nil
        let found = cached ?? occurrences(of: needle, in: text, wordBoundaries: false, within: scope)
        occurrenceCache = (key, found)
        return found.filter { match in !caretStorage.contains { NSIntersectionRange($0, match).length > 0 } }
    }

    // An outline rather than a fill: it separates from a real selection by shape, so it can
    // never read as "this is selected too" in either appearance.
    private func drawOccurrenceHighlights(in rect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.4).setStroke()
        for match in occurrenceMatches() {
            for segment in segmentRects(for: match) where segment.intersects(rect) {
                let outline = NSBezierPath(roundedRect: segment.insetBy(dx: -0.5, dy: 1), xRadius: 1.5, yRadius: 1.5)
                outline.lineWidth = 0.75
                outline.stroke()
            }
        }
    }

    // Overriding draw(_:) makes AppKit fall back to TextKit 1, so highlights are drawn here.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawOccurrenceHighlights(in: rect)
        guard caretStorage.count > 1 else { return }
        (caretsAreVisible ? NSColor.selectedTextBackgroundColor : .unemphasizedSelectedTextBackgroundColor).setFill()
        for (index, caret) in caretStorage.enumerated() where index != primaryIndex && caret.length > 0 {
            for segment in segmentRects(for: caret) where segment.intersects(rect) { segment.fill() }
        }
    }

    // An offscreen test process can never become key, so renders opt in to the focused look.
    private static let rendersAsFocused = ProcessInfo.processInfo.environment["MONOTEXT_RENDER_FOCUSED"] != nil

    private var caretsAreVisible: Bool {
        isFocused && (window?.isKeyWindow == true || Self.rendersAsFocused)
    }

    private func caretTip(_ caret: NSRange) -> NSRange {
        NSRange(location: headAtStart ? caret.location : NSMaxRange(caret), length: 0)
    }

    private func updateCaretIndicators() {
        while caretIndicators.count < caretStorage.count {
            let indicator = NSTextInsertionIndicator()
            addSubview(indicator)
            caretIndicators.append(indicator)
        }
        for (slot, indicator) in caretIndicators.enumerated() {
            let tip = slot < caretStorage.count ? caretTip(caretStorage[slot]) : nil
            guard let tip, let rect = segmentRects(for: tip).first else {
                indicator.isHidden = true
                indicator.frame = .zero
                continue
            }
            indicator.frame = rect
            indicator.isHidden = !caretsAreVisible
        }
    }

    // MARK: - Wrapping

    private static let sideGutter: CGFloat = 8
    private static let topGutter: CGFloat = 8

    private func applyGutter(to container: NSTextContainer) {
        container.lineFragmentPadding = Self.sideGutter
        textContainerInset = NSSize(width: 0, height: Self.topGutter)
    }

    private func applyWrapMode() {
        guard let container = textContainer else { return }
        let scroll = enclosingScrollView
        guard wrapsToWindow else {
            let paper = NSPrintInfo.shared
            let width = paper.paperSize.width - paper.leftMargin - paper.rightMargin
            applyGutter(to: container)
            container.widthTracksTextView = false
            container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
            isHorizontallyResizable = true
            maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            autoresizingMask = []
            minSize = NSSize(width: width, height: 0)
            setFrameSize(NSSize(width: width, height: frame.height))
            scroll?.hasHorizontalScroller = true
            return
        }
        applyGutter(to: container)
        container.widthTracksTextView = true
        container.size = NSSize(width: scroll?.contentSize.width ?? frame.width, height: .greatestFiniteMagnitude)
        isHorizontallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        autoresizingMask = .width
        minSize = NSSize(width: 0, height: 0)
        scroll?.hasHorizontalScroller = false
        if let width = scroll?.contentSize.width { setFrameSize(NSSize(width: width, height: frame.height)) }
    }

    // MARK: - Focus and layout

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
        guard let window else { return }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            focusObservers.append(observe(NSView.boundsDidChangeNotification, from: clip) { $0.updateCaretIndicators() })
        }
        focusObservers.append(observe(NSWindow.didBecomeKeyNotification, from: window) { $0.focusChanged() })
        focusObservers.append(observe(NSWindow.didResignKeyNotification, from: window) { $0.focusChanged() })
    }

    private func observe(_ name: Notification.Name, from object: AnyObject, _ action: @escaping (EditorTextView) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            guard let self else { return }
            action(self)
        }
    }

    // The highlight colour depends on focus, so a focus change has to repaint, not just
    // reposition the indicators.
    private func focusChanged() {
        needsDisplay = true
        updateCaretIndicators()
    }

    deinit { focusObservers.forEach(NotificationCenter.default.removeObserver) }

    // NSTextView lays out legacily, so layout() never fires; this is the hook that follows
    // scrolling, resizing and TextKit 2 finishing a viewport layout.
    override func viewWillDraw() {
        updateCaretIndicators()
        super.viewWillDraw()
    }

    override func didChangeText() {
        textRevision += 1
        super.didChangeText()
        updateCaretIndicators()
    }

    override func becomeFirstResponder() -> Bool {
        isFocused = super.becomeFirstResponder()
        focusChanged()
        return isFocused
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        isFocused = false
        focusChanged()
        return true
    }
}
