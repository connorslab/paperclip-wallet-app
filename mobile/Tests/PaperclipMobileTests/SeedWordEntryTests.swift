import XCTest
@testable import PaperclipMobile

final class SeedWordEntryTests: XCTestCase {
    func testWordListAndSpellingSuggestions() {
        XCTAssertEqual(SeedWordEntry.words.count, 2048)
        XCTAssertEqual(Set(SeedWordEntry.words).count, 2048)
        XCTAssertTrue(SeedWordEntry.isWord(" ABOUT\n"))
        XCTAssertFalse(SeedWordEntry.isWord("abotu"))
        XCTAssertTrue(SeedWordEntry.suggestions("aba").contains("abandon"))
        XCTAssertTrue(SeedWordEntry.suggestions("").isEmpty)
    }
    func testNumberedPastesAndOrderedVerification() {
        for count in [12, 24] {
            let words = Array(SeedWordEntry.words.prefix(count))
            let numbered = words.enumerated().map { "\($0.offset + 1). \($0.element.uppercased())" }.joined(separator: "\n")
            XCTAssertEqual(SeedWordEntry.pastedWords(numbered), words)
            let phrase = words.joined(separator: " ")
            XCTAssertTrue(SeedVerification.matches(phrase: phrase, confirmation: SeedWordEntry.pastedWords(numbered).joined(separator: " ")))
            XCTAssertTrue(SeedWordEntry.mismatches(phrase: phrase, entries: words).isEmpty)
            var swapped = words; swapped.swapAt(0, 1)
            XCTAssertEqual(SeedWordEntry.mismatches(phrase: phrase, entries: swapped), [0, 1])
        }
        XCTAssertEqual(SeedWordEntry.pastedWords("1) abandon\n2) abotu"), ["abandon", "abotu"])
    }
}
