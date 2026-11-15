import XCTest
@testable import PaperclipMobile

final class TorStartupTests: XCTestCase {
    func testControlPortIsStrictlyLoopback() {
        XCTAssertEqual(TorStartupSnapshot.controlPort("PORT=127.0.0.1:49152\n"), 49152)
        for value in ["127.0.0.1:9050", "PORT=0.0.0.0:9050", "PORT=example.com:9050", "PORT=127.0.0.1:0", "PORT=127.0.0.1:65536", "PORT=127.0.0.1:9050/path", "PORT=user@127.0.0.1:9050", "PORT=127.0.0.1:9050\nPORT=127.0.0.1:9051"] {
            XCTAssertNil(TorStartupSnapshot.controlPort(value), value)
        }
    }
    func testBootstrapCompletionIsSeparateFromCircuitAndSOCKSReadiness() {
        let pending = TorStartupSnapshot(values: ["0", "\"127.0.0.1:49152\"", "NOTICE BOOTSTRAP PROGRESS=100 TAG=done"])
        XCTAssertEqual(pending?.progress, 100)
        XCTAssertEqual(pending?.circuitReady, false)
        XCTAssertEqual(pending?.socksEndpoint, "socks5h://127.0.0.1:49152")
        let ready = TorStartupSnapshot(values: ["1", "\"[::1]:9000\" \"127.0.0.1:49152\"", "NOTICE BOOTSTRAP PROGRESS=100"])
        XCTAssertEqual(ready?.circuitReady, true)
        XCTAssertEqual(ready?.socksEndpoint, "socks5h://127.0.0.1:49152")
        XCTAssertNil(TorStartupSnapshot(values: ["1", "\"0.0.0.0:9050\"", "PROGRESS=100"])?.socksEndpoint)
    }
    func testMalformedStatusNeverCreatesAUsableProxy() {
        XCTAssertNil(TorStartupSnapshot(values: []))
        XCTAssertNil(TorStartupSnapshot(values: ["yes", "127.0.0.1:9050", "PROGRESS=100"]))
        for progress in ["-1", "101", "bad"] {
            XCTAssertNil(TorStartupSnapshot(values: ["0", "", "PROGRESS=\(progress)"])?.progress)
        }
        XCTAssertNotEqual(TorStartupStage.authentication.timeoutMessage, TorStartupStage.bootstrap.timeoutMessage)
    }
    func testCancelledWaiterReturnsWhileAnotherWaiterKeepsUsingStartup() async throws {
        let shared = Task<String, Error> {
            try await Task.sleep(for: .seconds(2))
            return "socks5h://127.0.0.1:19050"
        }
        defer { shared.cancel() }
        let cancelled = expectation(description: "Cancellation returns before bootstrap completes")
        let first = Task {
            do { _ = try await TorStartupWaiter.value(of: shared); XCTFail("Cancelled waiter succeeded") }
            catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected cancellation error") }
        }
        let second = Task { try await TorStartupWaiter.value(of: shared) }
        try await Task.sleep(for: .milliseconds(50))
        first.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertFalse(shared.isCancelled)
        let result = try await second.value
        XCTAssertEqual(result, "socks5h://127.0.0.1:19050")
        await first.value
    }

    func testStartupFailurePropagatesAndFreshAttemptCanSucceed() async throws {
        let failed = Task<String, Error> { throw URLError(.cannotConnectToHost) }
        do { _ = try await TorStartupWaiter.value(of: failed); XCTFail("Failure was lost") }
        catch let error as URLError { XCTAssertEqual(error.code, .cannotConnectToHost) }
        let fresh = Task<String, Error> { "socks5h://127.0.0.1:19051" }
        let endpoint = try await TorStartupWaiter.value(of: fresh)
        XCTAssertEqual(endpoint, "socks5h://127.0.0.1:19051")
    }

}
