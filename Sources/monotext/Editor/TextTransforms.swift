import Foundation

enum CaseStyle: Int {
    case upper, lower, title, camel, pascal, snake, kebab, constant
}

func transformed(_ text: String, to style: CaseStyle) -> String {
    switch style {
    case .upper: return text.uppercased()
    case .lower: return text.lowercased()
    case .title: return text.capitalized
    default: return text.replacing(#/\S(?:.*\S)?/#) { identifier(String($0.output), style) }
    }
}

private func identifier(_ phrase: String, _ style: CaseStyle) -> String {
    let words = phrase.matches(of: #/\p{Lu}+(?=\p{Lu}\p{Ll})|\p{Lu}?[\p{Ll}\p{N}]+|\p{Lu}+\p{N}*|[\p{L}\p{N}]+/#)
        .map { $0.output.lowercased() }
    switch style {
    case .camel: return (words.prefix(1) + words.dropFirst().map(\.capitalized)).joined()
    case .pascal: return words.map(\.capitalized).joined()
    case .snake: return words.joined(separator: "_")
    case .kebab: return words.joined(separator: "-")
    default: return words.joined(separator: "_").uppercased()
    }
}

func sortedLines(_ block: String, _ order: ComparisonResult) -> String {
    let endsWithNewline = block.hasSuffix("\n")
    let lines = (endsWithNewline ? String(block.dropLast()) : block).components(separatedBy: "\n")
    let sorted = lines.sorted { $0.localizedCompare($1) == order }
    return sorted.joined(separator: "\n") + (endsWithNewline ? "\n" : "")
}
