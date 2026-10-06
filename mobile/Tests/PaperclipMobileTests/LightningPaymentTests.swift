import XCTest
@testable import PaperclipMobile

final class LightningPaymentTests: XCTestCase {
    let hash = String(repeating: "a", count: 64)
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testReviewRejectsExpiredOrInvalidInvoices() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let invoice: [String: Any] = ["payment_hash": hash, "num_msat": "12000", "timestamp": "1900", "expiry": "200"]
        XCTAssertEqual(try LightningPaymentReview.decode(data(invoice), implementation: .lnd, now: now).millisatoshis, 12000)
        var expired = invoice; expired["expiry"] = "50"
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(expired), implementation: .lnd, now: now))
        var missing = invoice; missing["num_msat"] = "0"
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(missing), implementation: .lnd, now: now))
        let cln: [String: Any] = ["payment_hash": hash, "amount_msat": "12000msat", "created_at": 1900, "expiry": 200, "valid": true]
        XCTAssertEqual(try LightningPaymentReview.decode(data(cln), implementation: .cln, now: now).millisatoshis, 12000)
    }
    func testIncompleteOrDifferentPaymentNeverClearsPendingAttempt() throws {
        for records in [[], [["payment_hash": hash, "status": "IN_FLIGHT"]], [["payment_hash": "other", "status": "SUCCEEDED"]],
                        [["payment_hash": hash, "status": "FAILED"], ["payment_hash": hash, "status": "IN_FLIGHT"]]] {
            XCTAssertNil(try LightningPaymentState.terminalState(in: data(["payments": records]), hash: hash, implementation: .lnd))
        }
        XCTAssertEqual(try LightningPaymentState.terminalState(in: data(["payments": [["payment_hash": hash, "status": "SUCCEEDED"]]]), hash: hash, implementation: .lnd), "succeeded")
        XCTAssertEqual(try LightningPaymentState.terminalState(in: data(["pays": [["payment_hash": hash, "status": "failed"]]]), hash: hash, implementation: .cln), "failed")
    }
}
