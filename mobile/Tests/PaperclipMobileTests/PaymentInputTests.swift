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
}
