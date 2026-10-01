import Foundation

func normalizeCarets(_ ranges: [NSRange], length: Int) -> [NSRange] {
    let clamped = ranges.map { range -> NSRange in
        let location = min(max(range.location, 0), length)
        return NSRange(location: location, length: min(range.length, length - location))
    }
    guard let first = clamped.min(by: caretOrder) else { return [NSRange(location: 0, length: 0)] }
    var merged = [first]
    for range in clamped.sorted(by: caretOrder).dropFirst() {
        let last = merged[merged.count - 1]
        let touchesCaret = range.location == NSMaxRange(last) && (range.length == 0 || last.length == 0)
        guard range.location < NSMaxRange(last) || touchesCaret else {
            merged.append(range)
            continue
        }
        merged[merged.count - 1] = NSUnionRange(last, range)
    }
    return merged
}

private func caretOrder(_ a: NSRange, _ b: NSRange) -> Bool {
    a.location == b.location ? a.length < b.length : a.location < b.location
}

enum OccurrenceMatching {
    case wholeWordMatchCase
    case substringIgnoreCase
}

func occurrences(of needle: String, in text: NSString, matching: OccurrenceMatching, within limit: NSRange? = nil) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    let bounds = limit ?? NSRange(location: 0, length: text.length)
    let options: NSString.CompareOptions = matching == .wholeWordMatchCase ? [.literal] : [.literal, .caseInsensitive]
    var found: [NSRange] = []
    var searchStart = bounds.location
    while searchStart < NSMaxRange(bounds) {
        let scope = NSRange(location: searchStart, length: NSMaxRange(bounds) - searchStart)
        let hit = text.range(of: needle, options: options, range: scope)
        guard hit.location != NSNotFound else { break }
        searchStart = NSMaxRange(hit)
        guard matching == .substringIgnoreCase || isWholeWord(hit, in: text) else { continue }
        found.append(hit)
    }
    return found
}

// VS Code's default editor.wordSeparators plus the characters it classes as whitespace.
private let wordSeparators = CharacterSet(charactersIn: "`~!@#$%^&*()-=+[{]}\\|;:'\",.<>/? \t\r\n")

private func isWordCharacter(at index: Int, in text: NSString) -> Bool {
    guard let scalar = Unicode.Scalar(text.character(at: index)) else { return true }
    return !wordSeparators.contains(scalar)
}

private func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
    if range.location > 0, isWordCharacter(at: range.location - 1, in: text) { return false }
    let after = NSMaxRange(range)
    return after >= text.length || !isWordCharacter(at: after, in: text)
}

func wordRange(touching location: Int, in text: NSString) -> NSRange? {
    var start = location
    while start > 0, isWordCharacter(at: start - 1, in: text) { start -= 1 }
    var end = location
    while end < text.length, isWordCharacter(at: end, in: text) { end += 1 }
    return end > start ? NSRange(location: start, length: end - start) : nil
}

func nextOccurrence(after location: Int, of needle: String, in text: NSString, matching: OccurrenceMatching) -> NSRange? {
    let rest = NSRange(location: location, length: text.length - location)
    return occurrences(of: needle, in: text, matching: matching, within: rest).first
        ?? occurrences(of: needle, in: text, matching: matching).first
}

func summaryText(for ranges: [NSRange], in text: NSString) -> String {
    guard let first = ranges.first else { return "Ln 1, Col 1" }
    let lines = selectedLineCount(ranges, in: text)
    let plural = lines == 1 ? "" : "s"
    guard ranges.count > 1 else {
        guard first.length > 0 else {
            let line = text.lineRange(for: NSRange(location: min(first.location, max(text.length - 1, 0)), length: 0))
            return "Ln \(lineNumber(of: first.location, in: text)), Col \(first.location - line.location + 1)"
        }
        return "\(lines) line\(plural) selected"
    }
    guard ranges.contains(where: { $0.length > 0 }) else { return "\(ranges.count) cursors" }
    return "\(ranges.count) cursors · \(lines) line\(plural) selected"
}

private func selectedLineCount(_ ranges: [NSRange], in text: NSString) -> Int {
    var lines = Set<Int>()
    for range in ranges where range.length > 0 {
        var cursor = range.location
        let last = NSMaxRange(range) - 1
        while cursor <= last {
            let line = text.lineRange(for: NSRange(location: min(cursor, max(text.length - 1, 0)), length: 0))
            lines.insert(line.location)
            guard NSMaxRange(line) > cursor else { break }
            cursor = NSMaxRange(line)
        }
    }
    return lines.count
}

private func lineNumber(of location: Int, in text: NSString) -> Int {
    var number = 1
    var cursor = 0
    while cursor < location {
        let line = text.lineRange(for: NSRange(location: min(cursor, max(text.length - 1, 0)), length: 0))
        guard NSMaxRange(line) <= location, NSMaxRange(line) > cursor else { break }
        cursor = NSMaxRange(line)
        number += 1
    }
    return number
}

func occurrenceNeedle(for carets: [NSRange], primary: Int, in text: NSString) -> String? {
    let selection = carets[min(primary, carets.count - 1)]
    guard selection.length > 0, selection.length <= 200 else { return nil }
    let needle = text.substring(with: selection)
    guard carets.allSatisfy({ text.substring(with: $0).lowercased() == needle.lowercased() }) else { return nil }
    return needle
}

func lineBlocks(for carets: [NSRange], in text: NSString) -> [NSRange] {
    guard !carets.isEmpty, text.length > 0 else { return [] }
    let clamp = { (location: Int) in min(max(location, 0), text.length - 1) }
    let raw = carets.map { caret -> NSRange in
        let first = text.lineRange(for: NSRange(location: clamp(caret.location), length: 0))
        let last = text.lineRange(for: NSRange(location: clamp(max(caret.location, NSMaxRange(caret) - 1)), length: 0))
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
    var merged = [raw.sorted { $0.location < $1.location }[0]]
    for block in raw.sorted(by: { $0.location < $1.location }).dropFirst() {
        let last = merged[merged.count - 1]
        guard block.location <= NSMaxRange(last) else {
            merged.append(block)
            continue
        }
        merged[merged.count - 1] = NSUnionRange(last, block)
    }
    return merged
}
