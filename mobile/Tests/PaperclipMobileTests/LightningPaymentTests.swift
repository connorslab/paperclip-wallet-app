import XCTest
@testable import PaperclipMobile

final class LightningPaymentTests: XCTestCase {
    let invoiceHash = String(repeating: "a", count: 64)
    func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func testReviewRejectsExpiredOrInvalidInvoices() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let invoice: [String: Any] = ["payment_hash": invoiceHash, "num_msat": "12000", "timestamp": "1900", "expiry": "200"]
        XCTAssertEqual(try LightningPaymentReview.decode(data(invoice), implementation: .lnd, now: now).millisatoshis, 12000)
        var expired = invoice; expired["expiry"] = "50"
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(expired), implementation: .lnd, now: now))
        var missing = invoice; missing["num_msat"] = "0"
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(missing), implementation: .lnd, now: now))
        let cln: [String: Any] = ["payment_hash": invoiceHash, "amount_msat": "12000msat", "created_at": 1900, "expiry": 200, "valid": true]
        XCTAssertEqual(try LightningPaymentReview.decode(data(cln), implementation: .cln, now: now).millisatoshis, 12000)
    }
    func testIncompleteOrDifferentPaymentNeverClearsPendingAttempt() throws {
        for records in [[], [["payment_hash": invoiceHash, "status": "IN_FLIGHT"]], [["payment_hash": "other", "status": "SUCCEEDED"]],
                        [["payment_hash": invoiceHash, "status": "FAILED"], ["payment_hash": invoiceHash, "status": "IN_FLIGHT"]]] {
            XCTAssertNil(try LightningPaymentState.terminalState(in: data(["payments": records]), hash: invoiceHash, implementation: .lnd))
        }
        XCTAssertEqual(try LightningPaymentState.terminalState(in: data(["payments": [["payment_hash": invoiceHash, "status": "SUCCEEDED"]]]), hash: invoiceHash, implementation: .lnd), "succeeded")
        XCTAssertEqual(try LightningPaymentState.terminalState(in: data(["pays": [["payment_hash": invoiceHash, "status": "failed"]]]), hash: invoiceHash, implementation: .cln), "failed")
    }
}
