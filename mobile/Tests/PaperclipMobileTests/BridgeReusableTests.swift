import XCTest
@testable import PaperclipMobile

final class BridgeReusableTests: XCTestCase {
    func testCanonicalOfferNetworkAndAmountBoundaries() throws {
        struct Case: Decodable { let name: String; let offer: String; let xbt: Bool; let valid: Bool }
        let url = Bundle.module.url(forResource: "bridge-reusable", withExtension: "json", subdirectory: "Fixtures")!
        for item in try JSONDecoder().decode([Case].self, from: Data(contentsOf: url)) {
            if item.valid { XCTAssertNoThrow(try BridgeReusableOffer.validateOffer(item.offer, xbt: item.xbt), item.name) }
            else { XCTAssertThrowsError(try BridgeReusableOffer.validateOffer(item.offer, xbt: item.xbt), item.name) }
        }
        XCTAssertThrowsError(try BridgeReusableOffer.validateOffer("lno1" + String(repeating: "q", count: 16384), xbt: false))
    }
    func testManagementKeysCannotBeEmptyZeroOrURLData() {
        XCTAssertTrue(BridgeReusableOffer.validToken(String(repeating: "ab", count: 32)))
        for key in ["", String(repeating: "0", count: 64), String(repeating: "A", count: 64), "https://example.com/?token=" + String(repeating: "a", count: 64)] {
            XCTAssertFalse(BridgeReusableOffer.validToken(key))
        }
    }
}
