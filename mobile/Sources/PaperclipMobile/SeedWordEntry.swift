import Foundation

/// Standard BIP39 English list, from the CC0-licensed bip39 2.2.2 dependency.
public enum SeedWordEntry {
    public static let words: [String] = {
        guard let url = Bundle.module.url(forResource: "bip39-english", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isWhitespace).map(String.init)
    }()
    private static let vocabulary = Set(words)
    public static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public static func isWord(_ text: String) -> Bool { vocabulary.contains(normalized(text)) }
    public static func suggestions(_ text: String) -> [String] {
        let prefix = normalized(text)
        guard !prefix.isEmpty, !vocabulary.contains(prefix) else { return [] }
        return Array(words.lazy.filter { $0.hasPrefix(prefix) }.prefix(5))
    }
    /// Accept numbered written lists as well as whitespace-separated phrases.
    /// Words are never corrected or reordered silently.
    public static func pastedWords(_ text: String) -> [String] {
        let stripped = text.replacingOccurrences(of: #"(?:^|\s)\d{1,2}[.)?:]?\s*"#, with: " ", options: .regularExpression)
        return stripped.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }
    public static func mismatches(phrase: String, entries: [String]) -> [Int] {
        let expected = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        guard expected.count == entries.count else { return Array(entries.indices) }
        return entries.indices.filter { normalized(entries[$0]) != expected[$0] }
    }
}
