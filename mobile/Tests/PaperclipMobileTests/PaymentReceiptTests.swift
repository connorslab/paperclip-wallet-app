import XCTest
@testable import PaperclipMobile

final class PaymentReceiptTests: XCTestCase {
    func testRecoveredReceiptUsesTheConfirmedCandidateNotTheLatestProposal() {
        let original = String(repeating: "ab", count: 32), replacement = String(repeating: "cd", count: 32)
        var result: [String: Any] = ["state":"submitted", "txid":original, "replacement_txids":[replacement]]
        XCTAssertEqual(PaymentReceipt.recoveredTransactionID(result), replacement)
        result["state"] = "completed"
        XCTAssertNil(PaymentReceipt.recoveredTransactionID(result), "An older receipt does not prove which candidate confirmed")
        for winner in [original, replacement] {
            result["confirmed_txid"] = winner
            XCTAssertEqual(PaymentReceipt.recoveredTransactionID(result), winner)
        }
        result["confirmed_txid"] = String(repeating: "ef", count: 32)
        XCTAssertNil(PaymentReceipt.recoveredTransactionID(result))
        result["confirmed_txid"] = original; result["state"] = "unknown"
        XCTAssertNil(PaymentReceipt.recoveredTransactionID(result))
        XCTAssertEqual(PaymentReceipt.recoveredTransactionID(["state":"completed", "txid":original]), original)
        XCTAssertNil(PaymentReceipt.recoveredTransactionID(["state":"pending", "txid":NSNull()]))
    }
    func testSubmissionIsNotConfirmation() {
        let sent = PaymentReceipt(state: "submitted", transactionID: "test")
        XCTAssertFalse(sent.completed)
        XCTAssertEqual(sent.title, "Transaction sent")
        XCTAssertTrue(sent.message.contains("waiting for confirmation"))
        XCTAssertEqual(sent.transactionID, "test")
        XCTAssertFalse(PaymentReceipt(state: "pending_broadcast").completed)
        XCTAssertTrue(PaymentReceipt(state: "completed").completed)
    }
    func testBoardingPendingDoesNotClaimRegistration() {
        let receipt = PaymentReceipt(state: "pending", boarding: true)
        XCTAssertEqual(receipt.title, "Ark deposit started")
        XCTAssertFalse(receipt.completed)
        XCTAssertTrue(receipt.message.contains("registration with the Ark server"))
        XCTAssertFalse(receipt.message.contains("deposit is registered"))
        XCTAssertTrue(receipt.message.contains("Do not make another deposit"))
    }
    func testNotificationBaselineAndDeduplication() {
        func item(_ id: String, _ status: String, _ amount: Int64 = 100) -> ActivityItem {
            ActivityItem(id: id, title: "On-chain", status: status, amountSat: amount, detail: "")
        }
        var state = ActivityNotificationState()
        XCTAssertTrue(state.changes([item("old", "Confirmed")]).isEmpty)
        XCTAssertEqual(state.changes([item("old", "Confirmed"), item("new", "Pending")]).map(\.id), ["new"])
        XCTAssertTrue(state.changes([item("new", "Pending")]).isEmpty)
        XCTAssertEqual(state.changes([item("new", "Confirmed")]).map(\.id), ["new"])
        XCTAssertTrue(state.changes([item("zero", "Confirmed", 0)]).isEmpty)
        XCTAssertTrue(state.changes([ActivityItem(id: "historical", title: "On-chain", status: "Confirmed", amountSat: 100, detail: "", date: .distantPast)]).isEmpty)
        let restored = try! JSONDecoder().decode(ActivityNotificationState.self, from: JSONEncoder().encode(state))
        var reload = restored
        XCTAssertTrue(reload.changes([item("new", "Confirmed")]).isEmpty)
    }
}
