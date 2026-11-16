import XCTest
@testable import PaperclipMobile

final class FeeReplacementReviewTests: XCTestCase {
    func testReviewRejectsUnboundAmountsAndIncompleteRecipients() throws {
        let txid = String(repeating: "a", count: 64)
        let valid: [String:Any] = ["original_txid":txid, "replacement_txid":String(repeating:"b",count:64), "old_fee_sat":1000, "new_fee_sat":2000, "additional_fee_sat":1000, "recipients":[["address":"bcrt1qfixture", "amount_sat":100000]]]
        func validate(_ value: [String:Any]) throws { try FeeReplacementReview.validate(JSONSerialization.data(withJSONObject:value), expectedTransaction:txid) }
        XCTAssertNoThrow(try validate(valid))
        for (field, value) in [("additional_fee_sat", 999 as Any), ("new_fee_sat", 0), ("old_fee_sat", -1), ("recipients", []), ("recipients", [["address":"", "amount_sat":100000]]), ("original_txid", String(repeating:"c",count:64)), ("replacement_txid", txid)] {
            var changed = valid; changed[field] = value
            XCTAssertThrowsError(try validate(changed), field)
        }
    }
}
