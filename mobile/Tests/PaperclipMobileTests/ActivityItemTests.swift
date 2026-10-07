import XCTest
@testable import PaperclipMobile

final class ActivityItemTests: XCTestCase {
    private func item(_ id: String, _ date: Date?) -> ActivityItem {
        ActivityItem(id: id, title: "", status: "", amountSat: 0, detail: "", date: date)
    }
    func testMixedWalletActivitySortsByActualTime() throws {
        let early = try XCTUnwrap(ActivityItem.parseDate("2026-10-07T08:00:00.123456-06:00"))
        let late = try XCTUnwrap(ActivityItem.parseDate("2026-10-07T15:00:00Z"))
        let rows = [item("ark-older", early), item("unknown", nil), item("onchain", late), item("ark-newer", late.addingTimeInterval(1))]
        let sorted = ActivityItem.newestFirst(rows)
        XCTAssertEqual(sorted.map(\.id), ["ark-newer", "onchain", "ark-older", "unknown"])
        XCTAssertEqual(sorted.filter { $0.id.hasPrefix("ark-") }.map(\.id), ["ark-newer", "ark-older"])
    }
    func testMissingAndEqualTimesHaveStableOrdering() {
        let date = ActivityItem.unixDate(100)
        XCTAssertEqual(ActivityItem.newestFirst([item("b", date), item("z", nil), item("a", date)]).map(\.id), ["a", "b", "z"])
        XCTAssertNil(ActivityItem.parseDate("unknown"))
        XCTAssertNil(ActivityItem.unixDate(0))
        XCTAssertNil(ActivityItem.unixDate(.nan))
    }
}
