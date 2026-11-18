import XCTest
import PaperclipMobile

/// The native test host has a separate Keychain access group and no funded wallet.
final class NodePaymentRecoveryTests: XCTestCase {
    private let pendingKey = "lightning-pending-v1"
    private let connectionKey = "lightning-connection-v1"
    private func connection() -> LightningConnection {
        var c = LightningConnection(); c.implementation = .lnd
        c.endpoint = "https://127.0.0.1:1"; c.credential = "aabb"
        return c
    }
    private func prepare() throws {
        guard try WalletKeychain.read(pendingKey) == nil, try WalletKeychain.read(connectionKey) == nil else {
            throw XCTSkip("Existing native-test records were preserved")
        }
        try WalletKeychain.save(JSONEncoder().encode(connection()), account: connectionKey)
    }
    private func clean() {
        try? WalletKeychain.delete(pendingKey); try? WalletKeychain.delete(connectionKey)
    }
    private func legacy(_ byte: String = "12") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["invoice":"synthetic-invoice", "hash":String(repeating: byte, count: 32)])
    }
    @MainActor func testLegacyReviewDoesNotClearOrSubmitAndMismatchDoesNotQuery() async throws {
        try prepare(); defer { clean() }
        try WalletKeychain.save(legacy(), account: pendingKey)
        let monitor = LightningPaymentMonitor(); monitor.load()
        let original = try XCTUnwrap(monitor.pending)
        // A requestStarted event would mean the policy boundary was crossed.
        let node = try LightningNode(connection: connection(), diagnostics: { event in
            if case .requestStarted = event { XCTFail("An unbound or mismatched record contacted a node") }
        })
        monitor.useNode(node, connection: connection())
        await monitor.checkNow()
        XCTAssertTrue(monitor.pending?.needsNodeReview == true)
        XCTAssertNil(monitor.lastChecked); XCTAssertFalse(monitor.missingOnNode)
        try monitor.assignOriginalNode(original, connection: connection())
        XCTAssertEqual(monitor.pending?.hash, original.hash)
        XCTAssertFalse(monitor.pending?.needsNodeReview ?? true)
        XCTAssertThrowsError(try monitor.clearMissingAttempt(hash: original.hash))
        var different = connection(); different.endpoint = "https://127.0.0.1:2"
        try WalletKeychain.save(JSONEncoder().encode(different), account: connectionKey)
        await monitor.checkNow()
        XCTAssertNotNil(monitor.pending); XCTAssertNil(monitor.lastChecked)
        XCTAssertFalse(monitor.missingOnNode)
        XCTAssertTrue(monitor.status.contains("original node"))
    }
    @MainActor func testStaleReviewCannotOverwriteChangedStoredAttempt() throws {
        try prepare(); defer { clean() }
        try WalletKeychain.save(legacy(), account: pendingKey)
        let monitor = LightningPaymentMonitor(); monitor.load()
        monitor.useNode(try LightningNode(connection: connection()), connection: connection())
        let reviewed = try XCTUnwrap(monitor.pending)
        let changed = try legacy("34")
        try WalletKeychain.save(changed, account: pendingKey)
        XCTAssertThrowsError(try monitor.assignOriginalNode(reviewed, connection: connection()))
        XCTAssertEqual(try WalletKeychain.read(pendingKey), changed)
    }
}
