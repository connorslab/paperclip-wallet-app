import XCTest
@testable import PaperclipMobile

@MainActor final class XBTPriceTests: XCTestCase {
    func testFailureRetriesAndSuccessfulQuoteSurvivesRelaunch() async {
        let suite = "price-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_792_269_651)
        let data = Data("{\"price\":648.79,\"updated\":1792269651000}".utf8)
        var calls = 0
        let price = XBTPrice(defaults: defaults, clock: { now }) {
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
            return data
        }
        await price.refresh()
        XCTAssertNil(price.usd)
        await price.refresh()
        XCTAssertEqual(calls, 1)
        now += 31
        await price.refresh()
        XCTAssertEqual(price.usd, 648.79)
        await price.refresh()
        XCTAssertEqual(calls, 2)
        let restored = XBTPrice(defaults: defaults, clock: { now }, fetch: { data })
        XCTAssertEqual(restored.usd, 648.79)
        now += 86400
        let expired = XBTPrice(defaults: defaults, clock: { now }, fetch: { data })
        XCTAssertNil(expired.usd)
    }

    func testCancelledViewDoesNotCancelSharedRequest() async {
        let suite = "price-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_792_269_651)
        let price = XBTPrice(defaults: defaults, clock: { now }) {
            try await Task.sleep(nanoseconds: 20_000_000)
            try Task.checkCancellation()
            return Data("{\"price\":648.79,\"updated\":1792269651000}".utf8)
        }
        let viewTask = Task { await price.refresh() }
        await Task.yield()
        viewTask.cancel()
        await viewTask.value
        XCTAssertEqual(price.usd, 648.79)
        XCTAssertFalse(price.loading)
    }

    func testManualRetryBypassesBackoffAndRejectsBadQuotes() async {
        let suite = "price-tests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_792_269_651)
        var response = Data("{\"price\":-1,\"updated\":1792269651000}".utf8)
        let price = XBTPrice(defaults: defaults, clock: { now }, fetch: { response })
        await price.refresh()
        XCTAssertNil(price.usd)
        response = Data("{\"price\":648.79,\"updated\":1792269651000}".utf8)
        await price.refresh(force: true)
        XCTAssertEqual(price.usd, 648.79)
        response = Data("{\"price\":999,\"updated\":1792369651000}".utf8)
        await price.refresh(force: true)
        XCTAssertEqual(price.usd, 648.79)
    }
}
