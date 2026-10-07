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
        let cln: [String: Any] = ["type": "bolt11 invoice", "payment_hash": invoiceHash, "amount_msat": "12000msat", "created_at": 1900, "expiry": 200, "valid": true]
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
    func testBolt12ReviewFieldsDefaultExpiryAndInvalidSignatures() throws {
        let now = Date(timeIntervalSince1970: 2000)
        let invoice: [String: Any] = ["type": "bolt12 invoice", "valid": true, "invoice_payment_hash": invoiceHash,
                                    "invoice_amount_msat": "12001msat", "invoice_created_at": 1900]
        let review = try LightningPaymentReview.decode(data(invoice), implementation: .cln, now: now)
        XCTAssertEqual(review.millisatoshis, 12001)
        XCTAssertEqual(review.expiresAt, 9100)
        for patch in [["valid": false], ["invoice_relative_expiry": 50], ["invoice_amount_msat": true], ["invoice_payment_hash": "bad"]] as [[String: Any]] {
            let bad = invoice.merging(patch) { _, new in new }
            XCTAssertThrowsError(try LightningPaymentReview.decode(data(bad), implementation: .cln, now: now))
        }
        XCTAssertThrowsError(try LightningPaymentReview.decode(data(invoice), implementation: .lnd, now: now))
    }
    func testOfferAmountsAndUnsupportedOptions() throws {
        let offer: [String: Any] = ["type": "bolt12 offer", "valid": true, "offer_amount_msat": "21001msat"]
        XCTAssertEqual(try LightningOfferReview.decode(data(offer)).amountMsat, 21001)
        var any = offer; any.removeValue(forKey: "offer_amount_msat")
        XCTAssertNil(try LightningOfferReview.decode(data(any)).amountMsat)
        for patch in [["valid": false], ["offer_amount_msat": true], ["offer_currency": "USD"],
                      ["offer_quantity_max": 2], ["offer_recurrence": [:]], ["offer_absolute_expiry": 1]] as [[String: Any]] {
            XCTAssertThrowsError(try LightningOfferReview.decode(data(offer.merging(patch) { _, new in new })))
        }
        let params = try LightningNode.fetchOfferParameters("lno1example", amountMsat: 21001)
        XCTAssertEqual(params["amount_msat"] as? String, "21001msat")
        XCTAssertEqual(params["offer"] as? String, "lno1example")
        XCTAssertNil(try LightningNode.fetchOfferParameters("lno1example", amountMsat: nil)["amount_msat"])
        XCTAssertThrowsError(try LightningNode.fetchOfferParameters("lnbc1example", amountMsat: 1))
        XCTAssertThrowsError(try LightningNode.fetchOfferParameters("lno1example", amountMsat: 0))
    }

}
