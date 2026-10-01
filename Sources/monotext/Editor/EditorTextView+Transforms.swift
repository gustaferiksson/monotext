import AppKit

extension EditorTextView {
    @objc func sortLinesAscending(_ sender: Any?) { sortLines(.orderedAscending) }

    @objc func sortLinesDescending(_ sender: Any?) { sortLines(.orderedDescending) }

    private func sortLines(_ order: ComparisonResult) {
        let text = string as NSString
        let saved = carets
        let spans = lineBlocks(for: saved.filter { $0.length > 0 }, in: text)
            .filter { text.substring(with: $0).dropLast().contains("\n") }
        let blocks = spans.isEmpty && saved.count == 1 ? [NSRange(location: 0, length: text.length)] : spans
        guard !blocks.isEmpty else { return }
        let record = beginLineEdit()
        undoManager?.setActionName("Sort Lines")
        for block in blocks.reversed() {
            let original = text.substring(with: block)
            let sorted = sortedLines(original, order)
            if sorted != original { _ = replaceCharacters(in: block, with: sorted) as Bool }
        }
        endLineEdit(record, saved)
    }

    @objc func transformCase(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, let style = CaseStyle(rawValue: tag) else { return }
        let text = string as NSString
        let saved = carets
        let targets = saved.map { $0.length > 0 ? $0 : identifierRange(at: $0.location, in: text) }
        var results = saved
        let record = beginLineEdit()
        undoManager?.setActionName("Change Case")
        for index in targets.indices.reversed() {
            let target = targets[index]
            guard index + 1 == targets.count || NSMaxRange(target) <= targets[index + 1].location else { continue }
            let original = text.substring(with: target)
            let replacement = transformed(original, to: style)
            guard !replacement.isEmpty, replacement != original, replaceCharacters(in: target, with: replacement) else { continue }
            let length = (replacement as NSString).length
            results[index] = saved[index].length > 0
                ? NSRange(location: target.location, length: length)
                : NSRange(location: target.location + min(saved[index].location - target.location, length), length: 0)
            for later in (index + 1)..<results.count { results[later].location += length - target.length }
        }
        endLineEdit(record, results)
    }

    private func identifierRange(at location: Int, in text: NSString) -> NSRange {
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let isWordUnit = { (index: Int) in Unicode.Scalar(text.character(at: index)).map(wordCharacters.contains) ?? false }
        var start = location
        while start > 0, isWordUnit(start - 1) { start -= 1 }
        var end = location
        while end < text.length, isWordUnit(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }
}
