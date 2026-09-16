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
