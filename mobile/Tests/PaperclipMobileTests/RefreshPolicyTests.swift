import XCTest
@testable import PaperclipMobile

final class RefreshPolicyTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)
    func snapshot(_ rows: [VTXO], age: Double = 0) -> WalletSnapshot {
        .init(tip: 1000, observedAt: now.addingTimeInterval(-age), estimatedBlockSeconds: 600, vtxos: rows)
    }
    func testExpiredAndLockedInputsAreNotRefreshed() {
        let state = snapshot([.init(id: "expired", expiryHeight: 1000, spendable: true),
            .init(id: "locked", expiryHeight: 1010, spendable: false),
            .init(id: "eligible", expiryHeight: 1144, spendable: true),
            .init(id: "later", expiryHeight: 1145, spendable: true)])
        XCTAssertEqual(RefreshPolicy.eligible(state, now: now).map(\.id), ["eligible"])
        XCTAssertTrue(RefreshPolicy.reminders(state, now: now)[0].body.contains("recovery"))
    }
    func testStaleDataDoesNotAuthorizeRefresh() {
        let state = snapshot([.init(id: "a", expiryHeight: 1100, spendable: true)], age: 30_000)
        XCTAssertTrue(RefreshPolicy.eligible(state, now: now).isEmpty)
        XCTAssertEqual(RefreshPolicy.reminders(state, now: now).map(\.id), ["paperclip.expiry.stale"])
    }
    func testRemindersAreBoundedAndPrivate() {
        let state = snapshot((0..<1000).map { .init(id: "private-\($0)", expiryHeight: 1600, spendable: true) })
        let reminders = RefreshPolicy.reminders(state, now: now)
        XCTAssertEqual(reminders.count, 4)
        XCTAssertEqual(Set(reminders.map(\.id)).count, reminders.count)
        XCTAssertTrue(reminders.allSatisfy { !$0.body.contains("private-") && $0.date > now })
        XCTAssertTrue(RefreshPolicy.reminders(snapshot([]), now: now).isEmpty)
    }
    func testUrgentRemindersCoalesce() {
        let reminders = RefreshPolicy.reminders(snapshot([.init(id: "a", expiryHeight: 1020, spendable: true)]), now: now)
        XCTAssertEqual(reminders.filter { $0.id == "paperclip.expiry.now" }.count, 1)
    }
    func testCoordinatorRechecksAfterRefresh() async throws {
        let engine = TestEngine(state: snapshot([.init(id: "a", expiryHeight: 1100, spendable: true)]))
        let coordinator = RefreshCoordinator(engine: engine)
        let after = try await coordinator.run(automatic: true, now: now)
        XCTAssertEqual(after?.vtxos.first?.expiryHeight, 2000)
        let count = await engine.refreshes
        XCTAssertEqual(count, 1)
    }
    func testDisabledAutomaticRefreshOnlySynchronizes() async throws {
        let engine = TestEngine(state: snapshot([.init(id: "a", expiryHeight: 1100, spendable: true)]))
        _ = try await RefreshCoordinator(engine: engine).run(automatic: false, now: now)
        let count = await engine.refreshes
        XCTAssertEqual(count, 0)
    }
}

actor TestEngine: WalletEngine {
    var state: WalletSnapshot
    var refreshes = 0
    init(state: WalletSnapshot) { self.state = state }
    func synchronize() async throws -> WalletSnapshot { state }
    func refreshEligible() async throws {
        refreshes += 1
        state = .init(tip: state.tip, observedAt: state.observedAt, estimatedBlockSeconds: 600,
            vtxos: [.init(id: "renewed", expiryHeight: 2000, spendable: true)])
    }
}
