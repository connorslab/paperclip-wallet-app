import XCTest
@testable import PaperclipMobile

final class NodePaymentBindingTests: XCTestCase {
    private let paymentHash = String(repeating: "12", count: 32)
    private func connection() -> LightningConnection {
        var c = LightningConnection(); c.implementation = .lnd
        c.endpoint = "https://node.example:8180"; c.credential = "aabb"
        return c
    }
    func testNewRecordIsBoundWithoutCopyingCredentials() throws {
        let c = connection(), payment = PendingNodePayment(invoice: "synthetic-invoice", hash: paymentHash, connection: connection())
        try payment.validate()
        XCTAssertFalse(payment.needsNodeReview); XCTAssertTrue(payment.matches(c))
        var other = c; other.endpoint = "https://another.example"
        XCTAssertFalse(payment.matches(other))
        other = c; other.implementation = .cln
        XCTAssertFalse(payment.matches(other))
        let encoded = try JSONEncoder().encode(payment)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["invoice", "hash", "endpoint", "implementation"])
        XCTAssertEqual(try JSONDecoder().decode(PendingNodePayment.self, from: encoded), payment)
        XCTAssertThrowsError(try payment.assigningOriginalNode(c))
    }
    func testLegacyRecordRequiresAssignmentAndKeepsExactInvoiceAndHash() throws {
        let data = try JSONSerialization.data(withJSONObject: ["invoice":"synthetic-invoice", "hash":paymentHash])
        let legacy = try JSONDecoder().decode(PendingNodePayment.self, from: data)
        try legacy.validate()
        XCTAssertTrue(legacy.needsNodeReview); XCTAssertFalse(legacy.matches(connection()))
        let assigned = try legacy.assigningOriginalNode(connection())
        XCTAssertEqual(assigned.invoice, legacy.invoice); XCTAssertEqual(assigned.hash, legacy.hash)
        XCTAssertTrue(assigned.matches(connection()))
        XCTAssertFalse(assigned.needsNodeReview)
        XCTAssertThrowsError(try assigned.assigningOriginalNode(connection()))
    }
    func testDamagedAndPartialBindingsCannotBecomeReviewedPayments() throws {
        for patch: [String: Any] in [["endpoint":"https://node.example"], ["implementation":"lnd"], ["hash":"short"], ["invoice":""]] {
            var fields: [String: Any] = ["invoice":"synthetic-invoice", "hash":paymentHash]
            fields.merge(patch) { _, new in new }
            let payment = try JSONDecoder().decode(PendingNodePayment.self, from: JSONSerialization.data(withJSONObject: fields))
            XCTAssertThrowsError(try payment.validate())
            XCTAssertThrowsError(try payment.assigningOriginalNode(connection()))
        }
    }
}
