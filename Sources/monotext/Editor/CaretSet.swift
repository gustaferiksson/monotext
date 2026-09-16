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
        guard range.location <= NSMaxRange(last) else {
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

func occurrences(of needle: String, in haystack: String, wordBoundaries: Bool) -> [NSRange] {
    guard !needle.isEmpty else { return [] }
    let text = haystack as NSString
    var found: [NSRange] = []
    var searchStart = 0
    while searchStart < text.length {
        let scope = NSRange(location: searchStart, length: text.length - searchStart)
        let hit = text.range(of: needle, options: [.literal], range: scope)
        guard hit.location != NSNotFound else { break }
        searchStart = hit.location + 1
        guard !wordBoundaries || isWholeWord(hit, in: text) else { continue }
        found.append(hit)
    }
    return found
}

private func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
    let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
    let isWordCharacter = { (index: Int) -> Bool in
        guard let scalar = Unicode.Scalar(text.character(at: index)) else { return false }
        return wordCharacters.contains(scalar)
    }
    if range.location > 0, isWordCharacter(range.location - 1) { return false }
    let after = NSMaxRange(range)
    return after >= text.length || !isWordCharacter(after)
}

func nextOccurrence(after location: Int, of needle: String, in haystack: String, wordBoundaries: Bool, excluding taken: [NSRange]) -> NSRange? {
    let all = occurrences(of: needle, in: haystack, wordBoundaries: wordBoundaries)
    let free = all.filter { candidate in !taken.contains { NSEqualRanges($0, candidate) } }
    guard !free.isEmpty else { return nil }
    return free.first { $0.location >= location } ?? free.first
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
