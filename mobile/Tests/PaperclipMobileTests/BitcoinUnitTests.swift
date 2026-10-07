import XCTest
@testable import PaperclipMobile

final class BitcoinUnitTests: XCTestCase {
    func testExactConversionsAndRoundTrips() {
        for amount: UInt64 in [0, 1, 100, 5880, 100_000_000, 2_100_000_000_000_000] {
            for unit in BitcoinUnit.allCases { XCTAssertEqual(unit.parse(unit.input(amount)), amount) }
        }
        XCTAssertEqual(BitcoinUnit.xbt.parse("0.00005880"), 5880)
        XCTAssertEqual(BitcoinUnit.xbt.parse("0,00000001"), 1)
        XCTAssertEqual(BitcoinUnit.xbt.input(1), "0.00000001")
        XCTAssertEqual(BitcoinUnit.xbt.signed(-5880), "−0.0000588 XBT")
    }
    func testInvalidAmountsNeverRoundOrOverflow() {
        for value in ["1e-8", "-1", "+1", "NaN", "0.000000001", "21000000.00000001", "18446744073709551615", "1,000.00"] {
            XCTAssertNil(BitcoinUnit.xbt.parse(value))
        }
        XCTAssertNil(BitcoinUnit.sats.parse("1.1"))
        XCTAssertNil(BitcoinUnit.sats.parse("1,000"))
    }
}
