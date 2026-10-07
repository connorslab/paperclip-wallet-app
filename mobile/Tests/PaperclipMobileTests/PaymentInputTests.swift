import XCTest
@testable import PaperclipMobile

final class PaymentInputTests: XCTestCase {
    func testInvoicePresentationAcceptsClipboardURIAndUppercase() {
        XCTAssertEqual(PaymentInput.normalized(" \nLIGHTNING:LNBC100u1example\n"), "LNBC100u1example")
        XCTAssertTrue(PaymentInput.isBolt11(" LIGHTNING:LNBC100u1example "))
        XCTAssertTrue(PaymentInput.isBolt11("lnbcrt1example"))
    }
    func testOtherDestinationsKeepAmountEntry() {
        for value in ["bc1pexample", "lno1example", "ark1example", ""] {
            XCTAssertFalse(PaymentInput.isBolt11(value))
            XCTAssertEqual(PaymentInput.normalized(value), value)
        }
    }
    func testScannedRequestPreservesExactSatsAndRejectsAmbiguity() throws {
        let request = try PaymentInput.scanned("bitcoin:bc1pexample?amount=0.00004001&label=Alice")
        XCTAssertEqual(request.destination, "bc1pexample")
        XCTAssertEqual(request.amountSat, 4001)
        XCTAssertNil(try PaymentInput.scanned("lightning:lnbc1example").amountSat)
        for query in ["amount=1e-8", "amount=-1", "amount=0.000000001", "amount=1&amount=2", "req-feature=x", "amount=21000000.00000001"] {
            XCTAssertThrowsError(try PaymentInput.scanned("bitcoin:bc1pexample?" + query))
        }
        XCTAssertThrowsError(try PaymentInput.scanned("https://example.com"))
    }

}
