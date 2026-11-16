import XCTest
@testable import PaperclipMobile

@MainActor final class PaymentReviewSessionTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var waiting = false
        func wait() async { await withCheckedContinuation { continuation = $0; waiting = true } }
        func release() { continuation?.resume(); continuation = nil }
    }
    func testDelayedReviewCannotAuthorizeAfterLockOrNavigation() async {
        let session = PaymentReviewSession(), gate = Gate()
        var approvals = 0
        let task = Task { @MainActor in
            let ticket = session.capture()
            await gate.wait()
            try session.check(ticket)
            approvals += 1
        }
        while !(await gate.waiting) { await Task.yield() }
        session.invalidate()
        let current = session.capture()
        await gate.release()
        do { try await task.value; XCTFail("A delayed response restored authorization") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(approvals, 0)
        XCTAssertNoThrow(try session.check(current))
    }
    func testLockDuringFinalPreflightStopsBeforeSubmissionJournal() async {
        let session = PaymentReviewSession(), gate = Gate(), reviewed = session.capture()
        var journaled = false, sent = false
        let task = Task { @MainActor in
            try session.check(reviewed)
            await gate.wait()
            try session.check(reviewed)
            journaled = true; sent = true
        }
        while !(await gate.waiting) { await Task.yield() }
        session.invalidate(); await gate.release()
        do { try await task.value; XCTFail("Stale review submitted") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(journaled); XCTAssertFalse(sent)
    }
    func testQueuedReviewUsesTheSessionAtTheTimeOfTheTap() async {
        let session = PaymentReviewSession(), ticket = session.capture()
        var requests = 0
        let queued = Task { @MainActor in try session.check(ticket); requests += 1 }
        session.invalidate()
        do { try await queued.value; XCTFail("Queued review survived navigation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 0)
    }
    func testOneSessionCannotAuthorizeAnotherScreen() {
        let first = PaymentReviewSession(), second = PaymentReviewSession()
        XCTAssertThrowsError(try second.check(first.capture()))
    }
}
