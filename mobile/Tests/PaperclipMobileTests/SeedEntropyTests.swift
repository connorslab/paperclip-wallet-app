import XCTest
@testable import PaperclipMobile

final class SeedEntropyTests: XCTestCase {
    func testDiceThresholdsAndVectors() throws {
        // Fixtures independently calculated with Python hashlib; these predictable
        // sequences are test vectors only, never examples for generating a wallet.
        let vectors = [(6, 50, "ec28f632c842726f6ed490c9115f9d32"), (12, 36, "28f23d996c90d93745bc88f05c6103c4"), (20, 30, "91a93aac185e128e5dd9f7aa027092bf")]
        for (sides, count, expected) in vectors {
            XCTAssertEqual(try SeedEntropy.requiredRolls(words: 12, sides: sides), count)
            XCTAssertEqual(try SeedEntropy.requiredRolls(words: 24, sides: sides), count * 2)
            let rolls = (0..<count).map { $0 % sides + 1 }
            XCTAssertThrowsError(try SeedEntropy.dice(Array(rolls.dropLast()), sides: sides, words: 12))
            XCTAssertEqual(try SeedEntropy.dice(rolls, sides: sides, words: 12).map { String(format: "%02x", $0) }.joined(), expected)
            XCTAssertEqual(try SeedEntropy.dice(rolls + rolls, sides: sides, words: 24).count, 32)
            XCTAssertThrowsError(try SeedEntropy.dice(rolls + [sides + 1], sides: sides, words: 12))
            XCTAssertThrowsError(try SeedEntropy.dice(rolls + [0], sides: sides, words: 12))
        }
        XCTAssertThrowsError(try SeedEntropy.requiredRolls(words: 12, sides: 8))
        XCTAssertThrowsError(try SeedEntropy.system(words: 15))
    }
    func testMixRequiresSystemRandomAndFixedDigest() throws {
        let system = Data(repeating: 1, count: 32), sensor = Data(repeating: 2, count: 32)
        let first = try SeedEntropy.mix(system: system, sensorDigest: sensor, words: 24)
        XCTAssertEqual(first.count, 32)
        XCTAssertNotEqual(first, try SeedEntropy.mix(system: Data(repeating: 3, count: 32), sensorDigest: sensor, words: 24))
        XCTAssertNotEqual(first, try SeedEntropy.mix(system: system, sensorDigest: Data(repeating: 3, count: 32), words: 24))
        XCTAssertThrowsError(try SeedEntropy.mix(system: Data(), sensorDigest: sensor, words: 24))
        XCTAssertThrowsError(try SeedEntropy.mix(system: system, sensorDigest: Data(), words: 24))
        XCTAssertEqual(try SeedEntropy.system(words: 12).count, 16)
        XCTAssertEqual(try SeedEntropy.system(words: 24).count, 32)
    }
}
